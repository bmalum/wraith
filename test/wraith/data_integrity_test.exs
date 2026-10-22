defmodule Wraith.DataIntegrityTest do
  @moduledoc """
  The data-layer fixes from the review: settings that can't take the site
  down, a redirects plug that never raises, a newsletter that is claimed
  before it is sent, mail headers that can't be injected, and a scheduled
  publish that reads the due end of the index.
  """
  use WraithWeb.ConnCase, async: false
  import Swoosh.TestAssertions

  alias Wraith.{Content, Settings}

  setup do
    owner = owner_fixture()
    {:ok, owner: owner}
  end

  describe "settings validation" do
    test "malformed redirects and navigation are refused, well-formed accepted" do
      assert {:error, %{"redirects" => _}} = Settings.update(%{"redirects" => "oops"})
      assert {:error, %{"redirects" => _}} = Settings.update(%{"redirects" => [%{"foo" => 1}]})
      # a self-redirect loop
      assert {:error, %{"redirects" => _}} =
               Settings.update(%{"redirects" => [%{"from" => "/a", "to" => "/a"}]})

      assert {:ok, _} = Settings.update(%{"redirects" => [%{"from" => "/old", "to" => "/new"}]})

      assert {:ok, _} =
               Settings.update(%{
                 "redirects" => [%{"from" => "/blog/*", "to" => "https://elsewhere.example/*"}]
               })

      assert {:error, %{"navigation" => _}} = Settings.update(%{"navigation" => "Home /"})

      assert {:error, %{"navigation" => _}} =
               Settings.update(%{"navigation" => [%{"label" => "X"}]})

      assert {:ok, _} = Settings.update(%{"navigation" => [%{"label" => "Home", "url" => "/"}]})

      assert {:error, %{"widget_fetch_hosts" => _}} =
               Settings.update(%{"widget_fetch_hosts" => "evil;rm -rf"})

      assert {:ok, _} =
               Settings.update(%{"widget_fetch_hosts" => "api.example.com, *.cdn.example"})

      assert {:error, %{"lang" => _}} = Settings.update(%{"lang" => "<script>"})
      assert {:ok, _} = Settings.update(%{"lang" => "pt-BR"})

      assert {:error, %{"logo" => _}} = Settings.update(%{"logo" => "javascript:alert(1)"})
      assert {:ok, _} = Settings.update(%{"logo" => "/uploads/2026/10/logo.png"})
    end
  end

  describe "Store.count" do
    test "counts what query/2 would return, with the same key conditions" do
      for i <- 1..7 do
        :ok =
          Wraith.Store.put(%{
            "pk" => "CNT",
            "sk" => "A##{i}",
            "gsi1pk" => "CNTIDX",
            "gsi1sk" => "2026-10-0#{i}"
          })
      end

      :ok = Wraith.Store.put(%{"pk" => "CNT", "sk" => "B#1"})

      assert Wraith.Store.count("CNT") == 8
      assert Wraith.Store.count("CNT", begins_with: "A#") == 7
      assert Wraith.Store.count("CNTIDX", index: :gsi1) == 7

      assert Wraith.Store.count("CNTIDX", index: :gsi1, between: {"2026-10-03", "2026-10-05"}) ==
               3

      assert Wraith.Store.count("NOPE") == 0
    end

    test "dashboard counts and member growth read only what they need", %{owner: owner} do
      post_fixture(owner)
      {:ok, _} = Wraith.Members.create(%{email: "g1@x.io"})
      {:ok, _} = Wraith.Members.create(%{email: "g2@x.io"})

      assert Wraith.Content.count_posts("published") == 1
      assert Wraith.Content.count_posts("draft") == 0
      assert Wraith.Members.count() == 2
      assert Enum.sum(Enum.map(Wraith.Analytics.member_growth(3), & &1.members)) == 2
      assert [%{"title" => "Hello World"}] = Wraith.Content.recent_posts(8)
    end
  end

  describe "redirects plug" do
    test "a bad rule never raises; good rules still redirect", %{conn: conn, owner: owner} do
      post_fixture(owner)
      # bypass validation to simulate a value that got in some other way
      {:ok, _} = Settings.write(&Map.put(&1, "redirects", ["garbage", %{"from" => 1}]))
      assert get(conn, ~p"/hello-world").status == 200

      {:ok, _} = Settings.write(&Map.put(&1, "redirects", "not even a list"))
      assert get(conn, ~p"/hello-world").status == 200

      {:ok, _} = Settings.update(%{"redirects" => [%{"from" => "/old", "to" => "/hello-world"}]})
      assert redirected_to(get(conn, "/old"), 301) == "/hello-world"
    end
  end

  describe "newsletter" do
    test "the send is claimed before mail goes out, so a second call never re-sends", %{
      owner: owner
    } do
      {:ok, _} = Settings.update(%{"members_enabled" => true})
      member_fixture(%{"email" => "a@wraith.test"})
      member_fixture(%{"email" => "b@wraith.test"})
      post = post_fixture(owner, %{title: "News", slug: "news"})

      assert {:ok, 2} = Wraith.Newsletter.send_post(post)
      assert {:error, :already_sent} = Wraith.Newsletter.send_post(post)
      assert Wraith.Newsletter.send_record(post)["status"] == "sent"
      assert Wraith.Newsletter.send_record(post)["recipients"] == 2
    end

    test "names with CR/LF cannot inject mail headers", %{owner: owner} do
      {:ok, _} = Settings.update(%{"members_enabled" => true})

      member_fixture(%{
        "email" => "evil@wraith.test",
        "name" => "Eve\r\nBcc: everyone@example.com"
      })

      post = post_fixture(owner, %{title: "Hi\r\nX-Injected: yes", slug: "hi"})

      assert {:ok, 1} = Wraith.Newsletter.send_post(post)

      assert_email_sent(fn mail ->
        [{name, "evil@wraith.test"}] = mail.to
        refute name =~ ~r/[\r\n]/
        refute mail.subject =~ ~r/[\r\n]/
        assert mail.subject =~ "Hi X-Injected: yes"
      end)
    end
  end

  describe "scheduled publishing" do
    test "publish_due publishes the DUE posts even when many are scheduled further out", %{
      owner: owner
    } do
      past = DateTime.utc_now() |> DateTime.add(-60, :second)
      future = DateTime.utc_now() |> DateTime.add(3600 * 24 * 30, :second)

      # many future posts first, so a "newest N" read would never see the due one
      for i <- 1..5 do
        {:ok, p} =
          Content.create_post(%{title: "Future #{i}", markdown: "x", author_id: owner["id"]})

        {:ok, _} = Content.publish_post(p, DateTime.add(future, i, :second))
      end

      {:ok, due} = Content.create_post(%{title: "Due now", markdown: "x", author_id: owner["id"]})
      {:ok, due} = Content.publish_post(due, past)
      # publish_post with a past time publishes immediately; force it back to scheduled
      {:ok, due} = Content.update_post(due, %{"status" => "scheduled"})
      assert due["status"] == "scheduled"

      assert Content.publish_due() == 1
      assert Content.get_post(due["id"])["status"] == "published"
      assert Content.count_posts("scheduled") == 5
    end
  end
end
