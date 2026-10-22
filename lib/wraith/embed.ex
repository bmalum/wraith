defmodule Wraith.Embed do
  @moduledoc """
  `{{embed <url> "optional caption"}}` on its own line in a post. YouTube,
  Vimeo and X get their player/embed; anything else becomes a bookmark card
  (title, description, image from the page's Open Graph tags, cached for a
  day).

  Rendering never waits on the network: a URL not yet cached renders as a
  plain link card and is fetched in the background (`warm/1` runs after
  every save, so readers normally find it cached). Code that renders once
  and can't be re-rendered — the newsletter — calls `prefetch/1` first.
  A page that does not answer is retried after five minutes, not a day.
  """

  @table :wraith_embed_cache
  @ttl_ms 24 * 60 * 60_000
  @miss_ttl_ms 5 * 60_000
  # a fetch in flight: other renders don't start a second one
  @pending_ms 10_000

  def html(url, caption \\ nil) do
    figure(embed(URI.parse(url), url), caption)
  end

  defp embed(%URI{host: h, path: path, query: q}, url)
       when h in ["youtube.com", "www.youtube.com", "youtu.be", "m.youtube.com"] do
    id =
      cond do
        h == "youtu.be" -> String.trim_leading(path || "", "/")
        is_binary(q) -> URI.decode_query(q)["v"]
        true -> nil
      end

    if id,
      do:
        ~s(<div class="embed is-video"><iframe src="https://www.youtube-nocookie.com/embed/#{esc(id)}" title="YouTube video" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></div>),
      else: bookmark(url)
  end

  defp embed(%URI{host: h, path: path}, url) when h in ["vimeo.com", "www.vimeo.com"] do
    case Regex.run(~r{/(\d+)}, path || "") do
      [_, id] ->
        ~s(<div class="embed is-video"><iframe src="https://player.vimeo.com/video/#{id}" title="Vimeo video" loading="lazy" allow="autoplay; fullscreen; picture-in-picture" allowfullscreen></iframe></div>)

      _ ->
        bookmark(url)
    end
  end

  defp embed(%URI{host: h}, url)
       when h in ["twitter.com", "x.com", "www.twitter.com", "www.x.com"] do
    # X's widgets.js is not loaded (no third-party scripts in posts); a card with the link instead
    ~s(<div class="embed is-social"><a href="#{esc(url)}" rel="noopener" target="_blank">View post on X →</a></div>)
  end

  defp embed(_uri, url), do: bookmark(url)

  @player_hosts ~w(youtube.com www.youtube.com youtu.be m.youtube.com vimeo.com www.vimeo.com
                   twitter.com x.com www.twitter.com www.x.com)

  defp bookmark(url) do
    meta = metadata(url)
    host = URI.parse(url).host || url

    ~s(<a class="embed is-bookmark" href="#{esc(url)}" rel="noopener" target="_blank">) <>
      if(meta["image"], do: ~s(<img src="#{esc(meta["image"])}" alt="" loading="lazy">), else: "") <>
      ~s(<span class="embed-text"><strong>#{esc(meta["title"] || url)}</strong>) <>
      if(meta["description"], do: ~s(<span>#{esc(meta["description"])}</span>), else: "") <>
      ~s(<small>#{esc(host)}</small></span></a>)
  end

  @doc """
  Open Graph title/description/image of a page from the cache; `%{}` (and a
  background fetch) when it isn't there yet.
  """
  def metadata(url) do
    case cached(url) do
      {:ok, meta} ->
        meta

      :pending ->
        %{}

      :miss ->
        mark_pending(url)
        Task.Supervisor.start_child(Wraith.TaskSupervisor, fn -> fetch_and_cache(url) end)
        %{}
    end
  end

  @doc "Fetch, in the background, the metadata of every bookmark in a post body."
  def warm(markdown) when is_binary(markdown) do
    if bookmark_urls(markdown) != [] do
      Task.Supervisor.start_child(Wraith.TaskSupervisor, fn -> prefetch(markdown) end)
    end

    :ok
  end

  def warm(_), do: :ok

  @doc "Fetch the metadata of every not-yet-cached bookmark in a post body, now (4 at a time)."
  def prefetch(markdown) when is_binary(markdown) do
    markdown
    |> bookmark_urls()
    # pending ones too: the caller needs the answer now, not the warm-up's
    |> Enum.reject(&match?({:ok, _}, cached(&1)))
    |> Task.async_stream(&fetch_and_cache/1,
      max_concurrency: 4,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  def prefetch(_), do: :ok

  # the URLs a body embeds that would render as bookmark cards (players need no fetch)
  defp bookmark_urls(markdown) do
    markdown
    |> Wraith.Markdown.embed_urls()
    |> Enum.reject(&(URI.parse(&1).host in @player_hosts))
    |> Enum.uniq()
  end

  defp cached(url) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, url) do
      [{^url, :pending, at}] when now - at < @pending_ms -> :pending
      [{^url, meta, at}] when meta == %{} and now - at < @miss_ttl_ms -> {:ok, meta}
      [{^url, meta, at}] when is_map(meta) and meta != %{} and now - at < @ttl_ms -> {:ok, meta}
      _ -> :miss
    end
  end

  defp mark_pending(url),
    do: :ets.insert(@table, {url, :pending, System.monotonic_time(:millisecond)})

  defp fetch_and_cache(url) do
    meta = fetch_metadata(url)
    :ets.insert(@table, {url, meta, System.monotonic_time(:millisecond)})
    meta
  end

  defp fetch_metadata(url) do
    # only the first 100 KB are needed for <head> metadata; SafeHTTP stops
    # reading there and refuses private/internal addresses on every hop
    case Wraith.SafeHTTP.get(url,
           max_bytes: 100_000,
           timeout_ms: 3_000,
           headers: [{"user-agent", "Mozilla/5.0 (compatible; Wraith/1.0)"}]
         ) do
      {:ok, %{status: 200, body: html}} when is_binary(html) ->
        head = html

        %{
          "title" => og(head, "og:title") || tag(head, "title"),
          "description" => og(head, "og:description") || meta_name(head, "description"),
          "image" => og(head, "og:image")
        }
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Map.new()

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp og(html, prop) do
    case Regex.run(
           ~r/<meta[^>]+property=["']#{Regex.escape(prop)}["'][^>]+content=["']([^"']*)["']/i,
           html
         ) ||
           Regex.run(
             ~r/<meta[^>]+content=["']([^"']*)["'][^>]+property=["']#{Regex.escape(prop)}["']/i,
             html
           ) do
      [_, v] -> unescape(v)
      _ -> nil
    end
  end

  defp meta_name(html, name) do
    case Regex.run(~r/<meta[^>]+name=["']#{name}["'][^>]+content=["']([^"']*)["']/i, html) do
      [_, v] -> unescape(v)
      _ -> nil
    end
  end

  defp tag(html, name) do
    case Regex.run(~r/<#{name}[^>]*>([^<]*)<\/#{name}>/i, html) do
      [_, v] -> v |> String.trim() |> unescape()
      _ -> nil
    end
  end

  defp figure(inner, nil), do: inner
  defp figure(inner, ""), do: inner

  defp figure(inner, caption),
    do: ~s(<figure class="embed-figure">#{inner}<figcaption>#{esc(caption)}</figcaption></figure>)

  defp unescape(t),
    do:
      t
      |> String.replace("&amp;", "&")
      |> String.replace("&quot;", "\"")
      |> String.replace("&#39;", "'")

  defp esc(s), do: s |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
