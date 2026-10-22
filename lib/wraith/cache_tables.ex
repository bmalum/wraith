defmodule Wraith.CacheTables do
  @moduledoc """
  Owns the node-local ETS caches that have no process of their own:
  bookmark-card metadata (`Wraith.Embed`) and widget fetches
  (`Wraith.Widgets.Fetch`).

  An ETS table dies with the process that created it. Created lazily, these
  belonged to whichever process touched them first — usually a reader's
  LiveView — and vanished (taking in-flight inserts down with them) when that
  reader left. Here they live as long as the application.
  """
  use GenServer

  @tables [:wraith_embed_cache, :wraith_widget_fetch]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    for t <- @tables, do: :ets.new(t, [:set, :named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
