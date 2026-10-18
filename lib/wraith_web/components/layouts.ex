defmodule WraithWeb.Layouts do
  @moduledoc """
  Two layouts: `site/1` wraps every public page (masthead, navigation from
  the settings, footer), `admin/1` wraps the admin (rail on the left).
  Both take `flash`; `site` takes `site` (the settings map).
  """
  use WraithWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :site, :map, required: true
  attr :current_user, :map, default: nil
  attr :wide, :boolean, default: false
  slot :inner_block, required: true

  def site(assigns) do
    ~H"""
    <div class="site">
      <header class="masthead">
        <div class="masthead-inner">
          <a href="/" class="masthead-title">{@site["title"]}</a>
          <nav class="masthead-nav" aria-label="Site">
            <a :for={item <- @site["navigation"] || []} href={item["url"]}>{item["label"]}</a>
            <a :if={@site["members_enabled"]} href={~p"/subscribe"} class="masthead-cta">Subscribe</a>
            <a :if={@current_user} href={~p"/admin"} class="masthead-admin" title="Admin">
              <.icon name="hero-pencil-square" class="size-4" />
            </a>
          </nav>
        </div>
      </header>

      <main class={["site-main", @wide && "is-wide"]}>
        {render_slot(@inner_block)}
      </main>

      <footer class="site-footer">
        <div class="site-footer-inner">
          <span>{@site["title"]} © {Date.utc_today().year}</span>
          <span class="site-footer-links">
            <a href={~p"/rss"}>RSS</a>
            <span :if={@site["footer"] not in [nil, ""]}>{@site["footer"]}</span>
            <span>Published with <a href="https://github.com/mkarrer/wraith">Wraith</a></span>
          </span>
        </div>
      </footer>
    </div>
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
