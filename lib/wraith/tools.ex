defmodule Wraith.Tools do
  @moduledoc """
  Everything an agent can do to the site — the one MCP tool registry.
  Served two ways: to the studio agent over the bridge
  (`Wraith.Studio.Tools` delegates here) and to any MCP client over HTTP at
  `/mcp` (`WraithWeb.McpController`), authenticated with an API key.

  Every admin screen's action has a tool. Read-only tools carry the MCP
  `readOnlyHint` annotation; a Content (read-only) key only sees those.
  Destructive ones carry `destructiveHint`.

  `context` is `%{"user_id" => id, "scope" => "admin" | "content"}` —
  writes are made as that user.
  """
  @behaviour Wraith.Kiro.MCP

  alias Wraith.{
    Accounts,
    ApiKeys,
    Comments,
    Content,
    Ghost,
    Markdown,
    Members,
    Newsletter,
    Search,
    Settings,
    Uploads,
    Widgets
  }

  alias Wraith.Kiro.MCP
  alias Wraith.Widgets.Lua

  @impl true
  def server_info(_ctx) do
    %{
      name: "wraith",
      instructions:
        "Tools for a Wraith site: posts and pages (Markdown; `{{widget slug key=value}}` on its own line embeds " <>
          "a live widget), tags, authors, members, comments, newsletters, Lua widgets, settings, themes, " <>
          "redirects, API keys, uploads, search, and a Ghost-compatible export/import. Call `site_info` first " <>
          "for context and `widget_docs` before writing a widget; `widget_test` before `widget_save`. " <>
          "Ask before deleting or publishing anything the owner did not explicitly ask for."
    }
  end

  @impl true
  def tools(ctx) do
    all = catalogue()
    if ctx["scope"] == "content", do: Enum.filter(all, &read_only?/1), else: all
  end

  def read_only?(%{"annotations" => %{"readOnlyHint" => true}}), do: true
  def read_only?(_), do: false

  def names(ctx \\ %{"scope" => "admin"}), do: tools(ctx) |> Enum.map(& &1["name"])

  @impl true
  def call(ctx, name, args) do
    tool = Enum.find(catalogue(), &(&1["name"] == name))

    cond do
      is_nil(tool) ->
        MCP.error("unknown tool #{name}")

      ctx["scope"] == "content" and not read_only?(tool) ->
        MCP.error("#{name} needs an Admin key")

      true ->
        try do
          do_call(ctx, name, args || %{})
        rescue
          e -> MCP.error("#{name} failed: " <> Exception.message(e))
        end
    end
  end

  # ---- resources: posts, settings, widget docs, readable as documents ------------------

  @impl true
  def resources(_ctx) do
    base = WraithWeb.Endpoint.url()

    [
      %{
        "uri" => "wraith://settings",
        "name" => "Site settings",
        "mimeType" => "application/json",
        "description" => "The site's settings."
      },
      %{
        "uri" => "wraith://widgets/docs",
        "name" => "Widget authoring guide",
        "mimeType" => "text/markdown",
        "description" => "How to write a Lua widget."
      }
    ] ++
      for p <- Content.list_all_posts() |> Enum.take(200) do
        %{
          "uri" => "wraith://posts/#{p["slug"]}",
          "name" => p["title"],
          "mimeType" => "text/markdown",
          "description" => "#{p["type"]} · #{p["status"]} · #{base}/#{p["slug"]}"
        }
      end
  end

  @impl true
  def read_resource(_ctx, "wraith://settings"),
    do:
      {:ok,
       [
         %{
           "uri" => "wraith://settings",
           "mimeType" => "application/json",
           "text" => Jason.encode!(public_settings(Settings.get()), pretty: true)
         }
       ]}

  def read_resource(_ctx, "wraith://widgets/docs"),
    do:
      {:ok,
       [
         %{
           "uri" => "wraith://widgets/docs",
           "mimeType" => "text/markdown",
           "text" => Wraith.Studio.Tools.widget_docs()
         }
       ]}

  def read_resource(_ctx, "wraith://posts/" <> slug = uri) do
    case find_post(slug) do
      nil ->
        :error

      p ->
        {:ok,
         [
           %{
             "uri" => uri,
             "mimeType" => "text/markdown",
             "text" => "# #{p["title"]}\n\n#{p["markdown"]}"
           }
         ]}
    end
  end

  def read_resource(_ctx, _uri), do: :error

  # ---- the catalogue -----------------------------------------------------------------

  @doc false
  def catalogue do
    [
      # site
      read(
        "site_info",
        "The site: settings, authors, counts, installed widgets and themes.",
        %{}
      ),
      read(
        "settings_get",
        "Every site setting (title, description, navigation, theme, redirects, members/comments flags, Stripe price).",
        %{}
      ),
      write(
        "settings_update",
        "Change site settings. Any of: title, description, lang, timezone, posts_per_page, accent (#hex), theme, navigation ([{label,url}]), footer, members_enabled, comments_enabled, redirects ([{from,to,permanent}]), stripe_price_id, paid_price_label.",
        %{
          "title" => str(""),
          "description" => str(""),
          "lang" => str(""),
          "timezone" => str(""),
          "posts_per_page" => int(""),
          "accent" => str("#rrggbb"),
          "theme" => str("paper | ink"),
          "navigation" => arr("[{label, url}]"),
          "footer" => str(""),
          "members_enabled" => bool(""),
          "comments_enabled" => bool(""),
          "redirects" => arr("[{from, to, permanent}]; from may end in * to keep the rest"),
          "stripe_price_id" => str(""),
          "paid_price_label" => str("")
        }
      ),
      read("themes_list", "Installed themes and which is active.", %{}),

      # posts & pages
      read(
        "posts_list",
        "List posts or pages of any status: id, title, slug, status, type, tags, visibility, updated_at.",
        %{
          "status" => str("draft | scheduled | published"),
          "type" => str("post | page"),
          "limit" => int("default 50"),
          "query" => str("search words")
        }
      ),
      read(
        "post_get",
        "One post by id or slug, with Markdown body, widgets and revision count.",
        %{"id" => str("id or slug")},
        ["id"]
      ),
      read(
        "post_revisions",
        "Earlier versions of a post (title, markdown, when).",
        %{"id" => str("id or slug"), "limit" => int("default 10")},
        ["id"]
      ),
      write(
        "post_create",
        "Create a draft post or page.",
        %{
          "title" => str(""),
          "markdown" => str("Markdown body"),
          "html" => str("HTML body instead of Markdown (converted)"),
          "type" => str("post (default) | page"),
          "tags" => str("comma-separated"),
          "custom_excerpt" => str(""),
          "slug" => str(""),
          "feature_image" => str("URL"),
          "feature_image_alt" => str(""),
          "visibility" => str("public | members | paid"),
          "featured" => bool(""),
          "authors" => arr("co-author user ids"),
          "show_toc" => bool(""),
          "canonical_url" => str(""),
          "og_image" => str(""),
          "meta_title" => str(""),
          "meta_description" => str("")
        },
        ["title"]
      ),
      write(
        "post_update",
        "Change any field of a post (same fields as post_create).",
        %{
          "id" => str("id or slug"),
          "title" => str(""),
          "markdown" => str(""),
          "html" => str(""),
          "tags" => str(""),
          "custom_excerpt" => str(""),
          "slug" => str(""),
          "feature_image" => str(""),
          "feature_image_alt" => str(""),
          "visibility" => str(""),
          "featured" => bool(""),
          "authors" => arr(""),
          "show_toc" => bool(""),
          "canonical_url" => str(""),
          "og_image" => str(""),
          "meta_title" => str(""),
          "meta_description" => str(""),
          "type" => str("")
        },
        ["id"]
      ),
      write(
        "post_publish",
        "Publish now, or schedule with an ISO-8601 `at`.",
        %{"id" => str(""), "at" => str("ISO-8601, in the future to schedule")},
        ["id"]
      ),
      write("post_unpublish", "Back to draft.", %{"id" => str("")}, ["id"]),
      destructive(
        "post_delete",
        "Delete a post or page for good (revisions too).",
        %{"id" => str("")},
        ["id"]
      ),
      write(
        "post_restore_revision",
        "Put an earlier revision's title and body back (as a new revision).",
        %{
          "id" => str("post id or slug"),
          "revision" => str("the revision's sk from post_revisions")
        },
        ["id", "revision"]
      ),
      write(
        "newsletter_send",
        "Mail a published post to every subscribed member who may read it. Once per post unless force.",
        %{"id" => str(""), "force" => bool("send again")},
        ["id"]
      ),
      read(
        "newsletter_status",
        "Has this post gone out, when, to how many.",
        %{"id" => str("")},
        ["id"]
      ),
      read(
        "search",
        "Full-text search over published posts.",
        %{"query" => str(""), "limit" => int("default 10")},
        ["query"]
      ),

      # tags
      read("tags_list", "Every tag with its post count.", %{}),
      write(
        "tag_upsert",
        "Create a tag or rename/describe it.",
        %{
          "slug" => str(""),
          "name" => str(""),
          "description" => str(""),
          "accent" => str("#rrggbb")
        },
        ["slug"]
      ),
      destructive("tag_delete", "Delete a tag (posts keep the label).", %{"slug" => str("")}, [
        "slug"
      ]),

      # authors
      read("authors_list", "Authors: id, name, slug, role, bio, socials.", %{}),
      write(
        "author_create",
        "Add an author (owner only). They get the password you give or a random one plus a reset mail.",
        %{
          "email" => str(""),
          "name" => str(""),
          "password" => str("≥ 10 chars; omit to mail a reset link"),
          "bio" => str("")
        },
        ["email", "name"]
      ),
      write(
        "author_update",
        "Change an author's profile: name, bio, avatar (URL), website, twitter, github, mastodon, location. Your own, or anyone's as owner.",
        %{
          "id" => str("user id; defaults to you"),
          "name" => str(""),
          "bio" => str(""),
          "avatar" => str(""),
          "website" => str(""),
          "twitter" => str(""),
          "github" => str(""),
          "mastodon" => str(""),
          "location" => str("")
        }
      ),
      write("author_send_reset", "Mail an author a password-reset link.", %{"email" => str("")}, [
        "email"
      ]),

      # members
      read(
        "members_list",
        "Members, newest first: id, email, name, status, subscribed, labels.",
        %{"limit" => int("default 50"), "status" => str("free | paid | comped")}
      ),
      read("member_get", "One member by id or email.", %{"id" => str("id or email")}, ["id"]),
      write(
        "member_create",
        "Add a member.",
        %{
          "email" => str(""),
          "name" => str(""),
          "status" => str("free | paid | comped"),
          "labels" => arr(""),
          "note" => str(""),
          "subscribed" => bool(""),
          "welcome" => bool("send the welcome mail")
        },
        ["email"]
      ),
      write(
        "member_update",
        "Change a member: name, status, labels, note, subscribed.",
        %{
          "id" => str("id or email"),
          "name" => str(""),
          "status" => str(""),
          "labels" => arr(""),
          "note" => str(""),
          "subscribed" => bool("")
        },
        ["id"]
      ),
      destructive("member_delete", "Remove a member.", %{"id" => str("id or email")}, ["id"]),
      write(
        "member_send_login_link",
        "Mail a member a sign-in link.",
        %{"id" => str("id or email")},
        ["id"]
      ),

      # comments
      read("comments_list", "Newest comments across the site, or one post's thread.", %{
        "status" => str("published | hidden"),
        "post_id" => str("a post: its whole thread"),
        "limit" => int("default 50")
      }),
      write(
        "comment_moderate",
        "Hide, show or remove a comment.",
        %{"post_id" => str(""), "id" => str(""), "action" => str("hide | show | remove")},
        ["post_id", "id", "action"]
      ),

      # widgets
      read("widgets_list", "Every widget: slug, name, kind, enabled, props, rev.", %{}),
      read("widget_get", "A widget's definition with its Lua source.", %{"slug" => str("")}, [
        "slug"
      ]),
      read(
        "widget_docs",
        "How to write a Lua widget: functions, helpers, CSS classes, an example.",
        %{}
      ),
      read("widget_versions", "Saved versions of a Lua widget.", %{"slug" => str("")}, ["slug"]),
      read(
        "widget_test",
        "Run Lua widget source without saving: init, render, apply events, render again.",
        %{
          "source" => str(""),
          "props" => obj(""),
          "events" => arr("[{event, payload, visitor}]")
        },
        ["source"]
      ),
      write(
        "widget_save",
        "Create or update a Lua widget (a new version).",
        %{
          "slug" => str(""),
          "name" => str(""),
          "description" => str(""),
          "source" => str(""),
          "props" => arr("[{name, type, required, help}]")
        },
        ["slug", "name", "source"]
      ),
      write(
        "widget_rollback",
        "Make an earlier version the current source.",
        %{"slug" => str(""), "rev" => int("")},
        ["slug", "rev"]
      ),
      write(
        "widget_enable",
        "Enable or disable a widget.",
        %{"slug" => str(""), "enabled" => bool("")},
        ["slug", "enabled"]
      ),
      destructive(
        "widget_delete",
        "Delete a (non built-in) widget and its versions.",
        %{"slug" => str("")},
        ["slug"]
      ),
      read(
        "widget_state_get",
        "The live shared state of one embedded widget instance.",
        %{"slug" => str(""), "instance" => str("the instance id (post id:n or the id= prop)")},
        ["slug", "instance"]
      ),
      write(
        "widget_state_reset",
        "Reset an instance's shared state (next render runs init again).",
        %{"slug" => str(""), "instance" => str("")},
        ["slug", "instance"]
      ),

      # uploads
      write(
        "upload_from_url",
        "Fetch an image from a URL into the site's uploads; returns the hosted URL to use in posts.",
        %{"url" => str(""), "name" => str("file name stem")},
        ["url"]
      ),
      write(
        "upload_base64",
        "Store an image given as base64; returns the hosted URL.",
        %{
          "data" => str("base64 bytes"),
          "content_type" => str("image/png etc."),
          "name" => str("")
        },
        ["data", "content_type"]
      ),

      # keys, export, import
      read("api_keys_list", "API keys (never the secrets).", %{}),
      write(
        "api_key_create",
        "Create a Content (read) or Admin (read/write) API key; the key is returned once.",
        %{"label" => str(""), "kind" => str("content | admin")},
        ["label", "kind"]
      ),
      destructive("api_key_delete", "Revoke an API key.", %{"id" => str("")}, ["id"]),
      read("site_export", "The whole site as a Ghost-compatible export (JSON).", %{}),
      write(
        "site_import",
        "Import a Ghost or Wraith export (the decoded JSON as `data`). Existing slugs/emails are skipped.",
        %{"data" => obj("the export document")},
        ["data"]
      )
    ]
  end

  # ---- calls: site -----------------------------------------------------------------

  defp do_call(_ctx, "site_info", _a) do
    json(%{
      site: Settings.get() |> public_settings(),
      authors: Accounts.list_users() |> Enum.map(&Map.take(&1, ~w(id name slug role))),
      counts: %{
        published: Content.count_posts("published"),
        drafts: Content.count_posts("draft"),
        scheduled: Content.count_posts("scheduled"),
        members: Members.count(),
        tags: length(Content.list_tags())
      },
      widgets: Widgets.list() |> Enum.map(&Map.take(&1, ~w(slug name kind enabled description))),
      themes: WraithWeb.Themes.infos() |> Enum.map(&Map.take(&1, [:name, :label])),
      urls: %{site: WraithWeb.Endpoint.url(), admin: WraithWeb.Endpoint.url() <> "/admin"}
    })
  end

  defp do_call(_ctx, "settings_get", _a),
    do: json(%{settings: Settings.get() |> public_settings()})

  defp do_call(_ctx, "settings_update", a) do
    case Settings.update(a) do
      {:ok, s} -> json(%{ok: true, settings: public_settings(s)})
      {:error, errors} -> MCP.error("settings: " <> inspect(errors))
    end
  end

  defp do_call(_ctx, "themes_list", _a),
    do: json(%{themes: WraithWeb.Themes.infos(), active: Settings.get()["theme"]})

  # ---- posts -----------------------------------------------------------------------

  defp do_call(_ctx, "posts_list", a) do
    posts =
      if a["query"] in [nil, ""] do
        Content.list_all_posts(type: a["type"])
        |> Enum.filter(&(is_nil(a["status"]) or &1["status"] == a["status"]))
      else
        Search.search(a["query"], a["limit"] || 50) |> Enum.map(& &1.post)
      end

    json(%{posts: posts |> Enum.take(a["limit"] || 50) |> Enum.map(&summary/1)})
  end

  defp do_call(_ctx, "post_get", %{"id" => id}) do
    case find_post(id) do
      nil ->
        MCP.error("no post #{id}")

      p ->
        json(%{
          post: full(p),
          revisions: length(Content.revisions(p["id"])),
          url: WraithWeb.Endpoint.url() <> "/" <> p["slug"]
        })
    end
  end

  defp do_call(_ctx, "post_revisions", %{"id" => id} = a) do
    case find_post(id) do
      nil ->
        MCP.error("no post #{id}")

      p ->
        json(%{
          revisions:
            Content.revisions(p["id"])
            |> Enum.take(a["limit"] || 10)
            |> Enum.map(&Map.take(&1, ~w(sk title markdown created_at)))
        })
    end
  end

  defp do_call(ctx, "post_create", a) do
    attrs = a |> body_from_html() |> Map.put_new("author_id", ctx["user_id"])

    case Content.create_post(attrs) do
      {:ok, p} ->
        json(%{
          ok: true,
          post: full(p),
          url: WraithWeb.Endpoint.url() <> "/" <> p["slug"],
          editor: "/admin/posts/" <> p["id"]
        })

      {:error, errors} ->
        MCP.error("post_create: " <> inspect(errors))
    end
  end

  defp do_call(_ctx, "post_update", %{"id" => id} = a) do
    with %{} = p <- find_post(id) || {:error, "no post #{id}"},
         {:ok, p} <- Content.update_post(p, a |> Map.delete("id") |> body_from_html()) do
      json(%{ok: true, post: full(p)})
    else
      {:error, %{} = e} -> MCP.error("post_update: " <> inspect(e))
      {:error, why} -> MCP.error(to_string(why))
    end
  end

  defp do_call(_ctx, "post_publish", %{"id" => id} = a) do
    at =
      case a["at"] do
        nil ->
          {:ok, nil}

        iso ->
          case DateTime.from_iso8601(iso),
            do: (
              {:ok, dt, _} -> {:ok, dt}
              _ -> :error
            )
      end

    with {:ok, at} <- at,
         %{} = p <- find_post(id) || {:error, "no post #{id}"},
         {:ok, p} <- Content.publish_post(p, at) do
      json(%{ok: true, post: summary(p), url: WraithWeb.Endpoint.url() <> "/" <> p["slug"]})
    else
      :error -> MCP.error("`at` must be ISO-8601, e.g. 2027-01-01T10:00:00Z")
      {:error, %{} = e} -> MCP.error("post_publish: " <> inspect(e))
      {:error, why} -> MCP.error(to_string(why))
    end
  end

  defp do_call(_ctx, "post_unpublish", %{"id" => id}) do
    with %{} = p <- find_post(id) || {:error, "no post #{id}"},
         {:ok, p} <- Content.unpublish_post(p) do
      json(%{ok: true, post: summary(p)})
    else
      {:error, why} -> MCP.error(inspect(why))
    end
  end

  defp do_call(_ctx, "post_delete", %{"id" => id}) do
    case find_post(id) do
      nil ->
        MCP.error("no post #{id}")

      p ->
        :ok = Content.delete_post(p)
        json(%{ok: true, deleted: p["id"]})
    end
  end

  defp do_call(_ctx, "post_restore_revision", %{"id" => id, "revision" => sk}) do
    with %{} = p <- find_post(id) || {:error, "no post #{id}"},
         %{} = rev <-
           Enum.find(Content.revisions(p["id"]), &(&1["sk"] == sk)) ||
             {:error, "no revision #{sk}"},
         {:ok, p} <-
           Content.update_post(p, %{"title" => rev["title"], "markdown" => rev["markdown"]}) do
      json(%{ok: true, post: full(p)})
    else
      {:error, why} -> MCP.error(to_string(inspect(why)))
    end
  end

  defp do_call(_ctx, "newsletter_send", %{"id" => id} = a) do
    with %{} = p <- find_post(id) || {:error, "no post #{id}"},
         {:ok, n} <- Newsletter.send_post(p, force: a["force"] == true) do
      json(%{ok: true, recipients: n})
    else
      {:error, :already_sent} ->
        MCP.error("this post already went out; pass force: true to send again")

      {:error, :not_published} ->
        MCP.error("publish the post first")

      {:error, why} ->
        MCP.error(to_string(why))
    end
  end

  defp do_call(_ctx, "newsletter_status", %{"id" => id}) do
    case find_post(id) do
      nil ->
        MCP.error("no post #{id}")

      p ->
        json(%{
          sent: Newsletter.sent?(p),
          record:
            Newsletter.send_record(p) &&
              Map.take(Newsletter.send_record(p), ~w(sent_at recipients))
        })
    end
  end

  defp do_call(_ctx, "search", %{"query" => q} = a),
    do:
      json(%{
        results:
          Search.search(q, a["limit"] || 10)
          |> Enum.map(&%{post: summary(&1.post), score: &1.score, snippet: &1.snippet})
      })

  # ---- tags ---------------------------------------------------------------------------

  defp do_call(_ctx, "tags_list", _a) do
    counts = Content.tag_counts()

    json(%{
      tags:
        Content.list_tags()
        |> Enum.map(
          &%{
            slug: &1["slug"],
            name: &1["name"],
            description: &1["description"],
            accent: &1["accent"],
            posts: counts[&1["slug"]] || 0
          }
        )
    })
  end

  defp do_call(_ctx, "tag_upsert", %{"slug" => slug} = a) do
    {:ok, t} =
      Content.ensure_tag(Wraith.Slug.slugify(slug), Map.take(a, ~w(name description accent)))

    json(%{ok: true, tag: Map.take(t, ~w(slug name description accent))})
  end

  defp do_call(_ctx, "tag_delete", %{"slug" => slug}) do
    :ok = Content.delete_tag(slug)
    json(%{ok: true})
  end

  # ---- authors -------------------------------------------------------------------------

  defp do_call(_ctx, "authors_list", _a),
    do:
      json(%{
        authors:
          Accounts.list_users()
          |> Enum.map(
            &Map.take(
              &1,
              ~w(id name slug role bio avatar website twitter github mastodon location)
            )
          )
      })

  defp do_call(ctx, "author_create", a) do
    with %{"role" => "owner"} <- actor(ctx) || {:error, "only the owner adds authors"} do
      password = a["password"] || Base.url_encode64(:crypto.strong_rand_bytes(18))

      case Accounts.create_user(%{
             email: a["email"],
             name: a["name"],
             password: password,
             bio: a["bio"] || ""
           }) do
        {:ok, u} ->
          if is_nil(a["password"]), do: Newsletter.send_password_reset(u)

          json(%{
            ok: true,
            author: Map.take(u, ~w(id name slug email role)),
            reset_mailed: is_nil(a["password"])
          })

        {:error, errors} ->
          MCP.error("author_create: " <> inspect(errors))
      end
    else
      %{} -> MCP.error("only the owner adds authors")
      {:error, why} -> MCP.error(why)
    end
  end

  defp do_call(ctx, "author_update", a) do
    me = actor(ctx)
    target = if a["id"] in [nil, ""], do: me, else: Accounts.get_user(a["id"])

    cond do
      is_nil(target) ->
        MCP.error("no such author")

      target["id"] != me["id"] and me["role"] != "owner" ->
        MCP.error("only the owner edits other authors")

      true ->
        {:ok, u} = Accounts.update_profile(target, Map.drop(a, ["id"]))

        json(%{
          ok: true,
          author:
            Map.take(u, ~w(id name slug bio avatar website twitter github mastodon location))
        })
    end
  end

  defp do_call(_ctx, "author_send_reset", %{"email" => email}) do
    :ok = Accounts.request_password_reset(email)
    json(%{ok: true, note: "a reset link was mailed if that address belongs to an author"})
  end

  # ---- members -------------------------------------------------------------------------

  defp do_call(_ctx, "members_list", a) do
    members =
      Members.list(limit: a["limit"] || 50).members
      |> Enum.filter(&(is_nil(a["status"]) or &1["status"] == a["status"]))

    json(%{members: Enum.map(members, &member_json/1), total: Members.count()})
  end

  defp do_call(_ctx, "member_get", %{"id" => id}) do
    case find_member(id) do
      nil -> MCP.error("no member #{id}")
      m -> json(%{member: member_json(m)})
    end
  end

  defp do_call(_ctx, "member_create", a) do
    case Members.create(Map.take(a, ~w(email name status labels note subscribed))) do
      {:ok, m} ->
        if a["welcome"] == true, do: Newsletter.send_welcome(m)
        json(%{ok: true, member: member_json(m)})

      {:error, errors} ->
        MCP.error("member_create: " <> inspect(errors))
    end
  end

  defp do_call(_ctx, "member_update", %{"id" => id} = a) do
    with %{} = m <- find_member(id) || {:error, "no member #{id}"},
         {:ok, m} <- Members.update(m, Map.drop(a, ["id"])) do
      json(%{ok: true, member: member_json(m)})
    else
      {:error, why} -> MCP.error(inspect(why))
    end
  end

  defp do_call(_ctx, "member_delete", %{"id" => id}) do
    case find_member(id) do
      nil ->
        MCP.error("no member #{id}")

      m ->
        :ok = Members.delete(m)
        json(%{ok: true})
    end
  end

  defp do_call(_ctx, "member_send_login_link", %{"id" => id}) do
    case find_member(id) do
      nil ->
        MCP.error("no member #{id}")

      m ->
        Newsletter.send_login_link(m)
        json(%{ok: true})
    end
  end

  # ---- comments -------------------------------------------------------------------------

  defp do_call(_ctx, "comments_list", a) do
    comments =
      case a["post_id"] do
        nil ->
          Comments.recent(a["status"] || "published", a["limit"] || 50)

        post_id ->
          Comments.for_post(post_id, include_hidden: true)
          |> Enum.flat_map(&[&1.comment | &1.replies])
      end

    json(%{
      comments:
        Enum.map(
          comments,
          &Map.take(
            &1,
            ~w(id post_id post_title post_slug member_id member_name parent_id body status created_at)
          )
        )
    })
  end

  defp do_call(_ctx, "comment_moderate", %{"post_id" => post_id, "id" => id, "action" => action}) do
    with %{} = c <- Comments.get(post_id, id) || {:error, "no comment #{id}"} do
      case action do
        "hide" ->
          Comments.set_status(c, "hidden")
          json(%{ok: true})

        "show" ->
          Comments.set_status(c, "published")
          json(%{ok: true})

        "remove" ->
          Comments.delete(c)
          json(%{ok: true})

        _ ->
          MCP.error("action must be hide, show or remove")
      end
    else
      {:error, why} -> MCP.error(why)
    end
  end

  # ---- widgets -------------------------------------------------------------------------

  defp do_call(_ctx, "widgets_list", _a),
    do:
      json(%{
        widgets:
          Widgets.list()
          |> Enum.map(&Map.take(&1, ~w(slug name kind enabled description props rev builtin)))
      })

  defp do_call(_ctx, "widget_get", %{"slug" => slug}) do
    case Widgets.get(slug) do
      nil ->
        MCP.error("no widget #{slug}")

      w ->
        json(%{
          widget:
            Map.take(w, ~w(slug name kind enabled description props rev builtin source module))
        })
    end
  end

  defp do_call(_ctx, "widget_docs", _a), do: MCP.text(Wraith.Studio.Tools.widget_docs())

  defp do_call(_ctx, "widget_versions", %{"slug" => slug}),
    do: json(%{versions: Widgets.versions(slug) |> Enum.map(&Map.take(&1, ~w(rev created_at)))})

  defp do_call(_ctx, "widget_test", %{"source" => source} = a) do
    props = a["props"] || %{}

    meta = fn visitor ->
      %{"instance" => "test", "visitor" => visitor || "tester", "presence" => 1, "post" => nil}
    end

    with :ok <- Lua.check(source),
         {:ok, state} <- Lua.call(source, "init", [props], %{instance: "test"}),
         {:ok, html} <-
           Lua.call(source, "render", [state, props, meta.(nil)], %{instance: "test"}) do
      {steps, _} =
        Enum.reduce_while(a["events"] || [], {[], state}, fn ev, {acc, st} ->
          with {:ok, st} <-
                 Lua.call(
                   source,
                   "handle",
                   [st, ev["event"], ev["payload"] || %{}, meta.(ev["visitor"])],
                   %{instance: "test"}
                 ),
               {:ok, h} <-
                 Lua.call(source, "render", [st, props, meta.(ev["visitor"])], %{instance: "test"}) do
            {:cont, {acc ++ [%{event: ev["event"], state: st, html: h}], st}}
          else
            {:error, why} -> {:halt, {acc ++ [%{event: ev["event"], error: why}], st}}
          end
        end)

      json(%{ok: true, initial: %{state: state, html: html}, steps: steps})
    else
      {:error, why} -> MCP.error("widget_test: " <> to_string(why))
    end
  end

  defp do_call(_ctx, "widget_save", a) do
    case Widgets.save(
           Map.merge(Map.take(a, ~w(slug name description source props)), %{"kind" => "lua"})
         ) do
      {:ok, w} ->
        json(%{
          ok: true,
          widget: Map.take(w, ~w(slug name rev enabled)),
          shortcode: "{{widget #{w["slug"]}}}"
        })

      {:error, errors} ->
        MCP.error("widget_save: " <> inspect(errors))
    end
  end

  defp do_call(_ctx, "widget_rollback", %{"slug" => slug, "rev" => rev}) do
    case Widgets.rollback(slug, rev) do
      {:ok, w} -> json(%{ok: true, widget: Map.take(w, ~w(slug rev))})
      {:error, e} -> MCP.error(inspect(e))
    end
  end

  defp do_call(_ctx, "widget_enable", %{"slug" => slug, "enabled" => enabled}) do
    case Widgets.set_enabled(slug, enabled in [true, "true"]) do
      {:ok, w} -> json(%{ok: true, widget: Map.take(w, ~w(slug enabled))})
      {:error, why} -> MCP.error(inspect(why))
    end
  end

  defp do_call(_ctx, "widget_delete", %{"slug" => slug}) do
    case Widgets.get(slug) do
      nil ->
        MCP.error("no widget #{slug}")

      %{"builtin" => true} ->
        MCP.error("#{slug} is built in; disable it instead")

      _ ->
        Widgets.delete(slug)
        json(%{ok: true})
    end
  end

  defp do_call(_ctx, "widget_state_get", %{"slug" => slug, "instance" => instance}) do
    case Widgets.get(slug) do
      nil -> MCP.error("no widget #{slug}")
      w -> json(%{state: Widgets.state(w, instance, %{})})
    end
  end

  defp do_call(_ctx, "widget_state_reset", %{"slug" => slug, "instance" => instance}) do
    Widgets.reset_state(slug, instance)
    json(%{ok: true})
  end

  # ---- uploads -------------------------------------------------------------------------

  defp do_call(_ctx, "upload_from_url", %{"url" => url} = a) do
    case Req.get(url, receive_timeout: 20_000, max_redirects: 3, decode_body: false) do
      {:ok, %{status: 200, body: body, headers: h}} ->
        type =
          h
          |> Map.get("content-type", [])
          |> List.first()
          |> to_string()
          |> String.split(";")
          |> hd()

        case Uploads.store(body, type,
               name: a["name"] || Path.basename(URI.parse(url).path || "image")
             ) do
          {:ok, hosted} ->
            json(%{
              ok: true,
              url: WraithWeb.Endpoint.url() <> hosted,
              path: hosted,
              markdown: "![](#{hosted})"
            })

          {:error, why} ->
            MCP.error(why)
        end

      {:ok, %{status: s}} ->
        MCP.error("fetching #{url} answered #{s}")

      {:error, e} ->
        MCP.error("could not fetch #{url}: #{Exception.message(e)}")
    end
  end

  defp do_call(_ctx, "upload_base64", %{"data" => data, "content_type" => type} = a) do
    with {:ok, bytes} <- Base.decode64(data, ignore: :whitespace),
         {:ok, hosted} <- Uploads.store(bytes, type, name: a["name"] || "image") do
      json(%{
        ok: true,
        url: WraithWeb.Endpoint.url() <> hosted,
        path: hosted,
        markdown: "![](#{hosted})"
      })
    else
      :error -> MCP.error("data is not valid base64")
      {:error, why} -> MCP.error(why)
    end
  end

  # ---- keys, export, import -------------------------------------------------------------

  defp do_call(_ctx, "api_keys_list", _a),
    do:
      json(%{
        keys: ApiKeys.list() |> Enum.map(&Map.take(&1, ~w(id label kind last_used_at created_at)))
      })

  defp do_call(_ctx, "api_key_create", %{"label" => label, "kind" => kind}) do
    case ApiKeys.create(label, kind) do
      {:ok, raw, key} -> json(%{ok: true, key: raw, id: key["id"], note: "shown once"})
      {:error, why} -> MCP.error(why)
    end
  end

  defp do_call(_ctx, "api_key_delete", %{"id" => id}) do
    :ok = ApiKeys.delete(id)
    json(%{ok: true})
  end

  defp do_call(_ctx, "site_export", _a), do: json(Ghost.export())

  defp do_call(ctx, "site_import", %{"data" => data}) do
    case Ghost.import(data, author: actor(ctx)) do
      {:ok, counts} -> json(%{ok: true, imported: counts})
      {:error, why} -> MCP.error(to_string(why))
    end
  end

  defp do_call(_ctx, name, _args), do: MCP.error("#{name}: missing required arguments")

  # ---- helpers -------------------------------------------------------------------------

  defp actor(ctx),
    do:
      (ctx["user_id"] && Accounts.get_user(ctx["user_id"])) ||
        Enum.find(Accounts.list_users(), &(&1["role"] == "owner"))

  defp find_post(id) when is_binary(id), do: Content.get_post(id) || Content.get_post_by_slug(id)
  defp find_post(_), do: nil

  defp find_member(id) when is_binary(id), do: Members.get(id) || Members.get_by_email(id)
  defp find_member(_), do: nil

  defp body_from_html(%{"html" => html} = a)
       when is_binary(html) and not is_map_key(a, "markdown"),
       do: a |> Map.put("markdown", Ghost.html_to_markdown(html)) |> Map.delete("html")

  defp body_from_html(a), do: Map.delete(a, "html")

  defp summary(p),
    do:
      Map.take(p, ~w(id title slug status type tags visibility featured published_at updated_at))

  defp full(p),
    do:
      p
      |> summary()
      |> Map.merge(
        Map.take(
          p,
          ~w(markdown custom_excerpt excerpt feature_image feature_image_alt canonical_url og_image meta_title meta_description show_toc authors author_id)
        )
      )
      |> Map.put(
        "widgets",
        Markdown.widgets_in(p["markdown"])
        |> Enum.map(fn {s, props} -> %{slug: s, props: props} end)
      )

  defp member_json(m),
    do: Map.take(m, ~w(id email name status labels note subscribed created_at last_seen_at))

  defp public_settings(s),
    do:
      Map.drop(
        s,
        ~w(pk sk version created_at updated_at kiro_key_ciphertext kiro_key_hint stripe_secret_key stripe_webhook_secret)
      )

  defp json(term), do: MCP.text(Jason.encode!(term, pretty: true))

  defp read(name, desc, props, required \\ []),
    do: tool(name, desc, props, required, %{"readOnlyHint" => true, "destructiveHint" => false})

  defp write(name, desc, props, required \\ []),
    do: tool(name, desc, props, required, %{"readOnlyHint" => false, "destructiveHint" => false})

  defp destructive(name, desc, props, required),
    do: tool(name, desc, props, required, %{"readOnlyHint" => false, "destructiveHint" => true})

  defp tool(name, description, props, required, annotations) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{"type" => "object", "properties" => props, "required" => required},
      "annotations" =>
        Map.put(annotations, "title", name |> String.replace("_", " ") |> String.capitalize())
    }
  end

  defp str(d), do: %{"type" => "string", "description" => d}
  defp int(d), do: %{"type" => "integer", "description" => d}
  defp bool(d), do: %{"type" => "boolean", "description" => d}
  defp obj(d), do: %{"type" => "object", "description" => d}
  defp arr(d), do: %{"type" => "array", "description" => d, "items" => %{}}
end
