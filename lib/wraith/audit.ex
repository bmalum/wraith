defmodule Wraith.Audit do
  @moduledoc """
  Who did what in the admin: an append-only log (`AUDIT` / `<at>#<id>`),
  written by the contexts' callers (LiveViews, API, MCP) through `log/4`.
  `recent/1` is the dashboard's feed; entries are kept 90 days (`ttl`).
  """
  alias Wraith.Store

  @keep_days 90

  @doc "`log(actor, action, subject, detail)` — actor is a user map or an API-key label."
  def log(actor, action, subject \\ nil, detail \\ %{}) do
    now = Store.now()
    id = Store.id()

    Store.put(%{
      "pk" => "AUDIT",
      "sk" => now <> "#" <> id,
      "at" => now,
      "actor" => actor_name(actor),
      "actor_id" => actor_id(actor),
      "action" => to_string(action),
      "subject" => subject && to_string(subject),
      "detail" => detail,
      "ttl" => System.system_time(:second) + @keep_days * 86_400
    })
  end

  def recent(limit \\ 50) do
    {:ok, %{items: items}} = Store.query("AUDIT", forward: false, limit: limit)
    items
  end

  defp actor_name(%{"name" => n}), do: n
  defp actor_name(%{"label" => l}), do: "key:" <> l
  defp actor_name(s) when is_binary(s), do: s
  defp actor_name(_), do: "system"

  defp actor_id(%{"id" => id}), do: id
  defp actor_id(_), do: nil
end
