defmodule Mix.Tasks.Wraith.Site do
  @shortdoc "Build the project site (landing page + docs) into _site/"
  @moduledoc """
  Builds what GitHub Pages serves, into `_site/`:

    * `index.html`: the landing page, rendered from `site/index.html.eex` with
      facts read from the code (the theme list, the MCP tool catalogue, a real
      widget), so the page can't drift from what ships
    * `shots/`: the theme screenshots from `priv/screenshots` as WebP
    * `docs/`: ex_doc's API reference plus guides. The guides are the README's
      sections, the widget guide the MCP server serves, and an MCP tool
      reference generated from `Wraith.Tools.catalogue/0`

  Preview it on this machine only:

      mix wraith.site
      python3 -m http.server --bind 127.0.0.1 --directory _site 8765

  Options: `--skip-docs`, `--skip-shots` (rebuild just the landing page).
  Runs in the dev environment (ex_doc is a dev dependency).
  """
  use Mix.Task

  @out "_site"
  @guides "_build/guides"
  # width each view is published at (the source PNGs are 1400 or 780 wide)
  @views [home: 1200, post: 1200, mobile: 520]
  # the layouts in the order the README and Settings list them
  @layouts [
    {"editorial", "Editorial", "masthead, lead story, card feed"},
    {"list", "List", "dated rows, a narrow column"},
    {"grid", "Grid", "centred logo, image-first cards"},
    {"magazine", "Magazine", "a hero story and a sidebar"},
    {"minimal", "Minimal", "one narrow column"},
    {"journal", "Journal", "dated entries, the date in the margin"}
  ]
  @tool_groups [
    {"Posts, pages, newsletters", ~r/^(posts?_|newsletter_|search$)/},
    {"Widgets", ~r/^widgets?_/},
    {"Members", ~r/^members?_/},
    {"Site, settings, themes", ~r/^(site_|settings_|themes_)/},
    {"Authors", ~r/^authors?_/},
    {"Tags", ~r/^tags?_/},
    {"Uploads", ~r/^uploads?_/},
    {"API keys", ~r/^api_keys?_/},
    {"Comments", ~r/^comments?_/}
  ]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [skip_docs: :boolean, skip_shots: :boolean])
    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:image)

    File.mkdir_p!(@out)
    File.rm_rf!(Path.join(@out, "assets"))
    File.cp_r!("site/assets", Path.join(@out, "assets"))
    File.rm_rf!(Path.join([@out, "assets", "docs"]))
    unless opts[:skip_shots], do: shots()
    landing()
    unless opts[:skip_docs], do: docs()
    # GitHub Pages runs Jekyll otherwise, which drops files that start with `_`
    File.write!(Path.join(@out, ".nojekyll"), "")
    Mix.shell().info("Built #{@out}/")
  end

  # ---- screenshots ---------------------------------------------------------------

  defp shots do
    dir = Path.join(@out, "shots")
    File.mkdir_p!(dir)

    for theme <- WraithWeb.Themes.names(), {view, width} <- @views do
      src = "priv/screenshots/#{theme}/#{view}.png"
      dst = Path.join(dir, "#{theme}-#{view}.webp")
      if stale?(src, dst), do: webp(Image.open!(src), width, dst)
    end

    # crops of the demo post: the hero (title down to the counter) and the widgets
    post = "priv/screenshots/paper/post.png"

    crops = [
      {"hero.webp", {0, 0, 1400, 1460}, 1000},
      {"widgets.webp", {340, 1020, 720, 470}, 720}
    ]

    for {name, {l, t, w, h}, width} <- crops, dst = Path.join(dir, name), stale?(post, dst) do
      post |> Image.open!() |> Image.crop!(l, t, w, h) |> webp(width, dst)
    end

    Mix.shell().info("  shots/ (#{length(File.ls!(dir))} images)")
  end

  defp webp(img, width, dst) do
    img
    |> Image.resize!(width / Image.width(img))
    |> Image.write!(dst, quality: 78)
  end

  defp stale?(src, dst) do
    case File.stat(dst) do
      {:ok, %{mtime: out}} -> File.stat!(src).mtime > out
      _ -> true
    end
  end

  # ---- landing page --------------------------------------------------------------

  defp landing do
    infos = WraithWeb.Themes.infos()
    catalogue = Wraith.Tools.catalogue()
    names = Enum.map(catalogue, & &1["name"])
    project = Mix.Project.config()

    layouts =
      for {key, label, blurb} <- @layouts do
        themes =
          for i <- infos, i.layout_name == key do
            %{name: i.name, label: i.label, description: i.description, swatch: i.swatch}
          end

        %{label: label, blurb: blurb, themes: themes}
      end

    assigns = [
      layouts: layouts,
      theme_count: length(infos),
      theme_word: words(length(infos)),
      theme_count_word: words(length(infos)) |> String.capitalize(),
      layout_count_word: words(length(@layouts)) |> String.capitalize(),
      tool_count: length(names),
      content_tool_count: length(Wraith.Tools.names(%{"scope" => "content"})),
      tool_groups: tool_groups(names),
      widget_line: ~s({{widget poll question="Tabs or spaces?" options="Tabs|Spaces" id=tabs}}),
      widget_lua: readme_lua(),
      version: project[:version],
      elixir: project[:elixir] |> String.trim_leading("~> ") |> Kernel.<>(" or newer"),
      source_url: project[:source_url],
      homepage: project[:homepage_url]
    ]

    html =
      EEx.eval_file("site/index.html.eex", [assigns: Map.new(assigns)], engine: EEx.SmartEngine)

    File.write!(Path.join(@out, "index.html"), html)
    Mix.shell().info("  index.html")
  end

  # the README's widget example, so the page and the docs show the same code
  defp readme_lua do
    case Regex.run(~r/```lua\n(.*?)```/s, File.read!("README.md")) do
      [_, code] -> String.trim_trailing(code)
      nil -> Mix.raise("wraith.site: README.md has no ```lua example")
    end
  end

  # the page's own copy stays honest when a theme or tool is added
  defp tool_groups(names) do
    for {label, re} <- @tool_groups,
        mine = Enum.filter(names, &Regex.match?(re, &1)),
        mine != [] do
      %{label: label, count: length(mine), examples: Enum.take(mine, 3)}
    end
    |> tap(fn groups ->
      grouped = groups |> Enum.map(& &1.count) |> Enum.sum()

      if grouped != length(names),
        do: Mix.raise("wraith.site: #{length(names) - grouped} MCP tool(s) match no group")
    end)
  end

  @words ~w(zero one two three four five six seven eight nine ten eleven twelve thirteen
            fourteen fifteen sixteen seventeen eighteen nineteen twenty)
  defp words(n) when n in 0..20, do: Enum.at(@words, n)
  defp words(n), do: Integer.to_string(n)

  @doc false
  def h(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  # ---- docs ------------------------------------------------------------------------

  defp docs do
    File.rm_rf!(@guides)
    File.mkdir_p!(@guides)
    readme_guides()
    File.write!(Path.join(@guides, "widgets.md"), widget_guide())
    File.write!(Path.join(@guides, "mcp-tools.md"), tools_md())

    out = Path.join(@out, "docs")
    File.rm_rf!(out)
    Mix.Task.run("docs", ["--output", out])
    # ex_doc's pages ask for this (a version picker on hexdocs); there is one version
    File.write!(Path.join(out, "docs_config.js"), "var versionNodes = [];\n")
  end

  # README.md stays the one source: its `## ` sections become guide pages
  defp readme_guides do
    [intro | sections] = File.read!("README.md") |> String.split(~r/^## /m)
    {box, rest} = Enum.split_with(sections, &String.starts_with?(&1, "What's in the box"))

    write_guide("overview", intro <> Enum.map_join(box, "", &("## " <> &1)))

    for section <- rest do
      [title, body] = String.split(section, "\n", parts: 2)
      body = String.replace(body, ~r/^### /m, "## ")
      write_guide(guide_slug(title), "# #{title}\n" <> body)
    end
  end

  defp guide_slug(title) do
    title
    |> Wraith.Slug.slugify()
    |> String.replace_prefix("the-", "")
    |> String.replace_suffix("-notes", "")
  end

  defp write_guide(slug, md), do: File.write!(Path.join(@guides, "#{slug}.md"), md)

  # the guide agents get as `widget_docs`, under a title that fits the sidebar
  defp widget_guide do
    Wraith.Studio.Tools.widget_docs()
    |> String.replace(
      ~r/\A# .*\n/,
      "# Writing widgets\n\nLua 5.3, sandboxed. This is the guide the MCP server serves to agents as `widget_docs`.\n"
    )
  end

  defp tools_md do
    catalogue = Wraith.Tools.catalogue()
    content = MapSet.new(Wraith.Tools.names(%{"scope" => "content"}))

    sections =
      for {label, re} <- @tool_groups,
          tools = Enum.filter(catalogue, &Regex.match?(re, &1["name"])),
          tools != [] do
        "## #{label}\n\n" <> Enum.map_join(tools, "\n", &tool_md(&1, content))
      end

    """
    # MCP tool reference

    Generated from `Wraith.Tools.catalogue/0`: #{length(catalogue)} tools. Every
    admin action is one of these; the studio agent and any MCP client at
    `POST /mcp` see the same registry. A tool is **read** (`readOnlyHint`),
    **write**, or **destructive** (`destructiveHint`). Staff contexts get the
    tools their role allows (`Wraith.Policy`); a Content key gets the ones
    marked *Content key*, which see only published posts with the paywall
    applied.

    #{Enum.join(sections, "\n")}
    """
  end

  defp tool_md(tool, content) do
    a = tool["annotations"]

    kind =
      cond do
        a["destructiveHint"] -> "destructive"
        a["readOnlyHint"] -> "read"
        true -> "write"
      end

    scope = if MapSet.member?(content, tool["name"]), do: ", Content key", else: ""
    props = tool["inputSchema"]["properties"] || %{}
    required = tool["inputSchema"]["required"] || []

    args =
      for {name, spec} <- Enum.sort_by(props, fn {n, _} -> {n not in required, n} end) do
        req = if name in required, do: " (required)", else: ""
        desc = if spec["description"] in [nil, ""], do: "", else: ": #{spec["description"]}"
        "- `#{name}`, #{spec["type"] || "any"}#{req}#{desc}"
      end

    """
    ### `#{tool["name"]}`

    *#{kind}#{scope}*. #{tool["description"]}
    #{if args == [], do: "", else: "\n" <> Enum.join(args, "\n") <> "\n"}
    """
  end
end
