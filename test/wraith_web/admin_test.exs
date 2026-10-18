defmodule WraithWeb.AdminTest do
  use WraithWeb.ConnCase, async: false

  setup %{conn: conn} do
    owner = owner_fixture()
    %{owner: owner, conn: log_in(conn, owner)}
  end

  test "admin requires sign-in" do
    conn = build_conn() |> get(~p"/admin")
    assert redirected_to(conn) == ~p"/admin/login"
  end

  test "login and logout", %{owner: owner} do
    conn =
      build_conn()
      |> post(~p"/admin/login", user: %{email: owner["email"], password: "a very long password"})

    assert redirected_to(conn) == ~p"/admin"
    assert get_session(conn, :user_token)

    conn =
      build_conn() |> post(~p"/admin/login", user: %{email: owner["email"], password: "nope"})

    assert redirected_to(conn) == ~p"/admin/login"

    conn = build_conn() |> log_in(owner) |> get(~p"/admin/logout")
    assert redirected_to(conn) == ~p"/"
  end

  test "dashboard", %{conn: conn, owner: owner} do
    post_fixture(owner)
    {:ok, _, html} = live(conn, ~p"/admin")
    assert html =~ "Dashboard"
    assert html =~ "Hello World"
  end

  test "editor: new post, type, publish", %{conn: conn} do
    conn = get(conn, ~p"/admin/posts/new")
    assert "/admin/posts/" <> id = redirected_to(conn)
    {:ok, view, _} = live(conn, ~p"/admin/posts/#{id}")

    view
    |> form("#editor-form", %{title: "My post", markdown: "Hello **there**\n\n{{widget counter}}"})
    |> render_change()

    html = render(view)
    assert html =~ "<strong>there</strong>"
    assert html =~ ~s(data-widget="counter")
    assert html =~ "Saved"

    [post] = Wraith.Content.list_all_posts()
    assert post["title"] == "My post"
    assert post["status"] == "draft"

    view |> element("button", "Publish") |> render_click()
    assert Wraith.Content.get_post(post["id"])["status"] == "published"
    assert render(view) =~ "Unpublish"

    # metadata drawer
    view |> element("button", "Settings") |> render_click()
    view |> form("#meta-form", post: %{tags: "a, b", slug: "custom-slug"}) |> render_change()
    post = Wraith.Content.get_post(post["id"])
    assert post["tags"] == ["a", "b"]
    assert post["slug"] == "custom-slug"
  end

  test "editor: feature image and inline image uploads", %{conn: conn, owner: owner} do
    File.rm_rf!(Wraith.Uploads.Local.root())
    {:ok, p} = Wraith.Content.create_post(%{title: "Pics", author_id: owner["id"]})
    {:ok, view, _} = live(conn, ~p"/admin/posts/#{p["id"]}")
    view |> element("button", "Settings") |> render_click()

    feature =
      file_input(view, "#feature-upload-form", :feature, [
        %{name: "cover.png", content: <<137, 80, 78, 71>>, type: "image/png"}
      ])

    render_upload(feature, "cover.png")
    post = Wraith.Content.get_post(p["id"])
    assert "/uploads/" <> _ = post["feature_image"]
    assert post["feature_image"] =~ "cover-"
    assert render(view) =~ ~s(src="#{post["feature_image"]}")

    inline =
      file_input(view, "#inline-upload-form", :inline, [
        %{name: "diagram.png", content: <<137, 80, 78, 71>>, type: "image/png"}
      ])

    render_upload(inline, "diagram.png")
    assert_push_event(view, "editor:insert", %{text: text})
    assert text =~ ~r"!\[diagram\]\(/uploads/\d{4}/\d{2}/diagram-[0-9a-f]+\.png\)"

    bad =
      file_input(view, "#inline-upload-form", :inline, [
        %{name: "x.exe", content: "x", type: "application/octet-stream"}
      ])

    assert {:error, [[_, :not_accepted]]} = render_upload(bad, "x.exe")
  end

  test "editor: schedule", %{conn: conn, owner: owner} do
    {:ok, p} = Wraith.Content.create_post(%{title: "Later", author_id: owner["id"]})
    {:ok, view, _} = live(conn, ~p"/admin/posts/#{p["id"]}")
    view |> element("button", "Settings") |> render_click()
    view |> form("form[phx-submit=schedule]", %{at: "2999-01-01T10:00"}) |> render_submit()
    assert Wraith.Content.get_post(p["id"])["status"] == "scheduled"
  end

  test "posts list filters and deletes", %{conn: conn, owner: owner} do
    post = post_fixture(owner)
    {:ok, _d} = Wraith.Content.create_post(%{title: "Draft one", author_id: owner["id"]})
    {:ok, _view, html} = live(conn, ~p"/admin/posts")
    assert html =~ "Hello World"
    assert html =~ "Draft one"
    {:ok, _view, html} = live(conn, ~p"/admin/posts?status=draft")
    refute html =~ "Hello World"
    assert html =~ "Draft one"
    {:ok, view, _} = live(conn, ~p"/admin/posts")
    view |> element(~s(#post-#{post["id"]} button[phx-click=delete])) |> render_click()
    refute render(view) =~ "Hello World"
    assert Wraith.Content.get_post(post["id"]) == nil
    _ = view
  end

  test "tags, members, settings", %{conn: conn, owner: owner} do
    post_fixture(owner)
    {:ok, view, html} = live(conn, ~p"/admin/tags")
    assert html =~ "News"
    view |> element(~s(#tag-news button[phx-click=edit])) |> render_click()

    view
    |> form("#tag-news form", %{slug: "news", name: "Newsroom", description: "All the news"})
    |> render_submit()

    assert Wraith.Content.get_tag("news")["name"] == "Newsroom"

    {:ok, view, _} = live(conn, ~p"/admin/members")
    view |> form("form[phx-submit=create]", %{email: "m@x.io", name: "M"}) |> render_submit()
    assert render(view) =~ "m@x.io"

    {:ok, view, _} = live(conn, ~p"/admin/settings")

    view
    |> form("#site-form",
      site: %{
        title: "Renamed",
        description: "d",
        navigation: "Home /\nAbout /about",
        footer: "",
        accent: "#112233",
        posts_per_page: "7",
        lang: "en"
      }
    )
    |> render_submit()

    site = Wraith.Settings.get()
    assert site["title"] == "Renamed"
    assert site["posts_per_page"] == 7

    assert site["navigation"] == [
             %{"label" => "Home", "url" => "/"},
             %{"label" => "About", "url" => "/about"}
           ]

    view
    |> form("#author-form", user: %{name: "Co", email: "co@x.io", password: "another long pw"})
    |> render_submit()

    assert Wraith.Accounts.get_user_by_email("co@x.io")["role"] == "author"
  end

  test "widgets: list, toggle, editor with live preview, save, versions", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/widgets")
    assert html =~ "Counter"
    view |> element(~s(#widget-counter button[phx-click=toggle])) |> render_click()
    assert Wraith.Widgets.get("counter")["enabled"] == false

    {:ok, view, html} = live(conn, ~p"/admin/widgets/new")
    assert html =~ "Click me"

    src =
      "function init(p) return {n=0} end\nfunction render(s,p,m) return '<button ' .. wraith.action('go') .. '>' .. s.n .. '</button>' end\nfunction handle(s,e,p,m) s.n = s.n + 10 return s end"

    view
    |> form("#widget-form", %{
      name: "Tenner",
      slug: "tenner",
      description: "adds ten",
      source: src
    })
    |> render_change()

    assert render(view) =~ ~s(phx-value-event="go")
    view |> element(~s(button[phx-value-event="go"])) |> render_click()
    assert render(view) =~ ">10</button>"

    view |> element("button", "Save") |> render_click()
    assert_patch(view, ~p"/admin/widgets/tenner")
    assert Wraith.Widgets.get("tenner")["rev"] == 1

    # a broken edit shows the error in the preview and refuses to save
    view |> form("#widget-form", %{source: "function init("}) |> render_change()
    assert render(view) =~ "syntax error"
    view |> element("button", "Save") |> render_click()
    assert Wraith.Widgets.get("tenner")["rev"] == 1
  end

  test "profile: avatar, socials, password change", %{conn: conn, owner: owner} do
    File.rm_rf!(Wraith.Uploads.Local.root())
    {:ok, view, _} = live(conn, ~p"/admin/profile")

    view
    |> form("#profile-form",
      user: %{
        name: "Ada L.",
        bio: "Engines.",
        website: "https://ada.example",
        twitter: "@ada",
        github: "ada",
        mastodon: "",
        location: "London"
      }
    )
    |> render_submit()

    u = Wraith.Accounts.get_user(owner["id"])
    assert u["twitter"] == "@ada" and u["slug"] == "ada-l"

    av =
      file_input(view, "#avatar-form", :avatar, [
        %{name: "me.png", content: <<137, 80, 78, 71>>, type: "image/png"}
      ])

    render_upload(av, "me.png")
    assert "/uploads/" <> _ = Wraith.Accounts.get_user(owner["id"])["avatar"]

    {:ok, _, html} = live(build_conn(), ~p"/author/ada-l")

    assert html =~ "https://x.com/ada" and html =~ "London" and
             html =~ ~s(class="author-avatar is-large is-img")

    view
    |> form("#password-form", %{current_password: "wrong", password: "a brand new password"})
    |> render_submit()

    assert render(view) =~ "is wrong"

    view
    |> form("#password-form", %{
      current_password: "a very long password",
      password: "a brand new password"
    })
    |> render_submit()

    assert {:ok, _} = Wraith.Accounts.authenticate(owner["email"], "a brand new password")
  end

  test "password reset by mail", %{owner: owner} do
    import Swoosh.TestAssertions
    set_swoosh_global()
    {:ok, view, _} = live(build_conn(), ~p"/admin/forgot")
    view |> form("#forgot-form", user: %{email: owner["email"]}) |> render_submit()
    assert render(view) =~ "reset link is on its way"

    assert_email_sent(fn email ->
      assert email.subject =~ "Reset your"
      [_, token] = Regex.run(~r{/admin/reset/([\w\-\.]+)}, email.html_body)
      {:ok, v, _} = live(build_conn(), ~p"/admin/reset/#{token}")
      v |> form("#reset-form", user: %{password: "short"}) |> render_submit()
      assert render(v) =~ "at least 10"
      v |> form("#reset-form", user: %{password: "reset to this one"}) |> render_submit()
      assert render(v) =~ "Done."
      assert {:ok, _} = Wraith.Accounts.authenticate(owner["email"], "reset to this one")
      true
    end)

    {:ok, v, _} = live(build_conn(), ~p"/admin/reset/not-a-token")
    v |> form("#reset-form", user: %{password: "reset to this one"}) |> render_submit()
    assert render(v) =~ "is not valid"

    # unknown address: same answer, no mail
    {:ok, view, _} = live(build_conn(), ~p"/admin/forgot")
    view |> form("#forgot-form", user: %{email: "nobody@x.io"}) |> render_submit()
    refute_email_sent()
  end

  test "studio: key, wake, prompt, tool calls stream into the console", %{conn: conn} do
    :ok = Wraith.Studio.shutdown()
    {:ok, view, html} = live(conn, ~p"/admin/studio")
    assert html =~ "Meet your studio agent"

    view |> form("#key-form", %{key: "ksk_" <> String.duplicate("d", 24)}) |> render_submit()
    assert render(view) =~ "ksk_…dddd"

    view |> element("button", "Wake the agent") |> render_click()
    # boot runs in a task; the state broadcast lands in the view
    assert eventually(fn -> render(view) =~ "Ready" end)

    view |> form("#composer", %{text: "!widget cheer"}) |> render_submit()
    assert eventually(fn -> render(view) =~ "@wraith/widget_save" end)
    assert eventually(fn -> render(view) =~ "Embed it with" end)
    assert Wraith.Widgets.get("cheer")
    :ok = Wraith.Studio.shutdown()
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end
end
