defmodule WraithWeb.Site.AuthorLive do
  @moduledoc "An author and what they published."
  use WraithWeb, :live_view
  import WraithWeb.SiteComponents

  alias Wraith.{Accounts, Content, Settings}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    author = Accounts.get_user_by_slug(slug) || raise(WraithWeb.NotFound, "no author #{slug}")
    site = Settings.get()
    %{posts: posts} = Content.posts_by_author(author["id"], limit: 50)

    {:ok,
     assign(socket,
       site: site,
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
    <Layouts.site flash={@flash} site={@site} current_user={@current_user}>
      <section class="lead is-small">
        <div class="author-avatar is-large">{String.first(@author["name"])}</div>
        <h1 class="lead-title">{@author["name"]}</h1>
        <p :if={@author["bio"] not in [nil, ""]} class="lead-desc">{@author["bio"]}</p>
        <p class="lead-count">{length(@posts)} {if length(@posts) == 1, do: "post", else: "posts"}</p>
      </section>
      <section class="feed">
        <.post_card :for={post <- @posts} post={post} authors={@authors} />
      </section>
    </Layouts.site>
    """
  end
end
