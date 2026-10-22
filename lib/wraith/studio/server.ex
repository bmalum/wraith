defmodule Wraith.Studio.Server do
  @moduledoc """
  The one process behind the studio (ported in spirit from shadow_corp's
  `Safehouses.Server`, cut down to one conversation):

    1. `wake/1` — start (or re-use) the VM through `Wraith.Kiro.Runtime`,
       open the ACP WebSocket, `initialize`, dial the bridge, then
       `ensure_session` + `set_mode` for the custom agent, `load_session`
       to replay history.
    2. `prompt/2` — one turn at a time; `session/update` notifications
       become transcript entries (`Wraith.Studio.Transcript`) broadcast to
       the LiveView and persisted.
    3. Agent→client requests: `session/request_permission` is held in
       `pending` until the owner decides (`permit/2`); `_kiro/userInput`
       likewise (`answer/2`); `bridge/http` is answered at once by
       `Wraith.Kiro.Bridge.handle/2` with `Wraith.Studio.Tools`.

  State phases: `:off` (no VM), `:booting`, `:ready`, `:error`.
  """
  use GenServer
  require Logger

  alias Wraith.{Settings, Studio}
  alias Wraith.Kiro.{Bridge, Runtime}
  alias Wraith.Studio.Transcript

  @cwd "/work"
  @turn_timeout_ms 30 * 60_000
  @idle_terminate_ms 3 * 60 * 60_000

  defstruct phase: :off,
            vm: nil,
            acp: nil,
            bridge: nil,
            session: nil,
            kas_session_id: nil,
            entries: [],
            seq: 0,
            turn: nil,
            pending: %{},
            user: nil,
            error: nil,
            idle_timer: nil

  # One studio per cluster: the name is registered with `:global`, so the second
  # node to boot finds it taken and runs no server of its own (calls go to the
  # owner over distribution). If the owning node dies, the next call on any
  # node starts a fresh one there and reopens the conversation from the store.
  @name {:global, __MODULE__}

  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: @name) do
      {:error, {:already_started, _pid}} -> :ignore
      other -> other
    end
  end

  defp server do
    case :global.whereis_name(__MODULE__) do
      :undefined ->
        case GenServer.start(__MODULE__, [], name: @name) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  def state, do: GenServer.call(server(), :state)
  def wake(user), do: GenServer.call(server(), {:wake, user}, 120_000)
  def prompt(text, user), do: GenServer.call(server(), {:prompt, text, user}, 10_000)
  def cancel, do: GenServer.cast(server(), :cancel)

  def permit(tool_call_id, option_id),
    do: GenServer.call(server(), {:permit, tool_call_id, option_id})

  def answer(tool_call_id, answer), do: GenServer.call(server(), {:answer, tool_call_id, answer})
  def new_session(user), do: GenServer.call(server(), {:new_session, user}, 120_000)
  def shutdown, do: GenServer.call(server(), :shutdown, 60_000)

  defp acp, do: Application.get_env(:wraith, :acp_client, Wraith.Kiro.ACP.Fake)

  # ---- GenServer -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, public(state), state}

  def handle_call({:wake, user}, _from, %{phase: :ready} = state) do
    {:reply, {:ok, public(state)}, state |> assign_user(user) |> touch()}
  end

  def handle_call({:wake, user}, _from, state) do
    state = state |> assign_user(user) |> boot()

    reply =
      if state.phase == :ready,
        do: {:ok, public(state)},
        else: {:error, state.error || "could not start"}

    {:reply, reply, touch(state)}
  end

  def handle_call({:prompt, text, user}, _from, state) do
    state = assign_user(state, user)

    cond do
      state.phase != :ready ->
        {:reply, {:error, "the studio is #{state.phase}; wake it first"}, state}

      state.turn ->
        {:reply, {:error, "a turn is already running"}, state}

      String.trim(text) == "" ->
        {:reply, {:error, "say something"}, state}

      true ->
        state = state |> add(Transcript.new_entry("user", text)) |> start_turn(text)
        {:reply, :ok, touch(state)}
    end
  end

  def handle_call({:permit, tc, option}, _from, state) do
    case Map.pop(state.pending, tc) do
      {nil, _} ->
        {:reply, {:error, :unknown}, state}

      {%{kind: :permission} = p, pending} ->
        acp().permit(state.acp, tc, option)
        # KAS also expects the request itself answered
        acp().respond(state.acp, p.id, %{outcome: %{outcome: "selected", optionId: option}})

        state =
          update_entry(
            state,
            p.entry_id,
            &Map.merge(&1, %{"status" => "answered", "decision" => option})
          )

        {:reply, :ok, %{state | pending: pending} |> publish_state()}
    end
  end

  def handle_call({:answer, tc, answer}, _from, state) do
    case Map.pop(state.pending, tc) do
      {%{kind: :question} = p, pending} ->
        acp().answer_question(state.acp, tc, answer)
        acp().respond(state.acp, p.id, %{answer: answer})

        state =
          update_entry(
            state,
            p.entry_id,
            &Map.merge(&1, %{"status" => "answered", "decision" => answer || "dismissed"})
          )

        {:reply, :ok, %{state | pending: pending} |> publish_state()}

      _ ->
        {:reply, {:error, :unknown}, state}
    end
  end

  def handle_call({:new_session, user}, _from, state) do
    state = assign_user(state, user)
    if state.kas_session_id && state.acp, do: acp().close_session(state.acp, state.kas_session_id)
    if state.session, do: Studio.close_session_row(state.session)
    session = Studio.create_session(user["id"])

    state = %{
      state
      | session: session,
        kas_session_id: nil,
        entries: [],
        seq: 0,
        turn: nil,
        pending: %{}
    }

    state = if state.phase == :ready, do: open_session(state), else: state
    Studio.broadcast({:studio, :entries, state.entries})
    {:reply, {:ok, public(state)}, publish_state(state)}
  end

  def handle_call(:shutdown, _from, state) do
    _ = teardown(state)
    # a full reset: the next wake starts from the store, not from this process's memory
    Studio.broadcast({:studio, :entries, []})
    {:reply, :ok, publish_state(%__MODULE__{})}
  end

  @impl true
  def handle_cast(:cancel, %{turn: nil} = state), do: {:noreply, state}

  def handle_cast(:cancel, state) do
    acp().cancel(state.acp, state.kas_session_id)
    {:noreply, state}
  end

  # ---- the agent speaks -------------------------------------------------------

  @impl true
  def handle_info(
        {:acp, conn, {:notification, "session/update", %{"update" => update}}},
        %{acp: conn} = state
      ) do
    {:noreply, apply_update(state, update)}
  end

  def handle_info(
        {:acp, conn, {:notification, "_kiro/error/rate_limit", p}},
        %{acp: conn} = state
      ) do
    {:noreply,
     add(
       state,
       Transcript.new_entry("status", "Kiro is rate-limited: " <> to_string(p["message"]), %{
         "level" => "error"
       })
     )}
  end

  def handle_info({:acp, conn, {:notification, "bridge/hello", %{"kas_bundle" => bundle}}}, state)
      when conn != state.acp do
    {:noreply,
     add(
       state,
       Transcript.new_entry("status", "Bridge open · KAS " <> hd(String.split(bundle, "-")))
     )}
  end

  def handle_info({:acp, _conn, {:notification, _method, _params}}, state), do: {:noreply, state}

  # a tool wants permission: hold it for the owner
  def handle_info(
        {:acp, conn, {:request, id, "session/request_permission", params}},
        %{acp: conn} = state
      ) do
    tool = params["toolCall"] || %{}
    tc = tool["toolCallId"]
    options = Enum.map(params["options"] || [], &Map.take(&1, ["optionId", "name", "kind"]))

    entry =
      Transcript.new_entry("permission", "", %{
        "tool_call_id" => tc,
        "tool" => tool["title"] || "a tool",
        "options" => options,
        "status" => "pending",
        "input" => get_in(params, ["_meta", "kiro", "command"]) || tool["rawInput"]
      })

    state = add(state, entry)
    pending = Map.put(state.pending, tc, %{kind: :permission, id: id, entry_id: entry["id"]})
    {:noreply, %{state | pending: pending} |> publish_state()}
  end

  def handle_info({:acp, conn, {:request, id, "_kiro/userInput", params}}, %{acp: conn} = state) do
    tc = params["toolCallId"]

    options =
      Enum.map(params["options"] || [], &Map.take(&1, ["title", "description", "recommended"]))

    entry =
      Transcript.new_entry("question", params["question"] || "", %{
        "tool_call_id" => tc,
        "options" => options,
        "status" => "pending"
      })

    state = add(state, entry)

    {:noreply,
     %{
       state
       | pending: Map.put(state.pending, tc, %{kind: :question, id: id, entry_id: entry["id"]})
     }
     |> publish_state()}
  end

  # MCP over the bridge (the fake relays on the ACP channel)
  def handle_info({:acp, conn, {:request, id, "bridge/http", params}}, state)
      when conn == state.bridge or (conn == state.acp and conn != nil) do
    if conn == state.bridge or acp().bridge_on_acp?() do
      # tools act as the person who is prompting right now, not whoever
      # happened to create the session record
      session = Map.put(state.session, "user_id", state.user && state.user["id"])
      reply = Bridge.handle(session, params)
      acp().respond(conn, id, reply)
    else
      acp().reject(conn, id, -32601, "bridge requests belong on the bridge")
    end

    {:noreply, state}
  end

  def handle_info({:acp, conn, {:request, id, method, _params}}, state) do
    acp().reject(conn, id, -32601, "unsupported: #{method}")
    {:noreply, state}
  end

  def handle_info({:acp, conn, {:closed, reason}}, %{acp: conn} = state) do
    state =
      state
      |> finish_turn({:error, "connection closed"})
      |> add(
        Transcript.new_entry(
          "status",
          "Agent connection closed (#{inspect(reason)}). Wake the studio to reconnect.",
          %{"level" => "error"}
        )
      )

    {:noreply, %{state | acp: nil, bridge: nil, phase: :off} |> publish_state()}
  end

  def handle_info({:acp, conn, {:closed, _reason}}, %{bridge: conn} = state) do
    {:noreply,
     %{state | bridge: nil}
     |> add(
       Transcript.new_entry("status", "Bridge dropped; tools are offline until the next wake.", %{
         "level" => "warn"
       })
     )}
  end

  def handle_info({:acp, _conn, _event}, state), do: {:noreply, state}

  # the prompt task ended
  def handle_info({ref, result}, %{turn: %{ref: ref}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_turn(state, result) |> touch()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{turn: %{ref: ref}} = state) do
    {:noreply, finish_turn(state, {:error, inspect(reason)})}
  end

  def handle_info(:idle_terminate, state) do
    Logger.info("studio: idle, terminating the VM")
    {:noreply, teardown(state) |> publish_state()}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.vm, do: Runtime.checkpoint(state.vm.id, state.vm.endpoint)
    :ok
  end

  # ---- boot -------------------------------------------------------------------------

  defp boot(state) do
    state = %{state | phase: :booting, error: nil} |> publish_state()
    key = Studio.key()

    with true <- not is_nil(key) || {:error, "no Kiro API key — add one in the studio settings"},
         {:ok, vm} <- ensure_vm(state, key),
         state = %{state | vm: vm} |> add(Transcript.new_entry("status", "VM #{vm.id} running")),
         {:ok, attach} <- wait_attach(vm, 60),
         {:ok, acp_conn} <- acp().connect(attach.url, protocols: attach.protocols, owner: self()),
         {:ok, _} <- acp().initialize(acp_conn) do
      state = %{state | acp: acp_conn} |> add(Transcript.new_entry("status", "Agent server up"))
      state = dial_bridge(state)
      state = %{state | session: state.session || Studio.current_session(state.user["id"])}
      state = open_session(%{state | phase: :ready})
      Studio.broadcast({:studio, :entries, state.entries})
      publish_state(state)
    else
      {:error, reason} ->
        why = if(is_binary(reason), do: reason, else: inspect(reason))
        Logger.warning("studio boot: #{why}")

        %{state | phase: :error, error: why}
        |> add(Transcript.new_entry("status", "Could not start: " <> why, %{"level" => "error"}))
        |> publish_state()
    end
  end

  defp ensure_vm(%{vm: %{id: id} = vm}, key) do
    case Runtime.status(id) do
      {:ok, :running} ->
        {:ok, vm}

      {:ok, :suspended} ->
        Runtime.resume(id)
        {:ok, vm}

      _ ->
        start_vm(key)
    end
  end

  defp ensure_vm(_state, key), do: start_vm(key)

  defp start_vm(key) do
    payload = %{
      company_id: "wraith",
      company: "Wraith studio",
      kiro_api_key: key,
      bridge_key: bridge_key(),
      journal_prefix: "wraith/studio"
    }

    Runtime.start(payload)
  end

  # the key the shim binds its /bridge to; stable per node, never persisted
  defp bridge_key do
    case :persistent_term.get({__MODULE__, :bridge_key}, nil) do
      nil ->
        k = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
        :persistent_term.put({__MODULE__, :bridge_key}, k)
        k

      k ->
        k
    end
  end

  # a fresh VM takes a moment before KAS answers on :8082
  defp wait_attach(vm, attempts) do
    case Runtime.attach(vm.id, vm.endpoint) do
      {:ok, attach} ->
        case probe(attach) do
          :ok ->
            {:ok, attach}

          :retry when attempts > 0 ->
            Process.sleep(2_000)
            wait_attach(vm, attempts - 1)

          :retry ->
            {:error, "the agent server did not come up"}
        end

      error ->
        error
    end
  end

  # the real client fails fast on a refused upgrade; the fake always connects
  defp probe(%{url: "fake://" <> _}), do: :ok

  defp probe(attach) do
    case acp().connect(attach.url, protocols: attach.protocols, owner: self(), timeout: 10_000) do
      {:ok, conn} ->
        acp().close(conn)
        :ok

      {:error, _} ->
        :retry
    end
  end

  defp dial_bridge(state) do
    case Runtime.attach_bridge(state.vm.id, state.vm.endpoint, key: bridge_key()) do
      {:ok, attach} ->
        case acp().connect(attach.url, protocols: attach.protocols, owner: self()) do
          {:ok, conn} ->
            %{state | bridge: conn}

          {:error, why} ->
            add(
              state,
              Transcript.new_entry(
                "status",
                "Bridge dial failed: #{inspect(why)} — tools offline",
                %{"level" => "warn"}
              )
            )
        end

      {:error, why} ->
        add(
          state,
          Transcript.new_entry("status", "Bridge unavailable: #{inspect(why)}", %{
            "level" => "warn"
          })
        )
    end
  end

  defp open_session(state) do
    site = Settings.get()
    sid = "wraith-studio-" <> state.session["id"]
    agent = Studio.agent(site)

    with {:ok, _} <-
           acp().ensure_session(state.acp, sid, @cwd, Studio.steering(site), %{
             customAgents: [agent],
             modeId: agent.id
           }),
         {:ok, _} <- acp().set_mode(state.acp, sid, agent.id) do
      persisted = Studio.entries(state.session["id"])
      # what we have on record first, then this boot's own status lines
      state = %{
        state
        | kas_session_id: sid,
          entries: persisted ++ state.entries,
          seq: length(persisted)
      }

      # replay only when nothing is persisted (a fresh node); otherwise our copy is the record
      if persisted == [], do: replay(state, sid), else: state
    else
      {:error, why} ->
        %{state | phase: :error, error: inspect(why)}
        |> add(
          Transcript.new_entry("status", "Could not open the session: #{inspect(why)}", %{
            "level" => "error"
          })
        )
    end
  end

  defp replay(state, sid) do
    case acp().load_session(state.acp, sid, @cwd, replay_limit: 40) do
      {:ok, _} -> drain_replay(state)
      {:error, _} -> state
    end
  end

  # replayed updates arrive as notifications; fold the ones already in the mailbox
  defp drain_replay(state) do
    receive do
      {:acp, conn, {:notification, "session/update", %{"update" => u}}} when conn == state.acp ->
        drain_replay(apply_update(state, u, persist: false))
    after
      300 -> state
    end
  end

  # ---- turns --------------------------------------------------------------------------

  defp start_turn(state, text) do
    conn = state.acp
    sid = state.kas_session_id
    client = acp()
    task = Task.async(fn -> client.prompt(conn, sid, text, @turn_timeout_ms) end)

    %{state | turn: %{ref: task.ref, started_at: System.monotonic_time(:millisecond), text: text}}
    |> publish_state()
  end

  defp finish_turn(%{turn: nil} = state, _result), do: state

  defp finish_turn(state, result) do
    state = %{state | turn: nil, entries: Transcript.close_open(state.entries)}

    state =
      case result do
        {:ok, _} ->
          state

        {:error, %{"message" => m}} ->
          add(state, Transcript.new_entry("status", "Turn failed: " <> m, %{"level" => "error"}))

        {:error, why} ->
          add(
            state,
            Transcript.new_entry("status", "Turn failed: " <> inspect(why), %{"level" => "error"})
          )
      end

    # anything still pending from a turn that died is moot
    state =
      Enum.reduce(state.pending, state, fn {_tc, p}, s ->
        update_entry(s, p.entry_id, &Map.put(&1, "status", "expired"))
      end)

    if state.session,
      do: Studio.update_session(state.session, &Map.update(&1, "turns", 1, fn n -> n + 1 end))

    %{state | pending: %{}} |> persist_all() |> publish_state()
  end

  defp apply_update(state, update, opts \\ []) do
    before = state.entries
    entries = Transcript.apply(before, update)
    state = %{state | entries: entries}

    # tell listeners about the entry that changed (the last one, or the tool whose update it was)
    changed =
      case update do
        %{"sessionUpdate" => "tool_call_update", "toolCallId" => tc} ->
          Enum.find(entries, &(&1["tool_call_id"] == tc))

        _ ->
          List.last(entries)
      end

    if changed && entries != before, do: Studio.broadcast({:studio, :entry, changed})

    if Keyword.get(opts, :persist, true) and
         match?(%{"sessionUpdate" => "session_info_update"}, update),
       do: persist_all(state),
       else: state
  end

  defp add(state, entry) do
    state = %{state | entries: Transcript.close_open(state.entries) ++ [entry]}
    Studio.broadcast({:studio, :entry, entry})
    persist_entry(state, entry)
  end

  defp update_entry(state, entry_id, fun) do
    case Enum.find_index(state.entries, &(&1["id"] == entry_id)) do
      nil ->
        state

      i ->
        entries = List.update_at(state.entries, i, fun)
        Studio.broadcast({:studio, :entry, Enum.at(entries, i)})
        %{state | entries: entries}
    end
  end

  # the transcript is persisted whole at the end of a turn (cheap: one item per entry, keyed by position)
  defp persist_all(%{session: nil} = state), do: state

  defp persist_all(state) do
    state.entries
    |> Enum.with_index()
    |> Enum.each(fn {e, i} -> Studio.save_entry(state.session["id"], e, i) end)

    %{state | seq: length(state.entries)}
  end

  defp persist_entry(%{session: nil} = state, _entry), do: state

  defp persist_entry(state, entry) do
    Studio.save_entry(state.session["id"], entry, length(state.entries) - 1)
    state
  end

  # ---- misc -------------------------------------------------------------------------

  defp teardown(state) do
    if state.turn, do: acp().cancel(state.acp, state.kas_session_id)
    if state.acp, do: safe(fn -> acp().close(state.acp) end)
    if state.bridge, do: safe(fn -> acp().close(state.bridge) end)

    if state.vm do
      Runtime.checkpoint(state.vm.id, state.vm.endpoint)
      Runtime.terminate(state.vm.id)
    end

    %{
      state
      | phase: :off,
        vm: nil,
        acp: nil,
        bridge: nil,
        kas_session_id: nil,
        turn: nil,
        pending: %{}
    }
    |> add(Transcript.new_entry("status", "Studio powered down"))
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end

  defp touch(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: Process.send_after(self(), :idle_terminate, @idle_terminate_ms)}
  end

  defp assign_user(state, nil), do: state
  defp assign_user(state, user), do: %{state | user: user}

  defp publish_state(state) do
    Studio.broadcast({:studio, :state, public(state)})
    state
  end

  defp public(state) do
    %{
      phase: state.phase,
      error: state.error,
      vm: state.vm && state.vm.id,
      bridge: not is_nil(state.bridge),
      turn: state.turn && %{text: state.turn.text, started_at: state.turn.started_at},
      pending: map_size(state.pending),
      session: state.session && Map.take(state.session, ~w(id title turns)),
      entries: state.entries
    }
  end
end
