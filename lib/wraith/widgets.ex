defmodule Wraith.Widgets do
  @moduledoc """
  The widget library and the live state of every embedded instance.

  A widget *definition* is an item: `slug`, `name`, `description`, `kind`
  (`"lua"` or `"elixir"`), `source` (Lua) or `module` (Elixir), `props`
  (documentation of the props it takes), `enabled`, `version`. Every save
  of a Lua widget writes a numbered version (`VER#n`) so the studio can
  roll back. The built-in Lua widgets ship in `priv/widgets/*.lua` and
  are seeded on boot when missing (`seed_builtins/0`); the Elixir ones are
  the modules in `builtin_modules/0`.

  An *instance* is `{slug, instance_id}`; its state lives at
  `WSTATE#slug#instance` and changes are broadcast on
  `"widget:" <> instance_id` as `{:widget, slug, instance_id, state}`.
  """
  alias Wraith.Store
  alias Wraith.Store.Keys
  alias Wraith.Widgets.Lua

  @kinds ~w(lua elixir)
  # a handler that grows the shared state past this is refused
  @max_state_bytes 64 * 1024

  @builtin_modules [
    Wraith.Widgets.Builtin.Countdown,
    Wraith.Widgets.Builtin.LiveVisitors
  ]

  def builtin_modules, do: @builtin_modules

  # ---- definitions ----------------------------------------------------------------

  def get(slug) when is_binary(slug) do
    {pk, sk} = Keys.widget(slug)

    case Store.get(pk, sk) do
      {:ok, w} -> w
      :error -> nil
    end
  end

  def list, do: Store.all(Keys.widgets_index(), index: :gsi1)

  def list_enabled, do: list() |> Enum.filter(&(&1["enabled"] == true))

  @doc "Create or replace a widget. Lua source is checked first; a change writes a version."
  @spec save(map()) :: {:ok, map()} | {:error, map()}
  def save(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    slug = attrs["slug"] |> to_string() |> String.trim() |> Wraith.Slug.slugify()
    kind = attrs["kind"] || "lua"

    errors =
      %{}
      |> put_error("slug", slug == "" or slug == "untitled", "can't be blank")
      |> put_error("kind", kind not in @kinds, "is unknown")
      |> put_error("name", to_string(attrs["name"]) == "", "can't be blank")
      |> lua_errors(kind, attrs["source"])
      |> module_errors(kind, attrs["module"])

    if map_size(errors) > 0 do
      {:error, errors}
    else
      {pk, sk} = Keys.widget(slug)

      result =
        Store.update(pk, sk, fn current ->
          current = current || %{"rev" => 0, "enabled" => true}
          changed? = kind == "lua" and current["source"] != attrs["source"]

          n =
            if current["rev"] in [nil, 0] or changed?,
              do: (current["rev"] || 0) + 1,
              else: current["rev"]

          current
          |> Map.merge(%{
            "gsi1pk" => Keys.widgets_index(),
            "gsi1sk" => to_string(attrs["name"]),
            "slug" => slug,
            "name" => to_string(attrs["name"]),
            "description" => to_string(attrs["description"] || current["description"] || ""),
            "kind" => kind,
            "props" => List.wrap(attrs["props"] || current["props"] || []),
            "enabled" => Map.get(attrs, "enabled", current["enabled"]) in [true, "true", "on"],
            "rev" => n
          })
          |> then(fn w ->
            if kind == "lua",
              do: Map.put(w, "source", attrs["source"]),
              else: Map.put(w, "module", attrs["module"])
          end)
          |> Map.put("builtin", attrs["builtin"] == true or current["builtin"] == true)
        end)

      with {:ok, widget} <- result do
        if kind == "lua", do: write_version(widget)
        {:ok, widget}
      end
    end
  end

  defp write_version(%{"slug" => slug, "rev" => n, "source" => source}) do
    {pk, sk} = Keys.widget_version(slug, n)
    Store.put(%{"pk" => pk, "sk" => sk, "rev" => n, "source" => source}, condition: :not_exists)
  end

  def versions(slug),
    do: Store.all("WIDGET#" <> slug, begins_with: Keys.widget_versions_prefix(), forward: false)

  @doc "Make an earlier version the current source (writes a new version)."
  def rollback(slug, n) do
    {pk, sk} = Keys.widget_version(slug, n)

    with {:ok, %{"source" => source}} <- Store.get(pk, sk),
         %{} = widget <- get(slug) do
      save(Map.put(widget, "source", source))
    else
      _ -> {:error, %{"version" => "not found"}}
    end
  end

  def set_enabled(slug, enabled?) do
    {pk, sk} = Keys.widget(slug)
    Store.update(pk, sk, &Map.put(&1, "enabled", enabled?))
  end

  def delete(slug) do
    {pk, sk} = Keys.widget(slug)
    Enum.each(versions(slug), &Store.delete(&1["pk"], &1["sk"]))
    Store.delete(pk, sk)
  end

  @doc "Seed the built-ins that are missing. Idempotent; run at boot."
  def seed_builtins do
    for mod <- @builtin_modules do
      d = mod.describe()

      slug =
        mod |> Module.split() |> List.last() |> Macro.underscore() |> String.replace("_", "-")

      if is_nil(get(slug)) do
        {:ok, _} =
          save(%{
            slug: slug,
            name: d.name,
            description: d.description,
            kind: "elixir",
            module: Atom.to_string(mod),
            props: d.props,
            builtin: true
          })
      end
    end

    for path <- Path.wildcard(Path.join(:code.priv_dir(:wraith), "widgets/*.lua")) do
      slug = Path.basename(path, ".lua")
      source = File.read!(path)
      {name, description} = header(source)

      if is_nil(get(slug)) do
        {:ok, _} =
          save(%{
            slug: slug,
            name: name,
            description: description,
            kind: "lua",
            source: source,
            builtin: true
          })
      end
    end

    :ok
  end

  # `-- name: Poll` / `-- description: ...` comment lines at the top of a .lua file
  defp header(source) do
    name =
      Regex.run(~r/^--\s*name:\s*(.+)$/m, source) |> then(&(&1 && String.trim(Enum.at(&1, 1))))

    desc =
      Regex.run(~r/^--\s*description:\s*(.+)$/m, source)
      |> then(&(&1 && String.trim(Enum.at(&1, 1))))

    {name || "Widget", desc || ""}
  end

  # ---- instances --------------------------------------------------------------------

  def topic(instance), do: "widget:" <> instance
  def subscribe(instance), do: Phoenix.PubSub.subscribe(Wraith.PubSub, topic(instance))

  @doc "The state of an instance (initialised from props when it has none)."
  def state(%{"slug" => slug} = widget, instance, props) do
    {pk, sk} = Keys.widget_state(slug, instance)

    case Store.get(pk, sk) do
      {:ok, %{"state" => state}} ->
        state

      :error ->
        case run(widget, :init, [props], %{instance: instance}) do
          {:ok, %{} = state} -> state
          _ -> %{}
        end
    end
  end

  @doc "Render an instance: `{:ok, html} | {:error, message}`."
  def render(%{"enabled" => false}, _instance, _props, _state, _meta),
    do: {:error, "widget is disabled"}

  def render(widget, instance, props, state, meta) do
    meta = Map.merge(%{instance: instance, visitor: nil, presence: 0, post: nil}, meta)

    meta =
      Map.put_new_lazy(meta, :private, fn -> private(widget["slug"], instance, meta[:visitor]) end)

    case run(widget, :render, [state, props, meta_for(meta)], meta) do
      {:ok, html} when is_binary(html) -> {:ok, sanitize(html)}
      {:ok, other} -> {:error, "render returned #{inspect(other)}, not a string"}
      {:error, _} = e -> e
    end
  end

  @doc """
  A reader's event: run `handle`, save and broadcast the state.
  `{:ok, state} | {:error, message}`. The save is a read-modify-write, so
  two readers clicking at once both count.
  """
  def dispatch(%{"slug" => slug} = widget, instance, props, event, payload, meta) do
    meta = Map.merge(%{instance: instance, visitor: nil, presence: 0, post: nil}, meta)
    meta = Map.put(meta, :private, private(slug, instance, meta[:visitor]))
    {pk, sk} = Keys.widget_state(slug, instance)
    payload = if is_map(payload), do: payload, else: %{}

    outcome =
      Store.update(pk, sk, fn current ->
        state = (current && current["state"]) || state(widget, instance, props)

        case run(widget, :handle, [state, event, payload, meta_for(meta)], meta) do
          {:ok, %{} = next} ->
            checked(next, slug, instance)

          {:ok, {%{} = next, priv}} ->
            put_private(slug, instance, meta[:visitor], priv)
            checked(next, slug, instance)

          {:ok, [%{} = next, priv]} ->
            put_private(slug, instance, meta[:visitor], priv)
            checked(next, slug, instance)

          {:ok, {:error, why}} ->
            throw({:refused, why})

          {:ok, other} ->
            throw({:refused, "handle returned #{inspect(other)}"})

          {:error, why} ->
            throw({:refused, why})
        end
      end)

    case outcome do
      {:ok, %{"state" => state}} ->
        Phoenix.PubSub.broadcast(Wraith.PubSub, topic(instance), {:widget, slug, instance, state})
        {:ok, state}

      {:error, e} ->
        {:error, inspect(e)}
    end
  catch
    {:refused, why} -> {:error, to_string(why)}
  end

  # the state item, refused when it has grown past the cap
  defp checked(next, slug, instance) do
    if byte_size(Jason.encode!(next)) > @max_state_bytes,
      do: throw({:refused, "widget state would exceed #{div(@max_state_bytes, 1024)} KB"}),
      else: %{"state" => next, "slug" => slug, "instance" => instance}
  end

  @doc "This visitor's private slice of an instance (a map; empty when none)."
  def private(_slug, _instance, nil), do: %{}

  def private(slug, instance, visitor) do
    {pk, sk} = Keys.widget_state(slug, instance <> "#" <> visitor)

    case Store.get(pk, sk) do
      {:ok, %{"private" => p}} when is_map(p) -> p
      _ -> %{}
    end
  end

  defp put_private(_slug, _instance, nil, _priv), do: :ok

  # per-visitor state is reader-influenced (a widget echoing payloads into it);
  # it gets the same cap as shared state so items can't grow to Dynamo's 400 KB
  defp put_private(slug, instance, visitor, priv) when is_map(priv) do
    if byte_size(Jason.encode!(priv)) > @max_state_bytes,
      do: throw({:refused, "widget private state would exceed #{div(@max_state_bytes, 1024)} KB"})

    {pk, sk} = Keys.widget_state(slug, instance <> "#" <> visitor)
    Store.put(%{"pk" => pk, "sk" => sk, "private" => priv})
  end

  defp put_private(_slug, _instance, _visitor, _priv), do: :ok

  @doc "The refresh interval a Lua widget asks for (`tick = N` in its chunk), in seconds, or nil."
  def tick(%{"kind" => "lua", "source" => source}) do
    # 5 s … 1 day; Process.send_after rejects anything past 2^32 ms, and a
    # bad value here would crash every reader's mount
    case Regex.run(~r/^\s*tick\s*=\s*(\d+)/m, source) do
      [_, n] -> n |> String.to_integer() |> max(5) |> min(86_400)
      _ -> nil
    end
  end

  def tick(_), do: nil

  def reset_state(slug, instance) do
    {pk, sk} = Keys.widget_state(slug, instance)
    Store.delete(pk, sk)
  end

  # ---- what a widget may emit ------------------------------------------------------

  # Widget authors are staff (and, through MCP, anyone the Policy lets manage
  # widgets); their HTML still goes through an allowlist before it reaches every
  # reader: no scripts, no event handlers, no javascript: URLs, and — because a
  # widget renders *inside* the reader's LiveView — no way to fire the host
  # page's own events: phx-click/phx-submit may only be "widget".
  @sanitize MDEx.Document.default_sanitize_options()
            |> Keyword.put(
              :add_tags,
              ~w(button input label select option textarea form svg path circle rect line polyline polygon g progress meter time small b section article header footer nav figure figcaption details summary)
            )
            |> Keyword.put(
              :add_generic_attributes,
              ~w(class style id role title type name value disabled checked selected placeholder min max step tabindex datetime for width height viewBox fill stroke d cx cy r x y x1 y1 x2 y2 points transform)
            )
            # phx-click is pinned to the widget event; any other phx-* (phx-hook,
            # phx-submit, a phx-click naming the host LiveView's own handlers like
            # comment-delete) is stripped — a widget may not drive the page it's on.
            # data-* is limited to the widget's own namespace; phoenix_html's
            # data-method/data-to would otherwise turn an <a> into a form POST.
            |> Keyword.put(:add_generic_attribute_prefixes, ~w(aria- data-w-))
            |> Keyword.put(:add_tag_attributes, %{
              "button" => ~w(phx-click phx-value-instance phx-value-event phx-value-payload),
              "a" => ~w(phx-click phx-value-instance phx-value-event phx-value-payload),
              "form" => ~w(phx-submit phx-value-instance phx-value-event),
              "input" => ~w(phx-value-instance phx-value-event),
              "select" => ~w(phx-value-instance phx-value-event)
            })
            |> Keyword.put(:rm_tags, ~w(script iframe object embed))

  @doc """
  Allowlist-sanitise widget HTML: `MDEx.safe_html/2` (ammonia) for tags,
  attributes and URLs, then a second pass that pins every `phx-click` /
  `phx-submit` to the value `"widget"`. The sanitiser can allow an attribute
  but not reliably constrain its value; a widget that could emit
  `phx-click="comment-delete"` would be clicking the reader's own buttons.
  """
  def sanitize(html) when is_binary(html) do
    html
    |> MDEx.safe_html(sanitize: @sanitize, escape: [content: false])
    |> pin_phx_events()
  end

  @phx_event_attrs ~w(phx-click phx-submit)

  defp pin_phx_events(html) do
    # cheap textual pass over attributes; the HTML is already well-formed from
    # ammonia, so attribute boundaries are regular
    Regex.replace(~r/\s(phx-(?:click|submit))="([^"]*)"/, html, fn whole, attr, value ->
      if attr in @phx_event_attrs and value == "widget", do: whole, else: ""
    end)
  end

  # Lua gets meta as a plain table (atoms become strings), Elixir widgets the map
  defp meta_for(meta),
    do:
      Map.new(meta, fn {k, v} ->
        {to_string(k), if(k == :post and is_map(v), do: Map.take(v, ~w(id title slug)), else: v)}
      end)

  defp run(%{"kind" => "lua", "source" => source}, fun, args, meta) do
    Lua.call(source, Atom.to_string(fun), args, meta)
  end

  defp run(%{"kind" => "elixir", "module" => mod}, fun, args, _meta) do
    module = String.to_existing_atom(mod)

    if module in @builtin_modules do
      try do
        case {fun, args} do
          {:init, [props]} ->
            {:ok, module.init(props)}

          {:render, [state, props, meta]} ->
            {:ok, module.render(state, props, atomize(meta))}

          {:handle, [state, event, payload, meta]} ->
            {:ok, module.handle(state, event, payload, atomize(meta))}
        end
      rescue
        e -> {:error, Exception.message(e)}
      end
    else
      {:error, "unknown widget module"}
    end
  end

  defp run(_widget, _fun, _args, _meta), do: {:error, "widget has no code"}

  defp atomize(meta), do: Map.new(meta, fn {k, v} -> {String.to_existing_atom(k), v} end)

  # ---- validation -------------------------------------------------------------------

  defp lua_errors(errors, "lua", source) do
    cond do
      not is_binary(source) or String.trim(source) == "" ->
        Map.put(errors, "source", "can't be blank")

      byte_size(source) > 64_000 ->
        Map.put(errors, "source", "is too long (64 KB max)")

      true ->
        case Lua.check(source) do
          :ok -> errors
          {:error, why} -> Map.put(errors, "source", why)
        end
    end
  end

  defp lua_errors(errors, _kind, _source), do: errors

  defp module_errors(errors, "elixir", module) do
    known = Enum.map(@builtin_modules, &Atom.to_string/1)

    if module in known,
      do: errors,
      else: Map.put(errors, "module", "is not a known widget module")
  end

  defp module_errors(errors, _kind, _module), do: errors

  defp put_error(errors, _k, false, _msg), do: errors
  defp put_error(errors, k, true, msg), do: Map.put(errors, k, msg)
end
