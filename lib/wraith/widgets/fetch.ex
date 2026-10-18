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
    ensure_table()

    with {:ok, uri} <- parse(url),
         :ok <- allowed(uri) do
      now = System.monotonic_time(:millisecond)

      case :ets.lookup(@table, url) do
        [{^url, body, at}] when now - at < @ttl_ms -> {:ok, body}
        _ -> fetch(url)
      end
    end
  end

  defp fetch(url) do
    case Req.get(url,
           receive_timeout: 5_000,
           max_redirects: 2,
           retry: false,
           headers: [{"user-agent", "Wraith widget"}]
         ) do
      {:ok, %{status: s, body: body}} when s in 200..299 ->
        body =
          if is_binary(body) and byte_size(body) > @max_bytes,
            do: binary_part(body, 0, @max_bytes),
            else: body

        :ets.insert(@table, {url, body, System.monotonic_time(:millisecond)})
        {:ok, body}

      {:ok, %{status: s}} ->
        {:error, "upstream answered #{s}"}

      {:error, e} ->
        {:error, "fetch failed: " <> Exception.message(e)}
    end
  end

  defp parse(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, "not an http(s) URL"}
    end
  end

  defp allowed(%URI{host: host}) do
    patterns =
      Wraith.Settings.get()["widget_fetch_hosts"]
      |> to_string()
      |> String.split(~r/[,\s]+/, trim: true)

    if Enum.any?(patterns, &host_matches?(host, &1)),
      do: :ok,
      else:
        {:error, "#{host} is not in the widget fetch allowlist (Settings → widget fetch hosts)"}
  end

  defp host_matches?(host, "*." <> suffix),
    do: String.ends_with?(host, "." <> suffix) or host == suffix

  defp host_matches?(host, pattern), do: host == pattern

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end
  end
end
