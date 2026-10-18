defmodule Wraith.Ghost do
  @moduledoc """
  Ghost's shapes, both ways.

  `post_json/2`, `author_json/1`, `tag_json/1` render our items the way
  Ghost's Content API does (`html`, `feature_image`, `primary_author`,
  `tags`, `reading_time`, …) so clients written for Ghost mostly work.

  `export/0` writes a Ghost-compatible export (`db[0].data.{posts, tags,
  posts_tags, users, posts_authors, settings}` plus Wraith's own `widgets`
  and `members`); `import/2` reads one — Ghost's own export JSON or ours —
  and creates what is missing: users (with a random password, to be reset),
  tags, posts (Ghost's `html`/`lexical`/`mobiledoc` bodies are turned into
  Markdown when they are plain HTML; `plaintext` otherwise), members.
  """
  alias Wraith.{Accounts, Content, Markdown, Members, Settings, Widgets}

  # ---- rendering ----------------------------------------------------------------------

  def post_json(post, opts \\ []) do
    authors = Keyword.get(opts, :authors, %{})
    tags = Keyword.get(opts, :tags, %{})
    base = WraithWeb.Endpoint.url()

    people =
      (post["authors"] || List.wrap(post["author_id"]))
      |> Enum.map(&authors[&1])
      |> Enum.reject(&is_nil/1)

    tag_list = Enum.map(post["tags"] || [], &(tags[&1] || %{"slug" => &1, "name" => &1}))

    %{
      "id" => post["id"],
      "uuid" => post["id"],
      "title" => post["title"],
      "slug" => post["slug"],
      "html" => if(Keyword.get(opts, :html, true), do: body_html(post), else: nil),
      "markdown" => if(Keyword.get(opts, :markdown, false), do: post["markdown"], else: nil),
      "plaintext" => Markdown.to_text(post["markdown"]),
      "excerpt" => post["excerpt"],
      "custom_excerpt" => post["custom_excerpt"],
      "feature_image" => absolute(post["feature_image"], base),
      "feature_image_alt" => post["feature_image_alt"],
      "featured" => post["featured"] == true,
      "status" => post["status"],
      "visibility" => post["visibility"],
      "type" => post["type"],
      "url" => base <> "/" <> post["slug"],
      "canonical_url" => post["canonical_url"],
      "og_image" => post["og_image"],
      "meta_title" => post["meta_title"],
      "meta_description" => post["meta_description"],
      "created_at" => post["created_at"],
      "updated_at" => post["updated_at"],
      "published_at" => post["published_at"],
      "reading_time" => Markdown.reading_minutes(post["markdown"]),
      "tags" => Enum.map(tag_list, &tag_json/1),
      "primary_tag" => tag_list |> List.first() |> then(&(&1 && tag_json(&1))),
      "authors" => Enum.map(people, &author_json/1),
      "primary_author" => people |> List.first() |> then(&(&1 && author_json(&1))),
      "widgets" =>
        Markdown.widgets_in(post["markdown"])
        |> Enum.map(fn {s, p} -> %{"slug" => s, "props" => p} end)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  # widgets cannot be static HTML; the API gets a marker element a client may hydrate
  defp body_html(post) do
    post["markdown"]
    |> Markdown.segments(post["id"])
    |> Enum.map_join("\n", fn
      {:html, h} ->
        h

      {:widget, slug, props, instance} ->
        ~s(<div class="wraith-widget" data-widget="#{slug}" data-instance="#{instance}" data-props='#{Jason.encode!(props) |> String.replace("'", "&#39;")}'></div>)
    end)
  end

  def author_json(user) do
    base = WraithWeb.Endpoint.url()

    %{
      "id" => user["id"],
      "name" => user["name"],
      "slug" => user["slug"],
      "email" => user["email"],
      "profile_image" => absolute(user["avatar"], base),
      "bio" => user["bio"],
      "website" => user["website"],
      "location" => user["location"],
      "twitter" => user["twitter"],
      "url" => base <> "/author/" <> to_string(user["slug"])
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  def tag_json(tag) do
    %{
      "id" => tag["slug"],
      "name" => tag["name"] || tag["slug"],
      "slug" => tag["slug"],
      "description" => tag["description"],
      "accent_color" => tag["accent"],
      "url" => WraithWeb.Endpoint.url() <> "/tag/" <> tag["slug"],
      "visibility" => "public"
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  def settings_json do
    s = Settings.get()

    %{
      "title" => s["title"],
      "description" => s["description"],
      "lang" => s["lang"],
      "timezone" => s["timezone"],
      "accent_color" => s["accent"],
      "navigation" => s["navigation"],
      "members_enabled" => s["members_enabled"],
      "comments_enabled" => s["comments_enabled"],
      "url" => WraithWeb.Endpoint.url(),
      "theme" => s["theme"]
    }
  end

  defp absolute(nil, _base), do: nil
  defp absolute("/" <> _ = path, base), do: base <> path
  defp absolute(url, _base), do: url

  # ---- export -------------------------------------------------------------------------

  @doc "A Ghost-compatible export of the whole site."
  def export do
    users = Accounts.list_users()
    posts = Content.list_all_posts()
    tags = Content.list_tags()
    tag_ids = Map.new(tags, &{&1["slug"], &1["slug"]})

    %{
      "meta" => %{
        "exported_on" => System.system_time(:millisecond),
        "version" => "5.0.0",
        "generator" => "wraith"
      },
      "data" => %{
        "posts" =>
          Enum.map(posts, fn p ->
            %{
              "id" => p["id"],
              "uuid" => p["id"],
              "title" => p["title"],
              "slug" => p["slug"],
              "markdown" => p["markdown"],
              "html" => Markdown.to_html(p["markdown"]),
              "plaintext" => Markdown.to_text(p["markdown"]),
              "custom_excerpt" => p["custom_excerpt"],
              "feature_image" => p["feature_image"],
              "feature_image_alt" => p["feature_image_alt"],
              "featured" => if(p["featured"], do: 1, else: 0),
              "type" => p["type"],
              "status" => p["status"],
              "visibility" => p["visibility"],
              "canonical_url" => p["canonical_url"],
              "meta_title" => p["meta_title"],
              "meta_description" => p["meta_description"],
              "og_image" => p["og_image"],
              "created_at" => p["created_at"],
              "updated_at" => p["updated_at"],
              "published_at" => p["published_at"],
              "author_id" => p["author_id"]
            }
          end),
        "tags" =>
          Enum.map(
            tags,
            &%{
              "id" => &1["slug"],
              "name" => &1["name"],
              "slug" => &1["slug"],
              "description" => &1["description"]
            }
          ),
        "posts_tags" =>
          for(
            p <- posts,
            {t, i} <- Enum.with_index(p["tags"] || []),
            tag_ids[t],
            do: %{"post_id" => p["id"], "tag_id" => t, "sort_order" => i}
          ),
        "users" =>
          Enum.map(
            users,
            &Map.take(
              &1,
              ~w(id name slug email bio avatar website twitter github mastodon location role)
            )
          ),
        "posts_authors" =>
          for(
            p <- posts,
            {a, i} <- Enum.with_index(p["authors"] || List.wrap(p["author_id"])),
            do: %{"post_id" => p["id"], "author_id" => a, "sort_order" => i}
          ),
        "settings" =>
          Enum.map(
            Settings.get()
            |> Map.drop(
              ~w(pk sk version created_at updated_at kiro_key_ciphertext kiro_key_hint stripe_secret_key stripe_webhook_secret stripe_secret_key_ciphertext stripe_webhook_secret_ciphertext stripe_secret_key_hint stripe_webhook_secret_hint)
            ),
            fn {k, v} -> %{"key" => k, "value" => v} end
          ),
        "widgets" =>
          Widgets.list()
          |> Enum.reject(& &1["builtin"])
          |> Enum.map(&Map.take(&1, ~w(slug name description kind source props enabled))),
        "members" => export_members()
      }
    }
    |> then(&%{"db" => [&1]})
  end

  defp export_members do
    Members.list(limit: 10_000).members
    |> Enum.map(&Map.take(&1, ~w(email name status labels note subscribed created_at)))
  end

  # ---- import -------------------------------------------------------------------------

  @doc """
  Import a Ghost or Wraith export (decoded JSON). Existing slugs/emails are
  skipped. Returns counts. `opts[:author]` is the user to own posts whose
  author is unknown.
  """
  def import(%{"db" => [%{"data" => data} | _]}, opts), do: import_data(data, opts)
  def import(%{"data" => data}, opts), do: import_data(data, opts)
  def import(_other, _opts), do: {:error, "not a Ghost export: expected db[0].data"}

  defp import_data(data, opts) do
    fallback = Keyword.fetch!(opts, :author)

    # users: by email; new ones get a random password (they reset it by mail)
    user_map =
      for u <- data["users"] || [], into: %{} do
        email =
          to_string(u["email"] || "#{u["slug"] || u["id"]}@imported.invalid") |> String.downcase()

        user =
          Accounts.get_user_by_email(email) ||
            case Accounts.create_user(%{
                   email: email,
                   name: u["name"] || "Imported author",
                   password: Base.url_encode64(:crypto.strong_rand_bytes(18)),
                   bio: u["bio"] || "",
                   role: "author"
                 }) do
              {:ok, created} ->
                Accounts.update_profile(
                  created,
                  Map.take(u, ~w(avatar website twitter github mastodon location))
                  |> Map.put_new("avatar", u["profile_image"])
                )

                Accounts.get_user(created["id"])

              _ ->
                nil
            end

        {u["id"], user}
      end

    tags =
      for t <- data["tags"] || [],
          into: %{},
          do: {t["id"], Wraith.Slug.slugify(t["slug"] || t["name"] || "tag")}

    for {_id, slug} <- tags,
        t = Enum.find(data["tags"], &(tags[&1["id"]] == slug)),
        do: Content.ensure_tag(slug, %{name: t["name"], description: t["description"] || ""})

    post_tags = Enum.group_by(data["posts_tags"] || [], & &1["post_id"], & &1["tag_id"])
    post_authors = Enum.group_by(data["posts_authors"] || [], & &1["post_id"], & &1["author_id"])

    results =
      for p <- data["posts"] || [] do
        slug = Wraith.Slug.slugify(p["slug"] || p["title"] || "post")

        if Content.get_post_by_slug(slug) do
          :skipped
        else
          author_ids =
            (post_authors[p["id"]] || List.wrap(p["author_id"]))
            |> Enum.map(&(user_map[&1] && user_map[&1]["id"]))
            |> Enum.reject(&is_nil/1)

          [primary | rest] = if author_ids == [], do: [fallback["id"]], else: author_ids

          attrs = %{
            title: p["title"] || "Untitled",
            slug: slug,
            markdown: body_markdown(p),
            type: if(p["type"] == "page", do: "page", else: "post"),
            status: status(p["status"]),
            visibility:
              if(p["visibility"] in ~w(public members paid), do: p["visibility"], else: "public"),
            featured: p["featured"] in [1, true, "1", "true"],
            tags: (post_tags[p["id"]] || []) |> Enum.map(&tags[&1]) |> Enum.reject(&is_nil/1),
            author_id: primary,
            authors: rest,
            custom_excerpt: p["custom_excerpt"],
            feature_image: p["feature_image"],
            feature_image_alt: p["feature_image_alt"],
            canonical_url: p["canonical_url"],
            og_image: p["og_image"],
            meta_title: p["meta_title"],
            meta_description: p["meta_description"],
            published_at: p["published_at"] && iso(p["published_at"])
          }

          case Content.create_post(attrs) do
            {:ok, _} -> :ok
            {:error, _} -> :failed
          end
        end
      end

    members =
      for m <- data["members"] || [], m["email"] do
        case Members.create(Map.take(m, ~w(email name status labels note subscribed))) do
          {:ok, _} -> :ok
          _ -> :skipped
        end
      end

    widgets =
      for w <- data["widgets"] || [], w["kind"] == "lua", is_nil(Widgets.get(w["slug"] || "")) do
        case Widgets.save(Map.take(w, ~w(slug name description kind source props))) do
          {:ok, _} -> :ok
          _ -> :failed
        end
      end

    {:ok,
     %{
       posts: Enum.count(results, &(&1 == :ok)),
       posts_skipped: Enum.count(results, &(&1 == :skipped)),
       posts_failed: Enum.count(results, &(&1 == :failed)),
       users: user_map |> Map.values() |> Enum.reject(&is_nil/1) |> length(),
       tags: map_size(tags),
       members: Enum.count(members, &(&1 == :ok)),
       widgets: Enum.count(widgets, &(&1 == :ok))
     }}
  end

  # Ghost gives us html (always), and lexical/mobiledoc JSON we do not parse;
  # a Wraith export carries markdown. Plain HTML is turned into Markdown.
  defp body_markdown(%{"markdown" => md}) when is_binary(md) and md != "", do: md

  defp body_markdown(%{"html" => html}) when is_binary(html) and html != "",
    do: html_to_markdown(html)

  defp body_markdown(%{"plaintext" => t}) when is_binary(t), do: t
  defp body_markdown(_), do: ""

  @doc false
  def html_to_markdown(html) do
    html
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r/<h([1-6])[^>]*>(.*?)<\/h\1>/s, fn m ->
      [_, n, t] = Regex.run(~r/<h([1-6])[^>]*>(.*?)<\/h\1>/s, m)
      "\n" <> String.duplicate("#", String.to_integer(n)) <> " " <> strip(t) <> "\n"
    end)
    |> String.replace(~r/<pre[^>]*><code([^>]*)>(.*?)<\/code><\/pre>/s, fn m ->
      [_, attrs, code] = Regex.run(~r/<pre[^>]*><code([^>]*)>(.*?)<\/code><\/pre>/s, m)

      lang =
        case Regex.run(~r/language-([\w+-]+)/, attrs),
          do: (
            [_, l] -> l
            _ -> ""
          )

      "\n```#{lang}\n#{unescape(code)}\n```\n"
    end)
    |> String.replace(~r/<blockquote[^>]*>(.*?)<\/blockquote>/s, fn m ->
      [_, t] = Regex.run(~r/<blockquote[^>]*>(.*?)<\/blockquote>/s, m)
      "\n> " <> strip(t) <> "\n"
    end)
    |> String.replace(~r/<img[^>]*src="([^"]*)"[^>]*alt="([^"]*)"[^>]*>/, "![\\2](\\1)")
    |> String.replace(~r/<img[^>]*src="([^"]*)"[^>]*>/, "![](\\1)")
    |> String.replace(~r/<a[^>]*href="([^"]*)"[^>]*>(.*?)<\/a>/s, "[\\2](\\1)")
    |> String.replace(~r/<(strong|b)>(.*?)<\/\1>/s, "**\\2**")
    |> String.replace(~r/<(em|i)>(.*?)<\/\1>/s, "*\\2*")
    |> String.replace(~r/<code>(.*?)<\/code>/s, "`\\1`")
    |> String.replace(~r/<li[^>]*>(.*?)<\/li>/s, "- \\1\n")
    |> String.replace(~r/<\/?(ul|ol)[^>]*>/, "\n")
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<hr\s*\/?>/, "\n---\n")
    |> String.replace(~r/<\/p>/, "\n\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> unescape()
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp strip(t), do: t |> String.replace(~r/<[^>]+>/, "") |> unescape() |> String.trim()

  defp unescape(t),
    do:
      t
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&quot;", "\"")
      |> String.replace("&#39;", "'")
      |> String.replace("&nbsp;", " ")
      |> String.replace("&amp;", "&")

  defp status("published"), do: "published"
  defp status("scheduled"), do: "scheduled"
  defp status(_), do: "draft"

  defp iso(v) when is_integer(v),
    do: DateTime.from_unix!(v, :millisecond) |> DateTime.to_iso8601()

  defp iso(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} ->
        DateTime.to_iso8601(dt)

      _ ->
        case NaiveDateTime.from_iso8601(String.replace(v, " ", "T")) do
          {:ok, ndt} -> ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
          _ -> nil
        end
    end
  end

  defp iso(_), do: nil
end
