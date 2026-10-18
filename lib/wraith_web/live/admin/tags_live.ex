defmodule WraithWeb.Admin.TagsLive do
  @moduledoc "Tags: rename, describe, delete."
  use WraithWeb, :live_view

  alias Wraith.Content

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Tags", editing: nil) |> load()}
  end

  defp load(socket) do
    counts = Content.tag_counts()
    assign(socket, tags: Content.list_tags() |> Enum.sort_by(& &1["name"]), counts: counts)
  end

  @impl true
  def handle_event("edit", %{"slug" => slug}, socket),
    do: {:noreply, assign(socket, editing: slug)}

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event(
        "save",
        %{"slug" => slug, "name" => name, "description" => description},
        socket
      ) do
    {:ok, _} = Content.update_tag(slug, %{name: name, description: description})
    {:noreply, socket |> assign(editing: nil) |> load()}
  end

  def handle_event("create", %{"name" => name}, socket) when name != "" do
    {:ok, _} = Content.ensure_tag(Wraith.Slug.slugify(name), %{name: name})
    {:noreply, load(socket)}
  end

  def handle_event("create", _params, socket), do: {:noreply, socket}

  def handle_event("delete", %{"slug" => slug}, socket) do
    :ok = Content.delete_tag(slug)
    {:noreply, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} active={:tags} title="Tags">
      <:actions>
        <form phx-submit="create" class="inline-form">
          <input type="text" name="name" placeholder="New tag" class="input" autocomplete="off" />
          <button type="submit" class="btn-accent">Add</button>
        </form>
      </:actions>

      <div :if={@tags == []} class="panel-empty">No tags yet — they appear as you tag posts.</div>

      <ul class="row-list" id="tags">
        <li :for={t <- @tags} class="row" id={"tag-" <> t["slug"]}>
          <%= if @editing == t["slug"] do %>
            <form phx-submit="save" class="row-edit">
              <input type="hidden" name="slug" value={t["slug"]} />
              <input type="text" name="name" value={t["name"]} class="input" placeholder="Name" />
              <input
                type="text"
                name="description"
                value={t["description"]}
                class="input"
                placeholder="Description"
              />
              <button type="submit" class="btn-accent">Save</button>
              <button type="button" phx-click="cancel" class="btn-ghost">Cancel</button>
            </form>
          <% else %>
            <a href={~p"/tag/#{t["slug"]}"} class="row-main" target="_blank">
              <span class="row-title">{t["name"]}</span>
              <span class="row-sub">/tag/{t["slug"]}
              <span :if={t["description"] != ""}> · {t["description"]}</span></span>
            </a>
            <span class="count-pill">{@counts[t["slug"]] || 0}</span>
            <div class="row-actions">
              <button phx-click="edit" phx-value-slug={t["slug"]} class="icon-btn" title="Edit"><.icon
                name="hero-pencil"
                class="size-4"
              /></button>
              <button
                phx-click="delete"
                phx-value-slug={t["slug"]}
                data-confirm="Delete this tag? Posts keep the label."
                class="icon-btn is-danger"
                title="Delete"
              ><.icon name="hero-trash" class="size-4" /></button>
            </div>
          <% end %>
        </li>
      </ul>
    </Layouts.admin>
    """
  end
end
