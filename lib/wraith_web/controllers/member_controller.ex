defmodule WraithWeb.MemberController do
  @moduledoc "The browser legs of member sign-in: the magic link, unsubscribe, sign out."
  use WraithWeb, :controller
  alias Wraith.{Members, Tokens}
  alias WraithWeb.MemberAuth

  def login(conn, %{"token" => token}) do
    with {:ok, id} <- Tokens.verify(:member_login, token),
         %{} = member <- Members.get(id) do
      conn
      |> put_flash(:info, "Signed in as #{member["email"]}.")
      |> MemberAuth.log_in_member(member)
    else
      {:error, :expired} ->
        conn
        |> put_flash(:error, "That sign-in link has expired. Ask for a new one.")
        |> redirect(to: ~p"/members")

      _ ->
        conn |> put_flash(:error, "That sign-in link is not valid.") |> redirect(to: ~p"/members")
    end
  end

  def confirm(conn, %{"token" => token}) do
    with {:ok, id} <- Tokens.verify(:confirm, token),
         %{} = member <- Members.get(id),
         {:ok, member} <- Members.confirm(member) do
      if is_nil(member["welcomed_at"]) do
        Wraith.Newsletter.send_welcome(member)
        Members.update(member, %{welcomed_at: Wraith.Store.now()})
      end

      conn
      |> put_flash(:info, "You're subscribed. Welcome!")
      |> MemberAuth.log_in_member(member, ~p"/")
    else
      {:error, :expired} ->
        conn
        |> put_flash(:error, "That link has expired — subscribe again for a fresh one.")
        |> redirect(to: ~p"/subscribe")

      _ ->
        conn
        |> put_flash(:error, "That confirmation link is not valid.")
        |> redirect(to: ~p"/subscribe")
    end
  end

  def unsubscribe(conn, %{"token" => token}) do
    with {:ok, id} <- Tokens.verify(:unsubscribe, token),
         %{} = member <- Members.get(id),
         {:ok, _} <- Members.unsubscribe(member) do
      conn
      |> put_flash(:info, "You are unsubscribed. Sorry to see you go.")
      |> redirect(to: ~p"/")
    else
      _ -> conn |> put_flash(:error, "That unsubscribe link is not valid.") |> redirect(to: ~p"/")
    end
  end

  # Stripe Checkout (Wraith.Billing); without Stripe configured it is a polite no-op
  def upgrade(conn, _params) do
    case conn.assigns[:current_member] do
      nil ->
        conn |> put_flash(:error, "Sign in first.") |> redirect(to: ~p"/members")

      member ->
        case Wraith.Billing.checkout_url(member, url(~p"/members"), url(~p"/members")) do
          {:ok, url} ->
            redirect(conn, external: url)

          {:error, why} ->
            conn
            |> put_flash(:error, "Payments are not available: #{why}")
            |> redirect(to: ~p"/members")
        end
    end
  end

  def logout(conn, _params),
    do: conn |> put_flash(:info, "Signed out.") |> MemberAuth.log_out_member()
end
