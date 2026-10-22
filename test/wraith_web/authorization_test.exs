defmodule WraithWeb.AuthorizationTest do
  @moduledoc """
  Policy is enforced inside every door, not just at it: the Admin API, the
  editor's event handlers, the posts list, and the MCP tools. Each test here
  is a way the lowest staff role (contributor) could once act as an owner.
  """
  use WraithWeb.ConnCase, async: false

  alias Wraith.{Accounts, Content, Tools}

  setup do
    owner = owner_fixture()
    {:ok, contributor} = staff("contrib@wraith.test", "Con Tributor", "contributor")
    {:ok, author} = staff("auth@wraith.test", "An Author", "author")
    {:ok, editor} = staff("ed@wraith.test", "An Editor", "editor")

    owners_post = post_fixture(owner, %{title: "Owner's post", slug: "owners-post"})

    {:ok, contrib_draft} =
      Content.create_post(%{title: "My draft", markdown: "x", author_id: contributor["id"]})

    {:ok,
     owner: owner,
     contributor: contributor,
     author: author,
     editor: editor,
     owners_post: owners_post,
     contrib_draft: contrib_draft}
  end

  defp staff(email, name, role) do
    Accounts.create_user(%{
      "email" => email,
      "name" => name,
      "password" => "a very long password",
      "role" => role
    })
  end

  # ---- Admin API -------------------------------------------------------------------

  describe "Admin API with a staff session" do
    test "a contributor session cannot read settings, members, or the export", %{
      conn: conn,
      contributor: c
    } do
      conn = log_in(conn, c)
      assert get(conn, "/api/admin/settings").status == 403
      assert get(conn, "/api/admin/members").status == 403
      assert get(conn, "/api/admin/db").status == 403
      assert get(conn, "/api/admin/users").status == 403
    end

    test "a contributor session lists only their own drafts", %{
      conn: conn,
      contributor: c,
      contrib_draft: d
    } do
      body = json_response(get(log_in(conn, c), "/api/admin/posts"), 200)
      assert Enum.map(body["posts"], & &1["id"]) == [d["id"]]
    end

    test "any session is read-only on the Admin API — mutations need a Bearer key",
         %{conn: conn, owner: owner, owners_post: p} do
      conn = log_in(conn, owner)
      res = put(conn, "/api/admin/posts/#{p["id"]}", %{"title" => "changed"})
      assert res.status == 403
      assert json_response(res, 403)["errors"] |> hd() |> Map.get("message") =~ "Admin API key"
      assert Content.get_post(p["id"])["title"] == "Owner's post"
    end

    test "an Admin key acts as the owner and may do everything", %{conn: conn, owners_post: p} do
      {:ok, key, _} = Wraith.ApiKeys.create("ci", "admin")
      conn = put_req_header(conn, "authorization", "Bearer " <> key)
      assert json_response(put(conn, "/api/admin/posts/#{p["id"]}", %{"title" => "via key"}), 200)
      assert Content.get_post(p["id"])["title"] == "via key"
      assert json_response(get(conn, "/api/admin/settings"), 200)
    end

    test "a contributor session cannot read someone else's post", %{
      conn: conn,
      contributor: c,
      owners_post: p
    } do
      assert get(log_in(conn, c), "/api/admin/posts/#{p["id"]}").status == 403
    end
  end

  # ---- the editor's event handlers ----------------------------------------------------

  describe "EditorLive" do
    test "meta cannot smuggle status or author_id", %{
      conn: conn,
      contributor: c,
      contrib_draft: d
    } do
      {:ok, view, _} = live(log_in(conn, c), ~p"/admin/posts/#{d["id"]}")

      # the drawer form is only rendered when open; the event is what matters —
      # a crafted payload can send it regardless
      render_hook(view, "meta", %{
        "post" => %{"status" => "published", "author_id" => "someone-else", "tags" => "sneaky"}
      })

      post = Content.get_post(d["id"])
      assert post["status"] == "draft"
      assert post["author_id"] == c["id"]
      assert post["tags"] == ["sneaky"], "harmless metadata still saves"
    end

    test "a contributor cannot schedule or unpublish", %{
      conn: conn,
      contributor: c,
      contrib_draft: d
    } do
      {:ok, view, _} = live(log_in(conn, c), ~p"/admin/posts/#{d["id"]}")
      html = view |> render_hook("schedule", %{"at" => "2020-01-01T10:00"})
      assert html =~ "cannot schedule"
      assert Content.get_post(d["id"])["status"] == "draft"
    end
  end

  describe "PostsLive" do
    test "a contributor cannot publish a post by id", %{
      conn: conn,
      contributor: c,
      owners_post: p,
      contrib_draft: d
    } do
      {:ok, view, _} = live(log_in(conn, c), ~p"/admin/posts")
      render_hook(view, "publish", %{"id" => d["id"]})
      assert Content.get_post(d["id"])["status"] == "draft"
      render_hook(view, "unpublish", %{"id" => p["id"]})
      assert Content.get_post(p["id"])["status"] == "published"
    end
  end

  # ---- MCP tools -----------------------------------------------------------------------

  describe "MCP tools" do
    defp call(user, name, args),
      do: Tools.call(%{"user_id" => user["id"], "scope" => "admin"}, name, args)

    test "an editor cannot touch settings, staff or keys", %{editor: e} do
      assert %{"isError" => true} = call(e, "settings_update", %{"title" => "pwned"})

      assert %{"isError" => true} =
               call(e, "api_key_create", %{"label" => "x", "kind" => "admin"})

      assert %{"isError" => true} =
               call(e, "author_create", %{"email" => "x@x.io", "name" => "X"})

      refute Enum.any?(
               Tools.tools(%{"actor" => e, "scope" => "admin"}),
               &(&1["name"] == "settings_update")
             )
    end

    test "a contributor cannot publish through post_update or post_publish",
         %{contributor: c, contrib_draft: d} do
      call(c, "post_update", %{"id" => d["id"], "status" => "published", "title" => "ok"})
      post = Content.get_post(d["id"])
      assert post["status"] == "draft"
      assert post["title"] == "ok"
      assert %{"isError" => true} = call(c, "post_publish", %{"id" => d["id"]})
    end

    test "an author cannot edit another author's post", %{author: a, owners_post: p} do
      assert %{"isError" => true} =
               call(a, "post_update", %{"id" => p["id"], "title" => "mine now"})

      assert %{"isError" => true} = call(a, "post_delete", %{"id" => p["id"]})
    end

    test "no acting user → nothing", %{} do
      assert Tools.tools(%{"scope" => "admin"}) == []
      assert %{"isError" => true} = Tools.call(%{"scope" => "admin"}, "posts_list", %{})
    end

    test "a Content key sees only the public tools and nothing about members", %{} do
      names = Tools.tools(%{"scope" => "content"}) |> Enum.map(& &1["name"])
      assert "posts_list" in names and "search" in names
      refute "members_list" in names
      refute "settings_get" in names
      refute "widget_test" in names
      assert %{"isError" => true} = Tools.call(%{"scope" => "content"}, "members_list", %{})
    end
  end
end
