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
  @doc "Optional: `resources/list` — `[%{uri, name, description, mimeType}]`."
  @callback resources(term()) :: [map()]
  @doc "Optional: `resources/read` — `{:ok, [%{uri, mimeType, text}]} | :error`."
  @callback read_resource(term(), String.t()) :: {:ok, [map()]} | :error
  @optional_callbacks resources: 1, read_resource: 2

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
    caps = %{"tools" => %{"listChanged" => false}}

    caps =
      if supports?(server, :resources, 1),
        do: Map.put(caps, "resources", %{"subscribe" => false, "listChanged" => false}),
        else: caps

    {:ok,
     %{
       "protocolVersion" => if(requested in @protocols, do: requested, else: hd(@protocols)),
       "capabilities" => caps,
       "serverInfo" => %{
         "name" => info.name,
         "version" => Application.spec(:wraith, :vsn) |> to_string()
       },
       "instructions" => info.instructions
     }}
  end

  defp dispatch(server, context, "resources/list", _params) do
    if supports?(server, :resources, 1),
      do: {:ok, %{"resources" => server.resources(context)}},
      else: {:error, -32601, "resources are not supported"}
  end

  defp dispatch(server, context, "resources/read", %{"uri" => uri}) do
    if supports?(server, :read_resource, 2) do
      case server.read_resource(context, uri) do
        {:ok, contents} -> {:ok, %{"contents" => contents}}
        :error -> {:error, -32002, "resource not found: #{uri}"}
      end
    else
      {:error, -32601, "resources are not supported"}
    end
  end

  defp dispatch(_server, _context, "prompts/list", _params), do: {:ok, %{"prompts" => []}}

  defp dispatch(_server, _context, "ping", _params), do: {:ok, %{}}

  defp dispatch(server, context, "tools/list", _params),
    do: {:ok, %{"tools" => server.tools(context)}}

  defp dispatch(server, context, "tools/call", %{"name" => name} = params),
    do: {:ok, server.call(context, name, params["arguments"] || %{})}

  defp dispatch(_server, _context, "tools/call", _params),
    do: {:error, -32602, "tool name missing"}

  defp dispatch(_server, _context, method, _params),
    do: {:error, -32601, "method not found: #{method}"}

  # modules load lazily; ask after loading
  defp supports?(server, fun, arity),
    do: Code.ensure_loaded?(server) and function_exported?(server, fun, arity)

  def text(t), do: %{"content" => [%{"type" => "text", "text" => t}]}
  def error(t), do: %{"content" => [%{"type" => "text", "text" => t}], "isError" => true}
end
