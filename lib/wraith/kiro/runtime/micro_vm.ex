defmodule Wraith.Kiro.Runtime.MicroVM do
  @moduledoc """
  `Wraith.Kiro.Runtime` on AWS Lambda MicroVMs (`lambda-microvms` API,
  SigV4 service `lambda`). Ported from shadow_corp; the image is the same
  shim (`microvm/`): lifecycle hooks and `/bridge` on :8080, KAS on :8082.

  Config (`config :wraith, Wraith.Kiro.Runtime.MicroVM`):

    * `:image_arn` (required), `:image_version`
    * `:region` — default `eu-central-1`
    * `:execution_role_arn` — IAM role for the VM (needed for the journal)
    * `:journal_bucket` — S3 bucket the shim ships `~/.kiro` and `/work` to
    * `:max_duration_s` (≤ 28_800), `:idle_s`, `:suspended_s`

  Credentials come from ex_aws's chain (`ExAws.Config.new(:lambda)`), the
  same one the DynamoDB store uses.
  """
  @behaviour Wraith.Kiro.Runtime
  require Logger

  @api "2025-09-09"
  @kas_port 8082
  @shim_port 8080
  @payload_limit 4_096

  @impl true
  def start(payload) do
    cfg = config()
    region = cfg[:region]

    payload =
      case cfg[:journal_bucket] do
        nil ->
          payload

        bucket ->
          Map.put(payload, :journal, %{
            bucket: bucket,
            region: region,
            prefix: payload[:journal_prefix] || "wraith"
          })
      end
      |> Map.delete(:journal_prefix)

    json = Jason.encode!(payload)

    if byte_size(json) > @payload_limit do
      {:error, {:payload_too_large, byte_size(json)}}
    else
      body =
        %{
          imageIdentifier: Keyword.fetch!(cfg, :image_arn),
          ingressNetworkConnectors: [
            "arn:aws:lambda:#{region}:aws:network-connector:aws-network-connector:ALL_INGRESS"
          ],
          egressNetworkConnectors: [
            "arn:aws:lambda:#{region}:aws:network-connector:aws-network-connector:INTERNET_EGRESS"
          ],
          idlePolicy: %{
            autoResumeEnabled: true,
            maxIdleDurationSeconds: cfg[:idle_s],
            suspendedDurationSeconds: cfg[:suspended_s]
          },
          maximumDurationInSeconds: cfg[:max_duration_s],
          runHookPayload: json
        }
        |> maybe_put(:executionRoleArn, cfg[:execution_role_arn])

      # creating a VM is not idempotent: never retry a POST that may have landed
      case call(:post, "/microvms", body, retry: false) do
        {:ok, %{"microvmId" => id, "endpoint" => endpoint}} ->
          {:ok, %{id: id, endpoint: endpoint}}

        {:ok, other} ->
          {:error, {:unexpected, other}}

        error ->
          error
      end
    end
  end

  @impl true
  def status(id) do
    case call(:get, "/microvms/#{id}", nil) do
      {:ok, %{"state" => state}} -> {:ok, normalize_state(state)}
      {:error, {:http, 404, _}} -> {:ok, :terminated}
      error -> error
    end
  end

  @impl true
  def attach(id, endpoint), do: attach_port(id, endpoint, @kas_port, "/")

  @impl true
  def attach_bridge(id, endpoint, opts \\ []) do
    path = if opts[:key], do: "/bridge?key=" <> URI.encode_www_form(opts[:key]), else: "/bridge"
    attach_port(id, endpoint, @shim_port, path)
  end

  defp attach_port(id, endpoint, port, path) do
    body = %{expirationInMinutes: 60, allowedPorts: [%{port: port}]}

    case call(:post, "/microvms/#{id}/auth-token", body) do
      {:ok, %{"authToken" => %{"X-aws-proxy-auth" => token}}} ->
        {:ok,
         %{
           url: "wss://#{endpoint}#{path}",
           protocols: [
             "lambda-microvms",
             "lambda-microvms.authentication.#{token}",
             "lambda-microvms.port.#{port}"
           ],
           expires_at: DateTime.add(DateTime.utc_now(), 60, :minute)
         }}

      {:ok, other} ->
        {:error, {:unexpected, other}}

      error ->
        error
    end
  end

  @impl true
  def list, do: list_page(nil, [])

  defp list_page(token, acc) do
    query =
      URI.encode_query(
        [imageIdentifier: Keyword.fetch!(config(), :image_arn)] ++
          if(token, do: [nextToken: token], else: [])
      )

    case call(:get, "/microvms?" <> query, nil) do
      {:ok, %{} = page} ->
        vms =
          (page["items"] || [])
          |> Enum.map(&%{id: &1["microvmId"], state: normalize_state(&1["state"])})
          |> Enum.reject(&(&1.state == :terminated))

        case page["nextToken"] do
          next when is_binary(next) and next != "" -> list_page(next, acc ++ vms)
          _ -> {:ok, acc ++ vms}
        end

      error ->
        error
    end
  end

  @impl true
  def checkpoint(id, endpoint) do
    body = %{expirationInMinutes: 5, allowedPorts: [%{port: @shim_port}]}

    with {:ok, %{"authToken" => %{"X-aws-proxy-auth" => token}}} <-
           call(:post, "/microvms/#{id}/auth-token", body),
         {:ok, %{status: 200}} <-
           Req.post(
             Req.new(
               url: "https://#{endpoint}/journal/ship",
               headers: [{"x-aws-proxy-auth", token}, {"x-aws-proxy-port", "#{@shim_port}"}],
               receive_timeout: 60_000,
               retry: false
             )
           ) do
      :ok
    else
      other -> {:error, other}
    end
  end

  @impl true
  def suspend(id), do: call(:post, "/microvms/#{id}/suspend", %{}) |> ok()
  @impl true
  def resume(id), do: call(:post, "/microvms/#{id}/resume", %{}) |> ok()
  @impl true
  def terminate(id), do: call(:delete, "/microvms/#{id}", nil) |> ok()

  # ---- HTTP ------------------------------------------------------------------------

  defp call(method, path, body, opts \\ []) do
    region = config()[:region]
    creds = ExAws.Config.new(:lambda, region: region)

    req =
      Req.new(
        method: method,
        url: "https://lambda.#{region}.amazonaws.com/#{@api}#{path}",
        json: body,
        receive_timeout: 20_000,
        retry: Keyword.get(opts, :retry, :transient),
        aws_sigv4: [
          access_key_id: creds.access_key_id,
          secret_access_key: creds.secret_access_key,
          token: creds[:security_token],
          service: :lambda,
          region: region
        ]
      )

    case Req.request(req) do
      {:ok, %{status: s, body: b}} when s in 200..299 ->
        {:ok, if(is_map(b), do: b, else: %{})}

      {:ok, %{status: s, body: b}} ->
        Logger.warning("lambda-microvms #{method} #{path} → #{s} #{inspect(b)}")
        {:error, {:http, s, b}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error

  defp normalize_state("PENDING"), do: :pending
  defp normalize_state("RUNNING"), do: :running
  defp normalize_state("SUSPENDING"), do: :running
  defp normalize_state("SUSPENDED"), do: :suspended
  defp normalize_state("RESUMING"), do: :suspended
  defp normalize_state("TERMINATING"), do: :terminated
  defp normalize_state("TERMINATED"), do: :terminated
  defp normalize_state(other) when other in ["FAILED", "RUN_FAILED"], do: :failed
  defp normalize_state(_), do: :pending

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp config do
    Keyword.merge(
      [region: "eu-central-1", max_duration_s: 28_800, idle_s: 900, suspended_s: 7_200],
      Application.get_env(:wraith, __MODULE__, [])
    )
  end
end
