defmodule WraithWeb.PaywallTest do
  @moduledoc """
  The paywall has one definition (`Content.readable_markdown/2`) and every
  public channel must honour it. Each test here is a channel that leaked the
  gated body at some point: the page, the live update push, RSS and JSON
  feeds, the Content API, search, and preview links after publishing.
  """
  use WraithWeb.ConnCase, async: false

  alias Wraith.Content

  @secret "SECRET-MEMBERS-TEXT"
  @md "Free intro for everyone.\n\n<!--members-only-->\n\n#{@secret} that only members see."

  setup do
    owner = owner_fixture()
    {:ok, _} = Wraith.Settings.update(%{"members_enabled" => true, "comments_enabled" => true})

    gated =
      post_fixture(owner, %{title: "Gated", markdown: @md, visibility: "members", tags: "news"})

    :ok = Wraith.Search.rebuild()
    {:ok, owner: owner, gated: gated}
  end

  test "readable_markdown is the single gate" do
    post = %{"visibility" => "members", "markdown" => @md}
    refute Content.readable_markdown(post, false) =~ @secret
    assert Content.readable_markdown(post, false) =~ "Free intro"
    assert Content.readable_markdown(post, true) =~ @secret
    refute Content.readable_markdown(post, true) =~ "members-only"
    # public posts: everything, marker stripped
    assert Content.readable_markdown(%{"visibility" => "public", "markdown" => @md}, false) =~
             @secret
  end

  test "the page: anonymous locked, member unlocked", %{conn: conn} do
    {:ok, _, html} = live(conn, ~p"/gated")
    refute html =~ @secret
    assert html =~ ~s(class="paywall")

    member = member_fixture()
    {:ok, _, html} = live(log_in_member(conn, member), ~p"/gated")
    assert html =~ @secret
  end

  test "a live content update never pushes the gated body to a locked reader",
       %{conn: conn, gated: gated} do
    {:ok, view, _} = live(conn, ~p"/gated")
    # an editor saves — the broadcast reaches every open page
    {:ok, _} = Content.update_post(gated, %{"title" => "Gated, edited"})
    html = render(view)
    assert html =~ "Gated, edited"
    refute html =~ @secret
    assert html =~ ~s(class="paywall")
  end

  test "RSS and JSON feeds carry only the public preview", %{conn: conn} do
    rss = get(conn, ~p"/rss").resp_body
    assert rss =~ "Free intro"
    refute rss =~ @secret

    json = get(conn, ~p"/feed.json").resp_body
    assert json =~ "Free intro"
    refute json =~ @secret

    tag_rss = get(conn, ~p"/tag/news/rss").resp_body
    refute tag_rss =~ @secret
  end

  test "the Content API gates listing and single post, html and plaintext",
       %{conn: conn} do
    {:ok, key, _rec} = Wraith.ApiKeys.create("t", "content")

    body = json_response(get(conn, "/api/content/posts?key=#{key}"), 200)
    refute Jason.encode!(body) =~ @secret

    one = json_response(get(conn, "/api/content/posts/gated?key=#{key}"), 200)
    refute Jason.encode!(one) =~ @secret
    assert hd(one["posts"])["access"] == false
  end

  test "search neither matches nor snippets gated text", %{conn: conn} do
    assert Wraith.Search.search("secret") == []
    assert [%{snippet: snippet}] = Wraith.Search.search("intro")
    refute snippet =~ @secret

    {:ok, _, html} = live(conn, ~p"/search?q=secret")
    refute html =~ @secret
    assert html =~ "0 results"
  end

  test "a preview link unlocks a draft but not a published post", %{conn: conn, owner: owner} do
    {:ok, draft} =
      Content.create_post(%{
        title: "Draft",
        markdown: @md,
        visibility: "members",
        author_id: owner["id"]
      })

    {:ok, token} = Content.preview_token(draft)
    {:ok, _, html} = live(conn, ~p"/preview/#{token}")
    assert html =~ @secret, "a reviewer sees the whole draft"

    # publishing revokes the link entirely
    {:ok, _} = Content.publish_post(Content.get_post(draft["id"]))
    assert_error_sent(404, fn -> get(conn, ~p"/preview/#{token}") end)
    assert Content.get_post(draft["id"])["preview_token"] == nil
  end

  test "minting a preview token is idempotent and the pointer survives", %{owner: owner} do
    {:ok, draft} = Content.create_post(%{title: "D2", markdown: "x", author_id: owner["id"]})
    {:ok, t1} = Content.preview_token(draft)
    # a stale copy of the post (no token field) asks again — same token comes back
    {:ok, t2} = Content.preview_token(draft)
    assert t1 == t2
    assert Content.get_by_preview_token(t1)["id"] == draft["id"]

    :ok = Content.revoke_preview(Content.get_post(draft["id"]))
    assert Content.get_by_preview_token(t1) == nil
  end

  test "deleting a post removes its preview pointer", %{owner: owner} do
    {:ok, draft} = Content.create_post(%{title: "D3", markdown: "x", author_id: owner["id"]})
    {:ok, token} = Content.preview_token(draft)
    :ok = Content.delete_post(Content.get_post(draft["id"]))
    assert Content.get_by_preview_token(token) == nil
  end

  describe "MCP with a Content key (public, may sit in a page's source)" do
    setup %{owner: owner} do
      {:ok, draft} =
        Content.create_post(%{
          title: "Unpublished plans",
          markdown: "DRAFT-ONLY-TEXT",
          author_id: owner["id"]
        })

      {:ok, _} =
        Wraith.Settings.update(%{
          "stripe_secret_key" => "sk_test_abcdefgh12345678",
          "code_injection_head" => "<!-- owner only -->"
        })

      {:ok, ctx: %{"scope" => "content"}, draft: draft}
    end

    defp text(%{"content" => parts}), do: Enum.map_join(parts, "", & &1["text"])

    test "post_get serves published posts only, with the paywall applied",
         %{ctx: ctx, draft: draft, gated: gated} do
      got = Wraith.Tools.call(ctx, "post_get", %{"id" => gated["slug"]})
      refute got["isError"]
      refute text(got) =~ @secret
      assert text(got) =~ "Free intro"

      for id <- [draft["id"], draft["slug"]] do
        got = Wraith.Tools.call(ctx, "post_get", %{"id" => id})
        assert got["isError"], "a Content key read a draft by #{id}"
        refute text(got) =~ "DRAFT-ONLY-TEXT"
      end
    end

    test "posts_list lists published posts only", %{ctx: ctx} do
      listed = Wraith.Tools.call(ctx, "posts_list", %{}) |> text()
      assert listed =~ "Gated"
      refute listed =~ "Unpublished plans"

      # asking for drafts by status gets nothing either
      refute Wraith.Tools.call(ctx, "posts_list", %{"status" => "draft"}) |> text() =~
               "Unpublished plans"
    end

    test "site_info shows the public site, not secrets or private counts", %{ctx: ctx} do
      info = Wraith.Tools.call(ctx, "site_info", %{}) |> text() |> Jason.decode!()
      blob = Jason.encode!(info)

      refute blob =~ "ciphertext"
      refute blob =~ "sk_"
      refute blob =~ "owner only"
      refute Map.has_key?(info["counts"], "drafts")
      refute Map.has_key?(info["counts"], "members")
      assert info["site"]["title"]
    end

    test "resources: published posts only, gated bodies previewed", %{ctx: ctx, draft: draft} do
      uris = Wraith.Tools.resources(ctx) |> Enum.map(& &1["uri"])
      assert "wraith://posts/gated" in uris
      refute "wraith://posts/#{draft["slug"]}" in uris

      assert {:ok, [%{"text" => body}]} = Wraith.Tools.read_resource(ctx, "wraith://posts/gated")
      refute body =~ @secret
      assert :error = Wraith.Tools.read_resource(ctx, "wraith://posts/#{draft["slug"]}")

      assert {:ok, [%{"text" => settings}]} =
               Wraith.Tools.read_resource(ctx, "wraith://settings")

      refute settings =~ "ciphertext"
      refute settings =~ "owner only"
    end

    test "an Admin key still sees everything", %{draft: draft} do
      admin = %{"as_owner" => true, "scope" => "admin"}
      got = Wraith.Tools.call(admin, "post_get", %{"id" => draft["id"]})
      assert text(got) =~ "DRAFT-ONLY-TEXT"

      info = Wraith.Tools.call(admin, "site_info", %{}) |> text() |> Jason.decode!()
      assert Map.has_key?(info["counts"], "drafts")
      # the owner sees the hint, never the ciphertext
      refute Jason.encode!(info) =~ "ciphertext"
    end
  end
end
