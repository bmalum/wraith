defmodule Wraith.Studio do
  @moduledoc """
  The agent studio: a Kiro agent, running on a MicroVM (or the offline
  fake), that builds this site with you — writes posts, scripts widgets,
  changes settings — through `Wraith.Studio.Tools` over the bridge.

  One site has one studio (`Wraith.Studio.Server`, a singleton), which
  owns one KAS conversation at a time (`sessions/0` lists past ones; `new_session/1`
  starts a fresh one). The Kiro API key is set once (`set_key/1`,
  Vault-encrypted into the site item) or comes from `KIRO_API_KEY`.

  Events for LiveViews are on the `"studio"` PubSub topic:

      {:studio, :entries, [entry]}            # the whole transcript (replace)
      {:studio, :entry, entry}                # one new/changed entry (upsert by id)
      {:studio, :state, %{phase, turn, pending}}  # phase: :off | :booting | :ready | :error
  """
  alias Wraith.{Settings, Store, Vault}
  alias Wraith.Store.Keys
  alias Wraith.Kiro.{Bridge, Key}
  alias Wraith.Studio.Server

  @topic "studio"
  def subscribe, do: Phoenix.PubSub.subscribe(Wraith.PubSub, @topic)
  def broadcast(msg), do: Phoenix.PubSub.broadcast(Wraith.PubSub, @topic, msg)

  # ---- the key ----------------------------------------------------------------------

  @doc "Verify and store a Kiro API key. Shows only its hint afterwards."
  def set_key(raw) do
    key = Key.normalize(raw)

    with true <- Key.valid_format?(key) || {:error, :invalid},
         {:ok, _} <- Key.verify(key) do
      {pk, sk} = Keys.site()

      Store.update(
        pk,
        sk,
        &Map.merge(&1 || %{}, %{
          "kiro_key_ciphertext" => Vault.encrypt(key),
          "kiro_key_hint" => Key.hint(key)
        })
      )

      :ok
    else
      {:error, :invalid} -> {:error, "That does not look like a live Kiro API key (ksk_…)."}
      {:error, :unreachable} -> {:error, "Could not reach Kiro to verify the key."}
      {:error, {:http, s}} -> {:error, "Kiro answered #{s} while verifying the key."}
      false -> {:error, "That does not look like a Kiro API key (ksk_…)."}
    end
  end

  def clear_key do
    {pk, sk} = Keys.site()
    Store.update(pk, sk, &Map.drop(&1 || %{}, ["kiro_key_ciphertext", "kiro_key_hint"]))
    :ok
  end

  @doc "The key in the clear — for the VM payload only."
  def key do
    case Settings.get() do
      %{"kiro_key_ciphertext" => c} ->
        case Vault.decrypt(c) do
          {:ok, k} -> k
          :error -> Application.get_env(:wraith, :kiro_api_key)
        end

      _ ->
        Application.get_env(:wraith, :kiro_api_key)
    end
  end

  def key_hint do
    case Settings.get() do
      %{"kiro_key_hint" => h} ->
        h

      _ ->
        if k = Application.get_env(:wraith, :kiro_api_key), do: Key.hint(k) <> " (env)", else: nil
    end
  end

  def key?, do: key() != nil

  # ---- sessions (rows) ----------------------------------------------------------

  def sessions,
    do: Store.all("STUDIO", begins_with: Keys.studio_sessions_prefix(), forward: false)

  @doc "The current session row, created if none."
  def current_session(user_id) do
    case Enum.find(sessions(), &(&1["status"] == "open")) do
      nil -> create_session(user_id)
      s -> s
    end
  end

  def create_session(user_id) do
    for s <- sessions(), s["status"] == "open", do: close_session_row(s)
    id = Store.id()
    {pk, sk} = Keys.studio_session(id)

    :ok =
      Store.put(%{
        "pk" => pk,
        "sk" => sk,
        "id" => id,
        "user_id" => user_id,
        "status" => "open",
        "title" => "Session " <> String.slice(id, -6, 6),
        "turns" => 0,
        "credits" => 0
      })

    Store.get(pk, sk) |> elem(1)
  end

  def close_session_row(row), do: update_session(row, &Map.put(&1, "status", "closed"))

  def update_session(%{"id" => id} = row, fun) do
    {pk, sk} = Keys.studio_session(id)
    Store.update(pk, sk, &fun.(&1 || Map.merge(row, %{"pk" => pk, "sk" => sk})))
  end

  @doc "Persisted transcript entries of a session, oldest first."
  def entries(session_id) do
    Store.all(Keys.studio_messages_pk(session_id), begins_with: "MSG#") |> Enum.map(& &1["entry"])
  end

  def save_entry(session_id, %{"id" => _} = entry, seq) do
    {pk, sk} = Keys.studio_message(session_id, entry["at"] || Store.now(), seq)

    Store.put(%{
      "pk" => pk,
      "sk" => sk,
      "entry" => Map.delete(entry, "open"),
      "entry_id" => entry["id"]
    })
  end

  # ---- the agent definition ------------------------------------------------------

  @agent_rev "3"
  def agent_rev, do: @agent_rev

  @doc "The custom agent the studio conversation runs as: built-ins plus the `wraith` server."
  def agent(site) do
    %{
      id: "wraith-studio-#{@agent_rev}",
      description: "Wraith studio for #{site["title"]}",
      prompt: prompt(site),
      tools: ["@builtin", "@wraith"],
      mcpServers: %{"wraith" => %{url: Bridge.url(), headers: Bridge.headers(), timeout: 120_000}},
      # Built-in tools need the agent to ask; our own write/destructive tools do
      # too — the system prompt says "ask before deleting or publishing" but a
      # prompt-injected comment shouldn't be able to walk straight into
      # member_delete or newsletter_send. Reads stay frictionless: one explicit
      # allow per read-only tool, then "ask" for everything else under wraith/.
      permissions: %{
        rules:
          Enum.map(
            read_tool_names(),
            &%{capability: "mcp", effect: "allow", resource: "wraith/" <> &1}
          ) ++
            [%{capability: "mcp", effect: "ask", resource: "wraith/*"}]
      }
    }
  end

  defp read_tool_names do
    Wraith.Tools.catalogue() |> Enum.filter(&Wraith.Tools.read_only?/1) |> Enum.map(& &1["name"])
  end

  defp prompt(site) do
    """
    You are the studio agent of "#{site["title"]}", a blog published with Wraith
    (Elixir/Phoenix). You help the owner build and run the site: write and edit posts
    and pages in Markdown, design and script live widgets in Lua, tune tags and
    settings. Your tools are on the `wraith` MCP server; call `site_info` first when
    you need context and `widget_docs` before writing a widget. Test every widget with
    `widget_test` before `widget_save`, then tell the owner the shortcode to embed.
    Be concrete and brief; show what you changed with its URL. Ask before deleting or
    publishing anything the owner did not explicitly ask to publish.
    """
  end

  def steering(site) do
    [
      %{
        name: "wraith-site",
        inclusion: "always",
        content:
          "# This site\n\nTitle: #{site["title"]}\nDescription: #{site["description"]}\n\nWidgets are embedded with `{{widget slug key=value}}` on a line of its own in a post's Markdown."
      }
    ]
  end

  # ---- the server ------------------------------------------------------------------

  defdelegate state(), to: Server
  defdelegate wake(user), to: Server
  defdelegate prompt(text, user), to: Server
  defdelegate cancel(), to: Server
  defdelegate permit(tool_call_id, option_id), to: Server
  defdelegate answer(tool_call_id, answer), to: Server
  defdelegate new_session(user), to: Server
  defdelegate shutdown(), to: Server
end
