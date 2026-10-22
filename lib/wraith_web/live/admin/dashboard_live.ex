defmodule WraithWeb.Admin.DashboardLive do
  @moduledoc "The admin's front door: counts, recent drafts, what to do next."
  use WraithWeb, :live_view

  alias Wraith.{Analytics, Audit, Content, Members, Widgets}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Content.subscribe()
    {:ok, load(assign(socket, page_title: "Dashboard"))}
  end

  defp load(socket) do
    assign(socket,
      published: Content.count_posts("published"),
      drafts: Content.count_posts("draft"),
      scheduled: Content.count_posts("scheduled"),
      members: Members.count(),
      widgets: Widgets.list() |> length(),
      recent: Content.list_all_posts() |> Enum.take(8),
      views: Analytics.series(14),
      top:
        Analytics.top_posts(30, 5)
        |> Enum.map(fn {id, n} -> {Content.get_post(id), n} end)
        |> Enum.reject(&is_nil(elem(&1, 0))),
      growth: Analytics.member_growth(14),
      audit: Audit.recent(12)
    )
  end

  @impl true
  def handle_info({:content, _, _}, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} active={:dashboard} title="Dashboard">
      <:actions>
        <.link href={~p"/admin/posts/new"} method="post" class="btn-accent"><.icon
          name="hero-plus"
          class="size-4"
        /> New post</.link>
      </:actions>

      <div class="kpi-grid">
        <.stat label="Published" value={@published} to={~p"/admin/posts"} />
        <.stat label="Drafts" value={@drafts} to={~p"/admin/posts?status=draft"} />
        <.stat label="Scheduled" value={@scheduled} to={~p"/admin/posts?status=scheduled"} />
        <.stat label="Members" value={@members} to={~p"/admin/members"} />
        <.stat label="Widgets" value={@widgets} to={~p"/admin/widgets"} />
      </div>

      <div class="two-col">
        <section class="panel">
          <header class="panel-head">
            <h2>Readers, last 14 days</h2>
          </header>
          <.spark series={Enum.map(@views, & &1.views)} labels={Enum.map(@views, & &1.day)} />
          <dl class="kv">
            <dt>Views</dt><dd>{Enum.sum(Enum.map(@views, & &1.views))}</dd>
            <dt>Unique today</dt><dd>{List.last(@views).uniques}</dd>
            <dt>New members</dt><dd>{Enum.sum(Enum.map(@growth, & &1.members))}</dd>
          </dl>
          <ul :if={@top != []} class="row-list">
            <li :for={{p, n} <- @top} class="row is-compact">
              <.link navigate={~p"/admin/posts/#{p["id"]}"} class="row-main"><span class="row-title">{p[
                "title"
              ]}</span></.link>
              <span class="count-pill">{n} views</span>
            </li>
          </ul>
        </section>

        <section class="panel">
          <header class="panel-head">
            <h2>Audit log</h2>
          </header>
          <div :if={@audit == []} class="panel-empty">Nothing yet.</div>
          <ul class="row-list">
            <li :for={a <- @audit} class="row is-compact">
              <span class="row-main"><span class="row-title">{a["actor"]} · {a["action"]}<span
                :if={a["subject"]}
                class="row-sub"
              >{a["subject"]}</span></span><span class="row-sub">{String.slice(a["at"], 0, 16)}</span></span>
            </li>
          </ul>
        </section>
      </div>

      <section class="panel">
        <header class="panel-head">
          <h2>Recent activity</h2>
        </header>
        <div :if={@recent == []} class="panel-empty">
          No posts yet. <.link href={~p"/admin/posts/new"} method="post">Write one</.link>
          or ask the <.link navigate={~p"/admin/studio"}>agent</.link>.
        </div>
        <ul class="row-list">
          <li :for={p <- @recent} class="row">
            <.link navigate={~p"/admin/posts/#{p["id"]}"} class="row-main">
              <span class="row-title">{if p["title"] == "", do: "(untitled)", else: p["title"]}</span>
              <span class="row-sub">{p["type"]} · {Calendar.strftime(
                parse(p["updated_at"]),
                "%b %-d, %H:%M"
              )}</span>
            </.link>
            <span class={["status-pill", "is-" <> p["status"]]}>{p["status"]}</span>
          </li>
        </ul>
      </section>
    </Layouts.admin>
    """
  end

  # a tiny inline bar chart; no JS
  attr :series, :list, required: true
  attr :labels, :list, required: true

  defp spark(assigns) do
    max = Enum.max([1 | assigns.series])
    assigns = assign(assigns, :max, max)

    ~H"""
    <div class="spark" role="img" aria-label={"views per day: " <> Enum.join(@series, ", ")}>
      <span
        :for={{v, d} <- Enum.zip(@series, @labels)}
        class="spark-bar"
        style={"height: #{max(round(v / @max * 100), 2)}%"}
        title={"#{d}: #{v}"}
      ></span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :to, :string, required: true

  defp stat(assigns) do
    ~H"""
    <.link navigate={@to} class="kpi">
      <span class="kpi-value">{@value}</span>
      <span class="kpi-label">{@label}</span>
    </.link>
    """
  end

  defp parse(iso) do
    case DateTime.from_iso8601(to_string(iso)) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
