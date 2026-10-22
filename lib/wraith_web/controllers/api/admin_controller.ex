defmodule WraithWeb.Api.AdminController do
  @moduledoc """
  The Admin API (`/api/admin/*`, Admin key or an author's session): CRUD on
  posts, tags, members, widgets; settings; Ghost-compatible export and
  import (`GET /api/admin/db`, `POST /api/admin/db`).
  """
  use WraithWeb, :controller
  alias Wraith.{Accounts, Content, Ghost, Members, Settings, Widgets}

  # ---- posts -------------------------------------------------------------------------

  def posts(conn, params) do
    posts =
      Content.list_all_posts(type: params["type"])
      |> Enum.filter(&(is_nil(params["status"]) or &1["status"] == params["status"]))

    json(conn, %{
      "posts" =>
        Enum.map(posts, &Ghost.post_json(&1, Keyword.merge(ctx(), markdown: true, access: true)))
    })
  end

  def post(conn, %{"id" => id}) do
    case find_post(id) do
      nil ->
        not_found(conn, "post")

      p ->
        json(conn, %{
          "posts" => [Ghost.post_json(p, Keyword.merge(ctx(), markdown: true, access: true))]
        })
    end
  end

  def create_post(conn, params) do
    attrs = post_attrs(params) |> Map.put_new("author_id", actor_id(conn))

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
    with %{} = p <- find_post(id) || :missing,
         {:ok, p} <- Content.update_post(p, post_attrs(params)) do
      json(conn, %{
        "posts" => [Ghost.post_json(p, Keyword.merge(ctx(), markdown: true, access: true))]
      })
    else
      :missing -> not_found(conn, "post")
      {:error, errors} -> validation(conn, errors)
    end
  end

  def delete_post(conn, %{"id" => id}) do
    case find_post(id) do
      nil ->
        not_found(conn, "post")

      p ->
        :ok = Content.delete_post(p)
        send_resp(conn, 204, "")
    end
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
  defp actor(conn),
    do:
      conn.assigns[:current_user] || Enum.find(Accounts.list_users(), &(&1["role"] == "owner")) ||
        hd(Accounts.list_users())

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
