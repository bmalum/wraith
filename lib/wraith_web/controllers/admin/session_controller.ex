defmodule WraithWeb.Admin.SessionController do
  use WraithWeb, :controller

  alias Wraith.Accounts
  alias WraithWeb.UserAuth

  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    case Accounts.authenticate(email, password) do
      {:ok, user} ->
        conn |> put_flash(:info, "Welcome back, #{user["name"]}.") |> UserAuth.log_in_user(user)

      {:error, :invalid} ->
        conn
        |> put_flash(:error, "That email and password do not match.")
        |> redirect(to: ~p"/admin/login")
    end
  end

  def delete(conn, _params) do
    conn |> put_flash(:info, "Signed out.") |> UserAuth.log_out_user()
  end
end
