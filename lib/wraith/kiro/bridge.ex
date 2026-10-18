defmodule Wraith.Kiro.Bridge do
  @moduledoc """
  The studio's MCP bridge, ported from shadow_corp: how the agent reaches
  the site's tools without any public endpoint or secret in the VM.

      KAS ─http─▶ shim 127.0.0.1:8090/mcp/studio ══WS (Phoenix dials :8080/bridge)══▶ Studio.Server ─▶ handle/2

  The shim turns each HTTP request into a JSON-RPC request on the bridge
  WebSocket (`bridge/http`, params `%{method, path, headers, body}`); we
  answer with `handle/2`'s `%{status, headers, body}`.

  The one route is `POST /mcp/studio`, served by `Wraith.Studio.Tools`.
  The request must carry the bearer token (`token/0`, an HMAC under the
  endpoint's secret) that only appears in the agent's definition; a wrong
  one is `403` (not `401`: a `WWW-Authenticate: Bearer` makes KAS start
  OAuth against us).
  """
  alias Wraith.Kiro.MCP
  alias Wraith.Studio.Tools

  @mcp_port 8090

  @doc "The URL KAS uses for the studio's tools (inside the VM)."
  def url, do: "http://127.0.0.1:#{@mcp_port}/mcp/studio"

  def token do
    :crypto.mac(:hmac, :sha256, secret(), "bridge-studio") |> Base.url_encode64(padding: false)
  end

  def headers, do: %{"authorization" => "Bearer " <> token()}

  @spec handle(term(), map()) :: %{status: integer(), headers: map(), body: String.t()}
  def handle(context, %{"method" => method, "path" => path} = req) do
    case {method, route(path)} do
      {_, :none} -> reply(404, "not found")
      {"GET", _} -> reply(405, "", %{"allow" => "POST, DELETE"})
      {"DELETE", _} -> reply(204, "")
      {"POST", :studio} -> post(context, req)
      _ -> reply(405, "", %{"allow" => "POST, DELETE"})
    end
  end

  def handle(_context, _req), do: reply(400, "bad bridge request")

  defp route(path) do
    case String.split(URI.parse(path || "").path || "", "/", trim: true) do
      ["mcp", "studio"] -> :studio
      _ -> :none
    end
  end

  defp post(context, req) do
    with :ok <- authorize(req),
         {:ok, msg} <- decode(req["body"]) do
      replies =
        msg
        |> List.wrap()
        |> Enum.map(&MCP.handle(Tools, context, &1, "studio"))
        |> Enum.reject(&is_nil/1)

      headers = Map.put(json(), "mcp-session-id", header(req, "mcp-session-id") || "studio")

      case {msg, replies} do
        {_, []} -> reply(202, "", %{"mcp-session-id" => "studio"})
        {m, [one]} when is_map(m) -> reply(200, Jason.encode!(one), headers)
        {_, many} -> reply(200, Jason.encode!(many), headers)
      end
    else
      :unauthorized -> reply(403, "wrong studio token")
      {:rpc_error, code, message} -> reply(400, Jason.encode!(rpc_error(code, message)), json())
    end
  end

  defp authorize(req) do
    given = header(req, "authorization") || ""
    if Plug.Crypto.secure_compare(given, "Bearer " <> token()), do: :ok, else: :unauthorized
  end

  defp decode(body) do
    case Jason.decode(body || "") do
      {:ok, m} when is_map(m) ->
        {:ok, m}

      {:ok, [_ | _] = l} ->
        if Enum.all?(l, &is_map/1), do: {:ok, l}, else: {:rpc_error, -32600, "invalid request"}

      {:ok, _} ->
        {:rpc_error, -32600, "invalid request"}

      {:error, _} ->
        {:rpc_error, -32700, "parse error"}
    end
  end

  defp rpc_error(code, message),
    do: %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => code, "message" => message}}

  defp json, do: %{"content-type" => "application/json"}

  defp header(req, name),
    do: Enum.find_value(req["headers"] || %{}, fn {k, v} -> String.downcase(k) == name && v end)

  defp secret,
    do:
      Application.get_env(:wraith, WraithWeb.Endpoint)[:secret_key_base] ||
        raise("secret_key_base is not configured")

  defp reply(status, body, headers \\ %{}), do: %{status: status, headers: headers, body: body}
end
