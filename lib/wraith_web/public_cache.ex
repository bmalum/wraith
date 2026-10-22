defmodule WraithWeb.PublicCache do
  @moduledoc """
  HTTP caching for the public site.

  Two halves:

  * `put/2` — for controller responses (RSS, JSON feed, sitemap): an `ETag`
    derived from the newest `updated_at` among the items, a `Last-Modified`,
    and `Cache-Control: public, max-age, stale-while-revalidate`. Returns a
    304 when the client's `If-None-Match` matches, so feed readers polling
    every few minutes cost nothing.

  * the plug (`plug WraithWeb.PublicCache`) — for the LiveView pages. A dead
    render has no stable body hash, so there is no ETag, but a CDN or browser
    can still hold it briefly. Anonymous readers get `public, max-age=60,
    stale-while-revalidate=300`; anyone with a staff or member session gets
    `private, no-store`, because their page is personalised (admin links,
    paywall, comment form).

  Max-ages are short on purpose: publishing a post should show up within a
  minute without an explicit purge. Tune with `:public_cache` in config.
  """
  import Plug.Conn

  @behaviour Plug

  @defaults [page_max_age: 60, page_swr: 300, feed_max_age: 300, feed_swr: 3600]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      # Phoenix's browser pipeline already set `max-age=0, private,
      # must-revalidate`; for the public site we know better and replace it.
      # The response is still personalised by cookie (session, visitor id), so
      # any cache must key on Cookie — and a response that *sets* a cookie is
      # for this browser only, never for a shared cache.
      conn = put_resp_header(conn, "vary", "Cookie")

      if personalised?(conn) or get_resp_header(conn, "set-cookie") != [] do
        put_resp_header(conn, "cache-control", "private, no-store")
      else
        put_resp_header(
          conn,
          "cache-control",
          "public, max-age=#{opt(:page_max_age)}, stale-while-revalidate=#{opt(:page_swr)}"
        )
      end
    end)
  end

  @doc """
  Set feed caching headers from a list of items (maps with `updated_at`).
  Halts with 304 when the client already has this version.
  """
  def put(conn, items) when is_list(items) do
    newest =
      items
      |> Enum.map(& &1["updated_at"])
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    etag = ~s("#{:erlang.phash2({newest, length(items)}, 4_294_967_296)}")

    conn =
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header(
        "cache-control",
        "public, max-age=#{opt(:feed_max_age)}, stale-while-revalidate=#{opt(:feed_swr)}"
      )
      |> maybe_last_modified(newest)

    if etag in get_req_header(conn, "if-none-match") do
      conn |> send_resp(304, "") |> halt()
    else
      conn
    end
  end

  defp maybe_last_modified(conn, nil), do: conn

  defp maybe_last_modified(conn, iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        put_resp_header(conn, "last-modified", Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT"))

      _ ->
        conn
    end
  end

  defp personalised?(conn) do
    session = get_session(conn)
    is_binary(session["user_token"]) or is_binary(session["member_token"])
  end

  defp opt(key),
    do: Keyword.get(Application.get_env(:wraith, :public_cache, []), key, @defaults[key])
end
