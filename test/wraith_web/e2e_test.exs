defmodule WraithWeb.E2ETest do
  @moduledoc """
  End-to-end walks of the public site: every view in every theme, plus the
  interactive member flows (search, subscribe, sign-in, comments, paywall).

  "End-to-end" here means a real request through the endpoint into the mounted
  LiveView, driven with `Phoenix.LiveViewTest` the way a browser would — the
  idiomatic full-stack test for Phoenix. A separate script captures real
  browser screenshots of these same views.
  """
  use WraithWeb.ConnCase, async: false

  setup %{conn: conn} do
    owner = owner_fixture(%{name: "Ada Lovelace"})
    {:ok, _} = Wraith.Settings.update(%{"members_enabled" => true, "comments_enabled" => true})

    public =
      post_fixture(owner, %{
        title: "Hello World",
        markdown: "# Hi\n\nBody text here, long enough to read.\n\n## A heading\n\nMore.",
        tags: "news, essays",
        custom_excerpt: "A short public intro."
      })

    members_only =
      post_fixture(owner, %{
        title: "For Members",
        markdown: "Public intro.\n\n<!--members-only-->\n\nSecret members text.",
        tags: "news",
        visibility: "members"
      })

    :ok = Wraith.Search.rebuild()
    {:ok, conn: conn, owner: owner, public: public, members_only: members_only}
  end

  # Walk the whole public surface in each of the 18 themes. If any theme's
  # templates break on any view, this is where it shows up.
  describe "every view renders in every theme" do
    for name <- WraithWeb.Themes.names() do
      @theme name

      test "theme #{name}", %{conn: conn} do
        {:ok, _} = Wraith.Settings.update(%{"theme" => @theme})
        info = WraithWeb.Themes.get(@theme).info()

        # home — the layout chrome + the feed
        {:ok, _view, html} = live(conn, ~p"/")
        assert html =~ "Hello World", "#{@theme}: home feed"

        assert html =~ ~s(l-#{root_class(info.layout_name)}),
               "#{@theme}: layout wrapper (l-#{root_class(info.layout_name)})"

        # the <head>: base + layout css, inline tokens, fonts
        {:ok, _, head} = live(conn, ~p"/")
        assert head =~ ~s(href="/themes/base.css")
        assert head =~ ~s(href="/themes/layouts/#{info.layout_name}.css")
        assert head =~ "--heading:" and head =~ "--accent:"
        # tokens must not be HTML-escaped (the quote-escaping regression)
        refute head =~ "&#39;", "#{@theme}: tokens were HTML-escaped"
        # the fonts URL is attribute-escaped in HTML (& → &amp;)
        if info.fonts do
          assert head =~ Phoenix.HTML.Safe.to_iodata(info.fonts) |> IO.iodata_to_binary(),
                 "#{@theme}: fonts link"
        end

        # post
        {:ok, _, html} = live(conn, ~p"/hello-world")
        assert html =~ "Hello World" and html =~ "Body text here"
        assert html =~ ~s(class="prose-wraith"), "#{@theme}: prose renders"

        # tag
        {:ok, _, html} = live(conn, ~p"/tag/news")
        assert html =~ "Hello World", "#{@theme}: tag listing"

        # author
        {:ok, _, html} = live(conn, ~p"/author/ada-lovelace")
        assert html =~ "Ada Lovelace", "#{@theme}: author page"

        # search (with results)
        {:ok, _, html} = live(conn, ~p"/search?q=hello")
        assert html =~ "Hello World" and html =~ "1 result", "#{@theme}: search results"

        # subscribe + member sign-in forms
        {:ok, _, html} = live(conn, ~p"/subscribe")
        assert html =~ ~s(id="subscribe-form"), "#{@theme}: subscribe form"

        {:ok, _, html} = live(conn, ~p"/members")
        assert html =~ ~s(id="member-login-form"), "#{@theme}: member login form"
      end
    end
  end

  describe "search as you type" do
    test "narrows and empties", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/search")
      view |> form("#search-form", %{q: "hello"}) |> render_change()
      assert_patch(view, ~p"/search?q=hello")
      assert render(view) =~ "Hello World" and render(view) =~ "1 result"

      {:ok, _, html} = live(conn, ~p"/search?q=zzzznope")
      assert html =~ "0 results"
    end
  end

  describe "subscribe flow" do
    test "submitting the form confirms and shows the notice", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/subscribe")

      html =
        view
        |> form("#subscribe-form", %{name: "New Reader", email: "new@wraith.test"})
        |> render_submit()

      assert html =~ "check your inbox" or html =~ "You&#39;re in"
      assert Wraith.Members.get_by_email("new@wraith.test")
    end
  end

  describe "member account" do
    test "a signed-in member sees their account, not the login form", %{conn: conn} do
      member = member_fixture(%{"email" => "reader@wraith.test", "name" => "Reader"})
      conn = log_in_member(conn, member)

      {:ok, _view, html} = live(conn, ~p"/members")
      assert html =~ "reader@wraith.test"
      assert html =~ "Sign out"
      refute html =~ ~s(id="member-login-form")
    end
  end

  describe "comments" do
    test "a member can post a comment and see it", %{conn: conn, public: post} do
      member = member_fixture(%{"email" => "commenter@wraith.test", "name" => "Grace"})
      conn = log_in_member(conn, member)

      {:ok, view, html} = live(conn, ~p"/hello-world")
      assert html =~ ~s(id="comment-form")

      view
      |> form("#comment-form", %{body: "First! Great post."})
      |> render_submit()

      # the comment is created and the view refreshes from the PubSub broadcast
      assert Wraith.Comments.for_post(post["id"]) != []
      assert render(view) =~ "First! Great post."
    end

    test "a signed-out reader is invited to sign in", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/hello-world")
      assert html =~ ~s(id="comments")
      refute html =~ ~s(id="comment-form")
      assert html =~ "Sign in" or html =~ "sign in"
    end
  end

  describe "paywall" do
    test "a members-only post is locked for anonymous readers", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/for-members")
      assert html =~ "Public intro."
      refute html =~ "Secret members text."
      assert html =~ ~s(class="paywall")
      assert html =~ "Subscribe"
    end

    test "a member reads the whole post", %{conn: conn} do
      member = member_fixture()
      conn = log_in_member(conn, member)

      {:ok, _view, html} = live(conn, ~p"/for-members")
      assert html =~ "Secret members text."
      refute html =~ ~s(class="paywall")
    end
  end

  # layout module name → the class on its root element
  defp root_class("editorial"), do: "editorial"
  defp root_class("list"), do: "list"
  defp root_class("grid"), do: "grid"
  defp root_class("magazine"), do: "mag"
  defp root_class("minimal"), do: "min"
  defp root_class("journal"), do: "jrn"
end
