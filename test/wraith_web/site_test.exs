defmodule WraithWeb.SiteTest do
  use WraithWeb.ConnCase, async: false

  describe "first run" do
    test "/ redirects to setup when there is no owner", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/setup"}}} = live(conn, ~p"/")
    end

    test "setup creates the owner and the site", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/setup")

      view
      |> form("#setup-form",
        user: %{title: "Spectre", name: "Ada", email: "ada@x.io", password: "ten characters!"}
      )
      |> render_submit()

      assert Wraith.Settings.get()["title"] == "Spectre"
      assert Wraith.Accounts.get_user_by_email("ada@x.io")["role"] == "owner"
      # the form now posts to /admin/login (phx-trigger-action)
      assert render(view) =~ ~s(phx-trigger-action)
    end

    test "setup refuses bad input", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/setup")

      html =
        view
        |> form("#setup-form", user: %{title: "", name: "", email: "x", password: "short"})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute Wraith.Accounts.any_users?()
    end
  end

  describe "the site" do
    setup do
      owner = owner_fixture()

      post =
        post_fixture(owner, %{
          markdown:
            "# Hi\n\nBody text.\n\n{{widget counter label=\"Claps\" id=claps}}\n\n{{widget poll question=\"Tabs?\" options=\"Tabs|Spaces\"}}"
        })

      %{owner: owner, post: post}
    end

    test "home lists published posts", %{conn: conn, post: post} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Hello World"
      assert html =~ ~s(href="/#{post["slug"]}")
      assert html =~ "news"
    end

    test "home hides drafts and reacts to publishing", %{conn: conn, owner: owner} do
      {:ok, draft} = Wraith.Content.create_post(%{title: "Secret", author_id: owner["id"]})
      {:ok, view, html} = live(conn, ~p"/")
      refute html =~ "Secret"
      {:ok, _} = Wraith.Content.publish_post(draft)
      assert render(view) =~ "Secret"
    end

    test "post page renders markdown and live widgets", %{conn: conn, post: post} do
      {:ok, view, html} = live(conn, ~p"/#{post["slug"]}")
      assert html =~ "<h1"
      assert html =~ "Body text."
      assert html =~ ~s(data-widget="counter")
      assert html =~ "Claps"
      assert html =~ ~s(data-widget="poll")
      assert html =~ "Tabs?"

      # clicking the counter updates everyone
      {:ok, other, _} = live(conn, ~p"/#{post["slug"]}")
      view |> element(~s(#widget-claps button[phx-value-event="inc"])) |> render_click()
      assert render(view) =~ ~s(<span class="w-counter-value">1</span>)
      assert render(other) =~ ~s(<span class="w-counter-value">1</span>)

      # voting in the poll
      view |> element(~s(button[phx-value-event="vote"]), "Tabs") |> render_click()
      assert render(view) =~ "100%"
      assert render(view) =~ "1 vote"
    end

    test "unknown slug is a 404", %{conn: conn} do
      assert_raise WraithWeb.NotFound, fn -> live(conn, ~p"/nope") end
    end

    test "tag and author pages", %{conn: conn, owner: owner} do
      {:ok, _, html} = live(conn, ~p"/tag/news")
      assert html =~ "Hello World"
      {:ok, _, html} = live(conn, ~p"/author/#{owner["slug"]}")
      assert html =~ "Owner One"
      assert html =~ "Hello World"
    end

    test "members-only post is locked for anonymous readers", %{conn: conn, owner: owner} do
      post = post_fixture(owner, %{title: "Inner circle", visibility: "members"})
      {:ok, _, html} = live(conn, ~p"/#{post["slug"]}")
      assert html =~ "for members"
      refute html =~ ~s(class="prose-wraith")
      {:ok, _, html} = conn |> log_in(owner) |> live(~p"/#{post["slug"]}")
      assert html =~ ~s(class="prose-wraith")
      assert html =~ "Some text."
    end

    test "subscribe", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/subscribe")
      view |> form("#subscribe-form", %{email: "reader@x.io", name: "R"}) |> render_submit()
      assert render(view) =~ "You&#39;re in"
      assert Wraith.Members.get_by_email("reader@x.io")
    end

    test "themes: paper is the default, ink renders the same pages, unknown names are refused", %{
      conn: conn,
      post: post
    } do
      {:ok, _, html} = live(conn, ~p"/")
      assert html =~ ~s(href="/themes/paper.css")
      assert html =~ "masthead"

      assert {:error, %{"theme" => _}} = Wraith.Settings.update(%{theme: "nope"})
      {:ok, _} = Wraith.Settings.update(%{theme: "ink"})

      {:ok, _, html} = live(conn, ~p"/")
      assert html =~ ~s(href="/themes/ink.css")
      assert html =~ "ink-list"
      assert html =~ "Hello World"
      {:ok, view, html} = live(conn, ~p"/#{post["slug"]}")
      assert html =~ "ink-post"
      assert html =~ ~s(data-widget="counter"), "widgets stay live in any theme"
      view |> element(~s(#widget-claps button[phx-value-event="inc"])) |> render_click()
      assert render(view) =~ ~s(<span class="w-counter-value">1</span>)
      {:ok, _, html} = live(conn, ~p"/tag/news")
      assert html =~ "#news"
      {:ok, _, html} = live(conn, ~p"/subscribe")
      assert html =~ "subscribe →"
      assert WraithWeb.Themes.names() == ["paper", "ink"]
    end

    test "rss, json feed, sitemap", %{conn: conn, post: post} do
      body = conn |> get(~p"/rss") |> response(200)
      assert body =~ "<rss"
      assert body =~ "Hello World"
      assert body =~ "Interactive counter"
      body = conn |> get(~p"/feed.json") |> response(200)
      assert Jason.decode!(body)["items"] |> hd() |> Map.get("title") == "Hello World"
      body = conn |> get(~p"/sitemap.xml") |> response(200)
      assert body =~ post["slug"]
    end
  end
end
