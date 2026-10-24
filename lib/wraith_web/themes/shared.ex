defmodule WraithWeb.Themes.Shared do
  @moduledoc """
  Pages and pieces every layout shares: subscribe, the member account, the
  search box, the nav and mode toggles, the footer credit, social links.

  Every reader-facing string here goes through `gettext`, so the public site
  follows the site's `lang` setting (`WraithWeb.Locale`).
  """
  use Phoenix.Component
  use Gettext, backend: WraithWeb.Gettext
  use WraithWeb, :verified_routes
  import WraithWeb.CoreComponents, only: [icon: 1, input: 1]
  alias Phoenix.LiveView.JS

  def subscribe_page(assigns) do
    ~H"""
    <section class="t-head">
      <h1 class="t-title">{gettext("Subscribe to %{site}", site: @site["title"])}</h1>
      <p class="t-lede">{gettext("New posts in your inbox. No spam, leave whenever.")}</p>
    </section>
    <div :if={@done} class="t-notice" role="status">
      <.icon name="hero-envelope" class="size-6" />
      <p>{gettext("You're in — check your inbox for a confirmation link.")}</p>
    </div>
    <.form :if={not @done} for={@form} phx-submit="subscribe" class="t-form" id="subscribe-form">
      <.input field={@form[:name]} label={gettext("Name")} placeholder={gettext("Optional")} />
      <.input
        field={@form[:email]}
        type="email"
        label={gettext("Email")}
        required
        placeholder="you@example.com"
      />
      <button class="btn-accent" type="submit">{gettext("Subscribe")}</button>
    </.form>
    """
  end

  def member_page(assigns) do
    ~H"""
    <section class="t-head">
      <h1 class="t-title">
        {if @current_member, do: gettext("Your account"), else: gettext("Sign in")}
      </h1>
      <p :if={is_nil(@current_member)} class="t-lede">
        {gettext("Members sign in with a link sent by mail — no password to remember.")}
      </p>
    </section>

    <%= if @current_member do %>
      <div class="t-account">
        <dl class="kv">
          <dt>{gettext("Email")}</dt>
          <dd>{@current_member["email"]}</dd>
          <dt>{gettext("Plan")}</dt>
          <dd><span class="status-pill">{@current_member["status"]}</span></dd>
          <dt>{gettext("Newsletter")}</dt>
          <dd>
            {if @current_member["subscribed"], do: gettext("On"), else: gettext("Off")}
            <button phx-click="toggle-newsletter" class="btn-ghost is-small">
              {if @current_member["subscribed"], do: gettext("Turn off"), else: gettext("Turn on")}
            </button>
          </dd>
        </dl>
        <p :if={@current_member["status"] == "free" and @site["stripe_price_id"] not in [nil, ""]}>
          <a href={~p"/members/upgrade"} class="btn-accent">
            {gettext("Upgrade")}{if @site["paid_price_label"] not in [nil, ""],
              do: " · " <> @site["paid_price_label"]}
          </a>
        </p>
        <p :if={@current_member["stripe_customer_id"]}>
          <a href={~p"/members/portal"} class="btn-ghost">{gettext("Manage billing")}</a>
        </p>
        <p>
          <.link href={~p"/members/logout"} method="post" class="btn-ghost">
            {gettext("Sign out")}
          </.link>
        </p>
        <form
          action={~p"/members/delete"}
          method="post"
          class="t-danger"
          data-confirm={
            gettext("Delete your account and every comment you wrote? This cannot be undone.")
          }
        >
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <button type="submit" class="btn-danger">{gettext("Delete my account")}</button>
        </form>
      </div>
    <% else %>
      <div :if={@sent} class="t-notice" role="status">
        <.icon name="hero-envelope" class="size-6" />
        <p>{gettext("If that address is a member, a sign-in link is on its way.")}</p>
      </div>
      <.form
        :if={not @sent}
        for={@form}
        phx-submit="request-link"
        class="t-form"
        id="member-login-form"
      >
        <.input
          field={@form[:email]}
          type="email"
          label={gettext("Email")}
          required
          placeholder="you@example.com"
        />
        <button class="btn-accent" type="submit">{gettext("Send me a sign-in link")}</button>
      </.form>
      <p class="form-help">
        {gettext("Not a member yet?")}
        <.link navigate={~p"/subscribe"}>{gettext("Subscribe")}</.link>
        {gettext("first.")}
      </p>
    <% end %>
    """
  end

  @doc "Avatar, location, website and socials for an author page."
  attr :author, :map, required: true

  def author_meta(assigns) do
    ~H"""
    <img :if={@author["avatar"]} src={@author["avatar"]} alt="" class="author-avatar is-large is-img" />
    <div :if={is_nil(@author["avatar"])} class="author-avatar is-large">
      {String.first(@author["name"] || "?")}
    </div>
    <p class="t-meta">
      <span :if={@author["location"] not in [nil, ""]}>{@author["location"]}</span>
      <a :if={@author["website"] not in [nil, ""]} href={@author["website"]} rel="me">
        {String.replace(@author["website"], ~r{^https?://}, "")}
      </a>
      <a
        :if={@author["twitter"] not in [nil, ""]}
        href={"https://x.com/" <> String.trim_leading(@author["twitter"], "@")}
        rel="me"
      >@{String.trim_leading(@author["twitter"], "@")}</a>
      <a
        :if={@author["github"] not in [nil, ""]}
        href={"https://github.com/" <> @author["github"]}
        rel="me"
      >github</a>
      <a :if={@author["mastodon"] not in [nil, ""]} href={@author["mastodon"]} rel="me">mastodon</a>
    </p>
    """
  end

  @doc "\"3 posts\" or, on the search page, \"3 results\"."
  attr :posts, :list, required: true
  attr :search, :boolean, default: false

  def listing_count(assigns) do
    n = length(assigns.posts)

    text =
      if assigns.search,
        do: ngettext("%{count} result", "%{count} results", n),
        else: ngettext("%{count} post", "%{count} posts", n)

    assigns = assign(assigns, :text, text)

    ~H"""
    <p class="t-count">{@text}</p>
    """
  end

  attr :q, :string, required: true

  def search_form(assigns) do
    ~H"""
    <form phx-change="search" phx-submit="search" class="t-search" id="search-form" role="search">
      <input
        type="search"
        name="q"
        value={@q}
        placeholder={gettext("Search posts…")}
        autofocus
        autocomplete="off"
        phx-debounce="200"
        class="input is-search"
        aria-label={gettext("Search")}
      />
    </form>
    """
  end

  @doc """
  The hamburger that shows the site nav on small screens. Pure JS commands —
  no hook — so it works the instant the dead render arrives. `target` is the
  nav's DOM id.
  """
  attr :target, :string, default: "site-nav"

  def nav_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class="nav-toggle"
      aria-controls={@target}
      aria-expanded="false"
      aria-label={gettext("Menu")}
      phx-click={
        JS.toggle_class("is-open", to: "#" <> @target)
        |> JS.toggle_attribute({"aria-expanded", "true", "false"})
      }
    >
      <.icon name="hero-bars-3" class="size-5 nav-toggle-open" />
      <.icon name="hero-x-mark" class="size-5 nav-toggle-close" />
    </button>
    """
  end

  def mode_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class="mode-toggle"
      phx-click={JS.dispatch("wraith:toggle-mode")}
      title={gettext("Light / dark")}
      aria-label={gettext("Toggle light or dark mode")}
    >
      <.icon name="hero-moon" class="size-4" />
    </button>
    """
  end

  @doc "The footer line every layout shares: the site's note and, if allowed, the Wraith credit."
  attr :site, :map, required: true

  def site_credit(assigns) do
    ~H"""
    <span :if={@site["footer"] not in [nil, ""]} class="t-footer-note">{@site["footer"]}</span>
    <span :if={@site["powered_by"] != false} class="t-credit">
      {gettext("Published with")}
      <a href="https://github.com/bmalum/wraith" rel="noopener">Wraith</a>
    </span>
    """
  end

  attr :site, :map, required: true

  def social_links(assigns) do
    ~H"""
    <span class="t-social">
      <a
        :if={@site["twitter"] not in [nil, ""]}
        href={"https://x.com/" <> String.trim_leading(@site["twitter"], "@")}
        rel="me noopener"
      >X</a>
      <a :if={@site["facebook"] not in [nil, ""]} href={@site["facebook"]} rel="me noopener">Facebook</a>
      <a href={~p"/rss"}>RSS</a>
    </span>
    """
  end
end
