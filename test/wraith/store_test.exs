defmodule Wraith.StoreTest do
  use Wraith.StoreCase, async: false

  test "put, get, delete" do
    assert :ok = Store.put(%{"pk" => "A", "sk" => "1", "x" => 1})

    assert {:ok, %{"x" => 1, "version" => 1, "created_at" => c, "updated_at" => c}} =
             Store.get("A", "1")

    assert :ok = Store.delete("A", "1")
    assert :error = Store.get("A", "1")
  end

  test "stamps bump version and keep created_at" do
    :ok = Store.put(%{"pk" => "A", "sk" => "1"})
    {:ok, first} = Store.get("A", "1")
    :ok = Store.put(first)
    {:ok, second} = Store.get("A", "1")
    assert second["version"] == 2
    assert second["created_at"] == first["created_at"]
  end

  test "condition: not_exists is the uniqueness primitive" do
    assert :ok = Store.put(%{"pk" => "SLUG#hi", "sk" => "POST"}, condition: :not_exists)

    assert {:error, :exists} =
             Store.put(%{"pk" => "SLUG#hi", "sk" => "POST"}, condition: :not_exists)
  end

  test "condition: version detects a concurrent writer" do
    :ok = Store.put(%{"pk" => "A", "sk" => "1"})
    {:ok, item} = Store.get("A", "1")
    assert :ok = Store.put(item, condition: {:version, 1})
    assert {:error, :conflict} = Store.put(item, condition: {:version, 1})
  end

  test "update retries read-modify-write" do
    {:ok, %{"n" => 1}} = Store.update("C", "x", fn nil -> %{"n" => 1} end)
    {:ok, %{"n" => 2}} = Store.update("C", "x", fn %{"n" => n} = i -> %{i | "n" => n + 1} end)
    assert {:ok, %{"n" => 2, "version" => 2}} = Store.get("C", "x")
  end

  test "query by partition, prefix, order, pages" do
    for i <- 1..5, do: :ok = Store.put(%{"pk" => "P", "sk" => "REV#0#{i}", "i" => i})
    :ok = Store.put(%{"pk" => "P", "sk" => "POST", "i" => 0})

    {:ok, %{items: items, next: nil}} = Store.query("P", begins_with: "REV#")
    assert Enum.map(items, & &1["i"]) == [1, 2, 3, 4, 5]

    {:ok, %{items: items, next: next}} =
      Store.query("P", begins_with: "REV#", forward: false, limit: 2)

    assert Enum.map(items, & &1["i"]) == [5, 4]
    assert next

    {:ok, %{items: items, next: next}} =
      Store.query("P", begins_with: "REV#", forward: false, limit: 2, start_key: next)

    assert Enum.map(items, & &1["i"]) == [3, 2]

    {:ok, %{items: items, next: nil}} =
      Store.query("P", begins_with: "REV#", forward: false, limit: 2, start_key: next)

    assert Enum.map(items, & &1["i"]) == [1]

    assert Store.all("P", begins_with: "REV#", limit: 2) |> length() == 5
  end

  test "gsi1 query and index maintenance on overwrite/delete" do
    :ok =
      Store.put(%{"pk" => "POST#1", "sk" => "POST", "gsi1pk" => "POSTS#draft", "gsi1sk" => "a"})

    :ok =
      Store.put(%{"pk" => "POST#2", "sk" => "POST", "gsi1pk" => "POSTS#draft", "gsi1sk" => "b"})

    {:ok, %{items: items}} = Store.query("POSTS#draft", index: :gsi1)
    assert Enum.map(items, & &1["pk"]) == ["POST#1", "POST#2"]

    # moving to another index partition removes it from the old one
    :ok =
      Store.put(%{
        "pk" => "POST#1",
        "sk" => "POST",
        "gsi1pk" => "POSTS#published",
        "gsi1sk" => "a"
      })

    {:ok, %{items: [%{"pk" => "POST#2"}]}} = Store.query("POSTS#draft", index: :gsi1)
    {:ok, %{items: [%{"pk" => "POST#1"}]}} = Store.query("POSTS#published", index: :gsi1)

    :ok = Store.delete("POST#2", "POST")
    {:ok, %{items: []}} = Store.query("POSTS#draft", index: :gsi1)
  end

  test "transact is all or nothing" do
    :ok = Store.put(%{"pk" => "SLUG#taken", "sk" => "POST"})

    assert {:error, :exists} =
             Store.transact([
               {:put, %{"pk" => "POST#9", "sk" => "POST"}},
               {:put, %{"pk" => "SLUG#taken", "sk" => "POST"}, condition: :not_exists}
             ])

    assert :error = Store.get("POST#9", "POST")

    assert :ok =
             Store.transact([
               {:put, %{"pk" => "POST#9", "sk" => "POST"}},
               {:put, %{"pk" => "SLUG#free", "sk" => "POST"}, condition: :not_exists},
               {:delete, "SLUG#taken", "POST"}
             ])

    assert {:ok, _} = Store.get("POST#9", "POST")
    assert :error = Store.get("SLUG#taken", "POST")
  end

  test "batch_get skips missing keys" do
    :ok = Store.put(%{"pk" => "A", "sk" => "1"})
    assert {:ok, [%{"pk" => "A"}]} = Store.batch_get([{"A", "1"}, {"A", "2"}])
  end

  test "ids are uuid v7, time-ordered" do
    a = Store.id()
    b = Store.id()

    assert Regex.match?(
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
             a
           )

    assert a < b
  end
end
