defmodule WraithWeb.Api.ContentController do
  @moduledoc """
  The Content API (`/api/content/*`, read-only, Content key): Ghost-shaped
  JSON for posts, pages, tags, authors, settings. Filters: `?limit=`,
  `?page=`, `?tag=`, `?author=`, `?filter=featured:true`.
  """
  use WraithWeb, :controller
  alias Wraith.{Accounts, Content, Ghost, Members}

  def posts(conn, params), do: listing(conn, params, "post")
  def pages(conn, params), do: listing(conn, params, "page")

  defp listing(conn, params, type) do
    limit = params["limit"] |> int(15) |> min(100)
    page = params["page"] |> int(1)

    %{posts: posts, has_next: has_next} =
      cond do
        tag = params["tag"] ->
          Content.page(&Content.posts_tagged(tag, &1), page, limit)

        author = params["author"] ->
          author_posts(author, page, limit)

        true ->
          Content.page(
            &Content.list_posts("published", Keyword.put(&1, :type, type)),
            page,
            limit
          )
      end

    posts = posts |> Enum.filter(&(&1["type"] == type)) |> apply_filter(params["filter"])

    json(conn, %{
      "posts" => Enum.map(posts, &Ghost.post_json(&1, ctx())),
      "meta" => %{
        "pagination" => %{"page" => page, "limit" => limit, "next" => if(has_next, do: page + 1)}
      }
    })
  end

  defp author_posts(slug, page, limit) do
    case Accounts.get_user_by_slug(slug) do
      nil -> %{posts: [], has_next: false}
      u -> Content.page(&Content.posts_by_author(u["id"], &1), page, limit)
    end
  end

  def post(conn, %{"slug" => slug}) do
    case Content.get_published(slug) || (uuid?(slug) && Content.get_post(slug)) do
      %{"status" => "published", "visibility" => "public"} = p ->
        json(conn, %{"posts" => [Ghost.post_json(p, ctx())]})

      %{"status" => "published"} = p ->
        json(conn, %{
          "posts" => [
            p |> Ghost.post_json(Keyword.put(ctx(), :html, false)) |> Map.put("access", false)
          ]
        })

      _ ->
        not_found(conn, "post")
    end
  end

  def tags(conn, _params),
    do: json(conn, %{"tags" => Content.list_tags() |> Enum.map(&Ghost.tag_json/1)})

  def tag(conn, %{"slug" => slug}) do
    case Content.get_tag(slug) do
      nil -> not_found(conn, "tag")
      t -> json(conn, %{"tags" => [Ghost.tag_json(t)]})
    end
  end

  def authors(conn, _params),
    do:
      json(conn, %{
        "authors" =>
          Accounts.list_users() |> Enum.map(&(&1 |> Ghost.author_json() |> Map.delete("email")))
      })

  def author(conn, %{"slug" => slug}) do
    case Accounts.get_user_by_slug(slug) do
      nil -> not_found(conn, "author")
      u -> json(conn, %{"authors" => [u |> Ghost.author_json() |> Map.delete("email")]})
    end
  end

  def settings(conn, _params), do: json(conn, %{"settings" => Ghost.settings_json()})

  def members_count(conn, _params), do: json(conn, %{"members" => %{"total" => Members.count()}})

  # ---- helpers -----------------------------------------------------------------------

  # authors in public JSON never carry their email
  defp ctx,
    do: [
      authors: Accounts.list_users() |> Map.new(&{&1["id"], Map.delete(&1, "email")}),
      tags: Content.list_tags() |> Map.new(&{&1["slug"], &1})
    ]

  defp apply_filter(posts, "featured:true"), do: Enum.filter(posts, &(&1["featured"] == true))

  defp apply_filter(posts, "visibility:public"),
    do: Enum.filter(posts, &(&1["visibility"] == "public"))

  defp apply_filter(posts, _), do: posts

  defp int(nil, d), do: d

  defp int(v, d) do
    case Integer.parse(to_string(v)) do
      {n, _} when n > 0 -> n
      _ -> d
    end
  end

  defp uuid?(s), do: Regex.match?(~r/^[0-9a-f-]{36}$/, s)

  defp not_found(conn, what),
    do:
      conn
      |> put_status(404)
      |> json(%{"errors" => [%{"message" => "#{what} not found", "type" => "NotFoundError"}]})
end
