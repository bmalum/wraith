defmodule WraithWeb.ApiTest do
  use WraithWeb.ConnCase, async: false
  alias Wraith.{ApiKeys, Content, Ghost}

  setup do
    owner = owner_fixture()

    post =
      post_fixture(owner, %{
        markdown: "# Hi\n\nBody **bold**.\n\n{{widget counter id=c1}}",
        tags: "news, elixir",
        custom_excerpt: "Short."
      })

    {:ok, content_key, _} = ApiKeys.create("site", "content")
    {:ok, admin_key, _} = ApiKeys.create("ci", "admin")
    %{owner: owner, post: post, ckey: content_key, akey: admin_key}
  end

  test "content api needs a content key and answers in Ghost's shape", %{
    conn: conn,
    ckey: key,
    post: post,
    owner: owner
  } do
    assert json_response(get(conn, ~p"/api/content/posts"), 401)["errors"]
           |> hd()
           |> Map.get("type") == "UnauthorizedError"

    assert json_response(get(conn, ~p"/api/content/posts?key=nope:nope"), 401)

    body = json_response(get(conn, "/api/content/posts?key=#{key}"), 200)
    assert [p] = body["posts"]
    assert p["title"] == "Hello World" and p["slug"] == post["slug"]
    assert p["html"] =~ "<strong>bold</strong>"
    assert p["html"] =~ ~s(class="wraith-widget" data-widget="counter" data-instance="c1")
    assert p["primary_author"]["name"] == owner["name"]
    refute Map.has_key?(p["primary_author"], "email")
    assert Enum.map(p["tags"], & &1["slug"]) == ["news", "elixir"]
    assert p["primary_tag"]["slug"] == "news"
    assert p["reading_time"] == 1
    assert p["url"] =~ "/" <> post["slug"]
    assert body["meta"]["pagination"]["page"] == 1

    assert [%{"slug" => s}] =
             json_response(get(conn, "/api/content/posts?key=#{key}&tag=elixir"), 200)["posts"]

    assert s == post["slug"]

    assert json_response(get(conn, "/api/content/posts?key=#{key}&tag=nothing"), 200)["posts"] ==
             []

    assert [_] =
             json_response(get(conn, "/api/content/posts/#{post["slug"]}?key=#{key}"), 200)[
               "posts"
             ]

    assert json_response(get(conn, "/api/content/posts/nope?key=#{key}"), 404)

    assert [%{"slug" => "elixir"}, %{"slug" => "news"}] =
             json_response(get(conn, "/api/content/tags?key=#{key}"), 200)["tags"]
             |> Enum.sort_by(& &1["slug"])

    assert [%{"slug" => "owner-one"}] =
             json_response(get(conn, "/api/content/authors?key=#{key}"), 200)["authors"]

    assert json_response(get(conn, "/api/content/settings?key=#{key}"), 200)["settings"]["title"] ==
             "Wraith"

    # members-only posts: metadata, no body
    locked = post_fixture(owner, %{title: "Locked", visibility: "members"})

    locked_json =
      json_response(get(conn, "/api/content/posts/#{locked["slug"]}?key=#{key}"), 200)["posts"]
      |> hd()

    assert locked_json["access"] == false
    refute Map.has_key?(locked_json, "html")
  end

  test "admin api: bearer key or session, CRUD, html bodies become markdown", %{
    conn: conn,
    akey: key,
    ckey: ckey,
    owner: owner
  } do
    assert json_response(get(conn, ~p"/api/admin/posts"), 401)

    assert json_response(
             conn
             |> put_req_header("authorization", "Bearer #{ckey}")
             |> get(~p"/api/admin/posts"),
             401
           ),
           "a content key is not an admin key"

    auth = fn c -> put_req_header(c, "authorization", "Bearer #{key}") end
    assert [_] = json_response(auth.(conn) |> get(~p"/api/admin/posts"), 200)["posts"]

    created =
      auth.(conn)
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/admin/posts",
        Jason.encode!(%{
          posts: [
            %{
              title: "Via API",
              html: "<p>Hello <em>there</em></p>",
              tags: "api",
              status: "published"
            }
          ]
        })
      )
      |> json_response(201)
      |> Map.get("posts")
      |> hd()

    assert created["markdown"] == "Hello *there*"

    assert created["status"] == "published" and
             created["tags"] |> hd() |> Map.get("slug") == "api"

    assert created["primary_author"]["id"] == owner["id"],
           "key writes are attributed to the owner"

    updated =
      auth.(conn)
      |> put_req_header("content-type", "application/json")
      |> put("/api/admin/posts/#{created["id"]}", Jason.encode!(%{title: "Renamed"}))
      |> json_response(200)

    assert hd(updated["posts"])["title"] == "Renamed"
    assert auth.(conn) |> delete("/api/admin/posts/#{created["id"]}") |> response(204)
    assert Content.get_post(created["id"]) == nil

    # a signed-in author may use it without a key
    assert json_response(conn |> log_in(owner) |> get(~p"/api/admin/settings"), 200)["settings"][
             "title"
           ] == "Wraith"

    assert json_response(
             auth.(conn)
             |> put_req_header("content-type", "application/json")
             |> put(~p"/api/admin/settings", Jason.encode!(%{title: "Renamed site"})),
             200
           )["settings"]["title"] == "Renamed site"

    assert json_response(
             auth.(conn)
             |> put_req_header("content-type", "application/json")
             |> post(~p"/api/admin/members", Jason.encode!(%{email: "api@x.io"})),
             201
           )
  end

  test "export round-trips and a Ghost export imports", %{conn: conn, akey: key, owner: owner} do
    export =
      json_response(
        conn |> put_req_header("authorization", "Bearer #{key}") |> get(~p"/api/admin/db"),
        200
      )

    assert [%{"data" => data}] = export["db"]
    assert [%{"slug" => "hello-world", "markdown" => "# Hi" <> _}] = data["posts"]
    assert Enum.map(data["tags"], & &1["slug"]) |> Enum.sort() == ["elixir", "news"]
    assert length(data["posts_tags"]) == 2
    refute Enum.any?(data["settings"], &(&1["key"] =~ "stripe_secret"))

    # import our own export into a wiped site: everything comes back (owner is kept)
    Wraith.StoreCase.reset()
    owner2 = owner_fixture()
    {:ok, counts} = Ghost.import(export, author: owner2)
    assert counts.posts == 1 and counts.tags == 2
    assert Content.get_post_by_slug("hello-world")["markdown"] =~ "{{widget counter"
    {:ok, counts} = Ghost.import(export, author: owner2)
    assert counts.posts_skipped == 1, "a second import skips what exists"

    # a real Ghost export
    ghost = File.read!("test/fixtures/ghost_export.json") |> Jason.decode!()
    {:ok, counts} = Ghost.import(ghost, author: owner2)
    assert counts.posts == 3 and counts.users == 1 and counts.tags == 2
    p = Content.get_post_by_slug("hello-from-ghost")
    assert p["status"] == "published" and p["featured"] == true
    assert p["markdown"] =~ "## Welcome"
    assert p["markdown"] =~ "**Ghost**"
    assert p["markdown"] =~ "[link](https://ghost.org)"
    assert p["markdown"] =~ "```js\nconsole.log(\"hi\")\n```"
    assert p["tags"] == ["getting-started", "news"]
    assert p["published_at"] =~ "2023-11-14T10:00:00"
    author = Wraith.Accounts.get_user_by_email("ghost@example.com")
    assert author["role"] == "author" and author["avatar"] == "https://img.example/me.png"
    assert p["author_id"] == author["id"]
    assert Content.get_post_by_slug("about")["type"] == "page"
    assert Content.get_post_by_slug("members-only")["visibility"] == "members"
    assert Content.get_tag("getting-started")["description"] == "How to begin"
    _ = owner

    # the admin page: keys and import upload
    {:ok, view, _} = live(log_in(conn, owner2), ~p"/admin/integrations")
    view |> form("#key-create-form", %{label: "zapier", kind: "content"}) |> render_submit()
    assert render(view) =~ "shown once"
    assert render(view) =~ "/mcp" and render(view) =~ "mcpServers"
    assert Enum.any?(ApiKeys.list(), &(&1["label"] == "zapier"))
  end
end
