defmodule WraithWeb.Admin.CommentsLive do
  @moduledoc "Moderation: the newest comments, hide or show, remove."
  use WraithWeb, :live_view
  alias Wraith.Comments

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(page_title: "Comments", status: "published") |> load()}

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, socket |> assign(status: params["status"] || "published") |> load()}

  defp load(socket), do: assign(socket, comments: Comments.recent(socket.assigns.status, 100))

  @impl true
  def handle_event("hide", %{"post" => post_id, "id" => id}, socket) do
    with %{} = c <- Comments.get(post_id, id), do: Comments.set_status(c, "hidden")
    {:noreply, load(socket)}
  end

  def handle_event("show", %{"post" => post_id, "id" => id}, socket) do
    with %{} = c <- Comments.get(post_id, id), do: Comments.set_status(c, "published")
    {:noreply, load(socket)}
  end

  def handle_event("delete", %{"post" => post_id, "id" => id}, socket) do
    with %{} = c <- Comments.get(post_id, id), do: Comments.delete(c)
    {:noreply, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} active={:comments} title="Comments">
      <div class="filter-chips" role="tablist">
        <.link patch={~p"/admin/comments"} class={["chip", @status == "published" && "is-active"]}>Published</.link>
        <.link
          patch={~p"/admin/comments?status=hidden"}
          class={["chip", @status == "hidden" && "is-active"]}
        >Hidden</.link>
      </div>
      <p :if={not Comments.enabled?()} class="lede">
        Comments are off. Turn them on in <.link navigate={~p"/admin/settings"}>Settings</.link>.
      </p>
      <div :if={@comments == []} class="panel-empty">Nothing here.</div>
      <ul class="row-list" id="comments">
        <li :for={c <- @comments} class="row" id={"comment-" <> c["id"]}>
          <div class="row-main">
            <span class="row-title">{c["member_name"]}
            <span class="row-sub">on
            <a href={"/#{c["post_slug"]}#comment-#{c["id"]}"} target="_blank">{c["post_title"]}</a>
            · {String.slice(c["created_at"], 0, 16)}</span></span>
            <span class="comment-text">{if c["body"] == "", do: "[removed]", else: c["body"]}</span>
          </div>
          <div class="row-actions">
            <button
              :if={c["status"] == "published"}
              phx-click="hide"
              phx-value-post={c["post_id"]}
              phx-value-id={c["id"]}
              class="icon-btn"
              title="Hide"
            ><.icon name="hero-eye-slash" class="size-4" /></button>
            <button
              :if={c["status"] == "hidden"}
              phx-click="show"
              phx-value-post={c["post_id"]}
              phx-value-id={c["id"]}
              class="icon-btn"
              title="Show"
            ><.icon name="hero-eye" class="size-4" /></button>
            <button
              phx-click="delete"
              phx-value-post={c["post_id"]}
              phx-value-id={c["id"]}
              data-confirm="Remove this comment?"
              class="icon-btn is-danger"
              title="Remove"
            ><.icon name="hero-trash" class="size-4" /></button>
          </div>
        </li>
      </ul>
    </Layouts.admin>
    """
  end
end
