defmodule WraithWeb.Admin.SettingsLive do
  @moduledoc "The site's settings and its authors."
  use WraithWeb, :live_view

  alias Wraith.{Accounts, Settings}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Settings", errors: %{}, author_errors: %{}) |> load()}
  end

  defp load(socket) do
    site = Settings.get()
    pages = Wraith.Content.list_posts("published", type: "page", limit: 100).posts
    page_urls = Enum.map(pages, &("/" <> &1["slug"]))
    # entries that point at a page show as ticks in the picker; the rest stay text
    {picked, hand} = Enum.split_with(site["navigation"], &(&1["url"] in page_urls))
    nav = Enum.map_join(hand, "\n", &"#{&1["label"]} #{&1["url"]}")

    assign(socket,
      site: site,
      nav_text: nav,
      pages: pages,
      picked: Enum.map(picked, &String.trim_leading(&1["url"], "/")),
      redirects_text: WraithWeb.Redirects.to_text(site["redirects"]),
      authors: Accounts.list_users()
    )
  end

  @impl true
  def handle_event("save", %{"site" => attrs}, socket) do
    attrs =
      attrs
      |> Map.put("navigation", parse_nav(attrs["navigation"] || "") ++ picked_pages(attrs))
      |> Map.put("redirects", WraithWeb.Redirects.parse(attrs["redirects"] || ""))
      |> Map.put("members_enabled", attrs["members_enabled"] == "true")
      |> Map.put("comments_enabled", attrs["comments_enabled"] == "true")

    case Settings.update(attrs) do
      {:ok, _} ->
        Wraith.Audit.log(socket.assigns.current_user, "settings_update", nil, %{
          "keys" => attrs |> Map.keys() |> Enum.reject(&(&1 =~ "secret"))
        })

        {:noreply, socket |> put_flash(:info, "Saved.") |> assign(errors: %{}) |> load()}

      {:error, errors} ->
        {:noreply, assign(socket, errors: errors)}
    end
  end

  def handle_event("pick-theme", %{"name" => name}, socket) do
    case Settings.update(%{"theme" => name}) do
      {:ok, _} ->
        Wraith.Audit.log(socket.assigns.current_user, "settings_update", nil, %{
          "keys" => ["theme"]
        })

        info = WraithWeb.Themes.get(name).info()
        {:noreply, socket |> put_flash(:info, "Theme set to #{info.label}.") |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That theme is not installed.")}
    end
  end

  def handle_event("set-role", %{"user" => id, "role" => role}, socket) do
    with true <- role in Wraith.Policy.assignable(socket.assigns.current_user),
         %{} = u <- Accounts.get_user(id),
         false <- u["role"] == "owner",
         {:ok, _} <- Accounts.set_role(u, role) do
      {:noreply, socket |> put_flash(:info, "#{u["name"]} is now #{role}.") |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Cannot change that role.")}
    end
  end

  def handle_event("remove-staff", %{"id" => id}, socket) do
    with true <- Wraith.Policy.can?(socket.assigns.current_user, :manage_staff, nil),
         %{} = u <- Accounts.get_user(id),
         :ok <- Accounts.delete_user(u) do
      {:noreply, socket |> put_flash(:info, "#{u["name"]} removed.") |> load()}
    else
      {:error, %{"base" => why}} -> {:noreply, put_flash(socket, :error, why)}
      _ -> {:noreply, put_flash(socket, :error, "Cannot remove that account.")}
    end
  end

  def handle_event("add-author", %{"user" => attrs}, socket) do
    attrs =
      if attrs["role"] in Wraith.Policy.assignable(socket.assigns.current_user),
        do: attrs,
        else: Map.put(attrs, "role", "author")

    case Accounts.create_user(attrs) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Author added.") |> assign(author_errors: %{}) |> load()}

      {:error, errors} ->
        {:noreply, assign(socket, author_errors: errors)}
    end
  end

  # pages ticked in the picker become nav entries after the hand-written ones
  defp picked_pages(attrs) do
    for slug <- List.wrap(attrs["nav_pages"]),
        slug != "",
        p = Wraith.Content.get_post_by_slug(slug),
        do: %{"label" => p["title"], "url" => "/" <> p["slug"]}
  end

  # secrets are stored encrypted; the form shows only a hint
  defp secret_state(site, name) do
    case site[name <> "_hint"] do
      nil -> " — not set"
      h -> " — set (#{h})"
    end
  end

  defp parse_nav(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(String.trim(line), ~r/\s+/, parts: 2) do
        [label, url] -> %{"label" => label, "url" => url}
        [label] -> %{"label" => label, "url" => "/" <> Wraith.Slug.slugify(label)}
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} active={:settings} title="Settings">
      <div class="two-col">
        <section class="panel">
          <header class="panel-head">
            <h2>Site</h2>
          </header>
          <.form for={to_form(@site, as: :site)} phx-submit="save" id="site-form" class="panel-form">
            <.input
              name="site[title]"
              value={@site["title"]}
              label="Title"
              errors={List.wrap(@errors["title"])}
            />
            <.input
              name="site[description]"
              type="textarea"
              value={@site["description"]}
              label="Description"
            />
            <.input
              name="site[logo]"
              value={@site["logo"]}
              label="Logo URL"
              placeholder="/uploads/… or https://"
            />
            <.input name="site[icon]" value={@site["icon"]} label="Icon / favicon URL" />
            <.input name="site[cover_image]" value={@site["cover_image"]} label="Cover image URL" />
            <.input
              name="site[twitter]"
              value={@site["twitter"]}
              label="X / Twitter"
              placeholder="@site"
            />
            <.input name="site[facebook]" value={@site["facebook"]} label="Facebook page" />
            <.input
              name="site[navigation]"
              type="textarea"
              value={@nav_text}
              label="Navigation"
              placeholder="Home /\nAbout /about"
            />
            <p class="form-help">One link per line: <code>Label /url</code>.</p>
            <fieldset :if={@pages != []} class="nav-pages">
              <legend class="drawer-label">Pages in the navigation</legend>
              <label :for={p <- @pages} class="nav-page">
                <input
                  type="checkbox"
                  name="site[nav_pages][]"
                  value={p["slug"]}
                  checked={p["slug"] in @picked}
                  class="checkbox"
                /> {p["title"]} <span class="row-sub">/{p["slug"]}</span>
              </label>
            </fieldset>
            <.input
              name="site[redirects]"
              type="textarea"
              value={@redirects_text}
              label="Redirects"
              placeholder="/old-post /new-post\n/blog/* /* temporary"
            />
            <p class="form-help">
              One per line: <code>/from /to</code>, optionally <code>temporary</code>
              (302). <code>/old/*</code>
              keeps the rest of the path.
            </p>
            <.input name="site[footer]" value={@site["footer"]} label="Footer note" />
            <.input
              name="site[accent]"
              type="color"
              value={@site["accent"]}
              label="Accent colour"
              errors={List.wrap(@errors["accent"])}
            />
            <.input
              name="site[posts_per_page]"
              type="number"
              value={@site["posts_per_page"]}
              label="Posts per page"
              errors={List.wrap(@errors["posts_per_page"])}
              min="1"
              max="100"
            />
            <.input name="site[lang]" value={@site["lang"]} label="Language code" />
            <.input
              name="site[members_enabled]"
              type="checkbox"
              checked={@site["members_enabled"]}
              label="Let readers subscribe"
            />
            <.input
              name="site[comments_enabled]"
              type="checkbox"
              checked={@site["comments_enabled"]}
              label="Let members comment"
            />
            <h3 class="panel-sub">Paid memberships (Stripe)</h3>
            <.input
              name="site[stripe_secret_key]"
              type="password"
              value=""
              label={"Secret key (sk_…)" <> secret_state(@site, "stripe_secret_key")}
              placeholder="empty keeps it; type clear to remove"
            />
            <.input
              name="site[stripe_webhook_secret]"
              type="password"
              value=""
              label={"Webhook signing secret (whsec_…)" <> secret_state(@site, "stripe_webhook_secret")}
              placeholder="empty keeps it; type clear to remove"
            />
            <.input
              name="site[stripe_price_id]"
              value={@site["stripe_price_id"]}
              label="Recurring price id (price_…)"
            />
            <.input
              name="site[paid_price_label]"
              value={@site["paid_price_label"]}
              label="Price as shown to readers"
              placeholder="€5 / month"
            />
            <p class="form-help">
              Secrets are stored encrypted. Point a Stripe webhook at <code>/webhooks/stripe</code>
              for <code>checkout.session.completed</code>
              and <code>customer.subscription.*</code>.
            </p>

            <.input
              name="site[widget_fetch_hosts]"
              value={@site["widget_fetch_hosts"]}
              label="Widget fetch allowlist"
              placeholder="api.example.com, *.wikipedia.org"
            />
            <p class="form-help">
              Hosts a Lua widget may <code>wraith.fetch</code>. Empty = widgets cannot fetch.
            </p>
            <h3 class="panel-sub">Code injection</h3>
            <.input
              name="site[code_injection_head]"
              type="textarea"
              value={@site["code_injection_head"]}
              label="Site header (inside <head>)"
              placeholder="<script>…</script> or <style>…</style>"
            />
            <.input
              name="site[code_injection_foot]"
              type="textarea"
              value={@site["code_injection_foot"]}
              label="Site footer (before </body>)"
            />
            <button type="submit" class="btn-accent">Save settings</button>
          </.form>
        </section>

        <section class="panel" id="appearance">
          <header class="panel-head">
            <h2>Theme</h2>
            <p class="panel-sub">
              {length(WraithWeb.Themes.infos())} themes across {map_size(WraithWeb.Themes.by_layout())} layouts. Your accent colour, set on the left, overrides the theme's.
            </p>
          </header>
          <div class="theme-groups">
            <div
              :for={{layout, infos} <- WraithWeb.Themes.by_layout()}
              class="theme-group"
              id={"layout-" <> layout}
            >
              <h3 class="theme-group-name">{layout}</h3>
              <div class="theme-gallery">
                <button
                  :for={info <- infos}
                  type="button"
                  phx-click="pick-theme"
                  phx-value-name={info.name}
                  class={["theme-card", @site["theme"] == info.name && "is-active"]}
                  id={"theme-" <> info.name}
                  aria-pressed={to_string(@site["theme"] == info.name)}
                  title={info.description}
                >
                  <span class="theme-swatch" aria-hidden="true">
                    <span :for={c <- info.swatch} class="theme-swatch-chip" style={"background: #{c}"}></span>
                  </span>
                  <span class="theme-card-label">
                    <span class="theme-card-name">{info.label}</span>
                    <span :if={@site["theme"] == info.name} class="theme-card-current">Current</span>
                  </span>
                  <span class="theme-card-desc">{info.description}</span>
                </button>
              </div>
            </div>
          </div>
        </section>

        <section class="panel">
          <header class="panel-head">
            <h2>Staff</h2>
          </header>
          <ul class="row-list" id="staff">
            <li :for={a <- @authors} class="row" id={"staff-" <> a["id"]}>
              <div class="row-main">
                <span class="row-title">{a["name"]} <span class="role-pill">{a["role"]}</span></span>
                <span class="row-sub">{a["email"]} · /author/{a["slug"]}</span>
              </div>
              <form
                :if={a["role"] != "owner" and Wraith.Policy.assignable(@current_user) != []}
                phx-change="set-role"
                class="row-inline"
                id={"role-" <> a["id"]}
              >
                <input type="hidden" name="user" value={a["id"]} />
                <select name="role" class="select">
                  <option
                    :for={r <- Wraith.Policy.assignable(@current_user)}
                    value={r}
                    selected={a["role"] == r}
                  >
                    {r}
                  </option>
                </select>
              </form>
              <div
                :if={a["role"] != "owner" and Wraith.Policy.can?(@current_user, :manage_staff, nil)}
                class="row-actions"
              >
                <button
                  phx-click="remove-staff"
                  phx-value-id={a["id"]}
                  data-confirm={"Remove #{a["name"]}? Their posts stay."}
                  class="icon-btn is-danger"
                  title="Remove"
                ><.icon name="hero-trash" class="size-4" /></button>
              </div>
            </li>
          </ul>
          <.form
            :if={Wraith.Policy.can?(@current_user, :manage_staff, nil)}
            for={to_form(%{}, as: :user)}
            phx-submit="add-author"
            id="author-form"
            class="panel-form"
          >
            <h3 class="panel-sub">Invite staff</h3>
            <.input
              name="user[name]"
              value=""
              label="Name"
              errors={List.wrap(@author_errors["name"])}
            />
            <.input
              name="user[email]"
              type="email"
              value=""
              label="Email"
              errors={List.wrap(@author_errors["email"])}
            />
            <.input
              name="user[role]"
              type="select"
              value="author"
              label="Role"
              options={
                Enum.map(Wraith.Policy.assignable(@current_user), &{String.capitalize(&1), &1})
              }
            />
            <.input
              name="user[password]"
              type="password"
              value=""
              label="Password"
              errors={List.wrap(@author_errors["password"])}
            />
            <p class="form-help">
              Admin: everything. Editor: all posts, members, comments. Author: their own posts. Contributor: their own drafts, no publishing.
            </p>
            <button type="submit" class="btn-ghost">Add</button>
          </.form>
        </section>
      </div>
    </Layouts.admin>
    """
  end
end
