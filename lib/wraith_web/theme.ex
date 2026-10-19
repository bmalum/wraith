defmodule WraithWeb.Theme do
  @moduledoc """
  What a theme is: a **layout** (the HEEx templates and the structural CSS
  for a kind of site — editorial, list, grid, magazine, minimal, journal) plus
  **tokens** (fonts, palette, radius, measure) inlined as CSS variables, plus
  a Google Fonts URL. Eighteen themes ship from six layouts, so the type and
  colour change completely while a layout's templates are written once.

      defmodule WraithWeb.Themes.Broadsheet do
        use WraithWeb.Theme,
          name: "broadsheet",
          label: "Broadsheet",
          description: "Black on white, newspaper serif, a big first story.",
          layout: WraithWeb.Themes.Layouts.Editorial,
          fonts: "https://fonts.googleapis.com/css2?family=Playfair+Display:wght@500;700&family=Source+Serif+4&display=swap",
          tokens: %{"--heading" => "'Playfair Display', serif", "--body" => "'Source Serif 4', serif", "--paper" => "#fff", …}
      end

  A layout module (`WraithWeb.Theme.Layout`) embeds `templates/{layout,index,
  post,listing}.html.heex` and gets `tag`, `author`, `search` from its
  `listing`, and `subscribe`/`member` from `WraithWeb.Themes.Shared`.
  Tokens every layout reads (`priv/static/themes/base.css` sets fallbacks):
  `--heading`, `--body`, `--mono`, `--paper`, `--paper-2`, `--rule`, `--ink`,
  `--ink-2`, `--ink-3`, `--accent`, `--radius`, `--measure`, `--scheme`
  (`light` | `dark`).
  """

  @type info :: %{
          name: String.t(),
          label: String.t(),
          description: String.t(),
          layout: module(),
          layout_name: String.t(),
          css: [String.t()],
          fonts: String.t() | nil,
          tokens: %{String.t() => String.t()},
          swatch: [String.t()]
        }

  @callback info() :: info()
  @callback layout(map()) :: Phoenix.LiveView.Rendered.t()
  @callback index(map()) :: Phoenix.LiveView.Rendered.t()
  @callback post(map()) :: Phoenix.LiveView.Rendered.t()
  @callback tag(map()) :: Phoenix.LiveView.Rendered.t()
  @callback author(map()) :: Phoenix.LiveView.Rendered.t()
  @callback search(map()) :: Phoenix.LiveView.Rendered.t()
  @callback subscribe(map()) :: Phoenix.LiveView.Rendered.t()
  @callback member(map()) :: Phoenix.LiveView.Rendered.t()

  @pages ~w(layout index post tag author search subscribe member)a
  def pages, do: @pages

  defmacro __using__(opts) do
    {opts, _} = Code.eval_quoted(opts, [], __CALLER__)
    name = Keyword.fetch!(opts, :name)
    layout = Keyword.fetch!(opts, :layout)
    tokens = Map.new(Keyword.get(opts, :tokens, %{}))

    quote bind_quoted: [
            name: name,
            layout: layout,
            label: Keyword.get(opts, :label, String.capitalize(name)),
            description: Keyword.get(opts, :description, ""),
            fonts: Keyword.get(opts, :fonts),
            tokens: Macro.escape(tokens)
          ] do
      @behaviour WraithWeb.Theme

      @layout layout
      @tokens tokens
      @info %{
        name: name,
        label: label,
        description: description,
        layout: layout,
        layout_name: layout.name(),
        css: ["/themes/base.css", "/themes/layouts/#{layout.name()}.css"],
        fonts: fonts,
        tokens: tokens,
        swatch: [
          tokens["--paper"] || "#fff",
          tokens["--ink"] || "#111",
          tokens["--accent"] || "#5b4bff"
        ]
      }

      @impl true
      def info, do: @info

      for page <- WraithWeb.Theme.pages() do
        @impl true
        def unquote(page)(assigns), do: @layout.unquote(page)(assigns)
      end
    end
  end
end
