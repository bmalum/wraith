defmodule WraithWeb.Admin.ResetLive do
  @moduledoc "Forgot the password: ask for a link (`:forgot`), then set a new one from it (`:reset`)."
  use WraithWeb, :live_view
  alias Wraith.Accounts

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       token: params["token"],
       sent: false,
       done: false,
       errors: %{},
       page_title: "Reset password",
       form: to_form(%{}, as: :user)
     )}
  end

  @impl true
  def handle_event("request", %{"user" => %{"email" => email}}, socket) do
    case Wraith.RateLimit.check(:forgot, String.downcase(email)) do
      :ok -> :ok = Accounts.request_password_reset(email)
      {:error, _} -> :ok
    end

    {:noreply, assign(socket, sent: true)}
  end

  def handle_event("reset", %{"user" => %{"password" => pw}}, socket) do
    case Accounts.reset_password(socket.assigns.token, pw) do
      {:ok, _} -> {:noreply, assign(socket, done: true)}
      {:error, errors} -> {:noreply, assign(socket, errors: errors)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.plain flash={@flash}>
      <div class="plain-brand"><span class="admin-brand-mark">W</span></div>
      <%= if @live_action == :forgot do %>
        <h1 class="plain-title">Forgot your password?</h1>
        <p :if={@sent} class="plain-lede">
          If that address belongs to an author, a reset link is on its way.
        </p>
        <.form :if={not @sent} for={@form} phx-submit="request" id="forgot-form" class="plain-form">
          <.input field={@form[:email]} type="email" label="Email" required />
          <button type="submit" class="btn-accent is-wide">Send reset link</button>
        </.form>
      <% else %>
        <h1 class="plain-title">Choose a new password</h1>
        <p :if={@done} class="plain-lede">
          Done. <a href={~p"/admin/login"}>Sign in</a> with your new password.
        </p>
        <p :if={@errors["token"]} class="form-error">
          This link {@errors["token"]}. <a href={~p"/admin/forgot"}>Ask for a new one.</a>
        </p>
        <.form :if={not @done} for={@form} phx-submit="reset" id="reset-form" class="plain-form">
          <.input
            name="user[password]"
            value=""
            type="password"
            label="New password"
            required
            errors={List.wrap(@errors["password"])}
            autocomplete="new-password"
          />
          <button type="submit" class="btn-accent is-wide">Set password</button>
        </.form>
      <% end %>
      <p class="plain-foot"><a href={~p"/admin/login"}>← Sign in</a></p>
    </Layouts.plain>
    """
  end
end
