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
       %{conn: conn, owner: owner} do
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
end
