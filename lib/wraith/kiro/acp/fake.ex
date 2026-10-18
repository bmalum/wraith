defmodule Wraith.Kiro.ACP.Fake do
  @moduledoc """
  A scripted Kiro Agent Server (ported from shadow_corp's fake) with the
  function surface of `Wraith.Kiro.ACP`. Used by tests and by the dev
  studio when no MicroVM image is configured.

  A prompt streams `session/update` notifications to the owner and ends
  the turn with a 0.25-credit summary. The text steers the script:

    * `tool` — one tool call + a `session/request_permission`
    * `question` — a `_kiro/userInput` question
    * `fail` — a display error; `crash` — the connection drops
    * `!widget <slug>` — the agent reads `widget_docs`, then calls
      `widget_test` and `widget_save` over the bridge with a small clap
      widget (so the whole tool path is exercised offline)
    * `!post <title>` — the agent calls `post_create`
    * `!info` — the agent calls `site_info`
    * anything else — "Acknowledged: …" and the text echoed back

  Like KAS, sessions outlive connections: what was said is kept per session
  id in a public ETS table and `session/load` replays it.
  """
  @behaviour Wraith.Kiro.ACP.Client
  use GenServer

  @history :wraith_acp_fake_history

  @impl true
  def bridge_on_acp?, do: true

  @impl true
  def connect(url, opts \\ []),
    do: GenServer.start_link(__MODULE__, {Keyword.get(opts, :owner, self()), url})

  def request(conn, method, params, _timeout \\ 60_000),
    do: GenServer.call(conn, {:request, method, params}, 65_000)

  @impl true
  def respond(conn, id, result), do: GenServer.cast(conn, {:respond, id, result})
  @impl true
  def reject(_conn, _id, _code, _message), do: :ok
  @impl true
  def close(conn), do: GenServer.stop(conn, :normal)
  @impl true
  def initialize(conn), do: request(conn, "initialize", %{})
  @impl true
  def ensure_session(conn, sid, cwd, steering \\ [], extra \\ %{}),
    do:
      request(conn, "session/ensure", %{
        sessionId: sid,
        cwd: cwd,
        steering: steering,
        extra: extra
      })

  @impl true
  def load_session(conn, sid, cwd, opts \\ []),
    do: request(conn, "session/load", %{sessionId: sid, cwd: cwd, opts: Map.new(opts)})

  @impl true
  def close_session(conn, sid), do: request(conn, "session/close", %{sessionId: sid})
  @impl true
  def set_mode(conn, sid, mode),
    do: request(conn, "session/set_mode", %{sessionId: sid, modeId: mode})

  @impl true
  def prompt(conn, sid, text, _timeout \\ :infinity),
    do: request(conn, "session/prompt", %{sessionId: sid, text: text})

  @impl true
  def cancel(_conn, _sid), do: :ok
  @impl true
  def steer(conn, sid, message),
    do: request(conn, "_session/steer", %{sessionId: sid, message: message})

  @impl true
  def permit(conn, tc, option),
    do: request(conn, "_kiro/permission/respond", %{toolCallId: tc, optionId: option})

  @impl true
  def answer_question(conn, tc, answer),
    do: request(conn, "_kiro/userInput/respond", %{toolCallId: tc, answer: answer})

  @doc "Every `_kiro/permission/respond` this connection saw (tests)."
  def permits(conn), do: GenServer.call(conn, :permits)

  # ---- GenServer -------------------------------------------------------------------

  @impl true
  def init({owner, url}) do
    if :ets.whereis(@history) == :undefined do
      try do
        :ets.new(@history, [:named_table, :public, :bag])
      rescue
        ArgumentError -> :ok
      end
    end

    if String.ends_with?(url, "/bridge"),
      do:
        send(
          owner,
          {:acp, self(), {:notification, "bridge/hello", %{"kas_bundle" => "0.0.0-fake"}}}
        )

    {:ok, %{owner: owner, url: url, agents: %{}, permits: [], rid: 1000}}
  end

  @impl true
  def handle_call({:request, "initialize", _}, _from, state),
    do:
      {:reply,
       {:ok,
        %{"protocolVersion" => 1, "agentInfo" => %{"name" => "fake-kas", "version" => "0.0.0"}}},
       state}

  def handle_call({:request, "session/ensure", %{sessionId: id} = p}, _from, state) do
    extra = p[:extra] || %{}

    {:reply,
     {:ok, %{"sessionId" => id, "modes" => %{"currentModeId" => extra[:modeId] || "vibe"}}},
     put_in(state, [:agents, id], extra)}
  end

  def handle_call({:request, "session/load", %{sessionId: id}}, _from, state) do
    for {kind, text} <- history(id) do
      replay = %{"kiro" => %{"replay" => true}}

      update(state, id, %{
        "sessionUpdate" =>
          if(kind == :user, do: "user_message_chunk", else: "agent_message_chunk"),
        "content" => %{"type" => "text", "text" => text},
        "_meta" => replay
      })

      if kind == :agent,
        do:
          update(state, id, %{
            "sessionUpdate" => "session_info_update",
            "_meta" => %{
              "kiro" => %{
                "replay" => true,
                "promptTurnSummaries" => [%{"unit" => "credit", "usage" => 0.25}]
              }
            }
          })
    end

    {:reply, {:ok, %{}}, state}
  end

  def handle_call({:request, "session/close", _}, _from, state), do: {:reply, {:ok, %{}}, state}

  def handle_call({:request, "session/set_mode", _}, _from, state),
    do: {:reply, {:ok, %{}}, state}

  def handle_call({:request, "_session/steer", _}, _from, state),
    do: {:reply, {:ok, %{"queued" => true}}, state}

  def handle_call({:request, "_kiro/userInput/respond", _}, _from, state),
    do: {:reply, {:ok, %{}}, state}

  def handle_call(
        {:request, "_kiro/permission/respond", %{toolCallId: tc, optionId: o}},
        _from,
        state
      ),
      do: {:reply, {:ok, %{}}, %{state | permits: state.permits ++ [{tc, o}]}}

  def handle_call(:permits, _from, state), do: {:reply, state.permits, state}

  def handle_call({:request, "session/prompt", %{sessionId: sid, text: text}}, _from, state) do
    cond do
      String.contains?(text, "crash") ->
        send(state.owner, {:acp, self(), {:closed, :remote}})
        {:stop, :normal, {:error, :closed}, state}

      true ->
        remember(sid, :user, text)
        state = script(state, sid, text)

        update(state, sid, %{
          "sessionUpdate" => "session_info_update",
          "_meta" => %{
            "kiro" => %{
              "promptTurnSummaries" => [
                %{"unit" => "credit", "unitPlural" => "credits", "usage" => 0.25}
              ],
              "elapsedTime" => 1200,
              "status" => "success"
            }
          }
        })

        {:reply, {:ok, %{"stopReason" => "end_turn"}}, state}
    end
  end

  def handle_call({:request, method, _}, _from, state),
    do: {:reply, {:error, %{"code" => -32601, "message" => "fake: #{method}"}}, state}

  @impl true
  def handle_cast({:respond, _id, _result}, state), do: {:noreply, state}

  # ---- the script ----------------------------------------------------------------

  defp script(state, sid, text) do
    if String.contains?(text, "fail"),
      do:
        update(state, sid, %{
          "sessionUpdate" => "session_info_update",
          "_meta" => %{
            "kiro" => %{
              "displayError" => %{"message" => "Kiro could not load the available models."}
            }
          }
        })

    if String.contains?(text, "question") do
      send(
        state.owner,
        {:acp, self(),
         {:request, next_id(state), "_kiro/userInput",
          %{
            "sessionId" => sid,
            "toolCallId" => "q_1",
            "question" => "Publish it now or keep it as a draft?",
            "options" => [%{"title" => "Publish", "recommended" => true}, %{"title" => "Draft"}]
          }}}
      )
    end

    cond do
      String.contains?(text, "tool") ->
        chunk(state, sid, "Let me read that file first.")

        update(state, sid, %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "tc_1",
          "title" => "Read File",
          "kind" => "read",
          "status" => "pending",
          "rawInput" => %{"path" => "/work/README.md"}
        })

        send(
          state.owner,
          {:acp, self(),
           {:request, next_id(state), "session/request_permission",
            %{
              "sessionId" => sid,
              "toolCall" => %{"toolCallId" => "tc_1", "title" => "Read File"},
              "options" => [
                %{"optionId" => "allow", "name" => "Allow", "kind" => "allow_once"},
                %{"optionId" => "reject", "name" => "Deny", "kind" => "reject_once"}
              ]
            }}}
        )

        update(state, sid, %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "tc_1",
          "status" => "completed"
        })

        remember(sid, :agent, "Read the file.")

      String.contains?(text, "!info") ->
        {status, out} = tool(state, sid, "site_info", %{})

        chunk(
          state,
          sid,
          if(status == "completed",
            do: "Here is the site:\n\n```json\n#{String.slice(out, 0, 600)}\n```",
            else: "site_info failed: #{out}"
          )
        )

        remember(sid, :agent, "Looked up the site.")

      String.contains?(text, "!post") ->
        title =
          text
          |> String.split("!post", parts: 2)
          |> List.last()
          |> String.trim()
          |> then(&if(&1 == "", do: "A post from the studio", else: &1))

        {status, out} =
          tool(state, sid, "post_create", %{
            "title" => title,
            "markdown" =>
              "Written by the studio agent.\n\n{{widget counter label=\"Readers who agree\"}}",
            "tags" => "studio"
          })

        chunk(
          state,
          sid,
          if(status == "completed",
            do: "Drafted **#{title}**. Open it in the editor to publish.",
            else: "Could not create the post: #{out}"
          )
        )

        remember(sid, :agent, "Drafted #{title}.")

      String.contains?(text, "!widget") ->
        slug =
          text
          |> String.split("!widget", parts: 2)
          |> List.last()
          |> String.trim()
          |> then(&if(&1 == "", do: "clap", else: &1))
          |> Wraith.Slug.slugify()

        chunk(state, sid, "I'll write a **#{slug}** widget. Reading the docs first…\n\n")
        tool(state, sid, "widget_docs", %{})
        source = clap_source(slug)

        {s1, _} =
          tool(state, sid, "widget_test", %{
            "source" => source,
            "props" => %{"label" => "claps"},
            "events" => [%{"event" => "clap", "visitor" => "a"}]
          })

        if s1 == "completed" do
          {s2, out} =
            tool(state, sid, "widget_save", %{
              "slug" => slug,
              "name" => String.capitalize(slug),
              "description" => "Readers clap for the post.",
              "source" => source
            })

          chunk(
            state,
            sid,
            if(s2 == "completed",
              do: "Saved. Embed it with `{{widget #{slug}}}` on its own line.",
              else: "Saving failed: #{out}"
            )
          )
        else
          chunk(state, sid, "The test failed, so I did not save it.")
        end

        remember(sid, :agent, "Wrote the #{slug} widget.")

      true ->
        chunk(state, sid, "Acknowledged: ")
        chunk(state, sid, text)
        remember(sid, :agent, "Acknowledged: " <> text)
    end

    state
  end

  defp clap_source(slug) do
    """
    -- name: #{String.capitalize(slug)}
    -- description: Readers clap for the post.
    function init(props) return { claps = 0 } end
    function render(state, props, meta)
      return '<div class="w-counter"><button class="w-btn" ' .. wraith.action("clap") .. '>👏</button>'
        .. '<span class="w-counter-value">' .. wraith.format(state.claps) .. '</span>'
        .. '<span class="w-counter-label">' .. wraith.escape(props.label or "claps") .. '</span></div>'
    end
    function handle(state, event, payload, meta)
      if event == "clap" then state.claps = state.claps + 1 end
      return state
    end
    """
  end

  # a tool call over the bridge: exactly what the shim sends for KAS's MCP call
  defp tool(state, sid, name, args) do
    %{"mcpServers" => servers} =
      stringify(get_in(state, [:agents, sid, :customAgents]) |> List.wrap() |> List.first()) ||
        %{"mcpServers" => %{}}

    case Map.to_list(servers) do
      [{server, %{"url" => url} = cfg}] ->
        tc = "tc_#{name}_#{System.unique_integer([:positive])}"

        update(state, sid, %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => tc,
          "title" => "@#{server}/#{name}",
          "kind" => "other",
          "status" => "pending",
          "rawInput" => %{"tool_id" => "#{server}::#{name}", "arguments" => args},
          "_meta" => %{"kiro" => %{"serverName" => server}}
        })

        rid = next_id(state)

        body =
          Jason.encode!(%{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{name: name, arguments: args}
          })

        send(
          state.owner,
          {:acp, self(),
           {:request, rid, "bridge/http",
            %{
              "method" => "POST",
              "path" => URI.parse(url).path,
              "headers" =>
                Map.merge(%{"content-type" => "application/json"}, cfg["headers"] || %{}),
              "body" => body
            }}}
        )

        output =
          receive do
            {:"$gen_cast", {:respond, ^rid, %{"body" => b}}} -> b
            {:"$gen_cast", {:respond, ^rid, %{body: b}}} -> b
          after
            5_000 -> nil
          end

        {status, blocks} =
          case output && Jason.decode(output) do
            {:ok, %{"result" => %{"isError" => true, "content" => c}}} -> {"failed", c}
            {:ok, %{"result" => %{"content" => c}}} when is_list(c) -> {"completed", c}
            _ -> {"failed", [%{"type" => "text", "text" => output || "no reply"}]}
          end

        update(state, sid, %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => tc,
          "status" => status,
          "content" => Enum.map(blocks, &%{"type" => "content", "content" => &1})
        })

        {status, blocks |> Enum.map(& &1["text"]) |> Enum.join("\n")}

      _ ->
        chunk(state, sid, "(no tool server in this session)")
        {"failed", "no server"}
    end
  end

  defp stringify(nil), do: nil
  defp stringify(map), do: map |> Jason.encode!() |> Jason.decode!()

  defp next_id(_state), do: System.unique_integer([:positive])

  defp chunk(state, sid, text),
    do:
      update(state, sid, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      })

  defp update(state, sid, u),
    do:
      send(
        state.owner,
        {:acp, self(), {:notification, "session/update", %{"sessionId" => sid, "update" => u}}}
      )

  defp remember(sid, kind, text),
    do: :ets.insert(@history, {sid, System.unique_integer([:monotonic]), kind, text})

  defp history(sid),
    do:
      @history
      |> :ets.lookup(sid)
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.map(fn {_, _, k, t} -> {k, t} end)
end
