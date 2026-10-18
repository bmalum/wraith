defmodule Wraith.Kiro.MCP do
  @moduledoc """
  The MCP plumbing for the studio tool server (JSON-RPC 2.0 over
  Streamable HTTP with plain JSON replies): `initialize`, `ping`,
  `tools/list`, `tools/call`. A server is a module with

      @callback tools(context) :: [tool_spec]
      @callback call(context, name, arguments) :: result_map

  where `context` is whatever `handle/4` is given.
  `handle/4` takes one decoded JSON-RPC message and returns the reply, or
  `nil` for notifications.
  """

  @protocols ~w(2025-11-25 2025-06-18 2025-03-26)

  @callback tools(term()) :: [map()]
  @callback call(term(), String.t(), map()) :: map()
  @callback server_info(term()) :: %{name: String.t(), instructions: String.t()}

  @spec handle(module(), term(), map(), String.t()) :: map() | nil
  def handle(server, context, %{"method" => method, "id" => id} = msg, _label)
      when not is_nil(id) do
    case dispatch(server, context, method, msg["params"] || %{}) do
      {:ok, result} ->
        %{"jsonrpc" => "2.0", "id" => id, "result" => result}

      {:error, code, message} ->
        %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
    end
  end

  # a notification
  def handle(_server, _context, %{"method" => _}, _label), do: nil

  def handle(_server, _context, msg, _label),
    do: %{
      "jsonrpc" => "2.0",
      "id" => msg["id"],
      "error" => %{"code" => -32600, "message" => "invalid request"}
    }

  defp dispatch(server, context, "initialize", params) do
    requested = params["protocolVersion"]
    info = server.server_info(context)

    {:ok,
     %{
       "protocolVersion" => if(requested in @protocols, do: requested, else: hd(@protocols)),
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => info.name, "version" => "1"},
       "instructions" => info.instructions
     }}
  end

  defp dispatch(_server, _context, "ping", _params), do: {:ok, %{}}

  defp dispatch(server, context, "tools/list", _params),
    do: {:ok, %{"tools" => server.tools(context)}}

  defp dispatch(server, context, "tools/call", %{"name" => name} = params),
    do: {:ok, server.call(context, name, params["arguments"] || %{})}

  defp dispatch(_server, _context, "tools/call", _params),
    do: {:error, -32602, "tool name missing"}

  defp dispatch(_server, _context, method, _params),
    do: {:error, -32601, "method not found: #{method}"}

  def text(t), do: %{"content" => [%{"type" => "text", "text" => t}]}
  def error(t), do: %{"content" => [%{"type" => "text", "text" => t}], "isError" => true}
end
