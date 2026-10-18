defmodule WraithWeb.Site.PostLive do
  @moduledoc "One post or page, with its widgets alive."
  use WraithWeb, :live_view
  import WraithWeb.WidgetHost
  import WraithWeb.SiteComponents

  alias Wraith.{Accounts, Content, Settings}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    site = Settings.get()
    post = Content.get_published(slug) || preview(socket, slug)

    case post do
      nil ->
        raise WraithWeb.NotFound, "no post at /#{slug}"

      post ->
        if connected?(socket), do: Content.subscribe()
        author = post["author_id"] && Accounts.get_user(post["author_id"])

        {:ok,
         socket
         |> assign(
           site: site,
           post: post,
           author: author && Accounts.public(author),
           authors: if(author, do: %{author["id"] => author}, else: %{}),
           page_title: post["meta_title"] || post["title"],
           meta_description:
             if(post["visibility"] == "members",
               do: nil,
               else: post["meta_description"] || post["excerpt"]
             ),
           locked: post["visibility"] == "members" and is_nil(socket.assigns.current_user)
         )
         |> mount_widgets(post["markdown"], post["id"], post)}
    end
  end

  # a signed-in author may read a draft at its URL
  defp preview(socket, slug) do
    if socket.assigns[:current_user], do: Content.get_post_by_slug(slug)
  end

  @impl true
  def handle_event("widget", params, socket), do: {:noreply, widget_event(socket, params)}

  @impl true
  def handle_info({:widget, _, _, _} = msg, socket), do: {:noreply, widget_info(socket, msg)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"} = msg, socket),
    do: {:noreply, widget_info(socket, msg)}

  def handle_info(
        {:content, :updated, %{"id" => id} = post},
        %{assigns: %{post: %{"id" => id}}} = socket
      ) do
    {:noreply, socket |> assign(post: post) |> mount_widgets(post["markdown"], post["id"], post)}
  end

  def handle_info(
        {:content, :deleted, %{"id" => id}},
        %{assigns: %{post: %{"id" => id}}} = socket
      ) do
    {:noreply, socket |> put_flash(:info, "This post was deleted.") |> push_navigate(to: ~p"/")}
  end

  def handle_info({:content, _, _}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.site flash={@flash} site={@site} current_user={@current_user}>
      <article class="post">
        <header class="post-head">
          <div class="post-card-tags">
            <.link :for={tag <- @post["tags"] || []} navigate={~p"/tag/#{tag}"}>{tag}</.link>
            <span :if={@post["status"] != "published"} class="badge-draft">{@post["status"]} preview</span>
          </div>
          <h1 class="post-title">{@post["title"]}</h1>
          <p :if={not @locked and @post["custom_excerpt"] not in [nil, ""]} class="post-excerpt">
            {@post["custom_excerpt"]}
          </p>
          <.byline post={@post} authors={@authors} />
          <div :if={@current_user} class="post-edit">
            <.link navigate={~p"/admin/posts/#{@post["id"]}"}><.icon
              name="hero-pencil"
              class="size-3"
            /> Edit</.link>
          </div>
        </header>

        <figure :if={@post["feature_image"]} class="post-figure">
          <img src={@post["feature_image"]} alt="" />
        </figure>

        <div :if={@locked} class="paywall">
          <h3>This post is for members</h3>
          <p>Sign up for free to keep reading.</p>
          <.link navigate={~p"/subscribe"} class="btn-accent">Subscribe</.link>
        </div>

        <.body :if={not @locked} segments={@segments} widgets={@widgets} />

        <footer :if={@author} class="post-foot">
          <div class="author-card">
            <div class="author-avatar">{String.first(@author["name"])}</div>
            <div>
              <.link navigate={~p"/author/#{@author["slug"]}"} class="author-name">{@author["name"]}</.link>
              <p :if={@author["bio"] not in [nil, ""]} class="author-bio">{@author["bio"]}</p>
            </div>
          </div>
        </footer>
      </article>
    </Layouts.site>
    """
  end
end
