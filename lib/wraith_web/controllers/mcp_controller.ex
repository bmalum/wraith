defmodule WraithWeb.McpController do
  @moduledoc """
  The site's MCP server over HTTP (MCP Streamable HTTP, JSON responses):
  `POST /mcp` takes one JSON-RPC message or a batch and answers in kind;
  notifications get `202`. `GET /mcp` is `405` (no server-initiated
  stream); `DELETE /mcp` is `204` (sessions are stateless).

  Authentication: `Authorization: Bearer <api key>`. An Admin key gets every
  tool (`Wraith.Tools`), a Content key the read-only ones. Writes are made as
  the site's owner. Point a client at it like so:

      {"mcpServers": {"wraith": {"url": "https://<site>/mcp",
                                 "headers": {"Authorization": "Bearer <key>"}}}}
  """
  use WraithWeb, :controller
  alias Wraith.{Accounts, ApiKeys}
  alias Wraith.Kiro.MCP

  def handle(conn, _params) do
    case authenticate(conn) do
      {:ok, ctx} ->
        with {:ok, msg} <- body(conn) do
          replies =
            msg
            |> List.wrap()
            |> Enum.map(&MCP.handle(Wraith.Tools, ctx, &1, "mcp"))
            |> Enum.reject(&is_nil/1)

          conn = put_resp_header(conn, "mcp-session-id", "wraith")

          case {msg, replies} do
            {_, []} -> send_resp(conn, 202, "")
            {m, [one]} when is_map(m) -> json(conn, one)
            {_, many} -> json(conn, many)
          end
        else
          {:error, code, message} -> conn |> put_status(400) |> json(rpc_error(code, message))
        end

      :error ->
        # 403, not 401: a WWW-Authenticate header makes some clients start OAuth discovery
        conn
        |> put_status(403)
        |> json(
          rpc_error(
            -32001,
            "a valid API key is required: Authorization: Bearer <key> (create one at /admin/integrations)"
          )
        )
    end
  end

  def not_allowed(conn, _params),
    do: conn |> put_resp_header("allow", "POST, DELETE") |> send_resp(405, "")

  def close(conn, _params), do: send_resp(conn, 204, "")

  defp authenticate(conn) do
    raw =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> raw] -> raw
        _ -> conn.params["key"]
      end

    owner = Enum.find(Accounts.list_users(), &(&1["role"] == "owner"))

    cond do
      match?({:ok, _}, ApiKeys.verify(raw, "admin")) ->
        {:ok, %{"user_id" => owner && owner["id"], "scope" => "admin"}}

      match?({:ok, _}, ApiKeys.verify(raw, "content")) ->
        {:ok, %{"user_id" => owner && owner["id"], "scope" => "content"}}

      true ->
        :error
    end
  end

  # the parser already decoded JSON; a batch arrives under "_json"
  defp body(%{body_params: %{"_json" => list}}) when is_list(list),
    do:
      if(Enum.all?(list, &is_map/1) and list != [],
        do: {:ok, list},
        else: {:error, -32600, "invalid request"}
      )

  defp body(%{body_params: %{"jsonrpc" => _} = m}), do: {:ok, m}
  defp body(_conn), do: {:error, -32600, "invalid request: expected a JSON-RPC message"}

  defp rpc_error(code, message),
    do: %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => code, "message" => message}}
end
