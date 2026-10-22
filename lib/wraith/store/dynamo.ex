defmodule Wraith.Store.Dynamo do
  @moduledoc """
  `Wraith.Store` on DynamoDB (ex_aws over Req). One table, keys `pk`/`sk`,
  one GSI `gsi1` on `gsi1pk`/`gsi1sk`, on-demand capacity.

  `config :wraith, Wraith.Store.Dynamo, table: "wraith"`; credentials and
  endpoint come from `:ex_aws` (see `config/runtime.exs`, `DYNAMO_ENDPOINT`
  for DynamoDB Local). `ensure_table!/0` creates the table when it is
  missing (`mix wraith.table`).
  """
  @behaviour Wraith.Store
  require Logger
  alias ExAws.Dynamo

  def table, do: Application.fetch_env!(:wraith, __MODULE__)[:table]

  @impl Wraith.Store
  def get(pk, sk) do
    case Dynamo.get_item(table(), %{pk: pk, sk: sk}, consistent_read: true) |> ExAws.request() do
      {:ok, %{"Item" => item}} when map_size(item) > 0 -> {:ok, decode(item)}
      {:ok, _} -> :error
      {:error, reason} -> raise "dynamo get #{pk}/#{sk}: #{inspect(reason)}"
    end
  end

  @impl Wraith.Store
  def put(item, opts) do
    table()
    |> Dynamo.put_item(item, condition(opts))
    |> ExAws.request()
    |> case do
      {:ok, _} -> :ok
      {:error, {"ConditionalCheckFailedException", _}} -> {:error, failed(opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Wraith.Store
  def delete(pk, sk) do
    {:ok, _} = Dynamo.delete_item(table(), %{pk: pk, sk: sk}) |> ExAws.request()
    :ok
  end

  @impl Wraith.Store
  def transact(ops) do
    items =
      Enum.map(ops, fn
        {:put, item, o} -> {:put, {table(), item, condition(o)}}
        {:delete, pk, sk} -> {:delete, {table(), %{pk: pk, sk: sk}, []}}
      end)

    case Dynamo.transact_write_items(items) |> ExAws.request() do
      {:ok, _} ->
        :ok

      {:error, {"TransactionCanceledException", msg, reasons}} ->
        transaction_error(ops, msg, reasons)

      {:error, {"TransactionCanceledException", msg}} ->
        if String.contains?(msg, "ConditionalCheckFailed"),
          do: {:error, :conflict},
          else: {:error, msg}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Wraith.Store
  def batch_get(keys) do
    keys
    |> Enum.chunk_every(100)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case batch_get_chunk(Enum.map(chunk, fn {pk, sk} -> %{pk: pk, sk: sk} end), [], 0) do
        {:ok, items} -> {:cont, {:ok, [items | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  # DynamoDB may return part of a batch and list the rest under UnprocessedKeys
  # (throttling, size); dropping them silently loses posts from tag/author
  # pages. Re-request with backoff, a few times.
  defp batch_get_chunk([], acc, _attempt), do: {:ok, acc}
  defp batch_get_chunk(_keys, acc, attempt) when attempt >= 5, do: {:ok, acc}

  defp batch_get_chunk(keys, acc, attempt) do
    if attempt > 0, do: Process.sleep(50 * Integer.pow(2, attempt - 1))

    case Dynamo.batch_get_item(%{table() => [keys: keys]}) |> ExAws.request() do
      {:ok, %{"Responses" => resp} = body} ->
        items = resp |> Map.get(table(), []) |> Enum.map(&decode/1)
        left = get_in(body, ["UnprocessedKeys", table(), "Keys"]) || []
        batch_get_chunk(Enum.map(left, &decode_key/1), acc ++ items, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_key(raw),
    do:
      raw
      |> decode()
      |> Map.take(["pk", "sk"])
      |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)

  # the key condition shared by query/2 and count/2
  defp key_condition(pk, opts) do
    index? = Keyword.get(opts, :index) == :gsi1
    {pk_name, sk_name} = if index?, do: {"gsi1pk", "gsi1sk"}, else: {"pk", "sk"}

    {cond_expr, values, names} =
      cond do
        prefix = opts[:begins_with] ->
          {"#pk = :pk AND begins_with(#sk, :prefix)", %{pk: pk, prefix: prefix},
           %{"#pk" => pk_name, "#sk" => sk_name}}

        range = opts[:between] ->
          {lo, hi} = range

          {"#pk = :pk AND #sk BETWEEN :lo AND :hi", %{pk: pk, lo: lo, hi: hi},
           %{"#pk" => pk_name, "#sk" => sk_name}}

        true ->
          {"#pk = :pk", %{pk: pk}, %{"#pk" => pk_name}}
      end

    [
      key_condition_expression: cond_expr,
      expression_attribute_names: names,
      expression_attribute_values: values
    ]
    |> then(fn p -> if index?, do: [{:index_name, "gsi1"} | p], else: p end)
  end

  @impl Wraith.Store
  def count(pk, opts), do: count_pages(key_condition(pk, opts) ++ [select: :count], nil, 0)

  # COUNT still pages at 1 MB of *read* items; follow LastEvaluatedKey
  defp count_pages(params, start, acc) do
    params_now = if start, do: [{:exclusive_start_key, start} | params], else: params

    case Dynamo.query(table(), params_now) |> ExAws.request() do
      {:ok, %{"Count" => n} = r} ->
        case r["LastEvaluatedKey"] do
          nil -> {:ok, acc + n}
          lek -> count_pages(params, decode(lek), acc + n)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Wraith.Store
  def query(pk, opts) do
    index? = Keyword.get(opts, :index) == :gsi1

    params =
      (key_condition(pk, opts) ++
         [
           scan_index_forward: Keyword.get(opts, :forward, true),
           # one more than asked: whether a next page exists is then a fact, not
           # DynamoDB's LastEvaluatedKey, which it also returns on the last full page
           limit: Keyword.get(opts, :limit, 1_000) + 1
         ])
      |> then(fn p ->
        case opts[:start_key] do
          nil -> p
          key -> [{:exclusive_start_key, key} | p]
        end
      end)

    limit = Keyword.get(opts, :limit, 1_000)

    case Dynamo.query(table(), params) |> ExAws.request() do
      {:ok, %{"Items" => raw}} ->
        items = Enum.map(raw, &decode/1)
        page = Enum.take(items, limit)

        # the cursor is the last item's key attributes — the same shape the
        # Memory and SQL adapters produce, so pagination behaves identically
        next =
          if length(items) > limit,
            do: page |> List.last() |> cursor(index?),
            else: nil

        {:ok, %{items: page, next: next}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # the cancelled op tells us which kind of condition failed: `:exists` for a
  # `not_exists` put (a taken slug), `:conflict` otherwise
  defp transaction_error(ops, msg, reasons) do
    failed =
      reasons
      |> Enum.with_index()
      |> Enum.find(fn {r, _} -> r["Code"] == "ConditionalCheckFailed" end)

    case failed do
      {_, i} ->
        case Enum.at(ops, i) do
          {:put, _, o} -> {:error, failed(o)}
          _ -> {:error, :conflict}
        end

      nil ->
        {:error, msg}
    end
  end

  # ExclusiveStartKey needs every key attribute of the index being queried
  @impl true
  def cursor(item, true), do: Map.take(item, ["pk", "sk", "gsi1pk", "gsi1sk"])
  def cursor(item, false), do: Map.take(item, ["pk", "sk"])

  # an item is a map of typed values; the Decoder knows it as an `M`
  @doc false
  def decode(item) when is_map(item), do: Dynamo.Decoder.decode(%{"M" => item})

  # ---- conditions ----------------------------------------------------------------

  defp condition(opts) do
    case Keyword.get(opts, :condition) do
      nil ->
        []

      :not_exists ->
        [condition_expression: "attribute_not_exists(pk)"]

      :exists ->
        [condition_expression: "attribute_exists(pk)"]

      {:version, nil} ->
        [condition_expression: "attribute_exists(pk) AND attribute_not_exists(version)"]

      {:version, v} ->
        [
          condition_expression: "version = :v",
          expression_attribute_values: %{v: v}
        ]
    end
  end

  defp failed(opts) do
    case Keyword.get(opts, :condition) do
      :not_exists -> :exists
      _ -> :conflict
    end
  end

  # ---- table bootstrap ----------------------------------------------------------

  @doc "Create the table (on-demand, with `gsi1`) unless it exists. Blocks until ACTIVE."
  def ensure_table! do
    case Dynamo.describe_table(table()) |> ExAws.request() do
      {:ok, %{"Table" => _}} ->
        enable_ttl()
        :exists

      {:error, {"ResourceNotFoundException", _}} ->
        {:ok, _} =
          table()
          |> Dynamo.create_table(
            [pk: :hash, sk: :range],
            [pk: :string, sk: :string, gsi1pk: :string, gsi1sk: :string],
            nil,
            nil,
            [
              %{
                index_name: "gsi1",
                key_schema: [
                  %{attribute_name: "gsi1pk", key_type: "HASH"},
                  %{attribute_name: "gsi1sk", key_type: "RANGE"}
                ],
                projection: %{projection_type: "ALL"}
              }
            ],
            [],
            :pay_per_request
          )
          |> ExAws.request()

        wait_active(30)
        enable_ttl()
        :created
    end
  end

  # expired sessions carry a unix `ttl`; the table drops them on its own
  defp enable_ttl do
    case Dynamo.update_time_to_live(table(), "ttl", true) |> ExAws.request() do
      {:ok, _} ->
        :ok

      # DynamoDB Local does not implement TTL updates on every version; nothing to do
      {:error, reason} ->
        Logger.info("dynamo: could not enable TTL on #{table()}: #{inspect(reason)}")
    end
  end

  defp wait_active(0), do: raise("table #{table()} did not become ACTIVE")

  defp wait_active(n) do
    case Dynamo.describe_table(table()) |> ExAws.request() do
      {:ok, %{"Table" => %{"TableStatus" => "ACTIVE"}}} ->
        :ok

      _ ->
        Process.sleep(1_000)
        wait_active(n - 1)
    end
  end
end
