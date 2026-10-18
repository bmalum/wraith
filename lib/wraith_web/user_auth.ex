defmodule WraithWeb.UserAuth do
  @moduledoc """
  Who is at the keyboard. A session cookie holds the raw token from
  `Wraith.Accounts.create_session/1`; `fetch_current_user` turns it into
  `conn.assigns.current_user`, and the `on_mount` hooks do the same for
  LiveViews. Readers get an anonymous `visitor` id (a cookie) so widgets
  can tell them apart without an account.
  """
  use WraithWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller
  alias Wraith.Accounts

  @session_key :user_token
  @visitor_cookie "_wraith_visitor"
  @visitor_max_age 60 * 60 * 24 * 365

  def log_in_user(conn, user, redirect_to \\ nil) do
    token = Accounts.create_session(user)

    conn
    |> renew_session()
    |> put_session(@session_key, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
    |> redirect(to: redirect_to || get_session(conn, :user_return_to) || ~p"/admin")
  end

  def log_out_user(conn) do
    token = get_session(conn, @session_key)
    token && Accounts.delete_session(token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      WraithWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> redirect(to: ~p"/")
  end

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  def fetch_current_user(conn, _opts) do
    token = get_session(conn, @session_key)
    user = token && Accounts.user_by_session(token)
    assign(conn, :current_user, user)
  end

  @doc "Give every browser a stable anonymous id (for polls, reactions)."
  def fetch_visitor(conn, _opts) do
    conn = conn |> fetch_cookies() |> put_session(:ip, WraithWeb.RateLimitPlug.client_ip(conn))

    case conn.cookies[@visitor_cookie] do
      id when is_binary(id) and byte_size(id) >= 16 ->
        conn |> assign(:visitor, id) |> put_session(:visitor, id)

      _ ->
        id = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

        conn
        |> put_resp_cookie(@visitor_cookie, id,
          max_age: @visitor_max_age,
          same_site: "Lax",
          http_only: true
        )
        |> assign(:visitor, id)
        |> put_session(:visitor, id)
    end
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "Sign in first.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/admin/login")
      |> halt()
    end
  end

  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user], do: conn |> redirect(to: ~p"/admin") |> halt(), else: conn
  end

  defp maybe_store_return_to(%{method: "GET"} = conn),
    do: put_session(conn, :user_return_to, current_path(conn))

  defp maybe_store_return_to(conn), do: conn

  # ---- LiveView ---------------------------------------------------------------------

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:require_authenticated_user, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "Sign in first.")
        |> Phoenix.LiveView.redirect(to: ~p"/admin/login")

      {:halt, socket}
    end
  end

  @doc "`on_mount {WraithWeb.UserAuth, {:can, :manage_settings}}` — the page needs this `Wraith.Policy` action."
  def on_mount({:can, action}, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if Wraith.Policy.can?(socket.assigns.current_user, action, nil) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "Your role does not allow that.")
       |> Phoenix.LiveView.redirect(to: ~p"/admin")}
    end
  end

  def on_mount(:mount_visitor, _params, session, socket) do
    {:cont,
     socket
     |> Phoenix.Component.assign_new(:visitor, fn -> session["visitor"] end)
     |> Phoenix.Component.assign_new(:client_ip, fn -> session["ip"] end)}
  end

  defp mount_current_user(socket, session) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      if token = session["user_token"], do: Accounts.user_by_session(token)
    end)
  end
end
