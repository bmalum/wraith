defmodule WraithWeb.Admin.ProfileLive do
  @moduledoc "The signed-in author: name, bio, avatar, links, password."
  use WraithWeb, :live_view
  alias Wraith.{Accounts, Uploads}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Your profile", errors: %{}, pw_errors: %{})
     |> allow_upload(:avatar,
       accept: ~w(.jpg .jpeg .png .webp .gif),
       max_entries: 1,
       max_file_size: 2_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  defp handle_progress(:avatar, entry, socket) do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Uploads.store_file(path, entry.client_type, name: "avatar")}
        end)

      case result do
        {:ok, url} ->
          {:ok, user} = Accounts.update_profile(socket.assigns.current_user, %{avatar: url})
          {:noreply, socket |> assign(current_user: user) |> put_flash(:info, "Avatar updated.")}

        {:error, why} ->
          {:noreply, put_flash(socket, :error, why)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate-upload", _params, socket), do: {:noreply, socket}

  def handle_event("remove-avatar", _params, socket) do
    {:ok, user} = Accounts.update_profile(socket.assigns.current_user, %{avatar: nil})
    {:noreply, assign(socket, current_user: user)}
  end

  def handle_event("save", %{"user" => attrs}, socket) do
    if to_string(attrs["name"]) |> String.trim() == "" do
      {:noreply, assign(socket, errors: %{"name" => "can't be blank"})}
    else
      {:ok, user} = Accounts.update_profile(socket.assigns.current_user, attrs)

      {:noreply,
       socket |> assign(current_user: user, errors: %{}) |> put_flash(:info, "Profile saved.")}
    end
  end

  def handle_event("password", %{"current_password" => cur, "password" => new}, socket) do
    case Accounts.change_password(socket.assigns.current_user, cur, new) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(current_user: user, pw_errors: %{})
         |> put_flash(:info, "Password changed.")}

      {:error, errors} ->
        {:noreply, assign(socket, pw_errors: errors)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} active={:profile} title="Your profile">
      <div class="two-col">
        <section class="panel">
          <header class="panel-head">
            <h2>About you</h2>
          </header>
          <div class="panel-form">
            <div class="avatar-row">
              <img
                :if={@current_user["avatar"]}
                src={@current_user["avatar"]}
                alt=""
                class="author-avatar is-large is-img"
              />
              <div :if={is_nil(@current_user["avatar"])} class="author-avatar is-large">
                {String.first(@current_user["name"])}
              </div>
              <form
                phx-change="validate-upload"
                phx-submit="validate-upload"
                id="avatar-form"
                class="drawer-row"
              >
                <label class="btn-ghost is-small"><.icon name="hero-arrow-up-tray" class="size-3" />
                Upload avatar <.live_file_input upload={@uploads.avatar} class="sr-only" /></label>
                <button
                  :if={@current_user["avatar"]}
                  type="button"
                  phx-click="remove-avatar"
                  class="btn-ghost is-small"
                >Remove</button>
                <span :for={e <- @uploads.avatar.entries} class="row-sub">{e.progress}%</span>
              </form>
            </div>
            <.form
              for={to_form(@current_user, as: :user)}
              phx-submit="save"
              id="profile-form"
              class="panel-form is-flush"
            >
              <.input
                name="user[name]"
                value={@current_user["name"]}
                label="Name"
                errors={List.wrap(@errors["name"])}
              />
              <.input name="user[bio]" type="textarea" value={@current_user["bio"]} label="Bio" />
              <.input name="user[location]" value={@current_user["location"]} label="Location" />
              <.input
                name="user[website]"
                value={@current_user["website"]}
                label="Website"
                placeholder="https://"
              />
              <.input
                name="user[twitter]"
                value={@current_user["twitter"]}
                label="X / Twitter handle"
                placeholder="@you"
              />
              <.input
                name="user[github]"
                value={@current_user["github"]}
                label="GitHub"
                placeholder="you"
              />
              <.input
                name="user[mastodon]"
                value={@current_user["mastodon"]}
                label="Mastodon"
                placeholder="https://instance/@you"
              />
              <button type="submit" class="btn-accent">Save profile</button>
            </.form>
          </div>
        </section>

        <section class="panel">
          <header class="panel-head">
            <h2>Password</h2>
          </header>
          <.form
            for={to_form(%{}, as: :pw)}
            phx-submit="password"
            id="password-form"
            class="panel-form"
          >
            <.input
              name="current_password"
              type="password"
              value=""
              label="Current password"
              errors={List.wrap(@pw_errors["current_password"])}
              autocomplete="current-password"
            />
            <.input
              name="password"
              type="password"
              value=""
              label="New password"
              errors={List.wrap(@pw_errors["password"])}
              autocomplete="new-password"
            />
            <button type="submit" class="btn-ghost">Change password</button>
          </.form>
          <p class="form-help" style="padding: 0 1.25rem 1rem">
            Signed in as {@current_user["email"]} · /author/{@current_user["slug"]}
          </p>
        </section>
      </div>
    </Layouts.admin>
    """
  end
end
