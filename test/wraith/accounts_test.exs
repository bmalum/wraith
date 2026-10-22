defmodule Wraith.AccountsTest do
  use Wraith.StoreCase, async: false
  alias Wraith.{Accounts, Members, Settings}

  test "setup owner once" do
    refute Settings.setup_done?()

    assert {:ok, owner} =
             Accounts.setup_owner(%{
               email: "Me@Example.com",
               name: "Me",
               password: "a long password"
             })

    assert owner["role"] == "owner"
    assert owner["email"] == "me@example.com"
    assert owner["slug"] == "me"
    assert Settings.setup_done?()

    assert {:error, %{"base" => _}} =
             Accounts.setup_owner(%{
               email: "x@example.com",
               name: "X",
               password: "a long password"
             })
  end

  test "a second setup racing the first loses on the owner claim" do
    # the first setup's claim is in, its user not yet visible to the second's any_users? check
    {cpk, csk} = Wraith.Store.Keys.owner_claim()
    :ok = Wraith.Store.put(%{"pk" => cpk, "sk" => csk})

    assert {:error, %{"base" => "the site already has an owner"}} =
             Accounts.setup_owner(%{
               email: "x@example.com",
               name: "X",
               password: "a long password"
             })

    assert Accounts.list_users() == []
  end

  test "author slugs are unique, follow renames, and free up on delete" do
    {:ok, a} =
      Accounts.create_user(%{email: "a@b.co", name: "Sam Lee", password: "long enough pw"})

    {:ok, b} =
      Accounts.create_user(%{email: "b@b.co", name: "Sam Lee", password: "long enough pw"})

    assert a["slug"] == "sam-lee"
    assert b["slug"] == "sam-lee-2"
    assert Accounts.get_user_by_slug("sam-lee")["id"] == a["id"]
    assert Accounts.get_user_by_slug("sam-lee-2")["id"] == b["id"]
    refute Map.has_key?(Accounts.get_user_by_slug("sam-lee"), "password_hash")

    # renaming onto a taken name gets the next free suffix, and frees the old slug
    {:ok, b} = Accounts.update_profile(b, %{name: "Kim Park"})
    assert b["slug"] == "kim-park"
    assert Accounts.get_user_by_slug("sam-lee-2") == nil
    assert Accounts.get_user_by_slug("kim-park")["id"] == b["id"]

    {:ok, b} = Accounts.update_profile(b, %{name: "Sam Lee"})
    assert b["slug"] == "sam-lee-2"

    # a profile edit that keeps the name keeps the slug
    {:ok, b} = Accounts.update_profile(b, %{bio: "hi"})
    assert b["slug"] == "sam-lee-2"

    :ok = Accounts.delete_user(b)
    assert Accounts.get_user_by_slug("sam-lee-2") == nil
  end

  test "create_user validates and keeps emails unique" do
    assert {:error, %{"email" => _, "password" => _}} =
             Accounts.create_user(%{email: "nope", name: "N", password: "short"})

    assert {:ok, _} =
             Accounts.create_user(%{email: "a@b.co", name: "A", password: "long enough pw"})

    assert {:error, %{"email" => "is already taken"}} =
             Accounts.create_user(%{email: "A@b.co", name: "A2", password: "long enough pw"})

    assert [%{"email" => "a@b.co"} = u] = Accounts.list_users()
    refute Map.has_key?(u, "password_hash")
  end

  test "authenticate and sessions" do
    {:ok, user} = Accounts.create_user(%{email: "a@b.co", name: "A", password: "long enough pw"})
    assert {:ok, _} = Accounts.authenticate("a@b.co", "long enough pw")
    assert {:error, :invalid} = Accounts.authenticate("a@b.co", "wrong")
    assert {:error, :invalid} = Accounts.authenticate("nobody@b.co", "wrong")

    token = Accounts.create_session(user)
    assert Accounts.user_by_session(token)["id"] == user["id"]
    assert Accounts.user_by_session("garbage") == nil
    :ok = Accounts.delete_session(token)
    assert Accounts.user_by_session(token) == nil
  end

  test "members" do
    assert {:ok, m} = Members.create(%{email: "Reader@x.io", name: "R"})
    assert m["status"] == "free"
    assert m["subscribed"]
    assert {:error, %{"email" => _}} = Members.create(%{email: "reader@x.io"})
    assert {:error, %{"email" => _}} = Members.create(%{email: "not-an-email"})
    assert Members.get_by_email("reader@x.io")["id"] == m["id"]
    {:ok, m} = Members.update(m, %{status: "paid"})
    assert m["status"] == "paid"
    assert Members.count() == 1
    :ok = Members.delete(m)
    assert Members.count() == 0
    assert Members.get_by_email("reader@x.io") == nil
  end

  test "settings defaults and update" do
    assert Settings.get()["title"] == "Wraith"
    assert {:ok, s} = Settings.update(%{title: "My Blog", posts_per_page: "5", accent: "#ff0000"})
    assert s["title"] == "My Blog"
    assert s["posts_per_page"] == 5
    assert Settings.get()["title"] == "My Blog"
    assert {:error, %{"posts_per_page" => _}} = Settings.update(%{posts_per_page: 0})
    assert {:error, %{"accent" => _}} = Settings.update(%{accent: "red"})
  end

  test "secrets are encrypted at rest and never returned by get" do
    {:ok, s} =
      Settings.update(%{
        stripe_secret_key: "sk_live_abcdefgh",
        stripe_webhook_secret: "whsec_1234567890"
      })

    refute Map.has_key?(s, "stripe_secret_key")
    assert s["stripe_secret_key_hint"] == "sk_…efgh"
    assert s["stripe_secret_key_ciphertext"] =~ ~r/^[A-Z]{3}\./
    refute Jason.encode!(Settings.get()) =~ "sk_live_abcdefgh"
    assert Settings.secret("stripe_secret_key") == "sk_live_abcdefgh"
    # an empty value keeps it, "clear" removes it
    {:ok, _} = Settings.update(%{stripe_secret_key: ""})
    assert Settings.secret("stripe_secret_key") == "sk_live_abcdefgh"
    {:ok, _} = Settings.update(%{stripe_secret_key: "clear"})
    assert Settings.secret("stripe_secret_key") == nil
    assert Settings.secret_hint("stripe_secret_key") == nil
  end

  test "analytics count views and uniques; audit logs actions" do
    Wraith.Analytics.hit("post-1", "v1")
    Wraith.Analytics.hit("post-1", "v1")
    Wraith.Analytics.hit("post-1", "v2")
    Wraith.Analytics.hit(nil, "v1")
    :ok = Wraith.Analytics.flush()
    [today] = Wraith.Analytics.series(1, "post-1")
    assert today.views == 3 and today.uniques == 2
    [site] = Wraith.Analytics.series(1)
    assert site.views == 4 and site.uniques == 2
    assert [{"post-1", 3}] = Wraith.Analytics.top_posts(1)

    :ok = Wraith.Audit.log(%{"id" => "u1", "name" => "Ada"}, :post_publish, "hello")
    :ok = Wraith.Audit.log("key:ci", "settings_update")

    assert [
             %{"actor" => "key:ci"},
             %{"actor" => "Ada", "action" => "post_publish", "subject" => "hello"}
           ] = Wraith.Audit.recent(5)
  end
end
