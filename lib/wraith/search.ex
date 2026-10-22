defmodule Wraith.Search do
  @moduledoc """
  Site search over published posts and pages, in memory: an inverted index
  in ETS keyed by word, rebuilt from the store on boot and kept fresh from
  `Wraith.Content` events. Titles weigh 5, tags 3, the excerpt 2, the body
  1; a prefix match on the last word makes search-as-you-type work.

  The index only ever holds what an anonymous reader may see: for `members`
  and `paid` posts that is the part above the paywall
  (`Wraith.Content.readable_markdown/2`), so neither matching nor snippets
  can leak gated text.

  Words live in an `ordered_set`, so a prefix is a bounded walk with
  `:ets.next/2`, not a scan of the whole table. The boot rebuild is retried
  with backoff if the store is unreachable — the node comes up with an empty
  index rather than crash-looping.

  `search/2` returns `[%{post, score, snippet}]`, best first.
  """
  use GenServer
  require Logger

  @table :wraith_search
  @docs :wraith_search_docs
  @max_prefix_words 200
  @retry_ms 5_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Posts matching `query`, up to `limit`."
  @spec search(String.t(), pos_integer()) :: [
          %{post: map(), score: number(), snippet: String.t()}
        ]
  def search(query, limit \\ 10) do
    terms = tokens(query)

    if terms == [] or :ets.whereis(@table) == :undefined do
      []
    else
      {prefix, exact} = List.pop_at(terms, -1)

      scores =
        exact
        |> Enum.flat_map(&word_hits/1)
        |> Enum.concat(prefix_hits(prefix))
        |> Enum.reduce(%{}, fn {id, weight}, acc ->
          Map.update(acc, id, weight, &(&1 + weight))
        end)
        # every exact term must appear (AND), the prefix term may
        |> Enum.filter(fn {id, _} -> Enum.all?(exact, &has?(&1, id)) end)

      scores
      |> Enum.sort_by(fn {_, s} -> -s end)
      |> Enum.take(limit)
      |> Enum.flat_map(fn {id, score} ->
        case :ets.lookup(@docs, id) do
          [{_, post, text}] -> [%{post: post, score: score, snippet: snippet(text, terms)}]
          [] -> []
        end
      end)
    end
  end

  @doc "Rebuild the whole index from the store."
  def rebuild, do: GenServer.call(__MODULE__, :rebuild, 30_000)

  def index(post), do: GenServer.cast(__MODULE__, {:index, post})
  def remove(post), do: GenServer.cast(__MODULE__, {:remove, post})

  # ---- server ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # {{word, post_id}, weight}: ordered so a prefix is a range walk
    :ets.new(@table, [:ordered_set, :named_table, :public, read_concurrency: true])
    :ets.new(@docs, [:set, :named_table, :public, read_concurrency: true])
    Wraith.Content.subscribe()
    {:ok, %{}, {:continue, :rebuild}}
  end

  @impl true
  def handle_continue(:rebuild, state) do
    try_rebuild()
    {:noreply, state}
  end

  @impl true
  def handle_call(:rebuild, _from, state) do
    do_rebuild()
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:index, post}, state) do
    put(post)
    {:noreply, state}
  end

  def handle_cast({:remove, post}, state) do
    drop(post["id"])
    {:noreply, state}
  end

  @impl true
  def handle_info(:retry_rebuild, state) do
    try_rebuild()
    {:noreply, state}
  end

  def handle_info({:content, :deleted, post}, state) do
    drop(post["id"])
    {:noreply, state}
  end

  def handle_info({:content, _event, post}, state) do
    if post["status"] == "published", do: put(post), else: drop(post["id"])
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # the store may not be reachable yet at boot; keep the node up and try again
  defp try_rebuild do
    do_rebuild()
  rescue
    e ->
      Logger.warning(
        "search index rebuild failed (#{Exception.message(e)}); retrying in #{@retry_ms}ms"
      )

      Process.send_after(self(), :retry_rebuild, @retry_ms)
  catch
    :exit, reason ->
      Logger.warning(
        "search index rebuild exited (#{inspect(reason)}); retrying in #{@retry_ms}ms"
      )

      Process.send_after(self(), :retry_rebuild, @retry_ms)
  end

  defp do_rebuild do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@docs)

    # every published post, pages followed — one DynamoDB page caps at 1 MB
    Wraith.Store.Keys.posts_index("published")
    |> Wraith.Store.all(index: :gsi1)
    |> Enum.each(&put/1)
  end

  defp put(post) do
    drop(post["id"])
    # only what an anonymous reader may see — never the gated part
    text = post |> Wraith.Content.readable_markdown(false) |> Wraith.Markdown.to_text()

    weighted =
      Enum.concat([
        tokens(post["title"]) |> Enum.map(&{&1, 5}),
        Enum.flat_map(post["tags"] || [], &tokens(&1)) |> Enum.map(&{&1, 3}),
        tokens(post["excerpt"]) |> Enum.map(&{&1, 2}),
        tokens(text) |> Enum.map(&{&1, 1})
      ])
      |> Enum.reduce(%{}, fn {w, weight}, acc -> Map.update(acc, w, weight, &(&1 + weight)) end)

    for {word, weight} <- weighted, do: :ets.insert(@table, {{word, post["id"]}, weight})

    :ets.insert(
      @docs,
      {post["id"],
       Map.take(
         post,
         ~w(id title slug excerpt tags type published_at author_id feature_image visibility)
       ), text}
    )
  end

  defp drop(id) do
    :ets.match_delete(@table, {{:_, id}, :_})
    :ets.delete(@docs, id)
  end

  defp has?(word, id), do: :ets.lookup(@table, {word, id}) != []

  # all {id, weight} for one exact word: a range over {word, _}
  defp word_hits(word) do
    :ets.select(@table, [{{{word, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
  end

  # exact hits first, then words that start with the prefix at half weight —
  # walked forward from the prefix in the ordered set, bounded, never a scan
  defp prefix_hits(prefix) do
    exact = word_hits(prefix)

    starts =
      prefix
      |> walk_from(@max_prefix_words)
      |> Enum.reject(fn {word, _id} -> word == prefix end)
      |> Enum.flat_map(fn key ->
        for {_, w} <- :ets.lookup(@table, key), do: {elem(key, 1), w * 0.5}
      end)

    exact ++ starts
  end

  # keys are {word, id}; step through them while word still starts with prefix
  defp walk_from(prefix, budget), do: collect(:ets.next(@table, {prefix, ""}), prefix, budget, [])

  defp collect(:"$end_of_table", _prefix, _budget, acc), do: Enum.reverse(acc)
  defp collect(_key, _prefix, 0, acc), do: Enum.reverse(acc)

  defp collect({word, _id} = key, prefix, budget, acc) do
    if String.starts_with?(word, prefix),
      do: collect(:ets.next(@table, key), prefix, budget - 1, [key | acc]),
      else: Enum.reverse(acc)
  end

  @stop ~w(the a an and or of to in on for with is it this that be as at by from)

  @doc false
  def tokens(nil), do: []

  def tokens(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.split(" ", trim: true)
    |> Enum.reject(&(&1 in @stop or String.length(&1) < 2))
    |> Enum.uniq()
  end

  # 180 characters around the first matching term — in graphemes, not bytes
  defp snippet(text, terms) do
    lower = String.downcase(text)

    idx =
      terms
      |> Enum.map(fn t ->
        case String.split(lower, t, parts: 2) do
          [before, _] -> String.length(before)
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> 0 end)

    start = max(idx - 60, 0)
    piece = String.slice(text, start, 180)

    if(start > 0, do: "…", else: "") <>
      piece <> if(start + 180 < String.length(text), do: "…", else: "")
  end
end
