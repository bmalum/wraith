defmodule WraithWeb.Layouts do
  @moduledoc """
  Two layouts: `site/1` wraps every public page in the current theme's
  layout (`WraithWeb.Theme`), `admin/1` wraps the admin (rail on the left).
  Both take `flash`; `site` takes `site` (the settings map) and `theme`.
  """
  use WraithWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :site, :map, required: true
  attr :theme, :atom, required: true, doc: "the theme module (`WraithWeb.Themes.current/0`)"
  attr :current_user, :map, default: nil
  attr :current_member, :map, default: nil
  slot :inner_block, required: true

  @doc "Every public page: the theme's layout around the page, then the flash."
  def site(assigns) do
    ~H"""
    <WraithWeb.SiteComponents.theme_layout
      theme={@theme}
      site={@site}
      current_user={@current_user}
      current_member={@current_member}
    >
      {render_slot(@inner_block)}
    </WraithWeb.SiteComponents.theme_layout>
    <.flash_group flash={@flash} />
    """
  end

  attr :flash, :map, required: true
  attr :current_user, :map, required: true
  attr :active, :atom, required: true
  attr :title, :string, default: nil
  attr :bare, :boolean, default: false, doc: "full-bleed content (the editors, the studio)"
  slot :inner_block, required: true
  slot :actions

  def admin(assigns) do
    ~H"""
    <div class="admin">
      <aside class="admin-rail" aria-label="Admin">
        <a href="/" class="admin-brand" title="View site">
          <span class="admin-brand-mark">W</span>
          <span class="admin-brand-name">Wraith</span>
        </a>
        <nav class="admin-nav">
          <.rail_link to={~p"/admin"} icon="hero-squares-2x2" active={@active == :dashboard}>Dashboard</.rail_link>
          <.rail_link to={~p"/admin/posts"} icon="hero-document-text" active={@active == :posts}>Posts</.rail_link>
          <.rail_link to={~p"/admin/pages"} icon="hero-rectangle-stack" active={@active == :pages}>Pages</.rail_link>
          <.rail_link to={~p"/admin/tags"} icon="hero-tag" active={@active == :tags}>Tags</.rail_link>
          <.rail_link to={~p"/admin/members"} icon="hero-users" active={@active == :members}>Members</.rail_link>
          <div class="admin-nav-sep">Build</div>
          <.rail_link to={~p"/admin/widgets"} icon="hero-cube" active={@active == :widgets}>Widgets</.rail_link>
          <.rail_link to={~p"/admin/studio"} icon="hero-sparkles" active={@active == :studio}>Agent studio</.rail_link>
          <div class="admin-nav-sep">Site</div>
          <.rail_link to={~p"/admin/settings"} icon="hero-cog-6-tooth" active={@active == :settings}>Settings</.rail_link>
        </nav>
        <div class="admin-rail-foot">
          <span class="admin-user" title={@current_user["email"]}>{@current_user["name"]}</span>
          <a href={~p"/admin/logout"} class="admin-signout" title="Sign out">
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
          </a>
        </div>
      </aside>

      <section class="admin-body">
        <header :if={@title} class="admin-head">
          <h1>{@title}</h1>
          <div class="admin-head-actions">{render_slot(@actions)}</div>
        </header>
        <div class={["admin-content", @bare && "is-bare"]}>
          {render_slot(@inner_block)}
        </div>
      </section>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  attr :to, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp rail_link(assigns) do
    ~H"""
    <.link navigate={@to} class={["rail-link", @active && "is-active"]}>
      <.icon name={@icon} class="size-4" />
      <span>{render_slot(@inner_block)}</span>
    </.link>
    """
  end

  @doc "A bare centred card (setup, login)."
  attr :flash, :map, required: true
  slot :inner_block, required: true

  def plain(assigns) do
    ~H"""
    <div class="plain">
      <div class="plain-card">
        {render_slot(@inner_block)}
      </div>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="Connection lost"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Reconnecting <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Reconnecting <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
