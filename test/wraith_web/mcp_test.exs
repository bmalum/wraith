defmodule WraithWeb.McpTest do
  use WraithWeb.ConnCase, async: false
  import Swoosh.TestAssertions

  alias Wraith.{ApiKeys, Content, Members, Settings, Tools, Widgets}

  setup %{conn: conn} do
    set_swoosh_global()
    owner = owner_fixture()

    post =
      post_fixture(owner, %{markdown: "Hello **there**\n\n{{widget counter id=c1}}", tags: "news"})

    {:ok, admin, _} = ApiKeys.create("agent", "admin")
    {:ok, content, _} = ApiKeys.create("reader", "content")

    %{
      owner: owner,
      post: post,
      admin: admin,
      content: content,
      conn: put_req_header(conn, "content-type", "application/json")
    }
  end

  defp rpc(conn, key, method, params \\ %{}, id \\ 1) do
    conn
    |> put_req_header("authorization", "Bearer #{key}")
    |> post(~p"/mcp", Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params}))
  end

  defp call(conn, key, name, args) do
    body = rpc(conn, key, "tools/call", %{name: name, arguments: args}) |> json_response(200)
    result = body["result"]
    text = result["content"] |> Enum.map_join("", & &1["text"])
    {result["isError"] == true, text}
  end

  defp call!(conn, key, name, args) do
    {err?, text} = call(conn, key, name, args)
    refute err?, "#{name} failed: #{text}"
    Jason.decode!(text)
  end

  test "protocol: auth, initialize, tools/list, notifications, batch, errors", %{
    conn: conn,
    admin: admin,
    content: content
  } do
    assert json_response(
             post(
               conn,
               ~p"/mcp",
               Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "initialize", params: %{}})
             ),
             403
           )["error"]["message"] =~ "API key"

    assert conn |> get(~p"/mcp") |> response(405)

    assert conn
           |> put_req_header("authorization", "Bearer #{admin}")
           |> delete(~p"/mcp")
           |> response(204)

    init =
      rpc(conn, admin, "initialize", %{protocolVersion: "2025-06-18", clientInfo: %{name: "test"}})
      |> json_response(200)

    assert init["result"]["protocolVersion"] == "2025-06-18"
    assert init["result"]["serverInfo"]["name"] == "wraith"

    assert is_map(init["result"]["capabilities"]["tools"]) and
             is_map(init["result"]["capabilities"]["resources"])

    # a notification: 202, no body
    assert conn
           |> put_req_header("authorization", "Bearer #{admin}")
           |> post(
             ~p"/mcp",
             Jason.encode!(%{jsonrpc: "2.0", method: "notifications/initialized"})
           )
           |> response(202) == ""

    admin_tools =
      rpc(conn, admin, "tools/list")
      |> json_response(200)
      |> Map.get("result")
      |> Map.get("tools")

    content_tools =
      rpc(conn, content, "tools/list")
      |> json_response(200)
      |> Map.get("result")
      |> Map.get("tools")

    assert length(admin_tools) >= 49
    assert Enum.all?(content_tools, &(&1["annotations"]["readOnlyHint"] == true))
    assert length(content_tools) < length(admin_tools)

    assert Enum.all?(
             admin_tools,
             &(is_map(&1["inputSchema"]) and is_binary(&1["description"]) and
                 &1["description"] != "")
           )

    # a content key may read but not write
    {false, _} = call(conn, content, "posts_list", %{})
    {true, msg} = call(conn, content, "post_create", %{title: "x"})
    assert msg =~ "needs an Admin key"

    # batch
    batch = [
      %{jsonrpc: "2.0", id: 1, method: "ping"},
      %{
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: %{name: "site_info", arguments: %{}}
      },
      %{jsonrpc: "2.0", method: "notifications/x"}
    ]

    replies =
      conn
      |> put_req_header("authorization", "Bearer #{admin}")
      |> post(~p"/mcp", Jason.encode!(batch))
      |> json_response(200)

    assert [%{"id" => 1, "result" => %{}}, %{"id" => 2, "result" => %{"content" => _}}] = replies

    assert rpc(conn, admin, "nope/method")
           |> json_response(200)
           |> Map.get("error")
           |> Map.get("code") == -32601

    {true, msg} = call(conn, admin, "no_such_tool", %{})
    assert msg =~ "unknown tool"
  end

  test "resources: list and read", %{conn: conn, admin: admin, post: post} do
    res =
      rpc(conn, admin, "resources/list")
      |> json_response(200)
      |> Map.get("result")
      |> Map.get("resources")

    assert Enum.any?(res, &(&1["uri"] == "wraith://settings"))
    assert Enum.any?(res, &(&1["uri"] == "wraith://posts/#{post["slug"]}"))

    read =
      rpc(conn, admin, "resources/read", %{uri: "wraith://posts/#{post["slug"]}"})
      |> json_response(200)

    assert [%{"mimeType" => "text/markdown", "text" => text}] = read["result"]["contents"]
    assert text =~ "# Hello World" and text =~ "{{widget counter"

    assert rpc(conn, admin, "resources/read", %{uri: "wraith://posts/nope"})
           |> json_response(200)
           |> Map.get("error")
           |> Map.get("code") == -32002
  end

  test "every UI action has a tool: the full lifecycle through MCP", %{
    conn: conn,
    admin: admin,
    post: post,
    owner: owner
  } do
    # settings & theme
    s =
      call!(conn, admin, "settings_update", %{
        title: "Agent Site",
        theme: "ink",
        comments_enabled: true,
        redirects: [%{from: "/old", to: "/"}]
      })

    assert s["settings"]["title"] == "Agent Site" and s["settings"]["theme"] == "ink"
    assert call!(conn, admin, "themes_list", %{})["active"] == "ink"
    {true, _} = call(conn, admin, "settings_update", %{theme: "nope"})

    # posts: create (from HTML), update, revisions, restore, publish/schedule, newsletter, unpublish, delete
    created =
      call!(conn, admin, "post_create", %{
        title: "Agent post",
        html: "<p>From <b>HTML</b></p>",
        tags: "agents, news",
        show_toc: true
      })

    assert created["post"]["markdown"] == "From **HTML**"
    assert created["post"]["tags"] == ["agents", "news"]
    id = created["post"]["id"]
    call!(conn, admin, "post_update", %{id: id, markdown: "## Section\n\nSecond body"})
    revs = call!(conn, admin, "post_revisions", %{id: id})["revisions"]
    assert length(revs) == 2

    restored =
      call!(conn, admin, "post_restore_revision", %{id: id, revision: List.last(revs)["sk"]})

    assert restored["post"]["markdown"] == "From **HTML**"
    scheduled = call!(conn, admin, "post_publish", %{id: id, at: "2999-01-01T10:00:00Z"})
    assert scheduled["post"]["status"] == "scheduled"
    published = call!(conn, admin, "post_publish", %{id: id})
    assert published["post"]["status"] == "published"
    assert call!(conn, admin, "post_get", %{id: "agent-post"})["post"]["id"] == id
    _ = :sys.get_state(Wraith.Search)

    assert [%{"post" => %{"id" => ^id}}] =
             call!(conn, admin, "search", %{query: "agent"})["results"]
             |> Enum.filter(&(&1["post"]["id"] == id))

    {:ok, _} = Members.create(%{email: "sub@x.io"})
    assert call!(conn, admin, "newsletter_send", %{id: id})["recipients"] == 1
    assert_received {:email, %Swoosh.Email{subject: "Agent post"}}
    assert call!(conn, admin, "newsletter_status", %{id: id})["sent"] == true
    {true, msg} = call(conn, admin, "newsletter_send", %{id: id})
    assert msg =~ "already went out"
    call!(conn, admin, "post_unpublish", %{id: id})
    call!(conn, admin, "post_delete", %{id: id})
    assert Content.get_post(id) == nil

    # tags
    call!(conn, admin, "tag_upsert", %{slug: "news", name: "Newsroom", description: "d"})
    assert Content.get_tag("news")["name"] == "Newsroom"

    assert Enum.any?(
             call!(conn, admin, "tags_list", %{})["tags"],
             &(&1["slug"] == "news" and &1["posts"] == 1)
           )

    call!(conn, admin, "tag_delete", %{slug: "news"})
    assert Content.get_tag("news") == nil

    # authors
    a = call!(conn, admin, "author_create", %{email: "new@x.io", name: "New Author"})
    assert a["reset_mailed"] == true
    assert_received {:email, %Swoosh.Email{subject: "Reset your Agent Site password"}}
    call!(conn, admin, "author_update", %{id: a["author"]["id"], bio: "Writes.", twitter: "@new"})
    assert Wraith.Accounts.get_user(a["author"]["id"])["twitter"] == "@new"
    assert length(call!(conn, admin, "authors_list", %{})["authors"]) == 2
    call!(conn, admin, "author_send_reset", %{email: owner["email"]})

    # members
    m =
      call!(conn, admin, "member_create", %{
        email: "vip@x.io",
        name: "VIP",
        status: "comped",
        welcome: true
      })

    assert_received {:email, %Swoosh.Email{subject: "Welcome to Agent Site"}}
    call!(conn, admin, "member_update", %{id: "vip@x.io", status: "paid", subscribed: false})

    assert call!(conn, admin, "member_get", %{id: m["member"]["id"]})["member"]["status"] ==
             "paid"

    call!(conn, admin, "member_send_login_link", %{id: "vip@x.io"})
    assert_received {:email, %Swoosh.Email{subject: "Sign in to Agent Site"}}
    assert call!(conn, admin, "members_list", %{status: "paid"})["members"] |> length() == 1
    call!(conn, admin, "member_delete", %{id: "vip@x.io"})
    assert Members.get_by_email("vip@x.io") == nil

    # comments
    {:ok, member} = Members.create(%{email: "c@x.io", name: "C"})
    {:ok, c} = Wraith.Comments.create(post, member, "Nice post")
    assert [%{"body" => "Nice post"}] = call!(conn, admin, "comments_list", %{})["comments"]
    call!(conn, admin, "comment_moderate", %{post_id: post["id"], id: c["id"], action: "hide"})

    assert [%{"status" => "hidden"}] =
             call!(conn, admin, "comments_list", %{status: "hidden"})["comments"]

    call!(conn, admin, "comment_moderate", %{post_id: post["id"], id: c["id"], action: "remove"})
    assert Wraith.Comments.count(post["id"]) == 0

    # widgets: docs, test, save, versions, rollback, enable, state, delete
    assert {false, docs} = call(conn, admin, "widget_docs", %{})
    assert docs =~ "wraith.action"

    src =
      "function init(p) return {n=0} end function render(s,p,m) return 'n=' .. s.n end function handle(s,e,p,m) s.n = s.n + 1 return s end"

    t =
      call!(conn, admin, "widget_test", %{source: src, events: [%{event: "go"}, %{event: "go"}]})

    assert t["steps"] |> List.last() |> get_in(["state", "n"]) == 2
    w = call!(conn, admin, "widget_save", %{slug: "tally", name: "Tally", source: src})
    assert w["shortcode"] == "{{widget tally}}"

    call!(conn, admin, "widget_save", %{
      slug: "tally",
      name: "Tally",
      source: String.replace(src, "n=", "N=")
    })

    assert Enum.map(
             call!(conn, admin, "widget_versions", %{slug: "tally"})["versions"],
             & &1["rev"]
           ) == [2, 1]

    assert call!(conn, admin, "widget_rollback", %{slug: "tally", rev: 1})["widget"]["rev"] == 3
    call!(conn, admin, "widget_enable", %{slug: "tally", enabled: false})
    assert Widgets.get("tally")["enabled"] == false
    {:ok, _} = Widgets.dispatch(Widgets.get("counter"), "c1", %{}, "inc", %{}, %{})

    assert call!(conn, admin, "widget_state_get", %{slug: "counter", instance: "c1"})["state"][
             "count"
           ] == 1

    call!(conn, admin, "widget_state_reset", %{slug: "counter", instance: "c1"})

    assert call!(conn, admin, "widget_state_get", %{slug: "counter", instance: "c1"})["state"][
             "count"
           ] == 0

    call!(conn, admin, "widget_delete", %{slug: "tally"})
    assert Widgets.get("tally") == nil
    {true, msg} = call(conn, admin, "widget_delete", %{slug: "counter"})
    assert msg =~ "built in"

    # uploads
    File.rm_rf!(Wraith.Uploads.Local.root())

    up =
      call!(conn, admin, "upload_base64", %{
        data: Base.encode64(<<137, 80, 78, 71>>),
        content_type: "image/png",
        name: "logo"
      })

    assert up["path"] =~ ~r"^/uploads/\d{4}/\d{2}/logo-"
    assert up["markdown"] =~ "![](/uploads/"

    # api keys, export/import
    k = call!(conn, admin, "api_key_create", %{label: "ci", kind: "content"})
    assert k["key"] =~ ":"
    assert Enum.any?(call!(conn, admin, "api_keys_list", %{})["keys"], &(&1["id"] == k["id"]))
    call!(conn, admin, "api_key_delete", %{id: k["id"]})
    export = call!(conn, admin, "site_export", %{})
    assert [%{"data" => %{"posts" => [_ | _]}}] = export["db"]
    imported = call!(conn, admin, "site_import", %{data: export})
    assert imported["imported"]["posts_skipped"] >= 1

    # site_info reflects it all
    info = call!(conn, admin, "site_info", %{})
    assert info["site"]["title"] == "Agent Site" and info["counts"]["published"] == 1
  end

  test "the catalogue is complete and consistent" do
    names = Tools.names()
    assert names == Enum.uniq(names), "duplicate tool names"

    # every admin screen's actions, by domain
    for required <- ~w(
          site_info settings_get settings_update themes_list
          posts_list post_get post_revisions post_create post_update post_publish post_unpublish post_delete post_restore_revision newsletter_send newsletter_status search
          tags_list tag_upsert tag_delete
          authors_list author_create author_update author_send_reset
          members_list member_get member_create member_update member_delete member_send_login_link
          comments_list comment_moderate
          widgets_list widget_get widget_docs widget_versions widget_test widget_save widget_rollback widget_enable widget_delete widget_state_get widget_state_reset
          upload_from_url upload_base64
          api_keys_list api_key_create api_key_delete site_export site_import
        ) do
      assert required in names, "missing tool #{required}"
    end

    # every tool answers a call with missing arguments cleanly (no crash, an isError result)
    ctx = %{"user_id" => nil, "scope" => "admin"}

    for name <- names do
      result = Tools.call(ctx, name, %{})
      assert is_list(result["content"]), "#{name} returned no content"
    end

    # the studio agent sees the same registry
    assert Wraith.Studio.Tools.tools(%{"user_id" => nil}) |> Enum.map(& &1["name"]) == names
  end
end
