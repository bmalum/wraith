defmodule WraithWeb.Admin.PostsLive do
  @moduledoc "Every post (or page), filterable by status."
  use WraithWeb, :live_view

  alias Wraith.Content

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Content.subscribe()
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    type = if socket.assigns.live_action == :pages, do: "page", else: "post"
    status = params["status"]

    {:noreply,
     socket
     |> assign(
       type: type,
       status: status,
       page_title: if(type == "page", do: "Pages", else: "Posts")
     )
     |> load()}
  end

  defp load(socket) do
    me = socket.assigns.current_user

    posts =
      Content.list_all_posts(type: socket.assigns.type)
      |> Enum.filter(&(is_nil(socket.assigns.status) or &1["status"] == socket.assigns.status))
      # authors and contributors see their own work; editors and up see everything
      |> Enum.filter(&Wraith.Policy.can?(me, :edit_post, &1))

    assign(socket, posts: posts, selected: MapSet.new())
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    with %{} = p <- Content.get_post(id),
         true <- Wraith.Policy.can?(socket.assigns.current_user, :delete_post, p) do
      :ok = Content.delete_post(p)
      {:noreply, socket |> put_flash(:info, "Deleted.") |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, "You cannot delete that.")}
    end
  end

  def handle_event("select", %{"id" => id}, socket) do
    sel = socket.assigns.selected
    sel = if MapSet.member?(sel, id), do: MapSet.delete(sel, id), else: MapSet.put(sel, id)
    {:noreply, assign(socket, selected: sel)}
  end

  def handle_event("select-all", _params, socket) do
    all = MapSet.new(socket.assigns.posts, & &1["id"])

    {:noreply,
     assign(socket,
       selected: if(MapSet.equal?(all, socket.assigns.selected), do: MapSet.new(), else: all)
     )}
  end

  # bulk: publish / unpublish / delete / tag the selection
  def handle_event("bulk", %{"action" => action} = params, socket) do
    me = socket.assigns.current_user

    posts =
      socket.assigns.posts |> Enum.filter(&MapSet.member?(socket.assigns.selected, &1["id"]))

    n =
      Enum.count(posts, fn p ->
        case action do
          "publish" ->
            Wraith.Policy.can?(me, :publish_post, p) and match?({:ok, _}, Content.publish_post(p))

          "unpublish" ->
            Wraith.Policy.can?(me, :publish_post, p) and
              match?({:ok, _}, Content.unpublish_post(p))

          "delete" ->
            Wraith.Policy.can?(me, :delete_post, p) and Content.delete_post(p) == :ok

          "feature" ->
            match?({:ok, _}, Content.update_post(p, %{featured: true}))

          "unfeature" ->
            match?({:ok, _}, Content.update_post(p, %{featured: false}))

          "tag" ->
            params["tag"] not in [nil, ""] and
              match?(
                {:ok, _},
                Content.update_post(p, %{tags: Enum.uniq(p["tags"] ++ [params["tag"]])})
              )

          _ ->
            false
        end
      end)

    {:noreply, socket |> put_flash(:info, "#{action}: #{n} post(s).") |> load()}
  end

  def handle_event("publish", %{"id" => id}, socket) do
    me = socket.assigns.current_user

    with %{} = post <- Content.get_post(id),
         true <- Wraith.Policy.can?(me, :publish_post, post),
         {:ok, _} <- Content.publish_post(post) do
      {:noreply, socket |> put_flash(:info, "Published.") |> load()}
    else
      false -> {:noreply, put_flash(socket, :error, "Your role cannot publish that post.")}
      _ -> {:noreply, put_flash(socket, :error, "Could not publish.")}
    end
  end

  def handle_event("unpublish", %{"id" => id}, socket) do
    me = socket.assigns.current_user

    with %{} = post <- Content.get_post(id),
         true <- Wraith.Policy.can?(me, :publish_post, post),
         {:ok, _} <- Content.unpublish_post(post) do
      {:noreply, socket |> put_flash(:info, "Back to draft.") |> load()}
    else
      false -> {:noreply, put_flash(socket, :error, "Your role cannot unpublish that post.")}
      _ -> {:noreply, put_flash(socket, :error, "Could not unpublish.")}
    end
  end

  @impl true
  def handle_info({:content, _, _}, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin
      flash={@flash}
      current_user={@current_user}
      active={if @type == "page", do: :pages, else: :posts}
      title={@page_title}
    >
      <:actions>
        <.link navigate={~p"/admin/posts/new?type=#{@type}"} class="btn-accent"><.icon
          name="hero-plus"
          class="size-4"
        /> New {@type}</.link>
      </:actions>

      <div class="filter-chips" role="tablist">
        <.chip to={base(@type)} active={is_nil(@status)}>All</.chip>
        <.chip
          :for={s <- Content.statuses()}
          to={base(@type) <> "?status=" <> s}
          active={@status == s}
        >
          {String.capitalize(s)}
        </.chip>
      </div>

      <div :if={@posts != []} class="bulk-bar">
        <label class="nav-page"><input
          type="checkbox"
          class="checkbox checkbox-sm"
          phx-click="select-all"
          checked={MapSet.size(@selected) == length(@posts)}
        /> all</label>
        <span class="row-sub">{MapSet.size(@selected)} selected</span>
        <form :if={MapSet.size(@selected) > 0} phx-submit="bulk" class="inline-form">
          <select name="action" class="select">
            <option value="publish">Publish</option>
            <option value="unpublish">Unpublish</option>
            <option value="feature">Feature</option>
            <option value="unfeature">Unfeature</option>
            <option value="tag">Add tag…</option>
            <option value="delete">Delete</option>
          </select>
          <input type="text" name="tag" placeholder="tag (for Add tag)" class="input" />
          <button type="submit" class="btn-ghost" data-confirm="Apply to the selected posts?">Apply</button>
        </form>
      </div>

      <div :if={@posts == []} class="panel-empty">Nothing here yet.</div>

      <ul class="row-list" id="posts">
        <li :for={p <- @posts} class="row" id={"post-" <> p["id"]}>
          <input
            type="checkbox"
            class="checkbox checkbox-sm"
            phx-click="select"
            phx-value-id={p["id"]}
            checked={MapSet.member?(@selected, p["id"])}
            aria-label="select"
          />
          <.link navigate={~p"/admin/posts/#{p["id"]}"} class="row-main">
            <span class="row-title">{if p["title"] == "", do: "(untitled)", else: p["title"]}</span>
            <span class="row-sub">
              /{p["slug"]}
              <span :if={p["tags"] != []}> · {Enum.join(p["tags"], ", ")}</span>
              <span :if={p["status"] == "scheduled"}> · goes live {p["published_at"]}</span>
            </span>
          </.link>
          <span class={["status-pill", "is-" <> p["status"]]}>{p["status"]}</span>
          <div class="row-actions">
            <a
              :if={p["status"] == "published"}
              href={~p"/#{p["slug"]}"}
              target="_blank"
              class="icon-btn"
              title="View"
            ><.icon name="hero-arrow-top-right-on-square" class="size-4" /></a>
            <button
              :if={p["status"] != "published"}
              phx-click="publish"
              phx-value-id={p["id"]}
              class="icon-btn"
              title="Publish now"
            ><.icon name="hero-paper-airplane" class="size-4" /></button>
            <button
              :if={p["status"] == "published"}
              phx-click="unpublish"
              phx-value-id={p["id"]}
              class="icon-btn"
              title="Unpublish"
            ><.icon name="hero-eye-slash" class="size-4" /></button>
            <button
              phx-click="delete"
              phx-value-id={p["id"]}
              data-confirm="Delete this post for good?"
              class="icon-btn is-danger"
              title="Delete"
            ><.icon name="hero-trash" class="size-4" /></button>
          </div>
        </li>
      </ul>
    </Layouts.admin>
    """
  end

  defp base("page"), do: ~p"/admin/pages"
  defp base(_), do: ~p"/admin/posts"

  attr :to, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp chip(assigns) do
    ~H"""
    <.link
      patch={@to}
      class={["chip", @active && "is-active"]}
      role="tab"
      aria-selected={to_string(@active)}
    >{render_slot(@inner_block)}</.link>
    """
  end
end
