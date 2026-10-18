defmodule WraithWeb.Admin.EditorLive do
  @moduledoc """
  Write a post: Markdown on the left, the rendered post on the right —
  including live widgets, exactly as readers will see them. Changes are
  saved as you type (debounced); publishing, scheduling and metadata live
  in the drawer.
  """
  use WraithWeb, :live_view
  import WraithWeb.WidgetHost
  import WraithWeb.SiteComponents, only: [body: 1]

  alias Wraith.{Content, Markdown, Uploads, Widgets}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    post = Content.get_post(id) || raise(WraithWeb.NotFound, "no post #{id}")

    socket =
      socket
      |> assign(
        post: post,
        title: post["title"],
        markdown: post["markdown"],
        errors: %{},
        drawer: false,
        saved_at: nil,
        widget_defs: Widgets.list_enabled(),
        all_authors: Wraith.Accounts.list_users(),
        page_title: if(post["title"] == "", do: "New " <> post["type"], else: post["title"])
      )
      |> mount_widgets(post["markdown"], post["id"], post)
      |> allow_upload(:feature,
        accept: Uploads.accepted_extensions(),
        max_entries: 1,
        max_file_size: Uploads.max_bytes(),
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> allow_upload(:inline,
        accept: Uploads.accepted_extensions(),
        max_entries: 5,
        max_file_size: Uploads.max_bytes(),
        auto_upload: true,
        progress: &handle_progress/3
      )

    {:ok, socket}
  end

  # auto_upload: as soon as an entry is fully in, store it and use the URL
  defp handle_progress(kind, entry, socket) do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Uploads.store_file(path, entry.client_type, name: entry.client_name)}
        end)

      case {kind, result} do
        {_, {:error, why}} ->
          {:noreply, put_flash(socket, :error, "Upload failed: " <> why)}

        {:feature, {:ok, url}} ->
          {:noreply, save(socket, %{"feature_image" => url})}

        {:inline, {:ok, url}} ->
          alt = entry.client_name |> Path.rootname() |> String.replace(~r/[-_]+/, " ")
          {:noreply, push_event(socket, "editor:insert", %{text: "\n![#{alt}](#{url})\n"})}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ---- writing -----------------------------------------------------------------------

  @impl true
  def handle_event("change", %{"title" => title, "markdown" => markdown}, socket) do
    socket = assign(socket, title: title, markdown: markdown)
    {:noreply, save(socket, %{"title" => title, "markdown" => markdown})}
  end

  def handle_event("insert", %{"snippet" => snippet}, socket) do
    markdown = String.trim_trailing(socket.assigns.markdown) <> "\n\n" <> snippet <> "\n"
    socket = assign(socket, markdown: markdown)

    {:noreply,
     socket |> save(%{"markdown" => markdown}) |> push_event("editor:set", %{markdown: markdown})}
  end

  def handle_event("drawer", _params, socket), do: {:noreply, update(socket, :drawer, &(not &1))}

  def handle_event("validate-upload", _params, socket), do: {:noreply, socket}

  def handle_event("clear-feature", _params, socket),
    do: {:noreply, save(socket, %{"feature_image" => nil})}

  def handle_event("meta", %{"post" => attrs}, socket) do
    {:noreply, save(socket, attrs)}
  end

  def handle_event("publish", _params, socket) do
    case Content.publish_post(socket.assigns.post) do
      {:ok, post} -> {:noreply, socket |> assign(post: post) |> put_flash(:info, "Published.")}
      {:error, errors} -> {:noreply, assign(socket, errors: errors)}
    end
  end

  def handle_event("schedule", %{"at" => at}, socket) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(at <> ":00"),
         {:ok, dt} <- DateTime.from_naive(naive, "Etc/UTC"),
         {:ok, post} <- Content.publish_post(socket.assigns.post, dt) do
      {:noreply, socket |> assign(post: post) |> put_flash(:info, "Scheduled for #{at} UTC.")}
    else
      {:error, %{} = errors} -> {:noreply, assign(socket, errors: errors)}
      _ -> {:noreply, put_flash(socket, :error, "Give me a date and time.")}
    end
  end

  def handle_event("unpublish", _params, socket) do
    {:ok, post} = Content.unpublish_post(socket.assigns.post)
    {:noreply, socket |> assign(post: post) |> put_flash(:info, "Back to draft.")}
  end

  def handle_event("delete", _params, socket) do
    :ok = Content.delete_post(socket.assigns.post)
    {:noreply, socket |> put_flash(:info, "Deleted.") |> push_navigate(to: ~p"/admin/posts")}
  end

  def handle_event("reset-widget", %{"instance" => instance}, socket) do
    case socket.assigns.widgets[instance] do
      %{slug: slug} ->
        Widgets.reset_state(slug, instance)

        {:noreply,
         socket
         |> mount_widgets(socket.assigns.markdown, socket.assigns.post["id"], socket.assigns.post)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("widget", params, socket), do: {:noreply, widget_event(socket, params)}

  @impl true
  def handle_info({:widget, _, _, _} = msg, socket), do: {:noreply, widget_info(socket, msg)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"} = msg, socket),
    do: {:noreply, widget_info(socket, msg)}

  defp save(socket, attrs) do
    case Content.update_post(socket.assigns.post, attrs) do
      {:ok, post} ->
        socket
        |> assign(
          post: post,
          errors: %{},
          saved_at: DateTime.utc_now(),
          page_title: if(post["title"] == "", do: "New " <> post["type"], else: post["title"])
        )
        |> then(fn s ->
          if Map.has_key?(attrs, "markdown") and widgets_changed?(s, post["markdown"]),
            do: mount_widgets(s, post["markdown"], post["id"], post),
            else: assign(s, :segments, Markdown.segments(post["markdown"], post["id"]))
        end)

      {:error, errors} ->
        assign(socket, errors: errors)
    end
  end

  defp widgets_changed?(socket, markdown) do
    now =
      for {:widget, s, p, i} <- Markdown.segments(markdown, socket.assigns.post["id"]),
          do: {s, p, i}

    was = for {:widget, s, p, i} <- socket.assigns.segments, do: {s, p, i}
    now != was
  end

  # ---- render ----------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin
      flash={@flash}
      current_user={@current_user}
      active={if @post["type"] == "page", do: :pages, else: :posts}
      bare
    >
      <div class="editor" id="editor" phx-hook="Editor">
        <header class="editor-bar">
          <.link
            navigate={if @post["type"] == "page", do: ~p"/admin/pages", else: ~p"/admin/posts"}
            class="editor-back"
          ><.icon name="hero-arrow-left" class="size-4" /> {String.capitalize(@post["type"])}s</.link>
          <span class="editor-status">
            <span class={["status-pill", "is-" <> @post["status"]]}>{@post["status"]}</span>
            <span :if={@saved_at} class="editor-saved">Saved</span>
            <span :if={@errors["slug"]} class="editor-err">slug {@errors["slug"]}</span>
          </span>
          <div class="editor-actions">
            <a
              :if={@post["status"] == "published"}
              href={~p"/#{@post["slug"]}"}
              target="_blank"
              class="btn-ghost"
            >View</a>
            <a
              :if={@post["status"] != "published"}
              href={~p"/#{@post["slug"]}"}
              target="_blank"
              class="btn-ghost"
            >Preview</a>
            <button phx-click="drawer" class="btn-ghost" aria-expanded={to_string(@drawer)}><.icon
              name="hero-adjustments-horizontal"
              class="size-4"
            /> Settings</button>
            <button
              :if={@post["status"] != "published"}
              phx-click="publish"
              class="btn-accent"
              disabled={@title == ""}
            >Publish</button>
            <button :if={@post["status"] == "published"} phx-click="unpublish" class="btn-ghost">Unpublish</button>
          </div>
        </header>

        <div class={["editor-split", @drawer && "has-drawer"]}>
          <form class="editor-write" phx-change="change" phx-debounce="400" id="editor-form">
            <input
              type="text"
              name="title"
              value={@title}
              placeholder={"#{String.capitalize(@post["type"])} title"}
              class="editor-title"
              autocomplete="off"
              phx-debounce="400"
            />
            <textarea
              name="markdown"
              id="editor-markdown"
              class="editor-markdown"
              placeholder="Write in Markdown. Drop a widget in with {{widget poll}} on its own line."
              phx-debounce="400"
              spellcheck="true"
            >{@markdown}</textarea>

            <div class="editor-palette">
              <span class="editor-palette-label"><.icon name="hero-cube" class="size-3" /> Widgets</span>
              <button
                :for={w <- @widget_defs}
                type="button"
                phx-click="insert"
                phx-value-snippet={snippet(w)}
                class="chip"
                title={w["description"]}
              >{w["name"]}</button>
            </div>
          </form>
          <form
            phx-change="validate-upload"
            phx-submit="validate-upload"
            id="inline-upload-form"
            class="editor-upload"
            phx-drop-target={@uploads.inline.ref}
          >
            <label
              class="chip editor-upload-label"
              title="Insert an image at the cursor (or drop one on the text)"
            >
              <.icon name="hero-photo" class="size-3" /> Image
              <.live_file_input upload={@uploads.inline} class="sr-only" />
            </label>
            <span :for={e <- @uploads.inline.entries} class="row-sub">{e.client_name} {e.progress}%</span>
            <span :for={{_ref, err} <- @uploads.inline.errors} class="editor-err">{upload_error(err)}</span>
          </form>

          <section class="editor-preview" aria-label="Preview">
            <article class="post is-preview">
              <h1 class="post-title">{if @title == "", do: "Untitled", else: @title}</h1>
              <.body segments={@segments} widgets={@widgets} />
            </article>
            <div :if={@widgets != %{}} class="editor-widget-list">
              <span class="editor-palette-label">Live instances on this page</span>
              <span :for={{instance, w} <- @widgets} class="chip is-static">
                {w.slug} <code>{instance}</code>
                <button
                  type="button"
                  phx-click="reset-widget"
                  phx-value-instance={instance}
                  title="Reset state"
                  class="chip-x"
                ><.icon name="hero-arrow-path" class="size-3" /></button>
              </span>
            </div>
          </section>

          <aside :if={@drawer} class="editor-drawer">
            <div class="drawer-feature">
              <span class="drawer-label">Feature image</span>
              <img
                :if={@post["feature_image"]}
                src={@post["feature_image"]}
                alt=""
                class="drawer-feature-img"
              />
              <form
                phx-change="validate-upload"
                phx-submit="validate-upload"
                id="feature-upload-form"
                phx-drop-target={@uploads.feature.ref}
                class="drawer-row"
              >
                <label class="btn-ghost is-small"><.icon name="hero-arrow-up-tray" class="size-3" />
                Upload <.live_file_input upload={@uploads.feature} class="sr-only" /></label>
                <button
                  :if={@post["feature_image"]}
                  type="button"
                  phx-click="clear-feature"
                  class="btn-ghost is-small"
                >Remove</button>
                <span :for={e <- @uploads.feature.entries} class="row-sub">{e.progress}%</span>
                <span :for={{_ref, err} <- @uploads.feature.errors} class="editor-err">{upload_error(
                  err
                )}</span>
              </form>
            </div>

            <.form
              for={to_form(@post, as: :post)}
              phx-change="meta"
              id="meta-form"
              class="drawer-form"
            >
              <.input
                name="post[slug]"
                value={@post["slug"]}
                label="URL slug"
                errors={List.wrap(@errors["slug"])}
              />
              <.input
                name="post[custom_excerpt]"
                type="textarea"
                value={@post["custom_excerpt"]}
                label="Excerpt"
                placeholder={@post["excerpt"]}
              />
              <.input
                name="post[tags]"
                value={Enum.join(@post["tags"], ", ")}
                label="Tags"
                placeholder="elixir, liveview"
              />
              <.input
                name="post[feature_image]"
                value={@post["feature_image"]}
                label="…or an image URL"
              />
              <.input
                name="post[visibility]"
                type="select"
                value={@post["visibility"]}
                label="Visibility"
                options={[{"Public", "public"}, {"Members only", "members"}]}
              />
              <.input
                name="post[featured]"
                type="checkbox"
                checked={@post["featured"]}
                label="Featured"
              />
              <.input name="post[meta_title]" value={@post["meta_title"]} label="Meta title" />
              <.input
                name="post[meta_description]"
                type="textarea"
                value={@post["meta_description"]}
                label="Meta description"
              />
            </.form>

            <div class="drawer-section">
              <label class="drawer-label" for="schedule-at">Schedule (UTC)</label>
              <form phx-submit="schedule" class="drawer-row">
                <input
                  type="datetime-local"
                  id="schedule-at"
                  name="at"
                  class="input"
                  value={local(@post["published_at"])}
                />
                <button type="submit" class="btn-ghost">Set</button>
              </form>
            </div>

            <div class="drawer-section is-danger">
              <button phx-click="delete" data-confirm="Delete this post for good?" class="btn-danger"><.icon
                name="hero-trash"
                class="size-4"
              /> Delete {@post["type"]}</button>
            </div>
          </aside>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  defp upload_error(:too_large), do: "too large (#{div(Uploads.max_bytes(), 1024 * 1024)} MB max)"
  defp upload_error(:not_accepted), do: "not an image"
  defp upload_error(:too_many_files), do: "too many files"
  defp upload_error(other), do: inspect(other)

  defp snippet(%{"slug" => slug, "props" => props}) do
    args =
      props
      |> List.wrap()
      |> Enum.filter(&(&1["required"] == true))
      |> Enum.map_join(" ", &"#{&1["name"]}=\"\"")

    String.trim("{{widget #{slug} #{args}}}")
  end

  defp local(nil), do: ""

  defp local(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%dT%H:%M")
      _ -> ""
    end
  end
end
