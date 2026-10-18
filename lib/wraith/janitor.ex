defmodule Wraith.Janitor do
  @moduledoc """
  Housekeeping once an hour: expired author and member sessions are deleted
  (they sit on the `SESSIONS` index sorted by expiry, so one range query
  finds them). On DynamoDB the table's TTL on `ttl` does the same on its
  own; this keeps SQL and the memory store honest too. Not started in tests;
  `sweep/0` runs one pass.
  """
  use GenServer
  require Logger
  alias Wraith.Store
  alias Wraith.Store.Keys

  @every_ms 60 * 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Delete every session whose expiry is in the past. Returns how many."
  def sweep do
    now = Store.now()

    Store.all(Keys.sessions_index(), index: :gsi1, between: {"0", now <> "#~"})
    |> Enum.filter(&(&1["expires_at"] < now))
    |> Enum.map(fn s -> Store.delete(s["pk"], s["sk"]) end)
    |> length()
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, 30_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      case sweep() do
        0 -> :ok
        n -> Logger.info("janitor: dropped #{n} expired session(s)")
      end
    rescue
      e -> Logger.warning("janitor: #{Exception.message(e)}")
    end

    Process.send_after(self(), :tick, @every_ms)
    {:noreply, state}
  end
end
