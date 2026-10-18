defmodule Wraith.RateLimit do
  @moduledoc """
  A small token bucket in ETS. `check(scope, key, limit, per_ms)` lets
  `limit` hits through per `per_ms` window for one `key` (an IP, a visitor
  id, an email) and answers `:ok` or `{:error, retry_after_ms}`. Fixed
  windows, one row per (scope, key); a sweep every minute drops stale rows.

  Scopes and their defaults (`limits/0`) are what the plugs and LiveViews
  use; tests may relax them with `config :wraith, :rate_limits`.
  """
  use GenServer

  @table :wraith_rate_limit

  @defaults %{
    # {hits, window ms}
    login: {5, 60_000},
    magic_link: {3, 15 * 60_000},
    subscribe: {5, 60 * 60_000},
    comment: {10, 60_000},
    widget_event: {60, 60_000},
    api: {300, 60_000},
    api_auth_fail: {20, 60_000},
    forgot: {3, 15 * 60_000}
  }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def limits, do: Map.merge(@defaults, Application.get_env(:wraith, :rate_limits, %{}))

  @spec check(atom(), term()) :: :ok | {:error, non_neg_integer()}
  def check(scope, key) do
    {limit, per_ms} = Map.fetch!(limits(), scope)
    check(scope, key, limit, per_ms)
  end

  @spec check(atom(), term(), pos_integer(), pos_integer()) :: :ok | {:error, non_neg_integer()}
  def check(scope, key, limit, per_ms) do
    if :ets.whereis(@table) == :undefined, do: raise("Wraith.RateLimit is not started")
    now = System.monotonic_time(:millisecond)
    row = {scope, key}

    case :ets.lookup(@table, row) do
      [{^row, window_start, count}] when now - window_start < per_ms ->
        if count < limit do
          :ets.update_counter(@table, row, {3, 1})
          :ok
        else
          {:error, per_ms - (now - window_start)}
        end

      _ ->
        :ets.insert(@table, {row, now, 1})
        :ok
    end
  end

  @doc "Forget a key (tests, or after a successful login)."
  def reset(scope, key), do: :ets.delete(@table, {scope, key})
  def reset_all, do: :ets.delete_all_objects(@table)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :named_table, :public, write_concurrency: true])
    Process.send_after(self(), :sweep, 60_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    longest = limits() |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.max()
    :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:<, :"$1", now - longest}], [true]}])
    Process.send_after(self(), :sweep, 60_000)
    {:noreply, state}
  end
end
