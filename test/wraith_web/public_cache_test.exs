defmodule WraithWeb.PublicCacheTest do
  use WraithWeb.ConnCase, async: false

  setup do
    owner = owner_fixture()
    post_fixture(owner)
    :ok = Wraith.Search.rebuild()
    {:ok, owner: owner}
  end

  describe "feeds" do
    test "RSS carries an ETag and public cache headers, and answers 304", %{conn: conn} do
      conn1 = get(conn, ~p"/rss")
      assert conn1.status == 200
      [etag] = get_resp_header(conn1, "etag")
      assert etag =~ ~r/^"\d+"$/
      assert [cc] = get_resp_header(conn1, "cache-control")
      assert cc =~ "public" and cc =~ "max-age=" and cc =~ "stale-while-revalidate="
      assert [_] = get_resp_header(conn1, "last-modified")

      conn2 = conn |> put_req_header("if-none-match", etag) |> get(~p"/rss")
      assert conn2.status == 304
      assert conn2.resp_body == ""
    end

    test "the ETag changes when a post changes", %{conn: conn, owner: owner} do
      [etag1] = conn |> get(~p"/rss") |> get_resp_header("etag")
      post_fixture(owner, %{title: "Another", slug: "another"})
      [etag2] = conn |> get(~p"/rss") |> get_resp_header("etag")
      assert etag1 != etag2
    end

    test "JSON feed and sitemap are cached too", %{conn: conn} do
      for path <- [~p"/feed.json", ~p"/sitemap.xml"] do
        c = get(conn, path)
        assert [_] = get_resp_header(c, "etag"), path
        assert [cc] = get_resp_header(c, "cache-control")
        assert cc =~ "public", path
      end
    end

    test "the sitemap lists posts, pages, tags and authors", %{conn: conn, owner: owner} do
      post_fixture(owner, %{type: "page", title: "About", slug: "about"})
      body = get(conn, ~p"/sitemap.xml").resp_body
      assert body =~ "/hello-world</loc>"
      assert body =~ "/about</loc>"
      assert body =~ "/tag/news</loc>"
      assert body =~ "/author/owner-one</loc>"
    end
  end

  describe "pages" do
    test "anonymous readers get a public, short-lived cache", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert [cc] = get_resp_header(conn, "cache-control")
      assert cc =~ "public" and cc =~ "max-age=60"

      conn = get(conn, ~p"/hello-world")
      assert [cc] = get_resp_header(conn, "cache-control")
      assert cc =~ "public"
    end

    test "signed-in staff get private, no-store", %{conn: conn, owner: owner} do
      conn = conn |> log_in(owner) |> get(~p"/")
      assert ["private, no-store"] = get_resp_header(conn, "cache-control")
    end

    test "signed-in members get private, no-store", %{conn: conn} do
      member = member_fixture()
      conn = conn |> log_in_member(member) |> get(~p"/hello-world")
      assert ["private, no-store"] = get_resp_header(conn, "cache-control")
    end
  end
end
