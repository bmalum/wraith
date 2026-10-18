defmodule Wraith.Billing do
  @moduledoc """
  Paid memberships through Stripe Checkout, with `Req` against the Stripe
  API (no SDK). Settings hold `stripe_secret_key`, `stripe_webhook_secret`
  and `stripe_price_id` (a recurring price); `configured?/0` is false until
  all three are set, and then:

    * `checkout_url/3` — a Checkout Session in subscription mode for the
      member (the Stripe customer is created on first use and remembered)
    * `handle_webhook/2` — verifies `Stripe-Signature` (HMAC-SHA256, 5 min
      tolerance) and syncs the member: `checkout.session.completed` and
      `customer.subscription.updated` (active/trialing) → `paid`;
      `customer.subscription.deleted` / unpaid → `free`

  `Wraith.Billing.API` is the HTTP seam (swapped for a fake in tests).
  """
  alias Wraith.{Members, Settings}

  @callback post(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}

  def api, do: Application.get_env(:wraith, :stripe_api, __MODULE__.API)

  def configured? do
    s = Settings.get()

    Enum.all?(
      ~w(stripe_secret_key stripe_webhook_secret stripe_price_id),
      &(s[&1] not in [nil, ""])
    )
  end

  @doc "Where to send a member to pay."
  def checkout_url(%{"id" => id} = member, success_url, cancel_url) do
    if configured?() do
      s = Settings.get()

      params =
        %{
          "mode" => "subscription",
          "success_url" => success_url <> "?paid=1",
          "cancel_url" => cancel_url,
          "client_reference_id" => id,
          "line_items[0][price]" => s["stripe_price_id"],
          "line_items[0][quantity]" => "1",
          "metadata[member_id]" => id,
          "subscription_data[metadata][member_id]" => id
        }
        |> then(fn p ->
          case member["stripe_customer_id"] do
            nil -> Map.put(p, "customer_email", member["email"])
            cid -> Map.put(p, "customer", cid)
          end
        end)

      case api().post("/v1/checkout/sessions", params, s["stripe_secret_key"]) do
        {:ok, %{"url" => url}} -> {:ok, url}
        {:ok, other} -> {:error, "unexpected answer from Stripe: #{inspect(other)}"}
        {:error, why} -> {:error, to_string(why)}
      end
    else
      {:error, "Stripe is not configured"}
    end
  end

  @doc "Verify and apply a webhook. Returns `{:ok, event_type} | {:error, reason}`."
  def handle_webhook(raw_body, signature_header) when is_binary(raw_body) do
    secret = Settings.get()["stripe_webhook_secret"] || ""

    with :ok <- verify_signature(raw_body, signature_header, secret),
         {:ok, event} <- Jason.decode(raw_body) do
      apply_event(event)
      {:ok, event["type"]}
    end
  end

  @tolerance 300

  def verify_signature(body, header, secret) when is_binary(header) and secret != "" do
    parts =
      header
      |> String.split(",")
      |> Map.new(fn kv ->
        case String.split(kv, "=", parts: 2),
          do: (
            [k, v] -> {k, v}
            _ -> {kv, ""}
          )
      end)

    ts = parts["t"]
    sig = parts["v1"]

    with true <- (is_binary(ts) and is_binary(sig)) || {:error, :bad_signature_header},
         {ts_i, ""} <- Integer.parse(ts),
         true <-
           abs(System.system_time(:second) - ts_i) <= @tolerance || {:error, :stale_signature} do
      expected =
        :crypto.mac(:hmac, :sha256, secret, ts <> "." <> body) |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(expected, sig), do: :ok, else: {:error, :bad_signature}
    else
      {:error, _} = e -> e
      _ -> {:error, :bad_signature_header}
    end
  end

  def verify_signature(_body, _header, _secret), do: {:error, :bad_signature_header}

  defp apply_event(%{"type" => "checkout.session.completed", "data" => %{"object" => session}}) do
    member_id = get_in(session, ["metadata", "member_id"]) || session["client_reference_id"]

    with %{} = member <- member_id && Members.get(member_id) do
      Members.update(member, %{
        status: "paid",
        stripe_customer_id: session["customer"],
        stripe_subscription_id: session["subscription"]
      })
    end
  end

  defp apply_event(%{"type" => type, "data" => %{"object" => sub}})
       when type in [
              "customer.subscription.updated",
              "customer.subscription.deleted",
              "customer.subscription.created"
            ] do
    member =
      (get_in(sub, ["metadata", "member_id"]) && Members.get(sub["metadata"]["member_id"])) ||
        Members.get_by_stripe_customer(sub["customer"])

    if member do
      status =
        if type != "customer.subscription.deleted" and sub["status"] in ["active", "trialing"],
          do: "paid",
          else: "free"

      Members.update(member, %{
        status: status,
        stripe_customer_id: sub["customer"],
        stripe_subscription_id: sub["id"]
      })
    end
  end

  defp apply_event(_other), do: :ok

  @doc "Build a signed header the way Stripe does (tests, and the docs' sanity check)."
  def sign_for_test(body, secret, ts \\ System.system_time(:second)) do
    "t=#{ts},v1=" <>
      (:crypto.mac(:hmac, :sha256, secret, "#{ts}.#{body}") |> Base.encode16(case: :lower))
  end

  defmodule API do
    @moduledoc false
    @behaviour Wraith.Billing

    @impl true
    def post(path, params, secret) do
      Req.post("https://api.stripe.com" <> path,
        form: params,
        auth: {:bearer, secret},
        receive_timeout: 15_000,
        retry: false
      )
      |> case do
        {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, body}
        {:ok, %{body: %{"error" => %{"message" => m}}}} -> {:error, m}
        {:ok, %{status: s}} -> {:error, "Stripe answered #{s}"}
        {:error, e} -> {:error, Exception.message(e)}
      end
    end
  end
end
