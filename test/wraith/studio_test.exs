defmodule Wraith.StudioTest do
  use Wraith.StoreCase, async: false
  alias Wraith.{Accounts, Content, Studio, Widgets}

  setup do
    # a clean server per test
    :ok = Studio.shutdown()
    :ok = Widgets.seed_builtins()

    {:ok, owner} =
      Accounts.setup_owner(%{email: "o@x.io", name: "Owner", password: "a very long password"})

    Studio.subscribe()
    %{owner: owner}
  end

  # state broadcasts pile up in the mailbox: drop the stale ones, prompt, then
  # wait for the turn to start and to end (the mailbox is ordered)
  defp run(text, owner) do
    flush()
    :ok = Studio.prompt(text, owner)

    receive do
      {:studio, :state, %{turn: %{}}} -> :ok
    after
      5_000 -> flunk("turn did not start")
    end

    receive do
      {:studio, :state, %{turn: nil}} -> :ok
    after
      5_000 -> flunk("turn did not end")
    end
  end

  defp flush do
    receive do
      {:studio, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  test "key management", %{} do
    refute Studio.key?()
    assert {:error, msg} = Studio.set_key("nope")
    assert msg =~ "ksk_"
    assert {:error, _} = Studio.set_key("ksk_" <> String.duplicate("a", 20) <> "dead")
    assert :ok = Studio.set_key("  KIRO_API_KEY=ksk_" <> String.duplicate("b", 24) <> " ")
    assert Studio.key?()
    assert Studio.key_hint() == "ksk_…bbbb"
    refute Wraith.Settings.get()["kiro_key_ciphertext"] =~ "ksk_"
  end

  test "wake needs a key", %{owner: owner} do
    assert {:error, msg} = Studio.wake(owner)
    assert msg =~ "Kiro API key"
    assert Studio.state().phase == :error
  end

  test "wake, prompt, replies stream, turn ends", %{owner: owner} do
    :ok = Studio.set_key("ksk_" <> String.duplicate("c", 24))
    assert {:ok, %{phase: :ready, vm: "fake-" <> _, bridge: true}} = Studio.wake(owner)
    run("hello there", owner)

    kinds = Studio.state().entries |> Enum.map(& &1["kind"])
    assert "user" in kinds and "agent" in kinds and "usage" in kinds
    agent = Studio.state().entries |> Enum.find(&(&1["kind"] == "agent"))
    assert agent["text"] == "Acknowledged: hello there"

    # persisted
    session = Studio.state().session
    assert Enum.any?(Studio.entries(session["id"]), &(&1["text"] == "hello there"))
  end

  test "the agent uses the tools over the bridge: a widget is written and saved", %{owner: owner} do
    :ok = Studio.set_key("ksk_" <> String.duplicate("c", 24))
    {:ok, _} = Studio.wake(owner)
    run("!widget applause", owner)

    tools = Studio.state().entries |> Enum.filter(&(&1["kind"] == "tool"))

    assert Enum.map(tools, & &1["tool"]) == [
             "@wraith/widget_docs",
             "@wraith/widget_test",
             "@wraith/widget_save"
           ]

    assert Enum.all?(tools, &(&1["status"] == "completed"))

    w = Widgets.get("applause")
    assert w["kind"] == "lua"
    assert w["rev"] == 1
    assert {:ok, html} = Widgets.render(w, "i", %{"label" => "bravo"}, %{"claps" => 3}, %{})
    assert html =~ "bravo"
    assert html =~ ">3<"
  end

  test "the agent drafts a post", %{owner: owner} do
    :ok = Studio.set_key("ksk_" <> String.duplicate("c", 24))
    {:ok, _} = Studio.wake(owner)
    run("!post Ghosts of Phoenix", owner)
    [post] = Content.list_all_posts()
    assert post["title"] == "Ghosts of Phoenix"
    assert post["author_id"] == owner["id"]
    assert post["status"] == "draft"
    assert post["tags"] == ["studio"]
  end

  test "permission requests are held until the owner decides", %{owner: owner} do
    :ok = Studio.set_key("ksk_" <> String.duplicate("c", 24))
    {:ok, _} = Studio.wake(owner)
    run("use a tool", owner)

    assert_received {:studio, :entry,
                     %{"kind" => "permission", "tool_call_id" => "tc_1", "options" => [_, _]}}

    # the fake's turn ended, so the hold expired with it
    perm = Studio.state().entries |> Enum.find(&(&1["kind"] == "permission"))
    assert perm["status"] in ["pending", "expired"]
  end

  test "a wrong bridge token is refused" do
    req = %{
      "method" => "POST",
      "path" => "/mcp/studio",
      "headers" => %{"authorization" => "Bearer nope"},
      "body" => "{}"
    }

    assert %{status: 403} = Wraith.Kiro.Bridge.handle(%{}, req)

    ok = %{
      "method" => "POST",
      "path" => "/mcp/studio",
      "headers" => Wraith.Kiro.Bridge.headers(),
      "body" => Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list"})
    }

    # a session with no acting user lists nothing; with one, the user's tools
    assert %{status: 200, body: body} = Wraith.Kiro.Bridge.handle(%{}, ok)
    assert body |> Jason.decode!() |> get_in(["result", "tools"]) == []

    owner = Wraith.Accounts.list_users() |> Enum.find(&(&1["role"] == "owner"))
    assert %{status: 200, body: body} = Wraith.Kiro.Bridge.handle(%{"user_id" => owner["id"]}, ok)
    names = body |> Jason.decode!() |> get_in(["result", "tools"]) |> Enum.map(& &1["name"])
    assert "widget_save" in names and "post_create" in names
  end

  test "new session resets the transcript; shutdown powers off", %{owner: owner} do
    :ok = Studio.set_key("ksk_" <> String.duplicate("c", 24))
    {:ok, _} = Studio.wake(owner)
    run("one", owner)
    {:ok, %{entries: entries}} = Studio.new_session(owner)
    assert entries == []
    assert length(Studio.sessions()) == 2
    :ok = Studio.shutdown()
    assert Studio.state().phase == :off
  end
end
