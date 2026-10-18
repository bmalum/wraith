defmodule WraithWeb.Admin.StudioLive do
  @moduledoc """
  The agent studio: a conversation with the Kiro agent that builds this
  site. Left, the transcript (streamed text, tool calls with their input
  and output, permission requests with buttons); bottom, the prompt box;
  right, the studio's state and the key.
  """
  use WraithWeb, :live_view

  alias Wraith.{Markdown, Studio}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Studio.subscribe()
    state = Studio.state()

    {:ok,
     socket
     |> assign(
       page_title: "Agent studio",
       state: Map.delete(state, :entries),
       key_hint: Studio.key_hint(),
       key_error: nil,
       draft: "",
       sessions: Studio.sessions()
     )
     |> stream_configure(:entries, dom_id: &"entry-#{&1["id"]}")
     |> stream(:entries, state.entries)}
  end

  # ---- events ----------------------------------------------------------------------

  @impl true
  def handle_event("wake", _params, socket) do
    user = socket.assigns.current_user
    # boot may take a minute on a real VM; do it off the LiveView
    Task.start(fn -> Studio.wake(user) end)
    {:noreply, socket}
  end

  def handle_event("send", %{"text" => text}, socket) do
    case Studio.prompt(text, socket.assigns.current_user) do
      :ok -> {:noreply, assign(socket, draft: "")}
      {:error, why} -> {:noreply, socket |> put_flash(:error, why) |> assign(draft: text)}
    end
  end

  def handle_event("draft", %{"text" => text}, socket),
    do: {:noreply, assign(socket, draft: text)}

  def handle_event("cancel", _params, socket) do
    Studio.cancel()
    {:noreply, socket}
  end

  def handle_event("permit", %{"tc" => tc, "option" => option}, socket) do
    Studio.permit(tc, option)
    {:noreply, socket}
  end

  def handle_event("answer", %{"tc" => tc, "answer" => answer}, socket) do
    Studio.answer(tc, answer)
    {:noreply, socket}
  end

  def handle_event("new-session", _params, socket) do
    {:ok, _} = Studio.new_session(socket.assigns.current_user)
    {:noreply, assign(socket, sessions: Studio.sessions())}
  end

  def handle_event("shutdown", _params, socket) do
    Task.start(fn -> Studio.shutdown() end)
    {:noreply, socket}
  end

  def handle_event("set-key", %{"key" => key}, socket) do
    case Studio.set_key(key) do
      :ok ->
        {:noreply,
         assign(socket, key_hint: Studio.key_hint(), key_error: nil)
         |> put_flash(:info, "Key saved.")}

      {:error, why} ->
        {:noreply, assign(socket, key_error: why)}
    end
  end

  def handle_event("clear-key", _params, socket) do
    Studio.clear_key()
    {:noreply, assign(socket, key_hint: Studio.key_hint())}
  end

  # ---- the studio speaks ---------------------------------------------------------

  @impl true
  def handle_info({:studio, :entry, entry}, socket),
    do: {:noreply, stream_insert(socket, :entries, entry)}

  def handle_info({:studio, :entries, entries}, socket),
    do: {:noreply, stream(socket, :entries, entries, reset: true)}

  def handle_info({:studio, :state, state}, socket) do
    {:noreply, assign(socket, state: Map.delete(state, :entries), sessions: Studio.sessions())}
  end

  # ---- render ----------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} active={:studio} bare>
      <div class="studio">
        <section class="studio-main">
          <header class="studio-bar">
            <span class={["studio-phase", "is-" <> to_string(@state.phase)]}>
              <span class="studio-dot" aria-hidden="true"></span>
              {phase_label(@state)}
            </span>
            <span :if={@state.session} class="row-sub">{@state.session["title"]} · {@state.session[
              "turns"
            ]} turns</span>
            <span class="studio-bar-actions">
              <button
                :if={@state.phase in [:off, :error]}
                phx-click="wake"
                class="btn-accent"
                disabled={is_nil(@key_hint)}
              ><.icon name="hero-bolt" class="size-4" /> Wake the agent</button>
              <button :if={@state.turn} phx-click="cancel" class="btn-ghost"><.icon
                name="hero-stop"
                class="size-4"
              /> Stop</button>
              <button
                :if={@state.phase == :ready}
                phx-click="new-session"
                class="btn-ghost"
                title="Start a fresh conversation"
              ><.icon name="hero-plus" class="size-4" /> New</button>
              <button
                :if={@state.phase not in [:off]}
                phx-click="shutdown"
                class="btn-ghost"
                data-confirm="Power the studio down? The VM is terminated; the conversation is kept."
                title="Power down"
              ><.icon name="hero-power" class="size-4" /></button>
            </span>
          </header>

          <div id="transcript" class="transcript" phx-update="stream" phx-hook="ScrollBottom">
            <div
              :for={{dom_id, e} <- @streams.entries}
              id={dom_id}
              class={["entry", "is-" <> e["kind"], e["replay"] && "is-replay"]}
            >
              <.entry entry={e} />
            </div>
          </div>

          <div :if={@state.phase == :off and is_nil(@key_hint)} class="studio-empty">
            <.icon name="hero-sparkles" class="size-8" />
            <h2>Meet your studio agent</h2>
            <p>
              A Kiro agent runs next to this site and can write posts, script widgets and change settings for you. Add a Kiro API key on the right to begin.
            </p>
          </div>

          <form phx-submit="send" phx-change="draft" class="composer" id="composer">
            <textarea
              name="text"
              placeholder={placeholder(@state)}
              rows="2"
              disabled={@state.phase != :ready}
              phx-debounce="200"
            >{@draft}</textarea>
            <button
              type="submit"
              class="btn-accent"
              disabled={@state.phase != :ready or @state.turn != nil}
            ><.icon name="hero-paper-airplane" class="size-4" /></button>
          </form>
        </section>

        <aside class="studio-side">
          <section class="panel">
            <header class="panel-head">
              <h2>Kiro API key</h2>
            </header>
            <div class="panel-form">
              <p :if={@key_hint} class="row-sub">Key <code>{@key_hint}</code> is set.</p>
              <form :if={is_nil(@key_hint)} phx-submit="set-key" class="drawer-row" id="key-form">
                <input
                  type="password"
                  name="key"
                  class="input is-mono"
                  placeholder="ksk_…"
                  autocomplete="off"
                />
                <button type="submit" class="btn-accent">Save</button>
              </form>
              <p :if={@key_error} class="form-error">{@key_error}</p>
              <p class="form-help">
                Mint one at app.kiro.dev → API Keys. It is stored encrypted and only ever sent to the studio VM.
              </p>
              <button
                :if={@key_hint}
                phx-click="clear-key"
                class="btn-ghost is-small"
                data-confirm="Remove the key?"
              >Remove</button>
            </div>
          </section>

          <section class="panel">
            <header class="panel-head">
              <h2>Studio</h2>
            </header>
            <dl class="kv">
              <dt>Phase</dt><dd>{@state.phase}</dd>
              <dt>VM</dt><dd><code>{@state.vm || "—"}</code></dd>
              <dt>Tools</dt><dd>{if @state.bridge, do: "connected", else: "offline"}</dd>
              <dt>Pending</dt><dd>{@state.pending}</dd>
              <dt :if={@state.error}>Error</dt><dd :if={@state.error} class="form-error">
                {@state.error}
              </dd>
            </dl>
          </section>

          <section class="panel">
            <header class="panel-head">
              <h2>Try asking</h2>
            </header>
            <ul class="hints">
              <li>
                “Write a poll widget that lets readers pick a mascot, one vote each, and embed it in a new draft.”
              </li>
              <li>“Draft a post announcing the launch with a countdown to 2027-01-01.”</li>
              <li>“Rename the ‘news’ tag to ‘Updates’ and give it a description.”</li>
              <li :if={@state.vm && String.starts_with?(@state.vm, "fake")} class="row-sub">
                Offline agent: try <code>!widget clap</code>, <code>!post Hello</code>, <code>!info</code>, <code>use a tool</code>.
              </li>
            </ul>
          </section>

          <section :if={@sessions != []} class="panel">
            <header class="panel-head">
              <h2>Sessions</h2>
            </header>
            <ul class="row-list">
              <li :for={s <- Enum.take(@sessions, 6)} class="row is-compact">
                <span class="row-main"><span class="row-title">{s["title"]}</span><span class="row-sub">{s[
                  "status"
                ]} · {s["turns"]} turns</span></span>
              </li>
            </ul>
          </section>
        </aside>
      </div>
    </Layouts.admin>
    """
  end

  attr :entry, :map, required: true

  defp entry(%{entry: %{"kind" => "user"}} = assigns) do
    ~H"""
    <div class="entry-bubble">{@entry["text"]}</div>
    """
  end

  defp entry(%{entry: %{"kind" => "agent"}} = assigns) do
    ~H"""
    <div class="entry-agent prose-wraith is-compact">
      {Phoenix.HTML.raw(Markdown.to_html(@entry["text"]))}<span
        :if={@entry["open"]}
        class="caret"
        aria-hidden="true"
      ></span>
    </div>
    """
  end

  defp entry(%{entry: %{"kind" => "thought"}} = assigns) do
    ~H"""
    <details class="entry-thought">
      <summary>Thinking</summary><p>{@entry["text"]}</p>
    </details>
    """
  end

  defp entry(%{entry: %{"kind" => "tool"}} = assigns) do
    ~H"""
    <details class={["entry-tool", "is-" <> (@entry["status"] || "pending")]}>
      <summary>
        <.icon name={tool_icon(@entry["status"])} class="size-4" />
        <code>{@entry["tool"]}</code>
        <span class="row-sub">{@entry["status"]}</span>
      </summary>
      <div :if={@entry["input"]} class="entry-io">
        <span class="entry-io-label">input</span><pre>{pretty(@entry["input"])}</pre>
      </div>
      <div :if={@entry["output"]} class="entry-io">
        <span class="entry-io-label">output</span><pre>{String.slice(to_string(@entry["output"]), 0, 4000)}</pre>
      </div>
    </details>
    """
  end

  defp entry(%{entry: %{"kind" => "permission"}} = assigns) do
    ~H"""
    <div class={["entry-ask", @entry["status"] != "pending" && "is-done"]}>
      <div class="entry-ask-head">
        <.icon name="hero-shield-exclamation" class="size-4" /> The agent wants to run
        <code>{@entry["tool"]}</code>
      </div>
      <pre :if={@entry["input"]} class="entry-ask-input">{pretty(@entry["input"])}</pre>
      <div :if={@entry["status"] == "pending"} class="entry-ask-actions">
        <button
          :for={o <- @entry["options"] || []}
          phx-click="permit"
          phx-value-tc={@entry["tool_call_id"]}
          phx-value-option={o["optionId"]}
          class={if allow?(o), do: "btn-accent", else: "btn-ghost"}
        >{o["name"] || o["optionId"]}</button>
      </div>
      <p :if={@entry["status"] != "pending"} class="row-sub">
        {@entry["status"]}{if @entry["decision"], do: ": " <> @entry["decision"]}
      </p>
    </div>
    """
  end

  defp entry(%{entry: %{"kind" => "question"}} = assigns) do
    ~H"""
    <div class={["entry-ask", @entry["status"] != "pending" && "is-done"]}>
      <div class="entry-ask-head">
        <.icon name="hero-question-mark-circle" class="size-4" /> {@entry["text"]}
      </div>
      <div :if={@entry["status"] == "pending"} class="entry-ask-actions">
        <button
          :for={o <- @entry["options"] || []}
          phx-click="answer"
          phx-value-tc={@entry["tool_call_id"]}
          phx-value-answer={o["title"]}
          class={if o["recommended"], do: "btn-accent", else: "btn-ghost"}
          title={o["description"]}
        >{o["title"]}</button>
      </div>
      <p :if={@entry["status"] != "pending"} class="row-sub">{@entry["decision"]}</p>
    </div>
    """
  end

  defp entry(%{entry: %{"kind" => "usage"}} = assigns) do
    ~H"""
    <div class="entry-usage">
      {@entry["text"]}<span :if={@entry["elapsed_ms"]}> · {Float.round(@entry["elapsed_ms"] / 1000, 1)} s</span>
    </div>
    """
  end

  defp entry(assigns) do
    ~H"""
    <div class={["entry-status", "is-" <> (@entry["level"] || "info")]}>{@entry["text"]}</div>
    """
  end

  defp tool_icon("completed"), do: "hero-check-circle"
  defp tool_icon("failed"), do: "hero-x-circle"
  defp tool_icon(_), do: "hero-arrow-path"

  defp allow?(o),
    do: String.starts_with?(to_string(o["kind"]), "allow") or o["optionId"] in ["allow", "accept"]

  defp pretty(v) when is_binary(v), do: v
  defp pretty(v), do: Jason.encode!(v, pretty: true)

  defp phase_label(%{phase: :off}), do: "Powered off"
  defp phase_label(%{phase: :booting}), do: "Starting the VM…"
  defp phase_label(%{phase: :ready, turn: nil}), do: "Ready"
  defp phase_label(%{phase: :ready}), do: "Thinking…"
  defp phase_label(%{phase: :error}), do: "Error"

  defp placeholder(%{phase: :ready}),
    do: "Ask the agent to write, build or change something… (Enter to send)"

  defp placeholder(_), do: "Wake the agent first"
end
