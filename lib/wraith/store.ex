defmodule Wraith.Store do
  @moduledoc """
  The one table everything lives in.

  Every item is a map with string keys. Two are mandatory — `"pk"` and
  `"sk"` — and two are optional index keys, `"gsi1pk"`/`"gsi1sk"`, which
  put the item on the single global secondary index. Everything else is the
  entity's own business; `Wraith.Store.Keys` says what goes where.

  Adapters (`config :wraith, :store`):

    * `Wraith.Store.Memory` — ETS, for dev and tests
    * `Wraith.Store.Dynamo` — DynamoDB, deployed

  Writes are plain puts; `put/2` with `condition: :not_exists` is the
  uniqueness primitive (slugs, emails) and `condition: {:version, n}` the
  optimistic-concurrency one (`update/3` wraps it). `transact/1` applies a
  handful of puts and deletes atomically (DynamoDB `TransactWriteItems`).
  """

  @type item :: %{required(String.t()) => term()}
  @type key :: {String.t(), String.t()}
  @type op :: {:put, item()} | {:put, item(), keyword()} | {:delete, String.t(), String.t()}
  @type query_opt ::
          {:begins_with, String.t()}
          | {:between, {String.t(), String.t()}}
          | {:index, :gsi1}
          | {:limit, pos_integer()}
          | {:forward, boolean()}
          | {:start_key, term()}
  @type page :: %{items: [item()], next: term() | nil}

  @callback get(String.t(), String.t()) :: {:ok, item()} | :error
  @callback put(item(), keyword()) :: :ok | {:error, :exists | :conflict | term()}
  @callback delete(String.t(), String.t()) :: :ok
  @callback query(String.t(), [query_opt()]) :: {:ok, page()} | {:error, term()}
  @callback transact([op()]) :: :ok | {:error, term()}
  @callback batch_get([key()]) :: {:ok, [item()]} | {:error, term()}

  def impl, do: Application.get_env(:wraith, :store, __MODULE__.Memory)

  @spec get(String.t(), String.t()) :: {:ok, item()} | :error
  def get(pk, sk), do: impl().get(pk, sk)

  @spec put(item(), keyword()) :: :ok | {:error, term()}
  def put(item, opts \\ []) do
    item = stamp(item)
    impl().put(item, opts)
  end

  @spec delete(String.t(), String.t()) :: :ok
  def delete(pk, sk), do: impl().delete(pk, sk)

  @doc """
  Items under a partition key (or an index partition when `index: :gsi1`),
  sorted by sort key. `begins_with:` narrows the sort key, `forward: false`
  walks newest-first, `limit:` + the returned `next` page through.
  """
  @spec query(String.t(), [query_opt()]) :: {:ok, page()} | {:error, term()}
  def query(pk, opts \\ []), do: impl().query(pk, opts)

  @doc "Every item of a query, pages followed. Use with care."
  @spec all(String.t(), [query_opt()]) :: [item()]
  def all(pk, opts \\ []) do
    Stream.unfold(:start, fn
      nil ->
        nil

      cursor ->
        opts = if cursor == :start, do: opts, else: Keyword.put(opts, :start_key, cursor)
        {:ok, %{items: items, next: next}} = query(pk, opts)
        {items, next}
    end)
    |> Enum.concat()
  end

  @spec transact([op()]) :: :ok | {:error, term()}
  def transact(ops) do
    ops =
      Enum.map(ops, fn
        {:put, item} -> {:put, stamp(item), []}
        {:put, item, o} -> {:put, stamp(item), o}
        other -> other
      end)

    impl().transact(ops)
  end

  @spec batch_get([key()]) :: {:ok, [item()]} | {:error, term()}
  def batch_get([]), do: {:ok, []}
  def batch_get(keys), do: impl().batch_get(keys)

  @doc """
  Read-modify-write with optimistic concurrency. `fun` gets the current
  item (or `nil`) and returns the new one; a concurrent writer makes the
  put fail with `:conflict` and we try again, up to five times.
  """
  @spec update(String.t(), String.t(), (item() | nil -> item())) ::
          {:ok, item()} | {:error, term()}
  def update(pk, sk, fun, attempts \\ 5)

  def update(_pk, _sk, _fun, 0), do: {:error, :conflict}

  def update(pk, sk, fun, attempts) do
    {current, condition} =
      case get(pk, sk) do
        {:ok, %{"version" => v} = item} -> {item, {:version, v}}
        {:ok, item} -> {item, {:version, nil}}
        :error -> {nil, :not_exists}
      end

    next =
      fun.(current)
      |> Map.put("pk", pk)
      |> Map.put("sk", sk)
      |> Map.put("version", (current && current["version"]) || 0)

    case put(next, condition: condition) do
      :ok -> {:ok, stamp(next)}
      {:error, e} when e in [:conflict, :exists] -> update(pk, sk, fun, attempts - 1)
      error -> error
    end
  end

  # every write bumps `version` and `updated_at`; `created_at` is kept
  defp stamp(item) do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

    item
    |> Map.update("version", 1, &((&1 || 0) + 1))
    |> Map.put("updated_at", now)
    |> Map.put_new("created_at", now)
  end

  @doc """
  A fresh, sortable id: UUIDv7 as a lowercase hex string. Ids minted in the
  same millisecond by this node still sort in minting order (a 12-bit
  counter in `rand_a`, UUIDv7 "method 1").
  """
  def id do
    ms = System.system_time(:millisecond)
    <<rand_b::62, _::2>> = :crypto.strong_rand_bytes(8)
    # one 64-bit cell: the ms clock in the high bits, a 12-bit counter in the low
    clock = id_clock()
    prev = :atomics.get(clock, 1)
    {prev_ms, prev_c} = {Bitwise.bsr(prev, 12), Bitwise.band(prev, 4095)}
    counter = if prev_ms == ms and prev_c < 4095, do: prev_c + 1, else: 0
    :atomics.put(clock, 1, Bitwise.bor(Bitwise.bsl(ms, 12), counter))

    <<ms::48, 7::4, counter::12, 2::2, rand_b::62>>
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  defp id_clock do
    case :persistent_term.get({__MODULE__, :id_clock}, nil) do
      nil ->
        ref = :atomics.new(1, signed: false)
        :persistent_term.put({__MODULE__, :id_clock}, ref)
        ref

      ref ->
        ref
    end
  end

  defp format_uuid(<<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>>),
    do: Enum.join([a, b, c, d, e], "-")

  @doc "Milliseconds-precision ISO 8601 of now — the sort-key clock."
  def now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
