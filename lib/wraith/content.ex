defmodule Wraith.Content do
  @moduledoc """
  Posts and pages, their tags and revisions.

  A post is a map: `id`, `type` (`"post" | "page"`), `title`, `slug`,
  `markdown`, `excerpt`, `status` (`"draft" | "scheduled" | "published"`),
  `visibility` (`"public" | "members"`), `featured`, `tags` (slugs),
  `author_id`, `published_at`, `feature_image`, `meta_title`,
  `meta_description`, `sort_at`.

  Layout (see `Wraith.Store.Keys`): the post item sits on the index under
  `POSTS#<status>` sorted by `sort_at` (published_at once published,
  updated_at while a draft); a slug item makes slugs unique; published
  posts also have one membership item per tag and one under their author,
  so tag/author pages are a single query. Every save writes a revision.

  `publish_due/0` flips scheduled posts whose time has come; `Wraith.Clock`
  calls it every minute.
  """
  alias Wraith.Store
  alias Wraith.Store.Keys
  alias Wraith.Slug
  alias Wraith.Markdown

  @statuses ~w(draft scheduled published)
  @types ~w(post page)
  @visibilities ~w(public members paid)
  @fields ~w(type title slug markdown custom_excerpt status visibility featured tags author_id authors published_at feature_image feature_image_alt feature_image_width feature_image_height canonical_url og_image meta_title meta_description show_toc noindex unpublish_at send_on_publish)
  @max_revisions 30

  @topic "content"
  def subscribe, do: Phoenix.PubSub.subscribe(Wraith.PubSub, @topic)

  defp broadcast(event, post),
    do: Phoenix.PubSub.broadcast(Wraith.PubSub, @topic, {:content, event, post})

  # ---- reads ----------------------------------------------------------------------

  def get_post(id) when is_binary(id) do
    {pk, sk} = Keys.post(id)

    case Store.get(pk, sk) do
      {:ok, p} -> p
      :error -> nil
    end
  end

  def get_post_by_slug(slug) when is_binary(slug) do
    {pk, sk} = Keys.post_slug(slug)

    case Store.get(pk, sk) do
      {:ok, %{"post_id" => id}} -> get_post(id)
      :error -> nil
    end
  end

  @doc "A published post or page by slug — what the public may read."
  def get_published(slug) do
    case get_post_by_slug(slug) do
      %{"status" => "published"} = p -> p
      _ -> nil
    end
  end

  # ---- the paywall --------------------------------------------------------------------

  @doc """
  The markdown a reader may see: the whole thing for public posts (and for a
  reader with access), only the part above `<!--members-only-->` otherwise.
  Every public-facing renderer — the page, feeds, the Content API, the search
  index — goes through here, so the paywall has exactly one definition.

  `access?` is the caller's answer to `Wraith.Members.can_read?/2` (or staff).
  """
  @spec readable_markdown(map(), boolean()) :: String.t()
  def readable_markdown(post, access? \\ false)

  def readable_markdown(%{"visibility" => v, "markdown" => md}, access?)
      when v in ["members", "paid"] and access? != true,
      do: Markdown.public_preview(md) || ""

  def readable_markdown(%{"markdown" => md}, _access?), do: Markdown.strip_paywall(md || "")

  @doc "Is the post gated at all?"
  def gated?(%{"visibility" => v}), do: v in ["members", "paid"]
  def gated?(_), do: false

  # ---- preview links ----------------------------------------------------------------

  @doc """
  A shareable preview link's token for `post`, minted on first ask and then
  stable, so a reviewer who isn't staff can read a draft at `/preview/<token>`.
  The token is random (128 bits) and never derived from the post.
  """
  @spec preview_token(map()) :: {:ok, String.t()} | {:error, term()}
  def preview_token(%{"id" => id}) do
    {pk, sk} = Keys.post(id)
    fresh = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    # Idempotent and race-free: the post is the single source of truth. The
    # update keeps whatever token is already there (two tabs, editor + MCP),
    # so exactly one token ever exists per post; only then is the pointer
    # written. A crash between the two leaves a token with no pointer — a
    # dead link, which is the harmless direction.
    with {:ok, post} <-
           Store.update(pk, sk, fn
             %{"preview_token" => t} = p when is_binary(t) and t != "" -> p
             p -> Map.put(p, "preview_token", fresh)
           end),
         token = post["preview_token"],
         {ppk, psk} = Keys.post_preview(token),
         :ok <- ensure_pointer(ppk, psk, id) do
      {:ok, token}
    end
  end

  defp ensure_pointer(ppk, psk, post_id) do
    case Store.transact([
           {:put, %{"pk" => ppk, "sk" => psk, "post_id" => post_id}, condition: :not_exists}
         ]) do
      :ok -> :ok
      # already there from an earlier mint — fine
      {:error, :exists} -> :ok
      other -> other
    end
  end

  @doc "Revoke a post's preview link: the pointer is deleted and the post forgets the token."
  @spec revoke_preview(map()) :: :ok
  def revoke_preview(%{"id" => id} = post) do
    if token = post["preview_token"] do
      {ppk, psk} = Keys.post_preview(token)
      Store.delete(ppk, psk)
    end

    {pk, sk} = Keys.post(id)
    _ = Store.update(pk, sk, &Map.delete(&1, "preview_token"))
    :ok
  end

  @doc "The post behind a preview token, whatever its status; nil when unknown."
  def get_by_preview_token(token) when is_binary(token) and token != "" do
    {pk, sk} = Keys.post_preview(token)

    case Store.get(pk, sk) do
      {:ok, %{"post_id" => id}} -> get_post(id)
      :error -> nil
    end
  end

  def get_by_preview_token(_), do: nil

  @doc """
  Posts of one status, newest first, paged. Options: `type:` (`"post"`,
  `"page"`, default both), `limit:`, `cursor:`, `featured: true`.
  Returns `%{posts, next}`.
  """
  def list_posts(status \\ "published", opts \\ []) when status in @statuses do
    limit = Keyword.get(opts, :limit, 20)

    {:ok, %{items: items, next: next}} =
      Store.query(Keys.posts_index(status),
        index: :gsi1,
        forward: false,
        limit: limit,
        start_key: opts[:cursor]
      )

    posts =
      items
      |> Enum.filter(&(is_nil(opts[:type]) or &1["type"] == opts[:type]))
      |> Enum.filter(&(not Keyword.get(opts, :featured, false) or &1["featured"] == true))

    %{posts: posts, next: next}
  end

  @doc """
  Page `n` (1-based) of a cursor-paged listing. `fetch` is a function of
  `[limit:, cursor:]` returning `%{posts, next}` (any of the listings
  above); cursors are walked from the start, which is fine for a blog.
  Returns `%{posts, page, has_next}`.
  """
  def page(fetch, n, per_page) when is_function(fetch, 1) and n >= 1 do
    Enum.reduce_while(1..n, {nil, nil}, fn i, {_result, cursor} ->
      result = fetch.(limit: per_page, cursor: cursor)

      cond do
        i == n -> {:halt, {result, nil}}
        is_nil(result.next) -> {:halt, {%{posts: [], next: nil}, nil}}
        true -> {:cont, {result, result.next}}
      end
    end)
    |> then(fn {%{posts: posts, next: next}, _} ->
      %{posts: posts, page: n, has_next: not is_nil(next)}
    end)
  end

  @doc "Every post of every status for the admin list, newest activity first."
  def list_all_posts(opts \\ []) do
    @statuses
    |> Enum.flat_map(&Store.all(Keys.posts_index(&1), index: :gsi1))
    |> Enum.filter(&(is_nil(opts[:type]) or &1["type"] == opts[:type]))
    |> Enum.sort_by(& &1["updated_at"], :desc)
  end

  def count_posts(status), do: Store.all(Keys.posts_index(status), index: :gsi1) |> length()

  @doc "Published posts carrying a tag, newest first."
  def posts_tagged(tag_slug, opts \\ []) do
    {:ok, %{items: items, next: next}} =
      Store.query("TAG#" <> tag_slug,
        begins_with: Keys.tag_posts_prefix(),
        forward: false,
        limit: Keyword.get(opts, :limit, 20),
        start_key: opts[:cursor]
      )

    %{posts: hydrate(items), next: next}
  end

  @doc "Published posts by an author, newest first."
  def posts_by_author(user_id, opts \\ []) do
    {:ok, %{items: items, next: next}} =
      Store.query(Keys.author_posts_pk(user_id),
        begins_with: "POST#",
        forward: false,
        limit: Keyword.get(opts, :limit, 20),
        start_key: opts[:cursor]
      )

    %{posts: hydrate(items), next: next}
  end

  # membership items carry only the post id; fetch the posts in one batch
  defp hydrate(items) do
    ids = Enum.map(items, & &1["post_id"])
    {:ok, posts} = Store.batch_get(Enum.map(ids, &Keys.post/1))
    by_id = Map.new(posts, &{&1["id"], &1})

    ids
    |> Enum.map(&by_id[&1])
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(&1["status"] == "published"))
  end

  @doc "Published posts sharing the most tags with this one (then the newest), up to `n`."
  def related(%{"id" => id, "tags" => tags}, n \\ 3) do
    tags
    |> Enum.flat_map(&posts_tagged(&1, limit: 20).posts)
    |> Enum.reject(&(&1["id"] == id))
    |> Enum.group_by(& &1["id"])
    |> Enum.map(fn {_id, [p | _] = dups} -> {length(dups), p} end)
    |> Enum.sort_by(fn {shared, p} -> {-shared, p["published_at"] || ""} end, fn {a, pa},
                                                                                 {b, pb} ->
      {a, pa} <= {b, pb}
    end)
    |> Enum.map(&elem(&1, 1))
    |> then(fn list ->
      list = Enum.take(list, n)
      # fill up with the newest posts when tags are thin
      if length(list) < n do
        extra =
          list_posts("published", limit: n + 5, type: "post").posts
          |> Enum.reject(&(&1["id"] == id or &1["id"] in Enum.map(list, fn p -> p["id"] end)))

        list ++ Enum.take(extra, n - length(list))
      else
        list
      end
    end)
  end

  def revisions(post_id) do
    Store.all("POST#" <> post_id, begins_with: Keys.post_revisions_prefix(), forward: false)
  end

  # ---- writes -------------------------------------------------------------------

  @doc "A new draft. `attrs` may carry any post field; `author_id` is required."
  @spec create_post(map()) :: {:ok, map()} | {:error, map()}
  def create_post(attrs) do
    attrs = stringify(attrs)
    id = Store.id()
    {pk, sk} = Keys.post(id)

    base = %{
      "pk" => pk,
      "sk" => sk,
      "id" => id,
      "type" => "post",
      "title" => "",
      "slug" => nil,
      "markdown" => "",
      "excerpt" => "",
      "status" => "draft",
      "visibility" => "public",
      "featured" => false,
      "tags" => [],
      "author_id" => nil,
      "published_at" => nil,
      "feature_image" => nil,
      "feature_image_alt" => nil,
      "canonical_url" => nil,
      "og_image" => nil,
      "meta_title" => nil,
      "meta_description" => nil,
      "authors" => [],
      "show_toc" => false
    }

    save(nil, base |> Map.merge(Map.take(attrs, @fields)) |> lock_slug(attrs))
  end

  @doc "Change fields on a post; the slug and the index items follow."
  @spec update_post(map() | String.t(), map()) :: {:ok, map()} | {:error, map()}
  def update_post(%{"id" => _} = post, attrs) do
    attrs = stringify(attrs)
    save(post, post |> Map.merge(Map.take(attrs, @fields)) |> lock_slug(attrs))
  end

  def update_post(id, attrs) when is_binary(id),
    do:
      with(
        %{} = p <- get_post(id) || {:error, %{"base" => "not found"}},
        do: update_post(p, attrs)
      )

  # an explicit, non-empty slug pins it; an emptied one lets the title take over again
  defp lock_slug(post, %{"slug" => s}) when is_binary(s) and s != "",
    do: Map.put(post, "slug_locked", true)

  defp lock_slug(post, %{"slug" => _}), do: Map.put(post, "slug_locked", false)
  defp lock_slug(post, _attrs), do: post

  @doc "Publish now (or at `at`, which schedules it)."
  def publish_post(post, at \\ nil)

  def publish_post(%{} = post, nil) do
    # a draft's preview link stops working the moment the post is live —
    # from here on the paywall decides who reads it. Re-read afterwards so the
    # publish is conditioned on the version the revoke produced.
    revoke_preview(post)
    post = get_post(post["id"]) || post

    update_post(post, %{
      "status" => "published",
      "published_at" => post["published_at"] || Store.now()
    })
  end

  def publish_post(%{} = post, %DateTime{} = at) do
    if DateTime.compare(at, DateTime.utc_now()) == :gt,
      do: update_post(post, %{"status" => "scheduled", "published_at" => iso(at)}),
      else: update_post(post, %{"status" => "published", "published_at" => iso(at)})
  end

  def unpublish_post(%{} = post), do: update_post(post, %{"status" => "draft"})

  def delete_post(%{"id" => id} = post) do
    {pk, sk} = Keys.post(id)

    preview_ops =
      case post["preview_token"] do
        t when is_binary(t) and t != "" -> [{:delete, elem(Keys.post_preview(t), 0), "POST"}]
        _ -> []
      end

    ops =
      [{:delete, pk, sk}] ++
        slug_ops(post, nil) ++
        preview_ops ++
        for({tpk, tsk} <- membership_keys(post), do: {:delete, tpk, tsk}) ++
        for(r <- revisions(id), do: {:delete, r["pk"], r["sk"]})

    # DynamoDB caps a transaction at 100 items; revisions beyond that go separately
    {first, rest} = Enum.split(ops, 100)
    :ok = Store.transact(first)
    Enum.each(rest, fn {:delete, p, s} -> Store.delete(p, s) end)
    broadcast(:deleted, post)
    :ok
  end

  def delete_post(id) when is_binary(id), do: if(p = get_post(id), do: delete_post(p), else: :ok)

  @doc """
  Scheduled posts whose time has come are published (and mailed when
  `send_on_publish`); published posts past their `unpublish_at` go back to
  draft. Returns how many changed.
  """
  def publish_due do
    now = Store.now()

    published =
      list_posts("scheduled", limit: 100).posts
      |> Enum.filter(&(&1["published_at"] && &1["published_at"] <= now))
      |> Enum.map(fn p ->
        with {:ok, p} <- update_post(p, %{"status" => "published"}) do
          if p["send_on_publish"], do: Wraith.Newsletter.send_post(p)
          {:ok, p}
        end
      end)
      |> Enum.count(&match?({:ok, _}, &1))

    unpublished =
      list_posts("published", limit: 500).posts
      |> Enum.filter(&(&1["unpublish_at"] && &1["unpublish_at"] <= now))
      |> Enum.map(&update_post(&1, %{"status" => "draft", "unpublish_at" => nil}))
      |> Enum.count(&match?({:ok, _}, &1))

    published + unpublished
  end

  @doc "Publish now; when the post asks for it, mail it too."
  def publish_and_send(post) do
    with {:ok, p} <- publish_post(post) do
      if p["send_on_publish"], do: Wraith.Newsletter.send_post(p)
      {:ok, p}
    end
  end

  @doc "Words in the body, for the editor."
  def word_count(markdown),
    do: markdown |> Wraith.Markdown.to_text() |> String.split(~r/\s+/, trim: true) |> length()

  # the one save path: validate, derive, write post + slug + memberships + revision atomically
  defp save(previous, post) do
    post = normalize(post)

    case validate(post) do
      errors when map_size(errors) > 0 ->
        {:error, errors}

      _ ->
        post = derive(post)

        # Optimistic concurrency: the put is conditioned on the version the
        # caller started from. Two editors saving the same post can't silently
        # overwrite each other, and the slug/tag/author pointer diffs below —
        # computed against `previous` — can never be applied on top of a
        # snapshot that is no longer current (which left orphan pointers).
        put =
          case previous do
            %{"version" => v} when is_integer(v) -> {:put, post, condition: {:version, v}}
            nil -> {:put, post, condition: :not_exists}
            _ -> {:put, post}
          end

        ops =
          [put] ++
            slug_ops(previous, post) ++
            membership_ops(previous, post) ++
            revision_ops(previous, post)

        case Store.transact(ops) do
          :ok ->
            saved = get_post(post["id"])
            # only tags that are new to this post need ensuring
            new_tags = (post["tags"] || []) -- ((previous && previous["tags"]) || [])
            Enum.each(new_tags, &ensure_tag/1)
            if revision_ops(previous, post) != [], do: trim_revisions(post["id"])
            broadcast(if(previous, do: :updated, else: :created), saved)
            {:ok, saved}

          # the post itself moved on since we read it
          {:error, :conflict} ->
            {:error, %{"base" => "this post was changed by someone else — reload and try again"}}

          # a slug pointer (or, on create, the post id) already exists
          {:error, :exists} ->
            {:error, %{"slug" => "is already taken"}}

          {:error, e} ->
            {:error, %{"base" => inspect(e)}}
        end
    end
  end

  defp derive(post) do
    # the slug follows the title until the author sets one by hand (`slug_locked`)
    slug =
      cond do
        post["slug_locked"] == true and is_binary(post["slug"]) and post["slug"] != "" ->
          if Slug.valid?(post["slug"]), do: post["slug"], else: Slug.slugify(post["slug"])

        post["title"] == "" ->
          "draft-" <> String.slice(post["id"], -8, 8)

        true ->
          Slug.slugify(post["title"])
      end

    published_at =
      if post["status"] in ["published", "scheduled"],
        do: post["published_at"] || Store.now(),
        else: post["published_at"]

    sort_at = if post["status"] == "draft", do: Store.now(), else: published_at

    # `custom_excerpt` is the author's own; `excerpt` always has something for cards and feeds
    custom =
      if is_binary(post["custom_excerpt"]) and post["custom_excerpt"] != "",
        do: post["custom_excerpt"],
        else: nil

    excerpt = custom || auto_excerpt(post["markdown"])

    post
    |> Map.put("slug", slug)
    |> Map.put("published_at", published_at)
    |> Map.put("sort_at", sort_at)
    |> Map.put("excerpt", excerpt)
    |> Map.put("custom_excerpt", custom)
    |> Map.put("gsi1pk", Keys.posts_index(post["status"]))
    |> Map.put("gsi1sk", Keys.post_sort(sort_at, post["id"]))
  end

  defp normalize(post) do
    tags =
      post["tags"]
      |> List.wrap()
      |> Enum.flat_map(&if(is_binary(&1), do: String.split(&1, ","), else: [&1]))
      |> Enum.map(&(&1 |> to_string() |> String.trim()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&Slug.slugify/1)
      |> Enum.uniq()

    # co-authors: the primary author first, then the rest, no duplicates
    authors =
      [
        post["author_id"]
        | List.wrap(post["authors"])
          |> Enum.flat_map(&if(is_binary(&1), do: String.split(&1, ","), else: [&1]))
      ]
      |> Enum.map(&(&1 && String.trim(to_string(&1))))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    post
    |> Map.put("tags", tags)
    |> Map.put("authors", authors)
    |> Map.put("show_toc", post["show_toc"] in [true, "true", "on"])
    |> Map.put("noindex", post["noindex"] in [true, "true", "on"])
    |> Map.put("send_on_publish", post["send_on_publish"] in [true, "true", "on"])
    |> Map.update("unpublish_at", nil, &if(&1 in [nil, ""], do: nil, else: &1))
    |> Map.put("featured", post["featured"] in [true, "true", "on"])
    |> Map.put("title", to_string(post["title"]))
    |> Map.put("markdown", to_string(post["markdown"]))
  end

  defp validate(post) do
    %{}
    |> put_error("title", post["title"] == "" and post["status"] != "draft", "can't be blank")
    |> put_error("status", post["status"] not in @statuses, "is unknown")
    |> put_error("type", post["type"] not in @types, "is unknown")
    |> put_error("visibility", post["visibility"] not in @visibilities, "is unknown")
    |> put_error("author_id", not is_binary(post["author_id"]), "is required")
  end

  # slug item moves with the slug; a new slug must be free
  defp slug_ops(previous, post) do
    old = previous && previous["slug"]
    new = post && post["slug"]

    cond do
      old == new -> []
      is_nil(new) -> [{:delete, elem(Keys.post_slug(old), 0), "POST"}]
      is_nil(old) -> [slug_put(post)]
      true -> [{:delete, elem(Keys.post_slug(old), 0), "POST"}, slug_put(post)]
    end
  end

  defp slug_put(post) do
    {pk, sk} = Keys.post_slug(post["slug"])
    {:put, %{"pk" => pk, "sk" => sk, "post_id" => post["id"]}, condition: :not_exists}
  end

  # tag/author memberships exist only for published posts
  defp membership_ops(previous, post) do
    old = if previous, do: membership_keys(previous), else: []
    new = membership_keys(post)

    for({pk, sk} <- old -- new, do: {:delete, pk, sk}) ++
      for({pk, sk} <- new, do: {:put, %{"pk" => pk, "sk" => sk, "post_id" => post["id"]}})
  end

  defp membership_keys(%{"status" => "published", "type" => "post"} = post) do
    sort = post["sort_at"]
    id = post["id"]

    Enum.map(post["tags"] || [], &Keys.tag_post(&1, sort, id)) ++
      Enum.map(post["authors"] || List.wrap(post["author_id"]), &Keys.author_post(&1, sort, id))
  end

  defp membership_keys(_), do: []

  defp revision_ops(previous, post) do
    if previous && previous["markdown"] == post["markdown"] && previous["title"] == post["title"] do
      []
    else
      # the post's version makes two saves in one millisecond distinct revisions
      {pk, sk} =
        Keys.post_revision(
          post["id"],
          Store.now() <> "#" <> Keys.pad((previous && previous["version"]) || 0)
        )

      [
        {:put,
         %{
           "pk" => pk,
           "sk" => sk,
           "title" => post["title"],
           "markdown" => post["markdown"],
           "author_id" => post["author_id"]
         }}
      ]
    end
  end

  defp trim_revisions(id) do
    id |> revisions() |> Enum.drop(@max_revisions) |> Enum.each(&Store.delete(&1["pk"], &1["sk"]))
  end

  # the excerpt never reveals what is behind the paywall marker
  defp auto_excerpt(markdown) do
    markdown = to_string(markdown)

    (Wraith.Markdown.public_preview(markdown) || markdown)
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r/\{\{.*?\}\}/s, "")
    |> String.replace(~r/[#>*_`\[\]()!-]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(40)
    |> Enum.join(" ")
  end

  # ---- tags -------------------------------------------------------------------------

  def list_tags, do: Store.all(Keys.tags_index(), index: :gsi1)

  def get_tag(slug) do
    {pk, sk} = Keys.tag(slug)

    case Store.get(pk, sk) do
      {:ok, t} -> t
      :error -> nil
    end
  end

  @doc "Make sure a tag item exists for the slug (named after it unless told otherwise)."
  def ensure_tag(slug, attrs \\ %{}) do
    {pk, sk} = Keys.tag(slug)
    attrs = stringify(attrs)

    Store.update(pk, sk, fn current ->
      base =
        current ||
          %{
            "slug" => slug,
            "name" => humanize(slug),
            "description" => "",
            "gsi1pk" => Keys.tags_index()
          }

      base
      |> Map.merge(Map.take(attrs, ~w(name description accent)))
      |> then(&Map.put(&1, "gsi1sk", &1["name"]))
    end)
  end

  def update_tag(slug, attrs), do: ensure_tag(slug, attrs)

  def delete_tag(slug) do
    {pk, sk} = Keys.tag(slug)
    Store.delete(pk, sk)
  end

  def tag_counts do
    list_tags()
    |> Map.new(fn t ->
      {:ok, %{items: items}} =
        Store.query("TAG#" <> t["slug"], begins_with: Keys.tag_posts_prefix())

      {t["slug"], length(items)}
    end)
  end

  defp humanize(slug), do: slug |> String.replace("-", " ") |> String.capitalize()

  # ---- helpers ----------------------------------------------------------------------

  def statuses, do: @statuses

  defp iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp put_error(errors, _k, false, _msg), do: errors
  defp put_error(errors, k, true, msg), do: Map.put(errors, k, msg)

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
