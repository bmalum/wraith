defmodule WraithWeb.ApiAuth do
  @moduledoc """
  API authentication plugs. Failures are JSON 401s.

  `:content` reads `?key=` (Ghost's Content API convention). A Content key is
  semi-public — it ships in front-end code — and only ever reaches published,
  paywall-honouring reads.

  `:admin` resolves an **actor** into `conn.assigns.actor`, which every
  controller action then checks with `Wraith.Policy`:

    * `Authorization: Bearer <id:secret>` with an Admin API key acts as the
      site owner (an Admin key is an owner-level credential by definition);
    * a signed-in staff session acts as that user, with *their* role — but
      only for safe (GET/HEAD) requests. The `/api/admin` pipeline has no
      CSRF protection (it is a JSON API), so a browser session must never
      be able to mutate through it; mutations need a Bearer key.
  """
  import Plug.Conn
  alias Wraith.{Accounts, ApiKeys}

  def init(kind), do: kind

  def call(conn, :content) do
    case ApiKeys.verify(conn.params["key"], "content") do
      {:ok, key} -> assign(conn, :api_key, key)
      :error -> unauthorized(conn, "a valid Content API key is required (?key=)")
    end
  end

  def call(conn, :admin) do
    bearer =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> raw] -> raw
        _ -> nil
      end

    case ApiKeys.verify(bearer, "admin") do
      {:ok, key} ->
        conn
        |> assign(:api_key, key)
        |> assign(:actor, owner_actor(key))

      :error ->
        cond do
          # a browser session may read; writing needs a key (no CSRF on this pipeline)
          conn.assigns[:current_user] && conn.method in ["GET", "HEAD"] ->
            assign(conn, :actor, conn.assigns.current_user)

          conn.assigns[:current_user] ->
            forbidden(conn, "mutations need an Admin API key (Authorization: Bearer <key>)")

          true ->
            unauthorized(conn, "a valid Admin API key is required (Authorization: Bearer <key>)")
        end
    end
  end

  # the owner's record when there is one, else a synthetic owner — an Admin
  # key must never act with *less* than owner rights, and must never be nil
  defp owner_actor(key) do
    case Enum.find(Accounts.list_users(), &(&1["role"] == "owner")) do
      %{} = owner -> Map.put(owner, "api_key_id", key["id"])
      nil -> %{"id" => "api-key:" <> key["id"], "role" => "owner", "name" => key["label"]}
    end
  end

  @doc "403 unless the actor may do `action` on `subject`."
  def authorize(conn, action, subject \\ nil) do
    if Wraith.Policy.can?(conn.assigns[:actor], action, subject),
      do: conn,
      else:
        forbidden(conn, "your role may not #{action |> to_string() |> String.replace("_", " ")}")
  end

  defp forbidden(conn, msg) do
    conn
    |> put_status(403)
    |> Phoenix.Controller.json(%{
      "errors" => [%{"message" => msg, "type" => "NoPermissionError"}]
    })
    |> halt()
  end

  defp unauthorized(conn, msg) do
    # a wrong key is counted against the client: 20 misses a minute, then 429
    case Wraith.RateLimit.check(:api_auth_fail, WraithWeb.RateLimitPlug.client_ip(conn)) do
      :ok ->
        conn

      {:error, _} ->
        conn
        |> put_status(429)
        |> Phoenix.Controller.json(%{
          "errors" => [
            %{"message" => "too many failed attempts", "type" => "TooManyRequestsError"}
          ]
        })
        |> halt()
    end
    |> case do
      %Plug.Conn{halted: true} = c -> c
      conn -> unauthorized_now(conn, msg)
    end
  end

  defp unauthorized_now(conn, msg) do
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{
      "errors" => [%{"message" => msg, "type" => "UnauthorizedError"}]
    })
    |> halt()
  end
end
