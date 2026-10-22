defmodule WraithWeb.Site.PostLive do
  @moduledoc "One post or page, with its widgets alive."
  use WraithWeb, :live_view
  alias WraithWeb.Themes
  import WraithWeb.WidgetHost

  alias Wraith.{Accounts, Comments, Content, Markdown, Settings}

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    # a preview link: any status, no analytics hit, flagged on the page
    case Content.get_by_preview_token(token) do
      nil -> raise WraithWeb.NotFound, "no preview for that link"
      post -> mount_post(post, assign(socket, preview?: true), analytics: false)
    end
  end

  def mount(%{"slug" => slug}, _session, socket) do
    case Content.get_published(slug) || preview(socket, slug) do
      nil -> raise WraithWeb.NotFound, "no post at /#{slug}"
      post -> mount_post(post, assign(socket, preview?: false), analytics: true)
    end
  end

  defp mount_post(post, socket, opts) do
    site = Settings.get()

    if connected?(socket) do
      Content.subscribe()
      Comments.subscribe(post["id"])
      if opts[:analytics], do: Wraith.Analytics.hit(post["id"], socket.assigns[:visitor])
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
       co_authors: (post["authors"] || []) |> Enum.map(&authors[&1]) |> Enum.reject(&is_nil/1),
       toc: if(post["show_toc"], do: Markdown.toc(post["markdown"]), else: []),
       comments: Comments.for_post(post["id"]),
       comments_enabled: Comments.enabled?() and post["status"] == "published",
       reply_to: nil,
       related:
         if(post["status"] == "published" and post["type"] == "post",
           do: Content.related(post),
           else: []
         ),
       noindex: post["noindex"] == true or socket.assigns.preview?,
       json_ld: json_ld(post, author, url),
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
       locked: locked?(post, socket)
     )
     |> then(fn socket ->
       mount_widgets(socket, body_for(post, socket.assigns.locked), post["id"], post)
     end)}
  end

  # The one place the paywall is decided for the page. A preview link unlocks a
  # draft for its reviewer, but never a *published* post — once live, the token
  # is just another way to reach a page that still asks for membership.
  defp locked?(post, socket) do
    preview_unlocks? = socket.assigns.preview? and post["status"] != "published"

    not (preview_unlocks? or socket.assigns.current_user != nil or
           Wraith.Members.can_read?(socket.assigns[:current_member], post["visibility"]))
  end

  defp body_for(post, locked?), do: Content.readable_markdown(post, not locked?)

  defp json_ld(post, author, url) do
    %{
      "@context" => "https://schema.org",
      "@type" => if(post["type"] == "page", do: "WebPage", else: "BlogPosting"),
      "headline" => post["title"],
      "description" => post["meta_description"] || post["custom_excerpt"] || post["excerpt"],
      "url" => url,
      "datePublished" => post["published_at"],
      "dateModified" => post["updated_at"],
      "image" => post["og_image"] || post["feature_image"],
      "keywords" => Enum.join(post["tags"] || [], ", "),
      "author" =>
        author &&
          %{
            "@type" => "Person",
            "name" => author["name"],
            "url" => url(~p"/author/#{author["slug"]}")
          },
      "publisher" => %{"@type" => "Organization", "name" => Settings.get()["title"]},
      "isAccessibleForFree" => post["visibility"] == "public"
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
    |> Map.new()
    # :html_safe escapes < > & and U+2028/9 so a title can't close the <script>
    |> Jason.encode!(escape: :html_safe)
  end

  # a signed-in author may read a draft at its URL
  defp preview(socket, slug) do
    if socket.assigns[:current_user], do: Content.get_post_by_slug(slug)
  end

  @impl true
  def handle_event("widget", params, socket) do
    case Wraith.RateLimit.check(
           :widget_event,
           socket.assigns[:visitor] || socket.assigns[:client_ip]
         ) do
      :ok -> {:noreply, widget_event(socket, params)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Easy there — too many clicks.")}
    end
  end

  def handle_event(
        "comment",
        %{"body" => body} = params,
        %{assigns: %{current_member: %{} = member}} = socket
      ) do
    parent = if params["parent_id"] in [nil, ""], do: nil, else: params["parent_id"]

    with :ok <- Wraith.RateLimit.check(:comment, member["id"]),
         {:ok, _} <- Comments.create(socket.assigns.post, member, body, parent) do
      {:noreply, assign(socket, reply_to: nil)}
    else
      {:error, retry_ms} when is_integer(retry_ms) ->
        {:noreply, put_flash(socket, :error, "You are commenting too fast; wait a moment.")}

      {:error, why} ->
        {:noreply, put_flash(socket, :error, why)}
    end
  end

  def handle_event("comment", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Sign in to comment.")}

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

  defp may_remove?(%{current_user: %{}}, _c), do: true
  defp may_remove?(%{current_member: %{"id" => id}}, %{"member_id" => id}), do: true
  defp may_remove?(_assigns, _c), do: false

  @impl true
  def handle_info({:comments, _post_id}, socket),
    do: {:noreply, assign(socket, comments: Comments.for_post(socket.assigns.post["id"]))}

  def handle_info({:widget, _, _, _} = msg, socket), do: {:noreply, widget_info(socket, msg)}
  def handle_info({:widget_tick, _, _} = msg, socket), do: {:noreply, widget_info(socket, msg)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"} = msg, socket),
    do: {:noreply, widget_info(socket, msg)}

  def handle_info(
        {:content, :updated, %{"id" => id} = post},
        %{assigns: %{post: %{"id" => id}}} = socket
      ) do
    # an unpublish while a non-staff reader has the page open: the page is gone
    if post["status"] != "published" and is_nil(socket.assigns.current_user) and
         not socket.assigns.preview? do
      {:noreply, push_navigate(socket, to: ~p"/")}
    else
      locked = locked?(post, socket)

      {:noreply,
       socket
       |> assign(post: post, locked: locked)
       |> mount_widgets(body_for(post, locked), post["id"], post)}
    end
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
      preview={if @preview?, do: @post}
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
