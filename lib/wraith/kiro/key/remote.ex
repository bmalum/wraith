defmodule Wraith.Kiro.Key.Remote do
  @moduledoc """
  Verifies a Kiro API key against the Kiro control plane: a cheap
  `GetUsageLimits` call with `TokenType: API_KEY`. A live key answers 200
  with the subscription's limits; a revoked or unknown one gets
  `AccessDeniedException` ("Invalid token").
  """
  @behaviour Wraith.Kiro.Key

  @endpoint "https://management.us-east-1.kiro.dev"
  @target "com.amazon.aws.codewhisperer.runtime.AmazonCodeWhispererService.GetUsageLimits"

  @impl true
  def verify(key) do
    req =
      Req.new(
        url: @endpoint,
        method: :post,
        headers: [
          {"authorization", "Bearer " <> key},
          {"tokentype", "API_KEY"},
          {"content-type", "application/x-amz-json-1.0"},
          {"x-amz-target", @target}
        ],
        body: Jason.encode!(%{origin: "AI_EDITOR"}),
        receive_timeout: 8_000,
        retry: false
      )
      |> Req.merge([])

    case Req.request(req) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200}} ->
        {:ok, %{}}

      {:ok, %{status: s, body: body}} when s in [400, 401, 403] and is_map(body) ->
        if String.contains?(to_string(body["__type"]), "AccessDenied"),
          do: {:error, :invalid},
          else: {:error, {:http, s}}

      {:ok, %{status: s}} ->
        {:error, {:http, s}}

      {:error, _} ->
        {:error, :unreachable}
    end
  end
end
