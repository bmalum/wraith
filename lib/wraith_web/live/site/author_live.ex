defmodule WraithWeb.Site.AuthorLive do
  @moduledoc "An author and what they published."
  use WraithWeb, :live_view
  alias WraithWeb.Themes

  alias Wraith.{Accounts, Content, Settings}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    author = Accounts.get_user_by_slug(slug) || raise(WraithWeb.NotFound, "no author #{slug}")
    site = Settings.get()
    %{posts: posts} = Content.posts_by_author(author["id"], limit: 50)

    {:ok,
     assign(socket,
       site: site,
       theme: Themes.get(site["theme"]),
       author: author,
       posts: posts,
       authors: %{author["id"] => author},
       page_title: author["name"],
       meta_description: author["bio"]
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.site
      flash={@flash}
      site={@site}
      theme={@theme}
      current_user={@current_user}
      current_member={assigns[:current_member]}
    >
      <WraithWeb.SiteComponents.theme_page
        theme={@theme}
        page={:author}
        assigns={page_assigns(assigns)}
      />
    </Layouts.site>
    """
  end

  # what the theme's template sees: everything but LiveView's own bookkeeping
  defp page_assigns(assigns),
    do:
      Map.drop(assigns, [
        :flash,
        :theme,
        :socket,
        :__changed__,
        :live_action,
        :streams,
        :uploads,
        :myself
      ])
end
