defmodule Wraith.Studio.Transcript do
  @moduledoc """
  What the studio shows: a list of entries built from KAS's `session/update`
  notifications (and our own lines). Entries are maps:

      %{"id", "kind", "text", "at", "status", "tool", "input", "output", "replay"}

  kinds: `user`, `agent` (streamed text, chunks appended), `tool` (a tool
  call; `status` pending/completed/failed, `tool` title, `input`, `output`),
  `thought`, `status` (one of our lines: VM booting, errors), `usage`
  (a turn's credit cost), `question`, `permission`.

  `apply/2` takes the current list (newest last) and one update and returns
  the new list; consecutive `agent` chunks of the same turn merge.
  """

  @type entry :: map()

  def new_entry(kind, text, extra \\ %{}) do
    %{"id" => id(), "kind" => kind, "text" => text, "at" => Wraith.Store.now()}
    |> Map.merge(extra)
    |> redact()
  end

  # Tool inputs and outputs are persisted and broadcast to every studio viewer.
  # Secrets that pass through tools (a freshly minted API key, a Stripe secret
  # in settings_update, a password in author_create) must not land there.
  @secret_keys ~w(password secret key api_key stripe_secret_key stripe_webhook_secret kiro_api_key token)
  @secret_patterns [
    ~r/\b(ksk|wsk|sk)_[A-Za-z0-9_-]{8,}/,
    ~r/\b[0-9a-f]{24}:[0-9a-f]{64}\b/,
    ~r/\bwhsec_[A-Za-z0-9]{8,}/
  ]

  @doc "Scrub secret-looking values from an entry's `input`/`output` (and the text)."
  def redact(entry) do
    entry
    |> Map.update("input", nil, &scrub/1)
    |> Map.update("output", nil, &scrub/1)
    |> Map.update("text", "", &scrub_text/1)
  end

  defp scrub(%{} = m) do
    Map.new(m, fn {k, v} ->
      if to_string(k) |> String.downcase() |> String.ends_with?(@secret_keys) and is_binary(v),
        do: {k, "[redacted]"},
        else: {k, scrub(v)}
    end)
  end

  defp scrub(list) when is_list(list), do: Enum.map(list, &scrub/1)
  defp scrub(s) when is_binary(s), do: scrub_text(s)
  defp scrub(other), do: other

  defp scrub_text(s) when is_binary(s),
    do: Enum.reduce(@secret_patterns, s, &Regex.replace(&1, &2, "[redacted]"))

  defp scrub_text(other), do: other

  @spec apply([entry()], map()) :: [entry()]
  def apply(
        entries,
        %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => text}} = u
      ) do
    replay? = replay?(u)

    case List.last(entries) do
      %{"kind" => "agent", "open" => true} = last ->
        List.replace_at(entries, -1, %{last | "text" => last["text"] <> text})

      _ ->
        entries ++ [new_entry("agent", text, %{"open" => true, "replay" => replay?})]
    end
  end

  def apply(
        entries,
        %{"sessionUpdate" => "user_message_chunk", "content" => %{"text" => text}} = u
      ) do
    entries ++ [new_entry("user", text, %{"replay" => replay?(u)})]
  end

  def apply(entries, %{"sessionUpdate" => "agent_thought_chunk", "content" => %{"text" => text}}) do
    case List.last(entries) do
      %{"kind" => "thought", "open" => true} = last ->
        List.replace_at(entries, -1, %{last | "text" => last["text"] <> text})

      _ ->
        entries ++ [new_entry("thought", text, %{"open" => true})]
    end
  end

  def apply(entries, %{"sessionUpdate" => "tool_call", "toolCallId" => tc} = u) do
    entry =
      new_entry("tool", "", %{
        "tool_call_id" => tc,
        "tool" => u["title"] || "tool",
        "status" => u["status"] || "pending",
        "input" => u["rawInput"],
        "server" => get_in(u, ["_meta", "kiro", "serverName"])
      })

    close_open(entries) ++ [entry]
  end

  def apply(entries, %{"sessionUpdate" => "tool_call_update", "toolCallId" => tc} = u) do
    case Enum.find_index(entries, &(&1["kind"] == "tool" and &1["tool_call_id"] == tc)) do
      nil ->
        entries

      i ->
        output = output_of(u)

        List.update_at(entries, i, fn e ->
          e
          |> Map.put("status", u["status"] || e["status"])
          |> then(&if(output, do: Map.put(&1, "output", output), else: &1))
          |> then(&if(u["title"], do: Map.put(&1, "tool", u["title"]), else: &1))
          |> redact()
        end)
    end
  end

  # the end of a turn: cost and context
  def apply(entries, %{"sessionUpdate" => "session_info_update", "_meta" => %{"kiro" => kiro}}) do
    entries = close_open(entries)

    cond do
      kiro["displayError"] ->
        entries ++
          [
            new_entry("status", "Kiro: " <> (kiro["displayError"]["message"] || "error"), %{
              "level" => "error"
            })
          ]

      is_list(kiro["promptTurnSummaries"]) ->
        credits = kiro["promptTurnSummaries"] |> Enum.map(&(&1["usage"] || 0)) |> Enum.sum()

        entries ++
          [
            new_entry("usage", "#{credits} credits", %{
              "credits" => credits,
              "elapsed_ms" => kiro["elapsedTime"],
              "replay" => kiro["replay"] == true
            })
          ]

      kiro["contextUsage"] ->
        entries

      true ->
        entries
    end
  end

  def apply(entries, _other), do: entries

  @doc "Close any streaming entry (a turn ended)."
  def close_open(entries), do: Enum.map(entries, &Map.delete(&1, "open"))

  defp output_of(%{"content" => [_ | _] = blocks}) do
    blocks
    |> Enum.map(fn
      %{"content" => %{"text" => t}} -> t
      %{"type" => "text", "text" => t} -> t
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp output_of(%{"rawOutput" => %{"response" => r}}) when is_binary(r), do: r
  defp output_of(%{"rawOutput" => r}) when is_binary(r), do: r
  defp output_of(%{"rawOutput" => r}) when is_map(r), do: Jason.encode!(r)
  defp output_of(_), do: nil

  defp replay?(u), do: get_in(u, ["_meta", "kiro", "replay"]) == true

  defp id, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
end
