defmodule Wraith.Store.SQL do
  @moduledoc """
  `Wraith.Store` on PostgreSQL or Aurora DSQL — the same single-table
  layout as DynamoDB, in one SQL table:

      items(pk text, sk text, gsi1pk text, gsi1sk text, version bigint, data text,
            primary key (pk, sk))
      index on (gsi1pk, gsi1sk, pk, sk)

  The whole item is JSON in `data` (both engines store it; DSQL cannot
  index json anyway and nothing queries inside it). Conditions map to
  `INSERT … ON CONFLICT DO NOTHING` (`:not_exists`) and
  `UPDATE … WHERE version = $n` (`{:version, n}`) with a row-count check;
  `transact/1` runs its ops in one transaction and rolls back at the first
  failed condition, so slugs and emails stay unique exactly as on DynamoDB.

  Config (`config :wraith, Wraith.Store.SQL`):

    * `:dialect` — `:postgres` (default) or `:dsql`
    * `:url` — `postgres://user:pass@host/db` (Postgres)
    * `:hostname`, `:username`, `:database`, `:port`, `:ssl` — or spelled out
    * `:table` — default `"items"`
    * `:pool_size` — default 10
    * DSQL: `:hostname` is the cluster endpoint, the password is an IAM
      token minted per connection (`dsql:DbConnectAdmin`, through ex_aws's
      credential chain), `ssl` is on, the database is `postgres`.

  DSQL rules honoured: the index is created `ASYNC`, DDL is one statement
  per transaction, a transaction mutates ≤ 3,000 rows (`transact/1` is a
  handful), and a `40001` serialization failure is retried a few times
  (DSQL has no locks; `Wraith.Store.update/3` retries on `:conflict` too).
  """
  @behaviour Wraith.Store

  @pool __MODULE__.Pool
  @retries 3

  # ---- supervision -----------------------------------------------------------------

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :supervisor}
  end

  def start_link do
    cfg = config()

    opts =
      [
        name: @pool,
        pool_size: cfg[:pool_size] || 10,
        hostname: cfg[:hostname],
        port: cfg[:port] || 5432,
        username: cfg[:username],
        database: cfg[:database],
        parameters: [application_name: "wraith"],
        # DSQL commits conflicting writes as 40001; Postgres rarely. Both are retried here.
        queue_target: 500,
        queue_interval: 1_000
      ]
      |> Keyword.merge(auth(cfg))

    Postgrex.start_link(opts)
  end

  # Postgres: a static password. DSQL: a fresh IAM token for every connection
  # (tokens live 15 min; Postgrex calls the function each time it connects).
  defp auth(%{dialect: :dsql} = cfg) do
    region = cfg[:region] || "eu-central-1"
    host = cfg[:hostname]

    [
      password: fn -> Wraith.Store.SQL.Token.generate!(host, region) end,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(host)
      ]
    ]
  end

  defp auth(cfg) do
    ssl =
      case cfg[:ssl] do
        true -> [ssl: [verify: :verify_none]]
        _ -> []
      end

    [password: cfg[:password] || ""] ++ ssl
  end

  @doc "The resolved config: `:url` is split into its parts; `:dialect` defaults to `:postgres`."
  def config do
    cfg = Application.get_env(:wraith, __MODULE__, []) |> Map.new()

    from_url =
      case cfg[:url] do
        nil ->
          %{}

        url ->
          uri = URI.parse(url)

          if uri.host in [nil, ""],
            do:
              raise(
                ArgumentError,
                "Wraith.Store.SQL :url must look like postgres://user:pass@host:5432/db, got #{inspect(url)}"
              )

          {user, pass} =
            case String.split(uri.userinfo || "", ":", parts: 2) do
              [u, p] -> {URI.decode(u), URI.decode(p)}
              [u] -> {URI.decode(u), nil}
            end

          %{
            hostname: uri.host,
            port: uri.port || 5432,
            username: user,
            password: pass,
            database: String.trim_leading(uri.path || "/wraith", "/")
          }
      end

    Map.merge(
      %{dialect: :postgres, table: "items", database: "postgres", username: "postgres"},
      Map.merge(from_url, Map.delete(cfg, :url))
    )
  end

  def table, do: config().table
  def dialect, do: config().dialect

  # ---- Store -----------------------------------------------------------------------

  @impl Wraith.Store
  def get(pk, sk) do
    case q!("SELECT data FROM #{table()} WHERE pk = $1 AND sk = $2", [pk, sk]) do
      %{rows: [[data]]} -> {:ok, decode(data)}
      _ -> :error
    end
  end

  @impl Wraith.Store
  def put(item, opts) do
    with_retry(fn conn -> do_put(conn, item, opts) end)
  end

  @impl Wraith.Store
  def delete(pk, sk) do
    q!("DELETE FROM #{table()} WHERE pk = $1 AND sk = $2", [pk, sk])
    :ok
  end

  @impl Wraith.Store
  def transact(ops) do
    with_retry(fn conn ->
      Postgrex.transaction(conn, fn tx ->
        Enum.each(ops, fn
          {:put, item, o} ->
            case do_put(tx, item, o) do
              :ok -> :ok
              {:error, why} -> Postgrex.rollback(tx, why)
            end

          {:delete, pk, sk} ->
            Postgrex.query!(tx, "DELETE FROM #{table()} WHERE pk = $1 AND sk = $2", [pk, sk])
        end)

        :ok
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, why} -> {:error, why}
      end
    end)
  end

  @impl Wraith.Store
  def batch_get(keys) do
    # one query per 100 keys: a tuple list in VALUES, joined
    keys
    |> Enum.chunk_every(100)
    |> Enum.flat_map(fn chunk ->
      {placeholders, params, _} =
        Enum.reduce(chunk, {[], [], 1}, fn {pk, sk}, {ph, ps, i} ->
          {["($#{i}, $#{i + 1})" | ph], ps ++ [pk, sk], i + 2}
        end)

      sql =
        "SELECT t.data FROM #{table()} t JOIN (VALUES #{Enum.join(Enum.reverse(placeholders), ", ")}) AS k(pk, sk) ON k.pk = t.pk AND k.sk = t.sk"

      q!(sql, params).rows |> Enum.map(fn [d] -> decode(d) end)
    end)
    |> then(&{:ok, &1})
  end

  @impl Wraith.Store
  def query(pk, opts) do
    index? = Keyword.get(opts, :index) == :gsi1
    {pk_col, sk_col} = if index?, do: {"gsi1pk", "gsi1sk"}, else: {"pk", "sk"}
    forward? = Keyword.get(opts, :forward, true)
    limit = Keyword.get(opts, :limit, 1_000)
    dir = if forward?, do: "ASC", else: "DESC"
    cmp = if forward?, do: ">", else: "<"

    {where, params} = {["#{pk_col} = $1"], [pk]}

    {where, params} =
      cond do
        prefix = opts[:begins_with] ->
          {where ++ ["left(#{sk_col}, $2) = $3"], params ++ [String.length(prefix), prefix]}

        range = opts[:between] ->
          {lo, hi} = range
          {where ++ ["#{sk_col} BETWEEN $2 AND $3"], params ++ [lo, hi]}

        true ->
          {where, params}
      end

    # the cursor is the last row's (sort, pk, sk); the order is total so it resumes exactly
    {where, params} =
      case opts[:start_key] do
        {s, cpk, csk} ->
          n = length(params)

          clause =
            "(#{sk_col} #{cmp} $#{n + 1} OR (#{sk_col} = $#{n + 1} AND pk #{cmp} $#{n + 2}) " <>
              "OR (#{sk_col} = $#{n + 1} AND pk = $#{n + 2} AND sk #{cmp} $#{n + 3}))"

          {where ++ [clause], params ++ [s, cpk, csk]}

        _ ->
          {where, params}
      end

    sql =
      "SELECT #{sk_col}, pk, sk, data FROM #{table()} WHERE #{Enum.join(where, " AND ")} " <>
        "ORDER BY #{sk_col} #{dir}, pk #{dir}, sk #{dir} LIMIT #{limit + 1}"

    rows = q!(sql, params).rows
    page = Enum.take(rows, limit)
    items = Enum.map(page, fn [_, _, _, d] -> decode(d) end)

    next =
      if length(rows) > limit do
        [s, cpk, csk, _] = List.last(page)
        {s, cpk, csk}
      end

    {:ok, %{items: items, next: next}}
  end

  @impl true
  def cursor(item, true), do: {item["gsi1sk"], item["pk"], item["sk"]}
  def cursor(item, false), do: {item["sk"], item["pk"], item["sk"]}

  # ---- writes --------------------------------------------------------------------

  defp do_put(conn, %{"pk" => pk, "sk" => sk} = item, opts) do
    data = Jason.encode!(item)
    gpk = item["gsi1pk"]
    gsk = item["gsi1sk"]
    version = item["version"]
    t = table()

    result =
      case Keyword.get(opts, :condition) do
        nil ->
          Postgrex.query(
            conn,
            "INSERT INTO #{t} (pk, sk, gsi1pk, gsi1sk, version, data) VALUES ($1, $2, $3, $4, $5, $6) " <>
              "ON CONFLICT (pk, sk) DO UPDATE SET gsi1pk = EXCLUDED.gsi1pk, gsi1sk = EXCLUDED.gsi1sk, version = EXCLUDED.version, data = EXCLUDED.data",
            [pk, sk, gpk, gsk, version, data]
          )

        :not_exists ->
          Postgrex.query(
            conn,
            "INSERT INTO #{t} (pk, sk, gsi1pk, gsi1sk, version, data) VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (pk, sk) DO NOTHING",
            [pk, sk, gpk, gsk, version, data]
          )

        :exists ->
          Postgrex.query(
            conn,
            "UPDATE #{t} SET gsi1pk = $3, gsi1sk = $4, version = $5, data = $6 WHERE pk = $1 AND sk = $2",
            [pk, sk, gpk, gsk, version, data]
          )

        {:version, nil} ->
          Postgrex.query(
            conn,
            "UPDATE #{t} SET gsi1pk = $3, gsi1sk = $4, version = $5, data = $6 WHERE pk = $1 AND sk = $2 AND version IS NULL",
            [pk, sk, gpk, gsk, version, data]
          )

        {:version, v} ->
          Postgrex.query(
            conn,
            "UPDATE #{t} SET gsi1pk = $3, gsi1sk = $4, version = $5, data = $6 WHERE pk = $1 AND sk = $2 AND version = $7",
            [pk, sk, gpk, gsk, version, data, v]
          )
      end

    case result do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        {:error, if(Keyword.get(opts, :condition) == :not_exists, do: :exists, else: :conflict)}

      {:error, e} ->
        {:error, e}
    end
  end

  # DSQL reports a write-write conflict as 40001 at commit; try again
  defp with_retry(fun, attempt \\ 1) do
    case fun.(@pool) do
      {:error, %Postgrex.Error{postgres: %{code: :serialization_failure}}}
      when attempt < @retries ->
        Process.sleep(20 * attempt)
        with_retry(fun, attempt + 1)

      other ->
        other
    end
  end

  defp q!(sql, params), do: Postgrex.query!(@pool, sql, params)

  defp decode(data) when is_binary(data), do: Jason.decode!(data)

  # ---- table bootstrap -----------------------------------------------------------

  @doc "Create the table and its index unless they exist. One DDL statement per transaction (DSQL)."
  def ensure_table! do
    t = table()

    existed? =
      q!("SELECT 1 FROM information_schema.tables WHERE table_name = $1", [t]).num_rows > 0

    q!(
      "CREATE TABLE IF NOT EXISTS #{t} (pk text NOT NULL, sk text NOT NULL, gsi1pk text, gsi1sk text, version bigint, data text NOT NULL, PRIMARY KEY (pk, sk))",
      []
    )

    async = if dialect() == :dsql, do: "ASYNC ", else: ""
    q!("CREATE INDEX #{async}IF NOT EXISTS #{t}_gsi1 ON #{t} (gsi1pk, gsi1sk, pk, sk)", [])

    if existed?, do: :exists, else: :created
  end
end
