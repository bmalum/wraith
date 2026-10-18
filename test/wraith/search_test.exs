defmodule Wraith.SearchTest do
  use Wraith.StoreCase, async: false
  alias Wraith.{Accounts, Content, Search}

  setup do
    {:ok, o} =
      Accounts.create_user(%{email: "o@x.io", name: "O", password: "a very long password"})

    :ok = Search.rebuild()
    %{owner: o}
  end

  defp publish(o, title, md, tags \\ "") do
    {:ok, p} = Content.create_post(%{title: title, markdown: md, author_id: o["id"], tags: tags})
    {:ok, p} = Content.publish_post(p)
    # the index follows the content broadcast; sync with the server
    _ = :sys.get_state(Search)
    p
  end

  test "indexes published posts, ranks titles over bodies, prefix on the last word", %{owner: o} do
    a = publish(o, "Elixir processes", "Notes on the BEAM scheduler.", "elixir")
    b = publish(o, "Cooking rice", "Elixir is also a word in alchemy; processes of distillation.")

    {:ok, draft} =
      Content.create_post(%{title: "Elixir draft", markdown: "unpublished", author_id: o["id"]})

    _ = :sys.get_state(Search)

    assert [%{post: %{"id" => id1}}, %{post: %{"id" => id2}}] = Search.search("elixir")
    assert {id1, id2} == {a["id"], b["id"]}
    refute Search.search("elixir") |> Enum.any?(&(&1.post["id"] == draft["id"]))

    assert [%{post: %{"id" => id}}] = Search.search("beam sched")
    assert id == a["id"]
    assert [%{snippet: snippet}] = Search.search("distillation")
    assert snippet =~ "distillation"
    assert Search.search("nothing-here") == []
    assert Search.search("") == []

    # unpublishing and deleting drop a post
    {:ok, _} = Content.unpublish_post(a)
    _ = :sys.get_state(Search)
    assert [%{post: %{"id" => ^id2}}] = Search.search("elixir")
    :ok = Content.delete_post(b)
    _ = :sys.get_state(Search)
    assert Search.search("elixir") == []
  end
end
