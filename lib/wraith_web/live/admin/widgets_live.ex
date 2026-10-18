defmodule WraithWeb.Admin.WidgetsLive do
  @moduledoc "The widget library."
  use WraithWeb, :live_view

  alias Wraith.Widgets

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Widgets") |> load()}
  end

  defp load(socket), do: assign(socket, widgets: Widgets.list())

  @impl true
  def handle_event("toggle", %{"slug" => slug}, socket) do
    w = Widgets.get(slug)
    {:ok, _} = Widgets.set_enabled(slug, not w["enabled"])
    {:noreply, load(socket)}
  end

  def handle_event("delete", %{"slug" => slug}, socket) do
    Widgets.delete(slug)
    {:noreply, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} active={:widgets} title="Widgets">
      <:actions>
        <.link navigate={~p"/admin/widgets/new"} class="btn-accent"><.icon
          name="hero-plus"
          class="size-4"
        /> New widget</.link>
      </:actions>

      <p class="lede">
        Widgets are tiny live apps you drop into a post with <code>{"{{widget slug}}"}</code>. Script your own in Lua, or ask the
        <.link navigate={~p"/admin/studio"}>agent</.link>
        to write one.
      </p>

      <ul class="wcard-grid" id="widgets">
        <li
          :for={w <- @widgets}
          class={["wcard", not w["enabled"] && "is-off"]}
          id={"widget-" <> w["slug"]}
        >
          <div class="wcard-head">
            <.icon
              name={if w["kind"] == "lua", do: "hero-code-bracket", else: "hero-cube"}
              class="size-5"
            />
            <h3>{w["name"]}</h3>
            <span class="kind-pill">{w["kind"]}</span>
          </div>
          <p class="wcard-desc">{w["description"]}</p>
          <code class="wcard-code">{"{{widget #{w["slug"]}}}"}</code>
          <div class="wcard-foot">
            <span class="row-sub">rev {w["rev"]}<span :if={w["builtin"]}> · built-in</span></span>
            <div class="row-actions">
              <button
                phx-click="toggle"
                phx-value-slug={w["slug"]}
                class="icon-btn"
                title={if w["enabled"], do: "Disable", else: "Enable"}
              >
                <.icon name={if w["enabled"], do: "hero-eye", else: "hero-eye-slash"} class="size-4" />
              </button>
              <.link
                :if={w["kind"] == "lua"}
                navigate={~p"/admin/widgets/#{w["slug"]}"}
                class="icon-btn"
                title="Edit"
              ><.icon name="hero-pencil" class="size-4" /></.link>
              <button
                :if={not w["builtin"]}
                phx-click="delete"
                phx-value-slug={w["slug"]}
                data-confirm="Delete this widget and its versions?"
                class="icon-btn is-danger"
                title="Delete"
              ><.icon name="hero-trash" class="size-4" /></button>
            </div>
          </div>
        </li>
      </ul>
    </Layouts.admin>
    """
  end
end
