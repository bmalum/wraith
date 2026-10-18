defmodule WraithWeb.Admin.MembersLive do
  @moduledoc "Who subscribed."
  use WraithWeb, :live_view

  alias Wraith.Members

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Members", errors: %{}) |> load()}
  end

  defp load(socket),
    do: assign(socket, members: Members.list(limit: 200).members, count: Members.count())

  @impl true
  def handle_event("create", %{"email" => email, "name" => name}, socket) do
    case Members.create(%{email: email, name: name}) do
      {:ok, _} -> {:noreply, socket |> assign(errors: %{}) |> load()}
      {:error, errors} -> {:noreply, assign(socket, errors: errors)}
    end
  end

  def handle_event("status", %{"member" => id, "status" => status}, socket) do
    with %{} = m <- Members.get(id), {:ok, _} <- Members.update(m, %{status: status}) do
      {:noreply, load(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if m = Members.get(id), do: Members.delete(m)
    {:noreply, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin
      flash={@flash}
      current_user={@current_user}
      active={:members}
      title={"Members (#{@count})"}
    >
      <:actions>
        <a href={~p"/api/admin/members.csv"} class="btn-ghost" download><.icon
          name="hero-arrow-down-tray"
          class="size-4"
        /> CSV</a>
        <form phx-submit="create" class="inline-form">
          <input type="text" name="name" placeholder="Name" class="input" autocomplete="off" />
          <input
            type="email"
            name="email"
            placeholder="email@example.com"
            class="input"
            autocomplete="off"
            required
          />
          <button type="submit" class="btn-accent">Add</button>
        </form>
      </:actions>
      <p :if={@errors["email"]} class="form-error">Email {@errors["email"]}.</p>

      <div :if={@members == []} class="panel-empty">
        No members yet. Share <code>/subscribe</code>.
      </div>

      <ul class="row-list" id="members">
        <li :for={m <- @members} class="row" id={"member-" <> m["id"]}>
          <div class="row-main">
            <span class="row-title">{if m["name"] == "", do: m["email"], else: m["name"]}</span>
            <span class="row-sub">{m["email"]} · joined {String.slice(m["created_at"], 0, 10)}</span>
          </div>
          <form phx-change="status" class="row-inline" id={"member-status-" <> m["id"]}>
            <input type="hidden" name="member" value={m["id"]} />
            <select name="status" class="select">
              <option :for={s <- ~w(free paid comped)} value={s} selected={m["status"] == s}>
                {s}
              </option>
            </select>
          </form>
          <div class="row-actions">
            <button
              phx-click="delete"
              phx-value-id={m["id"]}
              data-confirm="Remove this member?"
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
