defmodule Wraith.Analytics do
  @moduledoc """
  Privacy-light analytics: no cookies, no IPs stored. A page view bumps two
  daily counters — the post's and the site's (`STATS#<yyyy-mm-dd>` /
  `POST#<id>` and `SITE`) — and a per-day set of visitor ids is kept (the
  anonymous visitor cookie's SHA-256, so "unique readers today" is a count,
  not a trail). Counts are batched in memory and flushed every few seconds
  so a busy page costs the store one write per post per flush.
  """
  use GenServer
  alias Wraith.Store

  @flush_ms 5_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Record a view of `post_id` (or nil for the home page) by `visitor`."
  def hit(post_id, visitor) do
    if Process.whereis(__MODULE__),
      do: GenServer.cast(__MODULE__, {:hit, post_id || "home", visitor})

    :ok
  end

  @doc "Write pending counts now (tests, shutdown)."
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc "Views per day for the last `days`, site-wide or for one post: `[%{day, views, uniques}]`."
  def series(days \\ 30, post_id \\ nil) do
    today = Date.utc_today()

    for i <- (days - 1)..0//-1 do
      day = Date.add(today, -i) |> Date.to_iso8601()
      {pk, sk} = key(day, post_id)

      case Store.get(pk, sk) do
        {:ok, item} ->
          %{day: day, views: item["views"] || 0, uniques: length(item["visitors"] || [])}

        :error ->
          %{day: day, views: 0, uniques: 0}
      end
    end
  end

  @doc "Top posts by views over the last `days`."
  def top_posts(days \\ 30, n \\ 10) do
    today = Date.utc_today()

    for i <- 0..(days - 1), reduce: %{} do
      acc ->
        day = Date.add(today, -i) |> Date.to_iso8601()

        Store.all("STATS#" <> day, begins_with: "POST#")
        |> Enum.reduce(acc, fn item, m ->
          Map.update(m, item["post_id"], item["views"] || 0, &(&1 + (item["views"] || 0)))
        end)
    end
    |> Enum.sort_by(&(-elem(&1, 1)))
    |> Enum.take(n)
  end

  @doc "Member sign-ups per day for the last `days`."
  def member_growth(days \\ 30) do
    since = Date.utc_today() |> Date.add(-(days - 1)) |> Date.to_iso8601()

    by_day =
      Wraith.Members.list(limit: 100_000).members
      |> Enum.map(&String.slice(&1["created_at"], 0, 10))
      |> Enum.filter(&(&1 >= since))
      |> Enum.frequencies()

    for i <- (days - 1)..0//-1,
        day = Date.utc_today() |> Date.add(-i) |> Date.to_iso8601(),
        do: %{day: day, members: by_day[day] || 0}
  end

  defp key(day, nil), do: {"STATS#" <> day, "SITE"}
  defp key(day, post_id), do: {"STATS#" <> day, "POST#" <> post_id}

  # ---- GenServer -----------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.send_after(self(), :flush, @flush_ms)
    {:ok, %{pending: %{}}}
  end

  @impl true
  def handle_cast({:hit, post_id, visitor}, state) do
    day = Date.utc_today() |> Date.to_iso8601()

    v =
      visitor &&
        :crypto.hash(:sha256, to_string(visitor))
        |> Base.url_encode64(padding: false)
        |> String.slice(0, 12)

    # a post view counts for the post and the site; a home view only for the site
    pending = state.pending |> bump({day, nil}, v)
    pending = if post_id == "home", do: pending, else: bump(pending, {day, post_id}, v)

    {:noreply, %{state | pending: pending}}
  end

  defp bump(pending, key, v) do
    Map.update(pending, key, {1, MapSet.new(List.wrap(v))}, fn {n, set} ->
      {n + 1, if(v, do: MapSet.put(set, v), else: set)}
    end)
  end

  @impl true
  def handle_call(:flush, _from, state) do
    write(state.pending)
    {:reply, :ok, %{state | pending: %{}}}
  end

  @impl true
  def handle_info(:flush, state) do
    write(state.pending)
    Process.send_after(self(), :flush, @flush_ms)
    {:noreply, %{state | pending: %{}}}
  end

  defp write(pending) do
    for {{day, post_id}, {n, visitors}} <- pending do
      {pk, sk} = key(day, post_id)

      Store.update(pk, sk, fn current ->
        current = current || %{"day" => day, "post_id" => post_id, "views" => 0, "visitors" => []}
        seen = MapSet.new(current["visitors"] || [])
        # cap the per-day visitor set so one popular day cannot grow an item without bound
        merged = MapSet.union(seen, visitors) |> Enum.take(5_000)
        current |> Map.put("views", (current["views"] || 0) + n) |> Map.put("visitors", merged)
      end)
    end

    :ok
  end
end
