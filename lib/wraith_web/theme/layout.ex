defmodule WraithWeb.Theme.Layout do
  @moduledoc """
  A layout: `templates/layout.html.heex` (the frame), `index.html.heex` (the
  front page), `post.html.heex`, and `listing.html.heex` (the shape of a tag,
  author or search results page — it gets `@heading`, `@kicker`, `@lede`,
  `@posts`, `@authors`, plus `@tag`/`@author`/`@q`/`@results` as given).
  `subscribe` and `member` come from `WraithWeb.Themes.Shared`.

      defmodule WraithWeb.Themes.Layouts.Grid do
        use WraithWeb.Theme.Layout, name: "grid"
      end
  """

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)

    quote do
      use Phoenix.Component
      use WraithWeb, :verified_routes
      import WraithWeb.CoreComponents, only: [icon: 1, input: 1]
      import WraithWeb.SiteComponents

      import WraithWeb.Themes.Shared,
        only: [
          subscribe_page: 1,
          member_page: 1,
          search_form: 1,
          mode_toggle: 1,
          social_links: 1,
          site_credit: 1,
          nav_toggle: 1,
          author_meta: 1,
          listing_count: 1
        ]

      alias Phoenix.LiveView.JS

      def name, do: unquote(name)

      embed_templates "templates/*"

      def tag(assigns) do
        assigns
        |> Map.merge(%{
          kicker: "Tag",
          heading: assigns.tag["name"],
          lede: assigns.tag["description"]
        })
        |> listing()
      end

      def author(assigns) do
        assigns
        |> Map.merge(%{
          kicker: "Author",
          heading: assigns.author["name"],
          lede: assigns.author["bio"]
        })
        |> listing()
      end

      def search(assigns) do
        posts = Enum.map(assigns.results, & &1.post)

        assigns
        |> Map.merge(%{
          kicker: "Search",
          heading: if(assigns.q == "", do: "Search", else: "“#{assigns.q}”"),
          lede: nil,
          posts: posts,
          search: true
        })
        |> listing()
      end

      def subscribe(assigns), do: subscribe_page(assigns)
      def member(assigns), do: member_page(assigns)

      defoverridable tag: 1, author: 1, search: 1, subscribe: 1, member: 1
    end
  end
end
