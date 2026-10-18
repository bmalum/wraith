defmodule Wraith.Search do
  @moduledoc """
  Site search over published posts and pages, in memory: an inverted index
  in ETS keyed by word, rebuilt from the store on boot and kept fresh from
  `Wraith.Content` events. Titles weigh 5, tags 3, the excerpt 2, the body
  1; a prefix match on the last word makes search-as-you-type work.

  `search/2` returns `[%{post, score, snippet}]`, best first.
  """
  use GenServer

  @table :wraith_search
  @docs :wraith_search_docs

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
        |> Enum.flat_map(&:ets.lookup(@table, &1))
        |> Enum.concat(prefix_hits(prefix))
        |> Enum.reduce(%{}, fn {_word, id, weight}, acc ->
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

  @impl true
  def init(_opts) do
    :ets.new(@table, [:bag, :named_table, :public, read_concurrency: true])
    :ets.new(@docs, [:set, :named_table, :public, read_concurrency: true])
    Wraith.Content.subscribe()
    {:ok, %{}, {:continue, :rebuild}}
  end

  @impl true
  def handle_continue(:rebuild, state) do
    do_rebuild()
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
  def handle_info({:content, :deleted, post}, state) do
    drop(post["id"])
    {:noreply, state}
  end

  def handle_info({:content, _event, post}, state) do
    if post["status"] == "published", do: put(post), else: drop(post["id"])
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- the index ------------------------------------------------------------------

  defp do_rebuild do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@docs)
    Wraith.Content.list_posts("published", limit: 1_000).posts |> Enum.each(&put/1)
  end

  defp put(post) do
    drop(post["id"])
    text = Wraith.Markdown.to_text(post["markdown"])

    weighted =
      Enum.concat([
        tokens(post["title"]) |> Enum.map(&{&1, 5}),
        Enum.flat_map(post["tags"] || [], &tokens(&1)) |> Enum.map(&{&1, 3}),
        tokens(post["excerpt"]) |> Enum.map(&{&1, 2}),
        tokens(text) |> Enum.map(&{&1, 1})
      ])
      |> Enum.reduce(%{}, fn {w, weight}, acc -> Map.update(acc, w, weight, &(&1 + weight)) end)

    for {word, weight} <- weighted, do: :ets.insert(@table, {word, post["id"], weight})

    :ets.insert(
      @docs,
      {post["id"],
       Map.take(post, ~w(id title slug excerpt tags type published_at author_id feature_image)),
       text}
    )
  end

  defp drop(id) do
    :ets.match_delete(@table, {:_, id, :_})
    :ets.delete(@docs, id)
  end

  defp has?(word, id), do: :ets.match(@table, {word, id, :_}) != []

  defp prefix_hits(prefix) do
    # exact hits first, then any word starting with the prefix (shorter weight)
    exact = :ets.lookup(@table, prefix)

    starts =
      :ets.select(@table, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
      |> Enum.filter(fn {w, _, _} -> w != prefix and String.starts_with?(w, prefix) end)
      |> Enum.map(fn {w, id, weight} -> {w, id, weight * 0.5} end)

    exact ++ starts
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

  defp snippet(text, terms) do
    lower = String.downcase(text)

    idx =
      terms
      |> Enum.map(fn t ->
        case :binary.match(lower, t),
          do: (
            {i, _} -> i
            :nomatch -> nil
          )
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> 0 end)

    start = max(idx - 60, 0)
    piece = String.slice(text, start, 180)

    if(start > 0, do: "…", else: "") <>
      piece <> if(start + 180 < String.length(text), do: "…", else: "")
  end
end
