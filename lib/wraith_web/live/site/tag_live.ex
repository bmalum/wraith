defmodule WraithWeb.Site.TagLive do
  @moduledoc "Every published post carrying a tag."
  use WraithWeb, :live_view
  import WraithWeb.SiteComponents

  alias Wraith.{Accounts, Content, Settings}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    tag = Content.get_tag(slug) || raise(WraithWeb.NotFound, "no tag #{slug}")
    site = Settings.get()
    %{posts: posts} = Content.posts_tagged(slug, limit: 50)
    authors = Accounts.list_users() |> Map.new(&{&1["id"], &1})

    {:ok,
     assign(socket,
       site: site,
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
    <Layouts.site flash={@flash} site={@site} current_user={@current_user}>
      <section class="lead is-small">
        <p class="lead-kicker">Tag</p>
        <h1 class="lead-title">{@tag["name"]}</h1>
        <p :if={@tag["description"] not in [nil, ""]} class="lead-desc">{@tag["description"]}</p>
        <p class="lead-count">{length(@posts)} {if length(@posts) == 1, do: "post", else: "posts"}</p>
      </section>
      <section class="feed">
        <.post_card :for={post <- @posts} post={post} authors={@authors} />
      </section>
    </Layouts.site>
    """
  end
end
