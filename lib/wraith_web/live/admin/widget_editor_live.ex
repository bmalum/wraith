defmodule WraithWeb.Admin.WidgetEditorLive do
  @moduledoc """
  Write a Lua widget: source on the left, a live, clickable preview on the
  right (its own throw-away instance), versions underneath. The preview
  runs the unsaved source, so you see errors as you type.
  """
  use WraithWeb, :live_view

  alias Wraith.Widgets
  alias Wraith.Widgets.Lua

  @template """
  -- name: My widget
  -- description: What it does, in one line.

  function init(props)
    return { clicks = 0 }
  end

  function render(state, props, meta)
    local label = wraith.escape(props.label or "Click me")
    return '<div class="w-counter">'
      .. '<button class="w-btn" ' .. wraith.action("click") .. '>' .. label .. '</button>'
      .. '<span class="w-counter-value">' .. wraith.format(state.clicks) .. '</span>'
      .. '</div>'
  end

  function handle(state, event, payload, meta)
    if event == "click" then state.clicks = state.clicks + 1 end
    return state
  end
  """

  @impl true
  def mount(params, _session, socket) do
    widget =
      case socket.assigns.live_action do
        :new ->
          %{
            "slug" => "",
            "name" => "",
            "description" => "",
            "source" => @template,
            "kind" => "lua",
            "enabled" => true
          }

        :edit ->
          Widgets.get(params["slug"]) || raise(WraithWeb.NotFound, "no widget #{params["slug"]}")
      end

    {:ok,
     socket
     |> assign(
       widget: widget,
       source: widget["source"],
       name: widget["name"],
       slug: widget["slug"],
       description: widget["description"],
       props_text: "label=Hello",
       errors: %{},
       page_title: if(widget["name"] == "", do: "New widget", else: widget["name"]),
       versions: if(widget["slug"] != "", do: Widgets.versions(widget["slug"]), else: [])
     )
     |> preview_reset()}
  end

  # ---- events --------------------------------------------------------------------

  @impl true
  def handle_event("change", params, socket) do
    source_changed? =
      params["source"] not in [nil, socket.assigns.source] or
        params["props"] not in [nil, socket.assigns.props_text]

    socket =
      socket
      |> assign(
        source: params["source"] || socket.assigns.source,
        name: params["name"] || socket.assigns.name,
        slug: params["slug"] || socket.assigns.slug,
        description: params["description"] || socket.assigns.description,
        props_text: params["props"] || socket.assigns.props_text
      )

    # a new chunk means a new init(): the old state's shape may not fit any more
    {:noreply, if(source_changed?, do: preview_reset(socket), else: preview_render(socket))}
  end

  def handle_event("widget", %{"event" => event} = params, socket) do
    payload =
      case Jason.decode(params["payload"] || "{}") do
        {:ok, %{} = m} -> m
        _ -> %{}
      end

    meta = %{
      "instance" => "preview",
      "visitor" => socket.assigns.current_user["id"],
      "presence" => 1,
      "post" => nil
    }

    case Lua.call(
           socket.assigns.source,
           "handle",
           [socket.assigns.preview_state, event, payload, meta],
           %{instance: "preview"}
         ) do
      {:ok, %{} = state} ->
        {:noreply, socket |> assign(preview_state: state) |> preview_render()}

      {:ok, other} ->
        {:noreply, assign(socket, preview_html: {:error, "handle returned #{inspect(other)}"})}

      {:error, why} ->
        {:noreply, assign(socket, preview_html: {:error, why})}
    end
  end

  def handle_event("reset-preview", _params, socket), do: {:noreply, preview_reset(socket)}

  def handle_event("save", _params, socket) do
    attrs = %{
      slug: if(socket.assigns.slug == "", do: socket.assigns.name, else: socket.assigns.slug),
      name: socket.assigns.name,
      description: socket.assigns.description,
      kind: "lua",
      source: socket.assigns.source
    }

    case Widgets.save(attrs) do
      {:ok, widget} ->
        {:noreply,
         socket
         |> assign(
           widget: widget,
           slug: widget["slug"],
           errors: %{},
           versions: Widgets.versions(widget["slug"])
         )
         |> put_flash(:info, "Saved as rev #{widget["rev"]}.")
         |> push_patch(to: ~p"/admin/widgets/#{widget["slug"]}")}

      {:error, errors} ->
        {:noreply, assign(socket, errors: errors)}
    end
  end

  def handle_event("rollback", %{"rev" => rev}, socket) do
    case Widgets.rollback(socket.assigns.slug, String.to_integer(rev)) do
      {:ok, widget} ->
        {:noreply,
         socket
         |> assign(
           widget: widget,
           source: widget["source"],
           versions: Widgets.versions(widget["slug"])
         )
         |> put_flash(:info, "Rolled back to rev #{rev} (now rev #{widget["rev"]}).")
         |> preview_reset()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That version is gone.")}
    end
  end

  def handle_event("load-rev", %{"rev" => rev}, socket) do
    case Enum.find(socket.assigns.versions, &(&1["rev"] == String.to_integer(rev))) do
      %{"source" => source} ->
        {:noreply,
         socket
         |> assign(source: source)
         |> preview_reset()
         |> push_event("editor:set", %{source: source})}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ---- preview --------------------------------------------------------------------

  defp preview_reset(socket) do
    props = props(socket.assigns.props_text)

    state =
      case Lua.call(socket.assigns.source, "init", [props], %{instance: "preview"}) do
        {:ok, %{} = s} -> s
        _ -> %{}
      end

    socket |> assign(preview_state: state) |> preview_render()
  end

  defp preview_render(socket) do
    props = props(socket.assigns.props_text)

    meta = %{
      "instance" => "preview",
      "visitor" => socket.assigns.current_user["id"],
      "presence" => 1,
      "post" => nil
    }

    html =
      case Lua.check(socket.assigns.source) do
        :ok ->
          case Lua.call(
                 socket.assigns.source,
                 "render",
                 [socket.assigns.preview_state, props, meta],
                 %{instance: "preview"}
               ) do
            {:ok, html} when is_binary(html) -> {:ok, html}
            {:ok, other} -> {:error, "render returned #{inspect(other)}"}
            {:error, why} -> {:error, why}
          end

        {:error, why} ->
          {:error, why}
      end

    assign(socket, preview_html: html)
  end

  defp props(text) do
    text
    |> to_string()
    |> String.split(~r/\s+/, trim: true)
    |> Map.new(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {k, v}
        [k] -> {k, true}
      end
    end)
  end

  # ---- render ----------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} active={:widgets} bare>
      <div class="editor" id="widget-editor" phx-hook="Editor">
        <header class="editor-bar">
          <.link navigate={~p"/admin/widgets"} class="editor-back"><.icon
            name="hero-arrow-left"
            class="size-4"
          /> Widgets</.link>
          <span class="editor-status">
            <span :if={@widget["rev"]} class="status-pill is-published">rev {@widget["rev"]}</span>
            <span :if={@errors["source"]} class="editor-err">{@errors["source"]}</span>
            <span :if={@errors["slug"]} class="editor-err">slug {@errors["slug"]}</span>
            <span :if={@errors["name"]} class="editor-err">name {@errors["name"]}</span>
          </span>
          <div class="editor-actions">
            <button phx-click="save" class="btn-accent" disabled={@name == ""}>Save</button>
          </div>
        </header>

        <div class="editor-split">
          <form class="editor-write" phx-change="change" phx-debounce="300" id="widget-form">
            <div class="widget-meta">
              <input
                type="text"
                name="name"
                value={@name}
                placeholder="Widget name"
                class="editor-title is-small"
                autocomplete="off"
                phx-debounce="300"
              />
              <input
                type="text"
                name="slug"
                value={@slug}
                placeholder="slug"
                class="input is-mono"
                autocomplete="off"
                phx-debounce="300"
                disabled={@live_action == :edit}
              />
            </div>
            <input
              type="text"
              name="description"
              value={@description}
              placeholder="What it does, in one line"
              class="input"
              autocomplete="off"
              phx-debounce="300"
            />
            <textarea
              name="source"
              id="editor-markdown"
              class="editor-markdown is-code"
              spellcheck="false"
              phx-debounce="300"
            >{@source}</textarea>
          </form>

          <section class="editor-preview" aria-label="Preview">
            <div class="preview-bar">
              <label class="preview-props">
                <span>props</span>
                <input
                  type="text"
                  name="props"
                  value={@props_text}
                  form="widget-form"
                  class="input is-mono"
                  placeholder="label=Hi options=A|B"
                  phx-debounce="300"
                />
              </label>
              <button phx-click="reset-preview" class="btn-ghost" title="Reset the preview's state"><.icon
                name="hero-arrow-path"
                class="size-4"
              /> Reset</button>
            </div>

            <div class="preview-stage prose-wraith">
              <div class="widget" data-instance="preview">
                <%= case @preview_html do %>
                  <% {:ok, html} -> %>
                    {Phoenix.HTML.raw(html)}
                  <% {:error, why} -> %>
                    <div class="widget-error" role="alert">
                      <.icon name="hero-exclamation-triangle" class="size-4" /> {why}
                    </div>
                <% end %>
              </div>
            </div>

            <details class="preview-state">
              <summary>State</summary>
              <pre>{Jason.encode!(@preview_state, pretty: true)}</pre>
            </details>

            <section :if={@versions != []} class="versions">
              <h3>Versions</h3>
              <ul class="row-list">
                <li :for={v <- @versions} class="row is-compact">
                  <span class="row-main"><span class="row-title">rev {v["rev"]}</span><span class="row-sub">{String.slice(
                    v["created_at"],
                    0,
                    16
                  )}</span></span>
                  <div class="row-actions">
                    <button phx-click="load-rev" phx-value-rev={v["rev"]} class="btn-ghost is-small">Load</button>
                    <button
                      :if={v["rev"] != @widget["rev"]}
                      phx-click="rollback"
                      phx-value-rev={v["rev"]}
                      class="btn-ghost is-small"
                    >Roll back</button>
                  </div>
                </li>
              </ul>
            </section>

            <details class="help">
              <summary>Lua cheatsheet</summary>
              <pre>{help()}</pre>
            </details>
          </section>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  defp help do
    """
    init(props) -> state           state is a table; JSON-shaped
    render(state, props, meta)     -> HTML string (escape with wraith.escape)
    handle(state, event, payload, meta) -> new state (or error("why") to refuse)

    meta.instance, meta.visitor (per-browser id), meta.presence (readers now), meta.post

    wraith.action("evt", {k=v})   phx attributes for a clickable element
    wraith.escape(s)  wraith.format(n)  wraith.split("a|b", "|")
    wraith.json(t)  wraith.len(t)  wraith.keys(t)

    No os/io/require. 250 ms per call. Shortcode: {{widget slug key=value}}
    """
  end
end
