defmodule Wraith.Comments do
  @moduledoc """
  Members comment on posts; one level of replies. A comment is
  `id`, `post_id`, `member_id`, `member_name`, `parent_id`, `body` (plain
  text, rendered with line breaks), `status` (`"published" | "hidden"`),
  `created_at`. Comments live under the post (`POST#id` / `COMMENT#<at>#<id>`)
  so a page is one query; the index `COMMENTS#<status>` feeds admin
  moderation. Changes broadcast `{:comments, post_id}` on `"comments:<post_id>"`.
  """
  alias Wraith.{Settings, Store}
  alias Wraith.Store.Keys

  @max_len 4_000

  def enabled?, do: Settings.get()["comments_enabled"] == true

  def topic(post_id), do: "comments:" <> post_id
  def subscribe(post_id), do: Phoenix.PubSub.subscribe(Wraith.PubSub, topic(post_id))

  defp broadcast(post_id),
    do: Phoenix.PubSub.broadcast(Wraith.PubSub, topic(post_id), {:comments, post_id})

  @doc "Published comments of a post, oldest first, as a tree: `[%{comment, replies: [...]}]`."
  def for_post(post_id, opts \\ []) do
    all = Store.all("POST#" <> post_id, begins_with: Keys.comments_prefix())

    all =
      if opts[:include_hidden], do: all, else: Enum.filter(all, &(&1["status"] == "published"))

    {roots, replies} = Enum.split_with(all, &is_nil(&1["parent_id"]))
    by_parent = Enum.group_by(replies, & &1["parent_id"])
    Enum.map(roots, &%{comment: &1, replies: Map.get(by_parent, &1["id"], [])})
  end

  def count(post_id),
    do: for_post(post_id) |> Enum.reduce(0, fn %{replies: r}, n -> n + 1 + length(r) end)

  def get(post_id, id) do
    Store.all("POST#" <> post_id, begins_with: Keys.comments_prefix())
    |> Enum.find(&(&1["id"] == id))
  end

  @doc "A member posts a comment (or a reply with `parent_id`)."
  @spec create(map(), map(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, String.t()}
  def create(post, member, body, parent_id \\ nil)

  def create(
        %{"id" => post_id, "status" => "published"} = post,
        %{"id" => member_id} = member,
        body,
        parent_id
      ) do
    body = body |> to_string() |> String.trim()

    cond do
      not enabled?() ->
        {:error, "comments are off"}

      body == "" ->
        {:error, "say something"}

      String.length(body) > @max_len ->
        {:error, "that is too long (#{@max_len} characters)"}

      not Wraith.Members.can_read?(member, post["visibility"]) ->
        {:error, "only members who can read the post may comment"}

      parent_id && is_nil(get(post_id, parent_id)) ->
        {:error, "that comment is gone"}

      parent_id && not is_nil(parent_of(post_id, parent_id)) ->
        {:error, "replies go one level deep"}

      true ->
        id = Store.id()
        now = Store.now()
        {pk, sk} = Keys.comment(post_id, now <> "#" <> id)

        item = %{
          "pk" => pk,
          "sk" => sk,
          "gsi1pk" => Keys.comments_index("published"),
          "gsi1sk" => now <> "#" <> id,
          "id" => id,
          "post_id" => post_id,
          "post_title" => post["title"],
          "post_slug" => post["slug"],
          "member_id" => member_id,
          "member_name" => display_name(member),
          "parent_id" => parent_id,
          "body" => body,
          "status" => "published"
        }

        :ok = Store.put(item)
        broadcast(post_id)
        if parent_id, do: notify_parent(post, item, parent_id)
        {:ok, Store.get(pk, sk) |> elem(1)}
    end
  end

  def create(_post, _member, _body, _parent),
    do: {:error, "comments are only open on published posts"}

  # the author of the parent comment hears about a reply by mail (not when replying to themselves)
  defp notify_parent(post, reply, parent_id) do
    with %{"member_id" => mid} <- get(post["id"], parent_id),
         true <- mid != reply["member_id"],
         %{} = parent_member <- Wraith.Members.get(mid) do
      Wraith.Newsletter.send_reply_notice(parent_member, post, reply)
    else
      _ -> :ok
    end
  end

  defp parent_of(post_id, id), do: get(post_id, id) |> then(&(&1 && &1["parent_id"]))

  @doc "Hide (moderate) or show a comment."
  def set_status(%{"pk" => pk, "sk" => sk, "post_id" => post_id} = _c, status)
      when status in ["published", "hidden"] do
    {:ok, c} =
      Store.update(
        pk,
        sk,
        &Map.merge(&1, %{"status" => status, "gsi1pk" => Keys.comments_index(status)})
      )

    broadcast(post_id)
    {:ok, c}
  end

  @doc "A member removes their own comment (or an author removes any): the text goes, the slot stays for replies."
  def delete(%{"pk" => pk, "sk" => sk, "post_id" => post_id} = c) do
    if for_post(post_id, include_hidden: true)
       |> Enum.any?(&(&1.comment["id"] == c["id"] and &1.replies != [])) do
      # the text goes; the comment stays published so its replies keep their place
      {:ok, _} = Store.update(pk, sk, &Map.put(&1, "body", ""))
    else
      Store.delete(pk, sk)
    end

    broadcast(post_id)
    :ok
  end

  @doc "Every comment a member wrote (any status)."
  def by_member(member_id) do
    (recent("published", 10_000) ++ recent("hidden", 10_000))
    |> Enum.filter(&(&1["member_id"] == member_id))
  end

  @doc "Newest comments across the site, for moderation."
  def recent(status \\ "published", limit \\ 50) do
    {:ok, %{items: items}} =
      Store.query(Keys.comments_index(status), index: :gsi1, forward: false, limit: limit)

    items
  end

  defp display_name(%{"name" => n}) when is_binary(n) and n != "", do: n
  defp display_name(%{"email" => e}), do: e |> String.split("@") |> hd()
end
