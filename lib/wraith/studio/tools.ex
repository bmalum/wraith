defmodule Wraith.Studio.Tools do
  @moduledoc """
  The MCP server the studio agent gets (`Wraith.Kiro.MCP` behaviour): the
  site's content, widgets and settings, as tools. The `context` is the
  studio session (`%{"id" => ..., "user_id" => ...}`): writes are made as
  that user.

  Every write is also recorded on the session's transcript by
  `Wraith.Studio.Server`, which sees the `tool_call` updates from KAS.
  """
  @behaviour Wraith.Kiro.MCP

  alias Wraith.{Accounts, Content, Markdown, Members, Settings, Widgets}
  alias Wraith.Kiro.MCP

  @impl true
  def server_info(_ctx) do
    %{
      name: "wraith",
      instructions:
        "Tools for the Wraith site this studio belongs to: read and write posts, " <>
          "pages, tags and settings; write and test Lua widgets. Widgets are embedded " <>
          "in a post with `{{widget slug key=value}}` on a line of its own. " <>
          "Always `widget_test` a widget before `widget_save`."
    }
  end

  @impl true
  def tools(_ctx) do
    [
      tool("site_info", "The site's settings, authors, counts and what widgets exist.", %{}),
      tool(
        "posts_list",
        "List posts or pages (every status). Returns id, title, slug, status, tags, type, updated_at.",
        %{
          "status" => str("draft | scheduled | published; omit for all"),
          "type" => str("post | page; omit for both"),
          "limit" => int("default 50")
        }
      ),
      tool(
        "post_get",
        "One post by id or slug, with its Markdown body.",
        %{"id" => str("post id or slug")},
        ["id"]
      ),
      tool(
        "post_create",
        "Create a draft post or page. Returns the post.",
        %{
          "title" => str("title"),
          "markdown" =>
            str("Markdown body; use {{widget slug ...}} on its own line to embed a widget"),
          "type" => str("post (default) | page"),
          "tags" => str("comma-separated tag names"),
          "custom_excerpt" => str("optional excerpt"),
          "slug" => str("optional URL slug"),
          "feature_image" => str("optional image URL"),
          "visibility" => str("public (default) | members")
        },
        ["title", "markdown"]
      ),
      tool(
        "post_update",
        "Change fields of a post (title, markdown, tags, slug, custom_excerpt, feature_image, visibility, featured, meta_title, meta_description).",
        %{
          "id" => str("post id or slug"),
          "title" => str(""),
          "markdown" => str(""),
          "tags" => str("comma-separated"),
          "slug" => str(""),
          "custom_excerpt" => str(""),
          "feature_image" => str(""),
          "visibility" => str(""),
          "featured" => bool(""),
          "meta_title" => str(""),
          "meta_description" => str("")
        },
        ["id"]
      ),
      tool(
        "post_publish",
        "Publish a post now, or schedule it with an ISO-8601 `at`.",
        %{"id" => str("post id or slug"), "at" => str("optional ISO-8601 datetime")},
        ["id"]
      ),
      tool("post_unpublish", "Back to draft.", %{"id" => str("post id or slug")}, ["id"]),
      tool("post_delete", "Delete a post for good.", %{"id" => str("post id or slug")}, ["id"]),
      tool("tags_list", "Every tag with its post count.", %{}),
      tool(
        "tag_update",
        "Rename or describe a tag.",
        %{"slug" => str(""), "name" => str(""), "description" => str("")},
        ["slug"]
      ),
      tool("widgets_list", "Every widget: slug, name, kind, enabled, props, description.", %{}),
      tool("widget_get", "A widget's definition, with its Lua source.", %{"slug" => str("")}, [
        "slug"
      ]),
      tool(
        "widget_docs",
        "How to write a Lua widget: the three functions, the `wraith.*` helpers, the CSS classes, an example.",
        %{}
      ),
      tool(
        "widget_test",
        "Run Lua widget source without saving: init with props, render, then apply each event in `events` and render again. Returns the HTML and state after each step, or the error.",
        %{
          "source" => str("the Lua chunk"),
          "props" => obj("props as a JSON object"),
          "events" => %{
            "type" => "array",
            "description" => "[{event, payload, visitor}] to apply in order",
            "items" => %{"type" => "object"}
          }
        },
        ["source"]
      ),
      tool(
        "widget_save",
        "Create or update a Lua widget (a new version). Returns the saved widget.",
        %{
          "slug" => str("lowercase, hyphens"),
          "name" => str(""),
          "description" => str("one line"),
          "source" => str("the Lua chunk"),
          "props" => %{
            "type" => "array",
            "description" => "documentation: [{name, type, required, help}]",
            "items" => %{"type" => "object"}
          }
        },
        ["slug", "name", "source"]
      ),
      tool(
        "widget_enable",
        "Enable or disable a widget.",
        %{"slug" => str(""), "enabled" => bool("")},
        ["slug", "enabled"]
      ),
      tool("widget_delete", "Delete a (non built-in) widget.", %{"slug" => str("")}, ["slug"]),
      tool("members_count", "How many members, and the newest few.", %{}),
      tool(
        "settings_update",
        "Change site settings: title, description, navigation ([{label,url}]), footer, accent (hex), posts_per_page, members_enabled.",
        %{
          "title" => str(""),
          "description" => str(""),
          "footer" => str(""),
          "accent" => str("#rrggbb"),
          "posts_per_page" => int(""),
          "members_enabled" => bool(""),
          "navigation" => %{"type" => "array", "items" => %{"type" => "object"}}
        }
      )
    ]
  end

  @impl true
  def call(ctx, name, args) do
    try do
      do_call(ctx, name, args)
    rescue
      e -> MCP.error("#{name} failed: " <> Exception.message(e))
    end
  end

  # ---- site -----------------------------------------------------------------------

  defp do_call(_ctx, "site_info", _args) do
    site = Settings.get() |> Map.drop(~w(pk sk version created_at updated_at kiro_key_ciphertext))

    json(%{
      site: site,
      authors: Accounts.list_users() |> Enum.map(&Map.take(&1, ~w(id name slug role))),
      counts: %{
        published: Content.count_posts("published"),
        drafts: Content.count_posts("draft"),
        scheduled: Content.count_posts("scheduled"),
        members: Members.count()
      },
      widgets: Widgets.list() |> Enum.map(&Map.take(&1, ~w(slug name kind enabled description)))
    })
  end

  defp do_call(_ctx, "settings_update", args) do
    case Settings.update(args) do
      {:ok, site} ->
        json(%{
          ok: true,
          site:
            Map.take(
              site,
              ~w(title description navigation footer accent posts_per_page members_enabled)
            )
        })

      {:error, errors} ->
        MCP.error("settings: " <> inspect(errors))
    end
  end

  # ---- posts ----------------------------------------------------------------------

  defp do_call(_ctx, "posts_list", args) do
    posts =
      Content.list_all_posts(type: args["type"])
      |> Enum.filter(&(is_nil(args["status"]) or &1["status"] == args["status"]))
      |> Enum.take(args["limit"] || 50)
      |> Enum.map(&summary/1)

    json(%{posts: posts})
  end

  defp do_call(_ctx, "post_get", %{"id" => id}) do
    case find_post(id) do
      nil -> MCP.error("no post #{id}")
      post -> json(%{post: full(post)})
    end
  end

  defp do_call(ctx, "post_create", args) do
    attrs =
      args
      |> Map.take(~w(title markdown type tags custom_excerpt slug feature_image visibility))
      |> Map.put("author_id", ctx["user_id"])

    case Content.create_post(attrs) do
      {:ok, post} ->
        json(%{
          ok: true,
          post: full(post),
          url: "/" <> post["slug"],
          editor: "/admin/posts/" <> post["id"]
        })

      {:error, errors} ->
        MCP.error("post_create: " <> inspect(errors))
    end
  end

  defp do_call(_ctx, "post_update", %{"id" => id} = args) do
    with %{} = post <- find_post(id) || {:error, "no post #{id}"},
         {:ok, post} <- Content.update_post(post, Map.drop(args, ["id"])) do
      json(%{ok: true, post: full(post)})
    else
      {:error, %{} = errors} -> MCP.error("post_update: " <> inspect(errors))
      {:error, why} -> MCP.error(to_string(why))
    end
  end

  defp do_call(_ctx, "post_publish", %{"id" => id} = args) do
    at =
      case args["at"] do
        nil ->
          nil

        iso ->
          case DateTime.from_iso8601(iso),
            do: (
              {:ok, dt, _} -> dt
              _ -> :bad
            )
      end

    with false <- at == :bad,
         %{} = post <- find_post(id) || {:error, "no post #{id}"},
         {:ok, post} <- Content.publish_post(post, at) do
      json(%{ok: true, post: summary(post), url: "/" <> post["slug"]})
    else
      true -> MCP.error("`at` must be ISO-8601, e.g. 2027-01-01T10:00:00Z")
      {:error, %{} = errors} -> MCP.error("post_publish: " <> inspect(errors))
      {:error, why} -> MCP.error(to_string(why))
    end
  end

  defp do_call(_ctx, "post_unpublish", %{"id" => id}) do
    with %{} = post <- find_post(id) || {:error, "no post #{id}"},
         {:ok, post} <- Content.unpublish_post(post) do
      json(%{ok: true, post: summary(post)})
    else
      {:error, why} -> MCP.error(inspect(why))
    end
  end

  defp do_call(_ctx, "post_delete", %{"id" => id}) do
    case find_post(id) do
      nil ->
        MCP.error("no post #{id}")

      post ->
        :ok = Content.delete_post(post)
        json(%{ok: true, deleted: post["id"]})
    end
  end

  defp do_call(_ctx, "tags_list", _args) do
    counts = Content.tag_counts()

    json(%{
      tags:
        Content.list_tags()
        |> Enum.map(
          &%{
            slug: &1["slug"],
            name: &1["name"],
            description: &1["description"],
            posts: counts[&1["slug"]] || 0
          }
        )
    })
  end

  defp do_call(_ctx, "tag_update", %{"slug" => slug} = args) do
    {:ok, tag} = Content.update_tag(slug, Map.take(args, ~w(name description)))
    json(%{ok: true, tag: Map.take(tag, ~w(slug name description))})
  end

  # ---- widgets ------------------------------------------------------------------

  defp do_call(_ctx, "widgets_list", _args),
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

  defp do_call(_ctx, "widget_docs", _args), do: MCP.text(widget_docs())

  defp do_call(_ctx, "widget_test", %{"source" => source} = args) do
    alias Wraith.Widgets.Lua
    props = args["props"] || %{}

    meta = fn visitor ->
      %{"instance" => "test", "visitor" => visitor || "tester", "presence" => 1, "post" => nil}
    end

    with :ok <- Lua.check(source),
         {:ok, state} <- Lua.call(source, "init", [props], %{instance: "test"}),
         {:ok, html} <-
           Lua.call(source, "render", [state, props, meta.(nil)], %{instance: "test"}) do
      steps =
        (args["events"] || [])
        |> Enum.reduce_while({[], state}, fn ev, {acc, st} ->
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
        |> elem(0)

      json(%{ok: true, initial: %{state: state, html: html}, steps: steps})
    else
      {:error, why} -> MCP.error("widget_test: " <> to_string(why))
    end
  end

  defp do_call(_ctx, "widget_save", args) do
    case Widgets.save(
           Map.merge(Map.take(args, ~w(slug name description source props)), %{"kind" => "lua"})
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

  defp do_call(_ctx, "members_count", _args) do
    %{members: newest} = Members.list(limit: 5)

    json(%{
      count: Members.count(),
      newest: Enum.map(newest, &Map.take(&1, ~w(email name status created_at)))
    })
  end

  defp do_call(_ctx, name, _args), do: MCP.error("unknown tool #{name}")

  # ---- helpers ------------------------------------------------------------------

  defp find_post(id) when is_binary(id), do: Content.get_post(id) || Content.get_post_by_slug(id)
  defp find_post(_), do: nil

  defp summary(p),
    do:
      Map.take(p, ~w(id title slug status type tags published_at updated_at featured visibility))

  defp full(p),
    do:
      p
      |> summary()
      |> Map.merge(
        Map.take(p, ~w(markdown custom_excerpt excerpt feature_image meta_title meta_description))
      )
      |> Map.put(
        "widgets",
        Markdown.widgets_in(p["markdown"])
        |> Enum.map(fn {s, props} -> %{slug: s, props: props} end)
      )

  defp json(term), do: MCP.text(Jason.encode!(term, pretty: true))

  defp tool(name, description, props, required \\ []) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{"type" => "object", "properties" => props, "required" => required}
    }
  end

  defp str(d), do: %{"type" => "string", "description" => d}
  defp int(d), do: %{"type" => "integer", "description" => d}
  defp bool(d), do: %{"type" => "boolean", "description" => d}
  defp obj(d), do: %{"type" => "object", "description" => d}

  @doc false
  def widget_docs do
    """
    # Writing a Wraith widget (Lua 5.3, sandboxed)

    A widget is one Lua chunk defining three functions. Every embedded *instance*
    shares one state that all readers see live; an event from one browser runs
    `handle`, the new state is saved and every open page re-renders.

        -- name: Clap
        -- description: Readers clap for the post.
        function init(props)                       -- the state a fresh instance starts with
          return { claps = 0 }
        end
        function render(state, props, meta)        -- HTML for a state (a string)
          return '<div class="w-counter">'
            .. '<button class="w-btn" ' .. wraith.action("clap") .. '>👏</button>'
            .. '<span class="w-counter-value">' .. wraith.format(state.claps) .. '</span>'
            .. '<span class="w-counter-label">' .. wraith.escape(props.label or "claps") .. '</span>'
            .. '</div>'
        end
        function handle(state, event, payload, meta)   -- a reader's event → next state
          if event == "clap" then state.claps = state.claps + 1 end
          return state                            -- or error("why") to refuse
        end

    `meta`: `instance`, `visitor` (a stable per-browser id — use it for one-vote-per-reader),
    `presence` (readers on the page now), `post` ({id,title,slug} or nil).
    `props`: the shortcode's key=value pairs as strings (`{{widget clap label="Bravo"}}`).

    Helpers: `wraith.action(event, payload_table)` → the attributes a clickable element
    needs; `wraith.escape(s)`; `wraith.format(n)` (1,234); `wraith.split("a|b", "|")` →
    a table (there is no string.gmatch); `wraith.json(t)`, `wraith.len(t)`, `wraith.keys(t)`.

    Rules: no `os`, `io`, `require`; 250 ms per call; state must be JSON-shaped
    (string keys, numbers, strings, booleans, nested tables). Output is wrapped in
    `<div class="widget">`; use these classes for a native look: `w-btn`,
    `w-counter`/`w-counter-value`/`w-counter-label`, `w-poll-q`/`w-poll-row`/`w-poll-bar`/
    `w-poll-opt`/`w-poll-pct`/`w-poll-choice`/`is-mine`, `w-reactions`/`w-reaction`,
    `w-countdown`/`w-countdown-cell`, `w-visitors`. Inline styles are allowed.

    Test with `widget_test` (source, props, events), save with `widget_save`, embed with
    `{{widget slug key=value}}` on its own line in a post (`id=` names a shared instance).
    """
  end
end
