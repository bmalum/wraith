defmodule WraithWeb.Api.AdminController do
  @moduledoc """
  The Admin API (`/api/admin/*`): CRUD on posts, tags, members, widgets;
  settings; Ghost-compatible export and import (`GET /api/admin/db`,
  `POST /api/admin/db`).

  Authentication and the acting user come from `WraithWeb.ApiAuth` (an Admin
  key acts as the owner; a staff session acts as itself, reads only). Every
  action is gated by `Wraith.Policy` — the same rules the admin UI applies —
  so a contributor's session sees exactly their own drafts here too.
  """
  use WraithWeb, :controller
  alias Wraith.{Accounts, Content, Ghost, Members, Policy, Settings, Widgets}
  import WraithWeb.ApiAuth, only: [authorize: 2, authorize: 3]

  # Every action names the Policy action it needs. Post actions also check the
  # subject (an author may edit their own post, not someone else's) inside the
  # action, once the post is loaded. `actor` is set by WraithWeb.ApiAuth.
  @policy %{
    posts: :edit_post,
    post: :edit_post,
    create_post: :create_post,
    update_post: :edit_post,
    delete_post: :delete_post,
    tags: :manage_tags,
    upsert_tag: :manage_tags,
    delete_tag: :manage_tags,
    members: :manage_members,
    members_csv: :manage_members,
    import_members: :manage_members,
    create_member: :manage_members,
    widgets: :manage_widgets,
    upsert_widget: :manage_widgets,
    settings: :manage_settings,
    update_settings: :manage_settings,
    users: :manage_staff,
    export: :manage_settings,
    import: :manage_settings
  }

  plug :authorize_action

  defp authorize_action(conn, _opts) do
    case Map.fetch(@policy, action_name(conn)) do
      # post reads/edits are authorised per post below; listing is for anyone who can write
      {:ok, action} when action in [:edit_post, :delete_post] -> conn
      {:ok, action} -> authorize(conn, action)
      :error -> authorize(conn, :manage_settings)
    end
  end

  # ---- posts -------------------------------------------------------------------------

  def posts(conn, params) do
    actor = conn.assigns.actor

    posts =
      Content.list_all_posts(type: params["type"])
      |> Enum.filter(&(is_nil(params["status"]) or &1["status"] == params["status"]))
      |> Enum.filter(&Policy.can?(actor, :edit_post, &1))

    json(conn, %{
      "posts" =>
        Enum.map(posts, &Ghost.post_json(&1, Keyword.merge(ctx(), markdown: true, access: true)))
    })
  end

  def post(conn, %{"id" => id}) do
    with %{} = p <- find_post(id) || :missing,
         %Plug.Conn{halted: false} = conn <- authorize(conn, :edit_post, p) do
      json(conn, %{
        "posts" => [Ghost.post_json(p, Keyword.merge(ctx(), markdown: true, access: true))]
      })
    else
      :missing -> not_found(conn, "post")
      %Plug.Conn{} = halted -> halted
    end
  end

  def create_post(conn, params) do
    attrs = params |> post_attrs() |> constrain_for(conn.assigns.actor, nil)
    attrs = Map.put(attrs, "author_id", attrs["author_id"] || actor_id(conn))

    case Content.create_post(attrs) do
      {:ok, p} ->
        conn
        |> put_status(201)
        |> json(%{
          "posts" => [Ghost.post_json(p, Keyword.merge(ctx(), markdown: true, access: true))]
        })

      {:error, errors} ->
        validation(conn, errors)
    end
  end

  def update_post(conn, %{"id" => id} = params) do
    actor = conn.assigns.actor

    with %{} = p <- find_post(id) || :missing,
         %Plug.Conn{halted: false} = conn <- authorize(conn, :edit_post, p),
         attrs = params |> post_attrs() |> constrain_for(actor, p),
         {:ok, p} <- Content.update_post(p, attrs) do
      json(conn, %{
        "posts" => [Ghost.post_json(p, Keyword.merge(ctx(), markdown: true, access: true))]
      })
    else
      :missing -> not_found(conn, "post")
      %Plug.Conn{} = halted -> halted
      {:error, errors} -> validation(conn, errors)
    end
  end

  def delete_post(conn, %{"id" => id}) do
    with %{} = p <- find_post(id) || :missing,
         %Plug.Conn{halted: false} = conn <- authorize(conn, :delete_post, p) do
      :ok = Content.delete_post(p)
      send_resp(conn, 204, "")
    else
      :missing -> not_found(conn, "post")
      %Plug.Conn{} = halted -> halted
    end
  end

  # What a caller may set on a post depends on who they are. Publishing-related
  # fields need :publish_post on the post; reassigning authorship needs to be
  # able to edit *anyone's* post (editor and up). Everything else is content.
  @publish_fields ~w(status published_at)
  @author_fields ~w(author_id authors)

  defp constrain_for(attrs, actor, post) do
    subject = post || %{"author_id" => actor["id"], "status" => "draft"}

    attrs
    |> then(fn a ->
      if Policy.can?(actor, :publish_post, subject), do: a, else: Map.drop(a, @publish_fields)
    end)
    |> then(fn a ->
      # may this actor edit a post they don't own? then they may hand one over
      if Policy.can?(actor, :edit_post, %{"author_id" => "someone-else", "status" => "published"}),
         do: a,
         else: Map.drop(a, @author_fields)
    end)
  end

  # Ghost wraps bodies as {"posts": [{...}]}; plain bodies work too
  defp post_attrs(%{"posts" => [p | _]}), do: post_attrs(p)

  defp post_attrs(params),
    do:
      Map.take(
        params,
        ~w(title slug markdown html custom_excerpt status visibility featured tags author_id authors published_at feature_image feature_image_alt canonical_url og_image meta_title meta_description show_toc type)
      )
      |> html_to_markdown()

  defp html_to_markdown(%{"html" => html} = attrs) when not is_map_key(attrs, "markdown"),
    do: attrs |> Map.put("markdown", Ghost.html_to_markdown(html)) |> Map.delete("html")

  defp html_to_markdown(attrs), do: Map.delete(attrs, "html")

  # ---- tags, members, widgets, settings ------------------------------------------------

  def tags(conn, _params),
    do: json(conn, %{"tags" => Content.list_tags() |> Enum.map(&Ghost.tag_json/1)})

  def upsert_tag(conn, %{"slug" => slug} = params) do
    {:ok, t} =
      Content.ensure_tag(Wraith.Slug.slugify(slug), Map.take(params, ~w(name description accent)))

    json(conn, %{"tags" => [Ghost.tag_json(t)]})
  end

  def delete_tag(conn, %{"slug" => slug}) do
    :ok = Content.delete_tag(slug)
    send_resp(conn, 204, "")
  end

  def members(conn, _params),
    do:
      json(conn, %{
        "members" =>
          Members.list(limit: 1000).members
          |> Enum.map(&Map.take(&1, ~w(id email name status labels note subscribed created_at)))
      })

  def members_csv(conn, _params) do
    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="members-#{Date.utc_today()}.csv")
    )
    |> send_resp(200, Members.to_csv())
  end

  def import_members(conn, params) do
    csv =
      case params do
        %{"file" => %Plug.Upload{path: path}} -> File.read!(path)
        %{"csv" => csv} when is_binary(csv) -> csv
        _ -> ""
      end

    json(conn, %{"imported" => Members.from_csv(csv)})
  end

  def create_member(conn, params) do
    case Members.create(member_attrs(params)) do
      {:ok, m} ->
        conn
        |> put_status(201)
        |> json(%{
          "members" => [Map.take(m, ~w(id email name status labels note subscribed created_at))]
        })

      {:error, errors} ->
        validation(conn, errors)
    end
  end

  defp member_attrs(%{"members" => [m | _]}), do: m
  defp member_attrs(p), do: p

  def widgets(conn, _params),
    do:
      json(conn, %{
        "widgets" =>
          Widgets.list()
          |> Enum.map(
            &Map.take(&1, ~w(slug name description kind source props enabled rev builtin))
          )
      })

  def upsert_widget(conn, params) do
    case Widgets.save(Map.take(params, ~w(slug name description kind source props enabled))) do
      {:ok, w} ->
        json(conn, %{"widgets" => [Map.take(w, ~w(slug name description kind enabled rev))]})

      {:error, errors} ->
        validation(conn, errors)
    end
  end

  def settings(conn, _params), do: json(conn, %{"settings" => Ghost.settings_json()})

  def update_settings(conn, params) do
    attrs =
      case params do
        %{"settings" => s} when is_map(s) -> s
        p -> p
      end
      |> Map.drop(["kiro_key_ciphertext", "kiro_key_hint"])

    case Settings.update(attrs) do
      {:ok, _} -> json(conn, %{"settings" => Ghost.settings_json()})
      {:error, errors} -> validation(conn, errors)
    end
  end

  def users(conn, _params),
    do: json(conn, %{"users" => Accounts.list_users() |> Enum.map(&Ghost.author_json/1)})

  # ---- export / import --------------------------------------------------------------

  def export(conn, _params) do
    conn
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="wraith-export-#{Date.utc_today()}.json")
    )
    |> json(Ghost.export())
  end

  def import(conn, params) do
    data =
      case params do
        %{"importfile" => %Plug.Upload{path: path}} -> path |> File.read!() |> Jason.decode()
        %{"db" => _} = body -> {:ok, body}
        %{"data" => _} = body -> {:ok, body}
        _ -> {:error, :no_data}
      end

    with {:ok, decoded} <- data,
         {:ok, counts} <- Ghost.import(decoded, author: actor(conn)) do
      json(conn, %{"imported" => counts})
    else
      {:error, :no_data} ->
        conn
        |> put_status(400)
        |> json(%{
          "errors" => [%{"message" => "send a Ghost export as JSON body or `importfile`"}]
        })

      {:error, %Jason.DecodeError{}} ->
        conn |> put_status(400) |> json(%{"errors" => [%{"message" => "not valid JSON"}]})

      {:error, why} ->
        conn |> put_status(422) |> json(%{"errors" => [%{"message" => to_string(why)}]})
    end
  end

  # ---- helpers -----------------------------------------------------------------------

  defp ctx,
    do: [
      authors: Accounts.list_users() |> Map.new(&{&1["id"], &1}),
      tags: Content.list_tags() |> Map.new(&{&1["slug"], &1})
    ]

  defp find_post(id), do: Content.get_post(id) || Content.get_post_by_slug(id)

  # writes from an API key are attributed to the owner
  # set by WraithWeb.ApiAuth: the session user, or the owner for an Admin key
  defp actor(conn), do: conn.assigns.actor
  defp actor_id(conn), do: actor(conn)["id"]

  defp validation(conn, errors),
    do:
      conn
      |> put_status(422)
      |> json(%{
        "errors" =>
          Enum.map(errors, fn {k, v} ->
            %{"message" => "#{k} #{v}", "property" => k, "type" => "ValidationError"}
          end)
      })

  defp not_found(conn, what),
    do:
      conn
      |> put_status(404)
      |> json(%{"errors" => [%{"message" => "#{what} not found", "type" => "NotFoundError"}]})
end
