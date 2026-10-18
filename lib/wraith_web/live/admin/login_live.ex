defmodule WraithWeb.Admin.LoginLive do
  @moduledoc "Sign in. The form posts to the session controller, which sets the cookie."
  use WraithWeb, :live_view

  alias Wraith.Accounts

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.any_users?() do
      {:ok, assign(socket, form: to_form(%{}, as: :user), page_title: "Sign in")}
    else
      {:ok, push_navigate(socket, to: ~p"/admin/setup")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.plain flash={@flash}>
      <div class="plain-brand"><span class="admin-brand-mark">W</span></div>
      <h1 class="plain-title">Sign in</h1>

      <.form for={@form} id="login-form" action={~p"/admin/login"} method="post" class="plain-form">
        <.input field={@form[:email]} type="email" label="Email" required autocomplete="username" />
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          required
          autocomplete="current-password"
        />
        <button type="submit" class="btn-accent is-wide">Sign in</button>
      </.form>
      <p class="plain-foot">
        <a href={~p"/admin/forgot"}>Forgot your password?</a> · <a href="/">Back to the site</a>
      </p>
    </Layouts.plain>
    """
  end
end
