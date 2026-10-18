defmodule WraithWeb.Admin.DashboardLive do
  @moduledoc "The admin's front door: counts, recent drafts, what to do next."
  use WraithWeb, :live_view

  alias Wraith.{Content, Members, Widgets}

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
      recent: Content.list_all_posts() |> Enum.take(8)
    )
  end

  @impl true
  def handle_info({:content, _, _}, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} active={:dashboard} title="Dashboard">
      <:actions>
        <.link navigate={~p"/admin/posts/new"} class="btn-accent"><.icon
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

      <section class="panel">
        <header class="panel-head">
          <h2>Recent activity</h2>
        </header>
        <div :if={@recent == []} class="panel-empty">
          No posts yet. <.link navigate={~p"/admin/posts/new"}>Write one</.link>
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
