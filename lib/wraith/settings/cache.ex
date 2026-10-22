defmodule Wraith.Settings.Cache do
  @moduledoc """
  The site item, read once instead of on every plug and mount.

  `Wraith.Settings.get/0` is called several times per request (redirects,
  locale, the page's own mount, feeds); on DynamoDB each call was a network
  round trip for a map that changes when an admin saves the settings form.

  One ETS row, owned by this process, holds the merged item with the time it
  was read. Writes go through `Wraith.Settings.write/1`, which `put/1`s the
  fresh item here **and** broadcasts it on PubSub so every clustered node
  swaps its copy at once. Nodes that aren't clustered still converge: a row
  older than `@ttl_ms` is re-read from the store.
  """
  use GenServer

  @table :wraith_settings_cache
  @topic "settings"
  @ttl_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "The cached item, or `loader.()` (cached for the next caller) when stale or missing."
  @spec fetch((-> map())) :: map()
  def fetch(loader) when is_function(loader, 0) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, :site) do
      [{:site, item, read_at}] when now - read_at < @ttl_ms ->
        item

      _ ->
        item = loader.()
        :ets.insert(@table, {:site, item, now})
        item
    end
  rescue
    # the table isn't up yet (boot order) — serve from the store, no cache
    ArgumentError -> loader.()
  end

  @doc "A freshly written item: cache it here and on every other node."
  @spec put(map()) :: :ok
  def put(item) when is_map(item) do
    insert(item)
    Phoenix.PubSub.broadcast(Wraith.PubSub, @topic, {:settings_cache, :put, item})
  end

  @doc "Forget the cached item (tests, and after writes that bypass `Settings`)."
  @spec invalidate() :: :ok
  def invalidate do
    :ets.delete(@table, :site)
    Phoenix.PubSub.broadcast(Wraith.PubSub, @topic, {:settings_cache, :invalidate})
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Wraith.PubSub, @topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:settings_cache, :put, item}, state) do
    insert(item)
    {:noreply, state}
  end

  def handle_info({:settings_cache, :invalidate}, state) do
    :ets.delete(@table, :site)
    {:noreply, state}
  end

  defp insert(item), do: :ets.insert(@table, {:site, item, System.monotonic_time(:millisecond)})
end
