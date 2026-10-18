defmodule WraithWeb.ApiAuth do
  @moduledoc """
  API authentication plugs. `:content` reads `?key=` (Ghost's Content API
  convention); `:admin` reads `Authorization: Bearer <id:secret>`, or
  accepts a signed-in author's session. Failures are JSON 401s.
  """
  import Plug.Conn
  alias Wraith.ApiKeys

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

    cond do
      conn.assigns[:current_user] ->
        conn

      match?({:ok, _}, ApiKeys.verify(bearer, "admin")) ->
        assign(conn, :api_key, ApiKeys.verify(bearer, "admin") |> elem(1))

      true ->
        unauthorized(conn, "a valid Admin API key is required (Authorization: Bearer <key>)")
    end
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
