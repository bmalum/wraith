defmodule Wraith.Kiro.ACP do
  @moduledoc """
  Ported from shadow_corp. A client for the Agent Client Protocol — JSON-RPC 2.0 over WebSocket — as
  spoken by the Kiro Agent Server (KAS).

  One process per connection. The *owner* (the process that called
  `connect/2`) receives everything the agent sends that is not a reply:

      {:acp, pid, {:notification, method, params}}
      {:acp, pid, {:request, id, method, params}}   # answer with respond/3
      {:acp, pid, {:closed, reason}}

  Replies to our own requests come back to the caller of `request/4`.

  Two KAS facts baked in: over the WS transport every client is an
  *observer*, so (1) `_kiro/auth/getAccessToken` can never be satisfied by
  us — the credential lives in the VM — and (2) permission answers must go
  through `_kiro/permission/respond` (`permit/3`), a plain reply is dropped.
  """
  @behaviour Wraith.Kiro.ACP.Client
  use GenServer

  @impl Wraith.Kiro.ACP.Client
  def bridge_on_acp?, do: false
  require Logger

  @type conn :: pid()

  # The MicroVM endpoint drops a WebSocket that is silent for 60 s; KAS itself
  # never pings. A ping frame every 25 s keeps an idle operative on the wire.
  @ping_every_ms 25_000

  defstruct [
    :owner,
    :conn,
    :websocket,
    :ref,
    :url,
    :opener,
    :http_status,
    :http_headers,
    next_id: 1,
    pending: %{},
    # frames the server sent before Mint reported the upgrade `:done`
    early: [],
    status: :connecting
  ]

  # ---- API ---------------------------------------------------------------------

  @doc """
  Open a WebSocket to `url` (`ws://` or `wss://`). `opts[:protocols]` are
  Sec-WebSocket-Protocol values (MicroVM auth rides here), `opts[:owner]`
  defaults to the caller. Returns once the upgrade succeeded.
  """
  @spec connect(String.t(), keyword()) :: {:ok, conn()} | {:error, term()}
  @impl Wraith.Kiro.ACP.Client
  def connect(url, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    timeout = Keyword.get(opts, :timeout, 15_000)

    # start (not start_link): a refused TCP connect must come back as a
    # value, not take the caller down; the owner monitors the conn instead
    with {:ok, pid} <- GenServer.start(__MODULE__, {owner, url, opts}) do
      case await_open(pid, timeout) do
        :ok ->
          {:ok, pid}

        {:error, _} = err ->
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end

          err
      end
    end
  end

  defp await_open(pid, timeout) do
    GenServer.call(pid, :await_open, timeout)
  catch
    :exit, {reason, _} -> {:error, reason}
    :exit, reason -> {:error, reason}
  end

  @doc "Send a request and wait for the reply (result or error)."
  @spec request(conn(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, map() | term()}
  def request(conn, method, params, timeout \\ 60_000) do
    GenServer.call(conn, {:request, method, params}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, reason}
  end

  @doc "Fire a notification (no reply expected)."
  def notify(conn, method, params), do: GenServer.cast(conn, {:notify, method, params})

  @impl Wraith.Kiro.ACP.Client
  def respond(conn, id, result), do: GenServer.cast(conn, {:respond, id, result})

  @impl Wraith.Kiro.ACP.Client
  def reject(conn, id, code, message), do: GenServer.cast(conn, {:reject, id, code, message})

  @doc "A steering note into a session: `_session/steer` (a persisted user-style message)."
  @impl Wraith.Kiro.ACP.Client
  def steer(conn, session_id, message),
    do: request(conn, "_session/steer", %{sessionId: session_id, message: message}, 15_000)

  @doc "Grant/deny a `session/request_permission` the observer way."
  @impl Wraith.Kiro.ACP.Client
  def permit(conn, tool_call_id, option_id),
    do:
      request(
        conn,
        "_kiro/permission/respond",
        %{toolCallId: tool_call_id, optionId: option_id},
        10_000
      )

  @impl Wraith.Kiro.ACP.Client
  def close(conn), do: GenServer.stop(conn, :normal)

  @client_info %{name: "wraith", version: "0.1"}

  # `_meta.kiro.userInput: true` makes KAS ask questions via `_kiro/userInput`
  # instead of disguising them as permission requests.
  @impl Wraith.Kiro.ACP.Client
  def initialize(conn) do
    request(conn, "initialize", %{
      protocolVersion: 1,
      clientCapabilities: %{
        fs: %{readTextFile: false, writeTextFile: false},
        terminal: false,
        _meta: %{kiro: %{userInput: true, settings: %{memoryEnable: %{enabled: true}}}}
      },
      clientInfo: @client_info
    })
  end

  @doc "Answer (or dismiss with `nil`) a `_kiro/userInput` question."
  @impl Wraith.Kiro.ACP.Client
  def answer_question(conn, tool_call_id, answer) when is_binary(answer),
    do:
      request(
        conn,
        "_kiro/userInput/respond",
        %{toolCallId: tool_call_id, action: "answered", answer: answer},
        10_000
      )

  def answer_question(conn, tool_call_id, nil),
    do:
      request(
        conn,
        "_kiro/userInput/respond",
        %{toolCallId: tool_call_id, action: "dismissed"},
        10_000
      )

  @doc """
  Create-or-load a session under a caller-chosen id (`idempotent` +
  `overrideSessionId`), with steering documents. `extra` carries e.g.
  `%{customAgents: [agent], modeId: agent.id}`.
  """
  @impl Wraith.Kiro.ACP.Client
  def ensure_session(conn, session_id, cwd, steering \\ [], extra \\ %{}) do
    kiro = %{overrideSessionId: session_id, idempotent: true}
    kiro = if steering == [], do: kiro, else: Map.put(kiro, :steering, steering)
    kiro = Map.merge(kiro, extra)
    request(conn, "session/new", %{cwd: cwd, mcpServers: [], _meta: %{kiro: kiro}})
  end

  @doc "Close a live session (it stays on disk; `ensure_session` re-hydrates it)."
  @impl Wraith.Kiro.ACP.Client
  def close_session(conn, session_id),
    do: request(conn, "session/close", %{sessionId: session_id}, 30_000)

  @doc "Switch a session's agent (mode): a reopened session keeps the one it was saved with otherwise."
  @impl Wraith.Kiro.ACP.Client
  def set_mode(conn, session_id, mode_id),
    do: request(conn, "session/set_mode", %{sessionId: session_id, modeId: mode_id}, 30_000)

  @impl Wraith.Kiro.ACP.Client
  def load_session(conn, session_id, cwd, opts \\ []) do
    meta =
      case opts[:replay_limit] do
        n when is_integer(n) and n > 0 -> %{_meta: %{kiro: %{replayLimit: n}}}
        _ -> %{}
      end

    request(
      conn,
      "session/load",
      Map.merge(%{sessionId: session_id, cwd: cwd, mcpServers: []}, meta),
      120_000
    )
  end

  @impl Wraith.Kiro.ACP.Client
  def prompt(conn, session_id, text, timeout \\ :infinity),
    do:
      request(
        conn,
        "session/prompt",
        %{sessionId: session_id, prompt: [%{type: "text", text: text}]},
        timeout
      )

  @impl Wraith.Kiro.ACP.Client
  def cancel(conn, session_id), do: notify(conn, "session/cancel", %{sessionId: session_id})

  # ---- GenServer ----------------------------------------------------------------

  @impl true
  def init({owner, url, opts}) do
    uri = URI.parse(url)

    {scheme, ws_scheme} =
      if uri.scheme in ["wss", "https"], do: {:https, :wss}, else: {:http, :ws}

    port = uri.port || if(scheme == :https, do: 443, else: 80)

    headers =
      case Keyword.get(opts, :protocols, []) do
        [] -> []
        protocols -> [{"sec-websocket-protocol", Enum.join(protocols, ", ")}]
      end

    # not linked to the owner (see connect/2) — die with it instead
    Process.monitor(owner)

    with {:ok, conn} <- Mint.HTTP.connect(scheme, uri.host, port, protocol_opts(scheme)),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme, conn, request_target(uri), headers, extensions: []) do
      {:ok, %__MODULE__{owner: owner, conn: conn, ref: ref, url: url}}
    else
      {:error, reason} -> {:stop, {:connect, reason}}
      {:error, _conn, reason} -> {:stop, {:connect, reason}}
    end
  end

  # HTTP/1 only: Mint.WebSocket's h2 path needs an extended-CONNECT peer.
  defp protocol_opts(:https),
    do: [
      protocols: [:http1],
      transport_opts: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
    ]

  defp protocol_opts(:http), do: [protocols: [:http1]]

  @impl true
  def handle_call(:await_open, from, %{status: :connecting} = state) do
    {:noreply, %{state | opener: from}}
  end

  def handle_call(:await_open, _from, %{status: :open} = state), do: {:reply, :ok, state}

  def handle_call({:request, method, params}, from, %{status: :open} = state) do
    id = state.next_id
    msg = %{jsonrpc: "2.0", id: id, method: method, params: params}

    case send_frame(state, {:text, Jason.encode!(msg)}) do
      {:ok, state} ->
        {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}

      {:error, state, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:request, _, _}, _from, state), do: {:reply, {:error, :not_open}, state}

  @impl true
  def handle_cast({:notify, method, params}, state) do
    {:ok, state} = send_or_log(state, %{jsonrpc: "2.0", method: method, params: params})
    {:noreply, state}
  end

  def handle_cast({:respond, id, result}, state) do
    {:ok, state} = send_or_log(state, %{jsonrpc: "2.0", id: id, result: result})
    {:noreply, state}
  end

  def handle_cast({:reject, id, code, message}, state) do
    {:ok, state} =
      send_or_log(state, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})

    {:noreply, state}
  end

  @impl true
  def handle_info(:keepalive, %{status: :open} = state) do
    Process.send_after(self(), :keepalive, @ping_every_ms)

    case send_frame(state, {:ping, ""}) do
      {:ok, state} -> {:noreply, state}
      {:error, state, _reason} -> {:noreply, state}
    end
  end

  def handle_info(:keepalive, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info(:stop, state), do: {:stop, :normal, state}

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        {:noreply, Enum.reduce(responses, state, &handle_response/2)}

      {:error, conn, reason, _responses} ->
        state = %{state | conn: conn}
        notify_owner(state, {:closed, reason})
        {:stop, :normal, state}

      :unknown ->
        {:noreply, state}
    end
  end

  # the upgrade response
  defp handle_response({:status, ref, status}, %{ref: ref} = state),
    do: %{state | http_status: status}

  defp handle_response({:headers, ref, headers}, %{ref: ref} = state),
    do: %{state | http_headers: headers}

  defp handle_response({:done, ref}, %{ref: ref} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.http_status, state.http_headers) do
      {:ok, conn, websocket} ->
        if state.opener, do: GenServer.reply(state.opener, :ok)
        Process.send_after(self(), :keepalive, @ping_every_ms)
        state = %{state | conn: conn, websocket: websocket, status: :open, opener: nil}

        # A frame the server sent right after the handshake can arrive in the same
        # TCP read; Mint then delivers it as `:data` *before* `:done`. Decode it now.
        early = state.early
        Enum.reduce(early, %{state | early: []}, &decode_data/2)

      {:error, conn, reason} ->
        if state.opener,
          do: GenServer.reply(state.opener, {:error, {:upgrade, state.http_status, reason}})

        # nothing more will come over this socket
        send(self(), :stop)
        %{state | conn: conn, status: :failed, opener: nil}
    end
  end

  defp handle_response({:data, ref, data}, %{ref: ref, websocket: nil} = state),
    do: %{state | early: state.early ++ [data]}

  defp handle_response({:data, ref, data}, %{ref: ref} = state), do: decode_data(data, state)
  defp handle_response(_other, state), do: state

  defp decode_data(data, %{websocket: ws} = state) do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} ->
        Enum.reduce(frames, %{state | websocket: ws}, &handle_frame/2)

      {:error, ws, reason} ->
        Logger.warning("acp: websocket decode error #{inspect(reason)}")
        %{state | websocket: ws}
    end
  end

  defp handle_frame({:text, text}, state), do: handle_text(state, text)
  defp handle_frame({:ping, data}, state), do: elem(send_frame(state, {:pong, data}), 1)

  defp handle_frame({:close, _code, reason}, state) do
    notify_owner(state, {:closed, reason})
    # anyone still waiting on a request gets told; then the process goes
    for {_id, from} <- state.pending, do: GenServer.reply(from, {:error, :closed})
    send(self(), :stop)
    %{state | pending: %{}, status: :closed}
  end

  defp handle_frame(_frame, state), do: state

  defp handle_text(state, text) do
    case Jason.decode(text) do
      {:ok, %{"id" => id} = msg} when is_map_key(msg, "result") or is_map_key(msg, "error") ->
        case Map.pop(state.pending, id) do
          {nil, _} ->
            state

          {from, pending} ->
            reply =
              if Map.has_key?(msg, "result"),
                do: {:ok, msg["result"]},
                else: {:error, msg["error"]}

            GenServer.reply(from, reply)
            %{state | pending: pending}
        end

      {:ok, %{"id" => id, "method" => method} = msg} ->
        notify_owner(state, {:request, id, method, msg["params"] || %{}})
        state

      {:ok, %{"method" => method} = msg} ->
        notify_owner(state, {:notification, method, msg["params"] || %{}})
        state

      _ ->
        state
    end
  end

  # path plus query: the bridge key travels as `/bridge?key=…`
  defp request_target(%URI{path: path, query: nil}), do: path || "/"
  defp request_target(%URI{path: path, query: q}), do: (path || "/") <> "?" <> q

  defp notify_owner(%{owner: owner}, event), do: send(owner, {:acp, self(), event})

  defp send_or_log(state, msg) do
    case send_frame(state, {:text, Jason.encode!(msg)}) do
      {:ok, state} ->
        {:ok, state}

      {:error, state, reason} ->
        Logger.warning("acp: send failed #{inspect(reason)}")
        {:ok, state}
    end
  end

  defp send_frame(%{websocket: nil} = state, _frame), do: {:error, state, :not_open}

  defp send_frame(state, frame) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, %{state | websocket: ws, conn: conn}}
    else
      {:error, %Mint.WebSocket{} = ws, reason} -> {:error, %{state | websocket: ws}, reason}
      {:error, conn, reason} -> {:error, %{state | conn: conn}, reason}
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn} = state) when not is_nil(conn) do
    _ = if state.websocket, do: send_frame(state, {:close, 1000, "bye"})
    Mint.HTTP.close(conn)
    :ok
  end

  def terminate(_, _), do: :ok
end
