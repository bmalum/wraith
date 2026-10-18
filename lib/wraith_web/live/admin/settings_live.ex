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
    nav = site["navigation"] |> Enum.map_join("\n", &"#{&1["label"]} #{&1["url"]}")
    assign(socket, site: site, nav_text: nav, authors: Accounts.list_users())
  end

  @impl true
  def handle_event("save", %{"site" => attrs}, socket) do
    attrs =
      attrs
      |> Map.put("navigation", parse_nav(attrs["navigation"] || ""))
      |> Map.put("members_enabled", attrs["members_enabled"] == "true")

    case Settings.update(attrs) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Saved.") |> assign(errors: %{}) |> load()}

      {:error, errors} ->
        {:noreply, assign(socket, errors: errors)}
    end
  end

  def handle_event("add-author", %{"user" => attrs}, socket) do
    case Accounts.create_user(attrs) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Author added.") |> assign(author_errors: %{}) |> load()}

      {:error, errors} ->
        {:noreply, assign(socket, author_errors: errors)}
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
              name="site[navigation]"
              type="textarea"
              value={@nav_text}
              label="Navigation"
              placeholder="Home /\nAbout /about"
            />
            <p class="form-help">One link per line: <code>Label /url</code>.</p>
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
            <button type="submit" class="btn-accent">Save settings</button>
          </.form>
        </section>

        <section class="panel">
          <header class="panel-head">
            <h2>Authors</h2>
          </header>
          <ul class="row-list">
            <li :for={a <- @authors} class="row">
              <div class="row-main">
                <span class="row-title">{a["name"]} <span class="role-pill">{a["role"]}</span></span>
                <span class="row-sub">{a["email"]} · /author/{a["slug"]}</span>
              </div>
            </li>
          </ul>
          <.form
            :if={@current_user["role"] == "owner"}
            for={to_form(%{}, as: :user)}
            phx-submit="add-author"
            id="author-form"
            class="panel-form"
          >
            <h3 class="panel-sub">Add an author</h3>
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
              name="user[password]"
              type="password"
              value=""
              label="Password"
              errors={List.wrap(@author_errors["password"])}
            />
            <button type="submit" class="btn-ghost">Add author</button>
          </.form>
        </section>
      </div>
    </Layouts.admin>
    """
  end
end
