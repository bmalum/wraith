defmodule Wraith.Store.Memory do
  @moduledoc """
  `Wraith.Store` in ETS: two ordered sets — the table (`{pk, sk}`) and
  the index (`{gsi1pk, gsi1sk, pk, sk}`). Reads go straight to ETS;
  writes go through one GenServer so conditions and transactions are
  atomic. Nothing persists past the VM. `reset/0` empties it (tests).
  """
  @behaviour Wraith.Store
  use GenServer

  @table :wraith_store
  @index :wraith_store_gsi1

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl Wraith.Store
  def get(pk, sk) do
    case :ets.lookup(@table, {pk, sk}) do
      [{_, item}] -> {:ok, item}
      [] -> :error
    end
  end

  @impl Wraith.Store
  def put(item, opts), do: GenServer.call(__MODULE__, {:put, item, opts})

  @impl Wraith.Store
  def delete(pk, sk), do: GenServer.call(__MODULE__, {:delete, pk, sk})

  @impl Wraith.Store
  def transact(ops), do: GenServer.call(__MODULE__, {:transact, ops})

  @impl Wraith.Store
  def batch_get(keys) do
    {:ok,
     keys
     |> Enum.map(fn {pk, sk} -> get(pk, sk) end)
     |> Enum.flat_map(fn
       {:ok, item} -> [item]
       :error -> []
     end)}
  end

  @impl Wraith.Store
  def query(pk, opts) do
    limit = Keyword.get(opts, :limit, 1_000)
    forward = Keyword.get(opts, :forward, true)
    index? = Keyword.get(opts, :index) == :gsi1

    items =
      if index?, do: index_items(pk), else: table_items(pk)

    items =
      items
      |> Enum.filter(&sk_match?(sort_key(&1, index?), opts))
      |> Enum.sort_by(&{sort_key(&1, index?), &1["pk"], &1["sk"]})

    items = if forward, do: items, else: Enum.reverse(items)

    items =
      case Keyword.get(opts, :start_key) do
        nil -> items
        key -> items |> Enum.drop_while(&(cursor(&1, index?) != key)) |> Enum.drop(1)
      end

    page = Enum.take(items, limit)
    next = if length(items) > limit, do: cursor(List.last(page), index?), else: nil
    {:ok, %{items: page, next: next}}
  end

  defp cursor(item, true), do: {item["gsi1sk"], item["pk"], item["sk"]}
  defp cursor(item, false), do: {item["sk"], item["pk"], item["sk"]}

  defp sort_key(item, true), do: item["gsi1sk"]
  defp sort_key(item, false), do: item["sk"]

  defp table_items(pk) do
    :ets.select(@table, [{{{pk, :_}, :"$1"}, [], [:"$1"]}])
  end

  defp index_items(pk) do
    :ets.select(@index, [{{{pk, :_, :_, :_}, :"$1"}, [], [:"$1"]}])
    |> Enum.flat_map(fn {tpk, tsk} ->
      case get(tpk, tsk) do
        {:ok, item} -> [item]
        :error -> []
      end
    end)
  end

  defp sk_match?(sk, opts) do
    cond do
      prefix = opts[:begins_with] ->
        is_binary(sk) and String.starts_with?(sk, prefix)

      range = opts[:between] ->
        {lo, hi} = range
        is_binary(sk) and sk >= lo and sk <= hi

      true ->
        true
    end
  end

  # ---- GenServer -----------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:ordered_set, :named_table, :public, read_concurrency: true])
    :ets.new(@index, [:ordered_set, :named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@index)
    {:reply, :ok, state}
  end

  def handle_call({:put, item, opts}, _from, state) do
    {:reply, do_put(item, opts), state}
  end

  def handle_call({:delete, pk, sk}, _from, state) do
    do_delete(pk, sk)
    {:reply, :ok, state}
  end

  def handle_call({:transact, ops}, _from, state) do
    # check every condition first, then apply: all or nothing
    checks =
      Enum.map(ops, fn
        {:put, item, o} -> check(item, o)
        {:delete, _, _} -> :ok
      end)

    case Enum.find(checks, &(&1 != :ok)) do
      nil ->
        Enum.each(ops, fn
          {:put, item, _} -> write(item)
          {:delete, pk, sk} -> do_delete(pk, sk)
        end)

        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  defp do_put(item, opts) do
    case check(item, opts) do
      :ok -> write(item)
      error -> error
    end
  end

  defp check(%{"pk" => pk, "sk" => sk}, opts) do
    current = :ets.lookup(@table, {pk, sk})

    case Keyword.get(opts, :condition) do
      nil ->
        :ok

      :not_exists ->
        if current == [], do: :ok, else: {:error, :exists}

      :exists ->
        if current == [], do: {:error, :conflict}, else: :ok

      {:version, nil} ->
        if current == [], do: {:error, :conflict}, else: :ok

      {:version, v} ->
        case current do
          [{_, %{"version" => ^v}}] -> :ok
          _ -> {:error, :conflict}
        end
    end
  end

  defp write(%{"pk" => pk, "sk" => sk} = item) do
    do_delete(pk, sk)
    :ets.insert(@table, {{pk, sk}, item})

    case item do
      %{"gsi1pk" => gpk, "gsi1sk" => gsk} when is_binary(gpk) and is_binary(gsk) ->
        :ets.insert(@index, {{gpk, gsk, pk, sk}, {pk, sk}})

      _ ->
        :ok
    end

    :ok
  end

  defp do_delete(pk, sk) do
    case :ets.lookup(@table, {pk, sk}) do
      [{_, %{"gsi1pk" => gpk, "gsi1sk" => gsk}}] -> :ets.delete(@index, {gpk, gsk, pk, sk})
      _ -> :ok
    end

    :ets.delete(@table, {pk, sk})
  end
end
