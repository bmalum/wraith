defmodule WraithWeb.Admin.IntegrationsLive do
  @moduledoc "API keys for the Content and Admin APIs; export and import of the whole site (Ghost-compatible)."
  use WraithWeb, :live_view
  alias Wraith.{ApiKeys, Ghost}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Integrations", new_key: nil, imported: nil)
     |> load()
     |> allow_upload(:import,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: 100_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  defp load(socket), do: assign(socket, keys: ApiKeys.list())

  defp handle_progress(:import, entry, socket) do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          with {:ok, json} <- File.read(path), {:ok, data} <- Jason.decode(json) do
            {:ok, Ghost.import(data, author: socket.assigns.current_user)}
          else
            _ -> {:ok, {:error, "not a JSON export"}}
          end
        end)

      case result do
        {:ok, counts} ->
          {:noreply,
           socket
           |> assign(imported: counts)
           |> put_flash(:info, "Imported #{counts.posts} post(s).")}

        {:error, why} ->
          {:noreply, put_flash(socket, :error, to_string(why))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate-upload", _params, socket), do: {:noreply, socket}

  def handle_event("create-key", %{"label" => label, "kind" => kind}, socket) do
    case ApiKeys.create(label, kind) do
      {:ok, raw, _key} -> {:noreply, socket |> assign(new_key: raw) |> load()}
      {:error, why} -> {:noreply, put_flash(socket, :error, why)}
    end
  end

  def handle_event("delete-key", %{"id" => id}, socket) do
    :ok = ApiKeys.delete(id)
    {:noreply, socket |> assign(new_key: nil) |> load()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin
      flash={@flash}
      current_user={@current_user}
      active={:integrations}
      title="Integrations"
    >
      <div class="two-col">
        <section class="panel">
          <header class="panel-head">
            <h2>API keys</h2>
          </header>
          <div class="panel-form">
            <p class="form-help">
              Content API (read-only): <code>GET /api/content/posts?key=…</code>. Admin API:
              <code>Authorization: Bearer …</code>
              on <code>/api/admin/*</code>.
              Both answer in Ghost's JSON shape.
            </p>
            <div :if={@new_key} class="new-key" role="status">
              <strong>Copy it now — it is shown once.</strong>
              <code>{@new_key}</code>
            </div>
            <form phx-submit="create-key" class="inline-form" id="key-create-form">
              <input type="text" name="label" placeholder="What is it for?" class="input" required />
              <select name="kind" class="select">
                <option value="content">Content (read)</option>
                <option value="admin">Admin (read/write)</option>
              </select>
              <button type="submit" class="btn-accent">Create key</button>
            </form>
          </div>
          <ul class="row-list" id="api-keys">
            <li :for={k <- @keys} class="row" id={"key-" <> k["id"]}>
              <div class="row-main">
                <span class="row-title">{k["label"]} <span class="kind-pill">{k["kind"]}</span></span>
                <span class="row-sub">id {k["id"]} · {if k["last_used_at"],
                  do: "last used " <> String.slice(k["last_used_at"], 0, 16),
                  else: "never used"}</span>
              </div>
              <div class="row-actions">
                <button
                  phx-click="delete-key"
                  phx-value-id={k["id"]}
                  data-confirm="Revoke this key?"
                  class="icon-btn is-danger"
                  title="Revoke"
                ><.icon name="hero-trash" class="size-4" /></button>
              </div>
            </li>
          </ul>
        </section>

        <section class="panel">
          <header class="panel-head">
            <h2>Export &amp; import</h2>
          </header>
          <div class="panel-form">
            <p class="form-help">
              A Ghost-compatible JSON export of posts, tags, authors, settings, plus Wraith's widgets and members.
            </p>
            <a href={~p"/api/admin/db"} class="btn-ghost" download><.icon
              name="hero-arrow-down-tray"
              class="size-4"
            /> Download export</a>
            <h3 class="panel-sub">Import</h3>
            <p class="form-help">
              Upload a Ghost export (Settings → Labs → Export in Ghost) or a Wraith export. Existing slugs and emails are skipped; imported authors get a random password and can reset it by mail.
            </p>
            <form
              phx-change="validate-upload"
              phx-submit="validate-upload"
              id="import-form"
              phx-drop-target={@uploads.import.ref}
            >
              <label class="btn-ghost"><.icon name="hero-arrow-up-tray" class="size-4" />
              Choose a .json export <.live_file_input upload={@uploads.import} class="sr-only" /></label>
              <span :for={e <- @uploads.import.entries} class="row-sub">{e.client_name} {e.progress}%</span>
            </form>
            <dl :if={@imported} class="kv">
              <dt>Posts</dt><dd>
                {@imported.posts} imported, {@imported.posts_skipped} skipped, {@imported.posts_failed} failed
              </dd>
              <dt>Tags</dt><dd>{@imported.tags}</dd>
              <dt>Authors</dt><dd>{@imported.users}</dd>
              <dt>Members</dt><dd>{@imported.members}</dd>
              <dt>Widgets</dt><dd>{@imported.widgets}</dd>
            </dl>
          </div>
        </section>
      </div>
    </Layouts.admin>
    """
  end
end
