defmodule WraithWeb.Site.PostLive do
  @moduledoc "One post or page, with its widgets alive."
  use WraithWeb, :live_view
  alias WraithWeb.Themes
  import WraithWeb.WidgetHost

  alias Wraith.{Accounts, Comments, Content, Markdown, Settings}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    site = Settings.get()
    post = Content.get_published(slug) || preview(socket, slug)

    case post do
      nil ->
        raise WraithWeb.NotFound, "no post at /#{slug}"

      post ->
        if connected?(socket) do
          Content.subscribe()
          Comments.subscribe(post["id"])
        end

        author = post["author_id"] && Accounts.get_user(post["author_id"])
        authors = Accounts.list_users() |> Map.new(&{&1["id"], &1})
        url = url(~p"/#{post["slug"]}")

        {:ok,
         socket
         |> assign(
           site: site,
           theme: Themes.get(site["theme"]),
           post: post,
           author: author && Accounts.public(author),
           authors: authors,
           co_authors:
             (post["authors"] || []) |> Enum.map(&authors[&1]) |> Enum.reject(&is_nil/1),
           toc: if(post["show_toc"], do: Markdown.toc(post["markdown"]), else: []),
           comments: Comments.for_post(post["id"]),
           comments_enabled: Comments.enabled?() and post["status"] == "published",
           reply_to: nil,
           related:
             if(post["status"] == "published" and post["type"] == "post",
               do: Content.related(post),
               else: []
             ),
           meta: %{
             type: "article",
             title: post["meta_title"] || post["title"],
             description: post["meta_description"] || post["custom_excerpt"] || post["excerpt"],
             url: url,
             canonical: post["canonical_url"] || url,
             image: post["og_image"] || post["feature_image"],
             published_at: post["published_at"],
             tags: post["tags"]
           },
           page_title: post["meta_title"] || post["title"],
           meta_description:
             if(post["visibility"] == "members",
               do: nil,
               else: post["meta_description"] || post["excerpt"]
             ),
           locked:
             not (socket.assigns.current_user != nil or
                    Wraith.Members.can_read?(socket.assigns[:current_member], post["visibility"]))
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

  def handle_event(
        "comment",
        %{"body" => body} = params,
        %{assigns: %{current_member: %{} = member}} = socket
      ) do
    parent = if params["parent_id"] in [nil, ""], do: nil, else: params["parent_id"]

    case Comments.create(socket.assigns.post, member, body, parent) do
      {:ok, _} -> {:noreply, assign(socket, reply_to: nil)}
      {:error, why} -> {:noreply, put_flash(socket, :error, why)}
    end
  end

  def handle_event("comment", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Sign in to comment.")}

  defp may_remove?(%{current_user: %{}}, _c), do: true
  defp may_remove?(%{current_member: %{"id" => id}}, %{"member_id" => id}), do: true
  defp may_remove?(_assigns, _c), do: false

  def handle_event("reply-to", %{"id" => id}, socket),
    do: {:noreply, assign(socket, reply_to: if(id == "", do: nil, else: id))}

  def handle_event("comment-delete", %{"id" => id}, socket) do
    with %{} = c <- Comments.get(socket.assigns.post["id"], id),
         true <- may_remove?(socket.assigns, c) do
      :ok = Comments.delete(c)
      {:noreply, socket}
    else
      _ -> {:noreply, put_flash(socket, :error, "Not yours to remove.")}
    end
  end

  @impl true
  def handle_info({:comments, _post_id}, socket),
    do: {:noreply, assign(socket, comments: Comments.for_post(socket.assigns.post["id"]))}

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
    <Layouts.site
      flash={@flash}
      site={@site}
      theme={@theme}
      current_user={@current_user}
      current_member={assigns[:current_member]}
    >
      <WraithWeb.SiteComponents.theme_page
        theme={@theme}
        page={:post}
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
