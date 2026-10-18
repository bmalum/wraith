defmodule Wraith.Clock do
  @moduledoc "Once a minute: publish scheduled posts whose time has come. Not started in tests."
  use GenServer
  require Logger

  @every_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, 5_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      case Wraith.Content.publish_due() do
        0 -> :ok
        n -> Logger.info("clock: published #{n} scheduled post(s)")
      end
    rescue
      e -> Logger.warning("clock: #{Exception.message(e)}")
    end

    Process.send_after(self(), :tick, @every_ms)
    {:noreply, state}
  end
end
