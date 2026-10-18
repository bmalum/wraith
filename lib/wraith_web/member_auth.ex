defmodule WraithWeb.MemberAuth do
  @moduledoc """
  Readers who signed in with a magic link. A session cookie holds the raw
  token from `Wraith.Members.create_session/1`; `fetch_current_member`
  turns it into `conn.assigns.current_member`, `on_mount(:mount_current_member)`
  does the same for LiveViews.
  """
  use WraithWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller
  alias Wraith.Members

  @key :member_token

  def fetch_current_member(conn, _opts) do
    token = get_session(conn, @key)
    assign(conn, :current_member, token && Members.member_by_session(token))
  end

  def log_in_member(conn, member, redirect_to \\ ~p"/members") do
    token = Members.create_session(member)

    conn
    |> put_session(@key, token)
    |> configure_session(renew: true)
    |> redirect(to: redirect_to)
  end

  def log_out_member(conn) do
    get_session(conn, @key) |> Members.delete_session()
    conn |> delete_session(@key) |> redirect(to: ~p"/")
  end

  def on_mount(:mount_current_member, _params, session, socket) do
    {:cont,
     Phoenix.Component.assign_new(socket, :current_member, fn ->
       if token = session["member_token"], do: Members.member_by_session(token)
     end)}
  end
end
