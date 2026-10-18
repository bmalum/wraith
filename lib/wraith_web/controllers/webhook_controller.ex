defmodule WraithWeb.WebhookController do
  @moduledoc "Inbound webhooks. Stripe's body must be verified byte-for-byte, so `WraithWeb.RawBody` keeps it."
  use WraithWeb, :controller

  def stripe(conn, _params) do
    raw = conn.assigns[:raw_body] || ""
    sig = get_req_header(conn, "stripe-signature") |> List.first()

    case Wraith.Billing.handle_webhook(raw, sig) do
      {:ok, type} -> json(conn, %{received: type})
      {:error, reason} -> conn |> put_status(400) |> json(%{error: to_string(reason)})
    end
  end
end
