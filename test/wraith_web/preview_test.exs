defmodule WraithWeb.PreviewTest do
  @moduledoc "Shareable draft previews: /preview/<token>."
  use WraithWeb.ConnCase, async: false

  alias Wraith.Content

  setup do
    owner = owner_fixture()

    {:ok, draft} =
      Content.create_post(%{
        title: "Not yet",
        markdown: "Public bit.\n\n<!--members-only-->\n\nSecret bit.",
        author_id: owner["id"],
        visibility: "members"
      })

    {:ok, owner: owner, draft: draft}
  end

  test "a token is minted once and stays stable", %{draft: draft} do
    assert {:ok, token} = Content.preview_token(draft)
    assert String.length(token) >= 20
    assert {:ok, ^token} = Content.preview_token(Content.get_post(draft["id"]))
    assert Content.get_by_preview_token(token)["id"] == draft["id"]
    assert Content.get_by_preview_token("nope") == nil
  end

  test "a draft is not public by slug, but is by preview link", %{conn: conn, draft: draft} do
    assert_error_sent(404, fn -> get(conn, ~p"/not-yet") end)

    {:ok, token} = Content.preview_token(draft)
    {:ok, _view, html} = live(conn, ~p"/preview/#{token}")
    assert html =~ "Not yet"
    assert html =~ "Public bit"
    # a reviewer sees the whole thing — no paywall on a preview
    assert html =~ "Secret bit"
    refute html =~ ~s(class="paywall")
    # the banner, and noindex
    assert html =~ "preview-banner"
    assert html =~ ~s(name="robots" content="noindex")
  end

  test "an unknown token is a 404", %{conn: conn} do
    assert_error_sent(404, fn -> get(conn, ~p"/preview/not-a-real-token") end)
  end

  test "the editor's Share preview button shows the link", %{
    conn: conn,
    owner: owner,
    draft: draft
  } do
    {:ok, view, _} = live(log_in(conn, owner), ~p"/admin/posts/#{draft["id"]}")
    refute has_element?(view, "#editor-share")
    view |> element("button", "Share preview") |> render_click()
    assert has_element?(view, "#editor-share input[value*='/preview/']")
    view |> element("#editor-share button[aria-label=Close]") |> render_click()
    refute has_element?(view, "#editor-share")
  end

  test "the MCP tool returns the same link", %{draft: draft} do
    ctx = %{"user_id" => nil, "scope" => "admin"}
    decode = fn %{"content" => [%{"text" => t}]} -> Jason.decode!(t) end

    first = Wraith.Tools.call(ctx, "post_preview_link", %{"id" => draft["id"]}) |> decode.()
    assert %{"url" => url, "status" => "draft"} = first
    assert url =~ "/preview/"

    again = Wraith.Tools.call(ctx, "post_preview_link", %{"id" => draft["id"]}) |> decode.()
    assert again["url"] == url
  end
end
