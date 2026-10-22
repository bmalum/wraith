defmodule Wraith.TokensTest do
  @moduledoc "Mail-link tokens: single use where it matters, dead after a password change."
  use WraithWeb.ConnCase, async: false
  import Swoosh.TestAssertions

  alias Wraith.{Accounts, Members, Tokens}

  test "consume accepts a token exactly once" do
    t = Tokens.sign(:member_login, "m1")
    assert {:ok, "m1"} = Tokens.consume(:member_login, t)
    assert {:error, :used} = Tokens.consume(:member_login, t)
    # a different purpose never verifies
    assert {:error, :invalid} = Tokens.consume(:confirm, t)
  end

  test "verify stays repeatable for unsubscribe links" do
    t = Tokens.sign(:unsubscribe, "m1")
    assert {:ok, "m1"} = Tokens.verify(:unsubscribe, t)
    assert {:ok, "m1"} = Tokens.verify(:unsubscribe, t)
  end

  test "a magic sign-in link works once", %{conn: conn} do
    {:ok, _} = Wraith.Settings.update(%{"members_enabled" => true})
    m = member_fixture()
    t = Tokens.sign(:member_login, m["id"])

    c1 = get(conn, ~p"/members/login/#{t}")
    assert get_session(c1, :member_token)

    c2 = get(build_conn(), ~p"/members/login/#{t}")
    refute get_session(c2, :member_token)
    assert Phoenix.Flash.get(c2.assigns.flash, :error) =~ "already used"
  end

  test "password change revokes existing sessions and outstanding reset links", %{conn: conn} do
    owner = owner_fixture()
    old_session = Accounts.create_session(owner)
    assert Accounts.user_by_session(old_session)["id"] == owner["id"]

    # mint a reset link against the current password
    :ok = Accounts.request_password_reset(owner["email"])

    assert_email_sent(fn email ->
      [_, reset_token] = Regex.run(~r{/admin/reset/([\w\-\.]+)}, email.html_body)
      Process.put(:reset_token, reset_token)
      true
    end)

    # change the password by the normal route
    {:ok, _} = Accounts.change_password(owner, "a very long password", "a brand new password!")

    # the old cookie is dead…
    assert Accounts.user_by_session(old_session) == nil
    # …and so is the reset link minted against the old password
    assert {:error, %{"token" => msg}} =
             Accounts.reset_password(Process.get(:reset_token), "another long password")

    assert msg =~ "not valid"

    # but a fresh session on the new password works
    {:ok, u} = Accounts.authenticate(owner["email"], "a brand new password!")
    s = Accounts.create_session(u)
    assert Accounts.user_by_session(s)["id"] == owner["id"]
    _ = conn
  end

  test "a reset link survives a bad new password, then is spent by a good one" do
    owner = owner_fixture()
    t = Tokens.sign(:password_reset, {owner["id"], Accounts.reset_binding(owner)})

    assert {:error, %{"password" => _}} = Accounts.reset_password(t, "short")
    assert {:ok, _} = Accounts.reset_password(t, "long enough password")
    assert {:error, %{"token" => msg}} = Accounts.reset_password(t, "yet another long one")
    assert msg =~ "already been used" or msg =~ "not valid"
  end

  test "member confirm is single use", %{conn: conn} do
    {:ok, _} = Wraith.Settings.update(%{"members_enabled" => true})
    {:ok, m} = Members.create(%{"email" => "new@wraith.test"})
    t = Tokens.sign(:confirm, m["id"])
    assert get(conn, ~p"/members/confirm/#{t}").status in [302, 200]
    c2 = get(build_conn(), ~p"/members/confirm/#{t}")
    assert c2.status == 302
    refute get_session(c2, :member_token)
  end
end
