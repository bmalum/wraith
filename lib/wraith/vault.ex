defmodule Wraith.Vault do
  @moduledoc """
  Secrets at rest (the Kiro API key, Stripe keys): encrypted with a dedicated
  key (`config :wraith, Wraith.Vault, key:` — `WRAITH_VAULT_KEY` in prod), so
  the store never holds them in the clear and rotating the session secret
  doesn't destroy them.
  """

  @spec encrypt(String.t()) :: String.t()
  def encrypt(plain) when is_binary(plain),
    do: Plug.Crypto.encrypt(secret(), "wraith.vault", plain)

  @spec decrypt(String.t()) :: {:ok, String.t()} | :error
  def decrypt(cipher) when is_binary(cipher) do
    case Plug.Crypto.decrypt(secret(), "wraith.vault", cipher, max_age: :infinity) do
      {:ok, plain} -> {:ok, plain}
      _ -> :error
    end
  end

  def decrypt(_), do: :error

  # A dedicated key (WRAITH_VAULT_KEY in prod) so cookies can be rotated
  # without losing every stored secret. Dev and test fall back to the
  # endpoint's secret_key_base for convenience.
  defp secret do
    Application.get_env(:wraith, __MODULE__, [])[:key] ||
      Application.get_env(:wraith, WraithWeb.Endpoint)[:secret_key_base] ||
      raise("neither Wraith.Vault :key nor secret_key_base is configured")
  end
end
