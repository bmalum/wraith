defmodule WraithWeb.Site.TagLive do
  @moduledoc "Every published post carrying a tag."
  use WraithWeb, :live_view

  alias Wraith.{Accounts, Content}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    tag = Content.get_tag(slug) || raise(WraithWeb.NotFound, "no tag #{slug}")
    %{posts: posts} = Content.posts_tagged(slug, limit: 50)
    authors = Accounts.list_users() |> Map.new(&{&1["id"], &1})

    {:ok,
     assign(socket,
       tag: tag,
       posts: posts,
       authors: authors,
       page_title: tag["name"],
       meta_description: tag["description"]
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
        page={:tag}
        assigns={WraithWeb.SiteComponents.page_assigns(assigns)}
      />
    </Layouts.site>
    """
  end

  # what the theme's template sees: everything but LiveView's own bookkeeping
end
