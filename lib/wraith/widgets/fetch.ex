defmodule Wraith.Widgets.Fetch do
  @moduledoc """
  `wraith.fetch(url)` for Lua widgets: GET over Req, 5 s, 256 KB, only to
  hosts the owner lists in Settings (`widget_fetch_hosts`, comma-separated,
  `*.example.com` allowed), answers cached in ETS for 60 s so a page of
  readers does not hammer the upstream. JSON bodies come back decoded.
  """
  @table :wraith_widget_fetch
  @ttl_ms 60_000
  @max_bytes 256 * 1024

  def get(url) do
    now = System.monotonic_time(:millisecond)

    # the allowlist is checked by SafeHTTP on every hop — the first URL *and*
    # anything it redirects to — along with the public-address rule
    case :ets.lookup(@table, url) do
      [{^url, body, at}] when now - at < @ttl_ms -> {:ok, body}
      _ -> fetch(url)
    end
  end

  defp fetch(url) do
    sweep()

    case Wraith.SafeHTTP.get(url,
           allow: allowlist(),
           max_bytes: @max_bytes,
           max_redirects: 2,
           timeout_ms: 5_000,
           headers: [{"user-agent", "Wraith widget"}]
         ) do
      {:ok, %{status: s, body: body, headers: h}} when s in 200..299 ->
        body = maybe_json(body, h)
        :ets.insert(@table, {url, body, System.monotonic_time(:millisecond)})
        {:ok, body}

      {:ok, %{status: s}} ->
        {:error, "upstream answered #{s}"}

      {:error, why} ->
        {:error, why}
    end
  end

  # Req no longer decodes for us (streamed body); decode JSON when it says so
  defp maybe_json(body, headers) do
    ct = headers |> Map.get("content-type", []) |> List.wrap() |> List.first() |> to_string()

    if String.contains?(ct, "json") do
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        _ -> body
      end
    else
      body
    end
  end

  defp allowlist do
    Wraith.Settings.get()["widget_fetch_hosts"]
    |> to_string()
    |> String.split(~r/[,\s]+/, trim: true)
  end

  # the cache is keyed by full URL; a widget fetching unique query strings
  # would grow it without bound. Drop expired rows now and then, and cap it.
  @max_cached 2_000
  defp sweep do
    if :ets.info(@table, :size) > @max_cached do
      cutoff = System.monotonic_time(:millisecond) - @ttl_ms
      :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])

      if :ets.info(@table, :size) > @max_cached, do: :ets.delete_all_objects(@table)
    end
  end
end
