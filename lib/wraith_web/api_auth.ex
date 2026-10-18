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
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{
      "errors" => [%{"message" => msg, "type" => "UnauthorizedError"}]
    })
    |> halt()
  end
end
