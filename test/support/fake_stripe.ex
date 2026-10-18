defmodule Wraith.FakeStripe do
  @moduledoc "Tests: records every Stripe POST to the test process and answers a checkout session."
  @behaviour Wraith.Billing

  @impl true
  def post(path, params, _secret) do
    send(self(), {:stripe_post, path, params})
    {:ok, %{"id" => "cs_fake", "url" => "https://checkout.stripe.test/session_fake"}}
  end
end
