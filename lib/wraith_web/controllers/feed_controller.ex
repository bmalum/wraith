defmodule WraithWeb.FeedController do
  use WraithWeb, :controller

  alias Wraith.{Accounts, Content, Markdown, Settings}

  def rss(conn, params) do
    site = Settings.get()

    {posts, title} =
      cond do
        tag = params["tag"] ->
          t = Content.get_tag(tag) || %{"name" => tag}
          {Content.posts_tagged(tag, limit: 20).posts, "#{site["title"]} · #{t["name"]}"}

        slug = params["author"] ->
          case Accounts.get_user_by_slug(slug) do
            nil ->
              {[], site["title"]}

            u ->
              {Content.posts_by_author(u["id"], limit: 20).posts,
               "#{site["title"]} · #{u["name"]}"}
          end

        true ->
          {Content.list_posts("published", limit: 20, type: "post").posts, site["title"]}
      end

    site = Map.put(site, "title", title)
    authors = Accounts.list_users() |> Map.new(&{&1["id"], &1})
    base = url(~p"/")

    items =
      for p <- posts do
        author = authors[p["author_id"]]

        """
            <item>
              <title>#{x(p["title"])}</title>
              <link>#{base}#{p["slug"]}</link>
              <guid isPermaLink="true">#{base}#{p["slug"]}</guid>
              <pubDate>#{rfc822(p["published_at"])}</pubDate>
              #{if author, do: "<dc:creator>#{x(author["name"])}</dc:creator>", else: ""}
              #{Enum.map_join(p["tags"] || [], "\n          ", &"<category>#{x(&1)}</category>")}
              <description>#{x(p["excerpt"])}</description>
              <content:encoded><![CDATA[#{body_html(p)}]]></content:encoded>
            </item>
        """
      end

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:atom="http://www.w3.org/2005/Atom">
      <channel>
        <title>#{x(site["title"])}</title>
        <link>#{base}</link>
        <description>#{x(site["description"])}</description>
        <language>#{x(site["lang"])}</language>
        <atom:link href="#{base}rss" rel="self" type="application/rss+xml" />
        <generator>Wraith</generator>
    #{items}
      </channel>
    </rss>
    """

    conn |> put_resp_content_type("application/rss+xml") |> send_resp(200, xml)
  end

  def json(conn, _params) do
    site = Settings.get()
    posts = Content.list_posts("published", limit: 20, type: "post").posts
    authors = Accounts.list_users() |> Map.new(&{&1["id"], &1})
    base = url(~p"/")

    feed = %{
      version: "https://jsonfeed.org/version/1.1",
      title: site["title"],
      home_page_url: base,
      feed_url: base <> "feed.json",
      description: site["description"],
      items:
        for p <- posts do
          author = authors[p["author_id"]]

          %{
            id: p["id"],
            url: base <> p["slug"],
            title: p["title"],
            content_html: body_html(p),
            summary: p["excerpt"],
            date_published: p["published_at"],
            tags: p["tags"],
            authors: if(author, do: [%{name: author["name"]}], else: [])
          }
        end
    }

    conn |> put_resp_content_type("application/feed+json") |> send_resp(200, Jason.encode!(feed))
  end

  def sitemap(conn, _params) do
    base = url(~p"/")
    posts = Content.list_posts("published", limit: 500).posts

    urls =
      [~s(<url><loc>#{base}</loc></url>)] ++
        Enum.map(
          posts,
          &~s(<url><loc>#{base}#{&1["slug"]}</loc><lastmod>#{&1["updated_at"]}</lastmod></url>)
        ) ++
        Enum.map(Content.list_tags(), &~s(<url><loc>#{base}tag/#{&1["slug"]}</loc></url>))

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{Enum.join(urls, "\n")}
    </urlset>
    """

    conn |> put_resp_content_type("application/xml") |> send_resp(200, xml)
  end

  # feeds get the HTML with widgets replaced by a pointer to the live page
  defp body_html(post) do
    post["markdown"]
    |> Markdown.segments(post["id"])
    |> Enum.map_join("\n", fn
      {:html, html} ->
        html

      {:widget, slug, _, _} ->
        ~s(<p><em>[Interactive #{x(slug)} — <a href="#{url(~p"/#{post["slug"]}")}">open the post</a>]</em></p>)
    end)
  end

  defp x(nil), do: ""
  defp x(s), do: s |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp rfc822(iso) do
    case DateTime.from_iso8601(to_string(iso)) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S +0000")
      _ -> ""
    end
  end
end
