defmodule Wraith.Markdown do
  @moduledoc """
  Post bodies are Markdown (GFM: tables, strikethrough, task lists,
  footnotes, autolinks) rendered by `mdex` and sanitised — raw HTML an
  author pastes in is kept but scripts, handlers and the like are dropped.

  Widgets are embedded as shortcodes on a line of their own:

      {{widget poll question="Tabs or spaces?" options="Tabs|Spaces"}}
      {{widget counter}}
      {{widget countdown to=2027-01-01 id=launch}}

  `segments/1` splits a body into `{:html, html}` and
  `{:widget, slug, props, instance}` parts; the post page renders the
  HTML raw and each widget live. `id=` names the instance so the same
  state can be shared across posts; without it the instance is
  `<post id>:<n>`.
  """

  @shortcode ~r/^[ \t]*\{\{\s*widget\s+([a-z0-9][a-z0-9-]*)((?:\s+[a-zA-Z_][\w-]*(?:=(?:"[^"]*"|'[^']*'|[^\s}]+))?)*)\s*\}\}[ \t]*$/m

  @type segment :: {:html, String.t()} | {:widget, String.t(), map(), String.t()}

  @spec to_html(String.t()) :: String.t()
  def to_html(markdown) when is_binary(markdown) do
    MDEx.to_html!(markdown,
      extension: [
        table: true,
        strikethrough: true,
        tasklist: true,
        autolink: true,
        footnotes: true,
        header_id_prefix: "",
        shortcodes: true
      ],
      parse: [smart: true],
      render: [unsafe: true],
      syntax_highlight: [formatter: {:html_inline, theme: "github_light"}],
      sanitize: sanitize_options()
    )
  end

  def to_html(_), do: ""

  # the sanitizer must keep what the highlighter emits: inline colour styles,
  # `class`/`data-line`/`translate`/`tabindex` on pre/code/span, heading ids
  defp sanitize_options do
    MDEx.Document.default_sanitize_options()
    |> Keyword.update(:generic_attributes, ["id", "class", "style", "translate", "tabindex", "data-line"], &Enum.uniq(&1 ++ ["id", "class", "style", "translate", "tabindex", "data-line"]))
  end

  @doc "The headings (h2/h3) of a body as `[%{id, level, text}]` — the table of contents."
  @spec toc(String.t()) :: [map()]
  def toc(markdown) when is_binary(markdown) do
    markdown
    |> String.replace(@shortcode, "")
    |> String.replace(~r/```.*?```/s, "")
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^(\#{2,3})\s+(.+?)\s*\#*\s*$/, line) do
        [_, hashes, text] ->
          text = String.replace(text, ~r/[*_`\[\]]/, "")
          [%{"level" => String.length(hashes), "text" => text, "id" => Wraith.Slug.slugify(text)}]

        _ ->
          []
      end
    end)
  end

  def toc(_), do: []

  @doc "Split a post body into HTML and widget segments; `scope` seeds unnamed instance ids."
  @spec segments(String.t(), String.t()) :: [segment()]
  def segments(markdown, scope \\ "page") when is_binary(markdown) do
    parts = Regex.split(@shortcode, markdown, include_captures: true, trim: true)

    parts
    |> Enum.reduce({[], 0}, fn part, {acc, n} ->
      # split with include_captures hands every shortcode back as its own part
      case Regex.run(@shortcode, part) do
        [_, slug, args] ->
          props = parse_args(args)
          instance = props["id"] || "#{scope}:#{n}"
          {[{:widget, slug, props, instance} | acc], n + 1}

        _ ->
          case String.trim(part) do
            "" -> {acc, n}
            _ -> {[{:html, to_html(part)} | acc], n}
          end
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc "The shortcodes in a body: `[{slug, props}]` — for the editor's sidebar and the agent."
  def widgets_in(markdown) when is_binary(markdown) do
    for [_, slug, args] <- Regex.scan(@shortcode, markdown), do: {slug, parse_args(args)}
  end

  def widgets_in(_), do: []

  @doc "Plain text for excerpts and feeds."
  def to_text(markdown) do
    markdown
    |> to_string()
    |> String.replace(@shortcode, "")
    |> to_html()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  @doc "Estimated minutes to read."
  def reading_minutes(markdown) do
    words = markdown |> to_text() |> String.split(~r/\s+/, trim: true) |> length()
    max(1, round(words / 230))
  end

  defp parse_args(args) do
    ~r/([a-zA-Z_][\w-]*)(?:=(?:"([^"]*)"|'([^']*)'|([^\s}]+)))?/
    |> Regex.scan(args)
    |> Map.new(fn
      [_, key] -> {key, true}
      [_, key, dq] when dq != "" -> {key, dq}
      [_, key, "", sq] when sq != "" -> {key, sq}
      [_, key, "", "", bare] -> {key, cast(bare)}
      [_, key, dq, _, _] -> {key, dq}
      [_, key | _] -> {key, true}
    end)
  end

  defp cast("true"), do: true
  defp cast("false"), do: false

  defp cast(v) do
    case Integer.parse(v) do
      {i, ""} -> i
      _ -> v
    end
  end
end
