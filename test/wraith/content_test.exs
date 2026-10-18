defmodule Wraith.ContentTest do
  use Wraith.StoreCase, async: false
  alias Wraith.{Accounts, Content}

  setup do
    {:ok, owner} =
      Accounts.create_user(%{
        email: "o@x.io",
        name: "Owner Person",
        password: "correct horse battery"
      })

    %{owner: owner}
  end

  defp draft(owner, attrs \\ %{}) do
    {:ok, p} =
      Content.create_post(
        Map.merge(
          %{title: "Hello World", markdown: "# Hi\n\nSome *text* here.", author_id: owner["id"]},
          attrs
        )
      )

    p
  end

  test "create draft derives slug, excerpt, sort key", %{owner: o} do
    p = draft(o)
    assert p["slug"] == "hello-world"
    assert p["status"] == "draft"
    assert p["excerpt"] == "Hi Some text here."
    assert p["gsi1pk"] == "POSTS#draft"
    assert Content.get_post_by_slug("hello-world")["id"] == p["id"]
    assert Content.get_published("hello-world") == nil
  end

  test "slugs are unique; the second gets refused", %{owner: o} do
    draft(o)

    assert {:error, %{"slug" => _}} =
             Content.create_post(%{title: "Hello World", author_id: o["id"]})
  end

  test "validation", %{owner: o} do
    assert {:ok, %{"slug" => "draft-" <> _}} =
             Content.create_post(%{title: "", author_id: o["id"]})

    assert {:error, %{"title" => _}} =
             Content.create_post(%{title: "", author_id: o["id"], status: "published"})

    assert {:error, %{"author_id" => _}} = Content.create_post(%{title: "x"})

    assert {:error, %{"status" => _}} =
             Content.create_post(%{title: "x", author_id: o["id"], status: "weird"})
  end

  test "publish moves index, writes tag + author memberships", %{owner: o} do
    p = draft(o, %{tags: "Elixir, Live View"})
    assert p["tags"] == ["elixir", "live-view"]
    assert Content.list_posts("published").posts == []
    assert Content.posts_tagged("elixir").posts == []

    {:ok, p} = Content.publish_post(p)
    assert p["status"] == "published"
    assert p["published_at"]
    assert [%{"id" => id}] = Content.list_posts("published").posts
    assert id == p["id"]
    assert Content.list_posts("draft").posts == []
    assert [%{"id" => ^id}] = Content.posts_tagged("elixir").posts
    assert [%{"id" => ^id}] = Content.posts_tagged("live-view").posts
    assert [%{"id" => ^id}] = Content.posts_by_author(o["id"]).posts
    assert Content.get_published("hello-world")["id"] == id

    # tags were materialised
    assert Enum.map(Content.list_tags(), & &1["slug"]) |> Enum.sort() == ["elixir", "live-view"]
    assert Content.tag_counts() == %{"elixir" => 1, "live-view" => 1}

    # retagging drops the stale membership
    {:ok, p} = Content.update_post(p, %{tags: ["elixir"]})
    assert Content.posts_tagged("live-view").posts == []
    assert [%{"id" => ^id}] = Content.posts_tagged("elixir").posts

    # unpublish clears memberships
    {:ok, _} = Content.unpublish_post(p)
    assert Content.posts_tagged("elixir").posts == []
    assert Content.posts_by_author(o["id"]).posts == []
    assert Content.get_published("hello-world") == nil
  end

  test "renaming the slug frees the old one", %{owner: o} do
    p = draft(o)
    {:ok, p} = Content.update_post(p, %{slug: "Brand New"})
    assert p["slug"] == "brand-new"
    assert Content.get_post_by_slug("hello-world") == nil
    assert Content.get_post_by_slug("brand-new")["id"] == p["id"]
  end

  test "feed order is newest published first and pages", %{owner: o} do
    for i <- 1..3 do
      p = draft(o, %{title: "Post #{i}"})
      {:ok, _} = Content.publish_post(p, DateTime.utc_now() |> DateTime.add(-100 + i, :second))
    end

    %{posts: page, next: next} = Content.list_posts("published", limit: 2)
    assert Enum.map(page, & &1["title"]) == ["Post 3", "Post 2"]
    %{posts: page2, next: nil} = Content.list_posts("published", limit: 2, cursor: next)
    assert Enum.map(page2, & &1["title"]) == ["Post 1"]
  end

  test "scheduling and publish_due", %{owner: o} do
    p = draft(o)
    {:ok, p} = Content.publish_post(p, DateTime.utc_now() |> DateTime.add(1, :hour))
    assert p["status"] == "scheduled"
    assert Content.publish_due() == 0

    {:ok, _} =
      Content.update_post(p, %{
        published_at: DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
      })

    assert Content.publish_due() == 1
    assert Content.get_post(p["id"])["status"] == "published"
  end

  test "revisions are kept per content change", %{owner: o} do
    p = draft(o)
    assert length(Content.revisions(p["id"])) == 1
    {:ok, p} = Content.update_post(p, %{featured: true})
    assert length(Content.revisions(p["id"])) == 1
    {:ok, p} = Content.update_post(p, %{markdown: "changed"})
    assert [%{"markdown" => "changed"}, %{"markdown" => "# Hi" <> _}] = Content.revisions(p["id"])
  end

  test "pages do not get tag/author memberships", %{owner: o} do
    p = draft(o, %{type: "page", tags: "about"})
    {:ok, _} = Content.publish_post(p)
    assert Content.posts_tagged("about").posts == []
    assert Content.list_posts("published", type: "post").posts == []
    assert length(Content.list_posts("published", type: "page").posts) == 1
  end

  test "delete removes everything", %{owner: o} do
    p = draft(o, %{tags: "a"})
    {:ok, p} = Content.publish_post(p)
    :ok = Content.delete_post(p)
    assert Content.get_post(p["id"]) == nil
    assert Content.get_post_by_slug("hello-world") == nil
    assert Content.posts_tagged("a").posts == []
    assert Content.revisions(p["id"]) == []
  end

  test "broadcasts", %{owner: o} do
    Content.subscribe()
    p = draft(o)
    assert_receive {:content, :created, %{"id" => id}}
    assert id == p["id"]
    {:ok, _} = Content.publish_post(p)
    assert_receive {:content, :updated, %{"status" => "published"}}
  end

  test "co-authors, related posts, toc, highlighting", %{owner: o} do
    {:ok, co} =
      Accounts.create_user(%{email: "c@x.io", name: "Co Author", password: "another long pw"})

    p =
      draft(o, %{
        authors: [co["id"]],
        tags: "a, b",
        markdown:
          "## One\n\ntext\n\n### Two\n\n```elixir\ndef x, do: 1\n```\n\n{{widget counter}}\n\n## Three"
      })

    assert p["authors"] == [o["id"], co["id"]]
    {:ok, p} = Content.publish_post(p)
    assert [%{"id" => id}] = Content.posts_by_author(co["id"]).posts
    assert id == p["id"]

    assert Wraith.Markdown.toc(p["markdown"]) == [
             %{"level" => 2, "text" => "One", "id" => "one"},
             %{"level" => 3, "text" => "Two", "id" => "two"},
             %{"level" => 2, "text" => "Three", "id" => "three"}
           ]

    html = Wraith.Markdown.to_html(p["markdown"])
    assert html =~ ~s(<h2 id="one">One)
    assert html =~ ~s(class="lumis")
    assert html =~ "language-elixir"

    other = draft(o, %{title: "Shares a tag", tags: "a"})
    {:ok, other} = Content.publish_post(other)
    unrelated = draft(o, %{title: "Nothing in common", tags: "zzz"})
    {:ok, unrelated} = Content.publish_post(unrelated)
    related = Content.related(p, 2) |> Enum.map(& &1["id"])
    assert hd(related) == other["id"]
    assert unrelated["id"] in related, "fills up with the newest"
    refute p["id"] in related
  end
end
