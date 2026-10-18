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
    Map.merge(%{"id" => id(), "kind" => kind, "text" => text, "at" => Wraith.Store.now()}, extra)
  end

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
