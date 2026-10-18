defmodule WraithWeb.Theme do
  @moduledoc """
  What a theme is. A theme is a directory under `lib/wraith_web/themes/<name>/`:

      <name>.ex                 # `use WraithWeb.Theme, name: "<name>", label: "…", description: "…"`
      templates/layout.html.heex   # wraps every public page; gets @inner_block, @site, @current_user
      templates/index.html.heex    # the feed: @site, @posts, @authors, @page, @has_next
      templates/post.html.heex     # one post: @post, @author, @authors, @segments, @widgets, @locked
      templates/tag.html.heex      # @tag, @posts, @authors
      templates/author.html.heex   # @author, @posts, @authors
      templates/subscribe.html.heex # @form, @done

  and its stylesheet at `priv/static/themes/<name>.css` (plain CSS, served
  as is; the root layout links it). Templates are HEEx compiled into the
  theme module, so a theme ships with the release. They can use
  `WraithWeb.SiteComponents` (`post_card`, `byline`, `body`, `pager`,
  `widget_frame`) and `~p` routes; `<.body segments={@segments} widgets={@widgets} />`
  is what keeps widgets live, whatever the theme looks like.

  The owner picks the theme in Settings (`theme`); `WraithWeb.Themes.current/0`
  resolves it, falling back to `paper`.
  """

  @type info :: %{name: String.t(), label: String.t(), description: String.t(), css: String.t()}

  @callback info() :: info()
  @callback layout(map()) :: Phoenix.LiveView.Rendered.t()
  @callback index(map()) :: Phoenix.LiveView.Rendered.t()
  @callback post(map()) :: Phoenix.LiveView.Rendered.t()
  @callback tag(map()) :: Phoenix.LiveView.Rendered.t()
  @callback author(map()) :: Phoenix.LiveView.Rendered.t()
  @callback subscribe(map()) :: Phoenix.LiveView.Rendered.t()

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)

    quote do
      @behaviour WraithWeb.Theme
      use Phoenix.Component
      use WraithWeb, :verified_routes
      import WraithWeb.CoreComponents, only: [icon: 1, input: 1]
      import WraithWeb.SiteComponents
      alias Phoenix.LiveView.JS

      @impl true
      def info,
        do: %{
          name: unquote(name),
          label: unquote(Keyword.get(opts, :label, String.capitalize(name))),
          description: unquote(Keyword.get(opts, :description, "")),
          css: "/themes/#{unquote(name)}.css"
        }

      embed_templates "templates/*"
    end
  end
end
