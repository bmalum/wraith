defmodule Wraith.Vault do
  @moduledoc """
  Secrets at rest (the Kiro API key): encrypted with a key derived from the
  endpoint's `secret_key_base`, so the store never holds them in the clear.
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

  defp secret do
    Application.get_env(:wraith, WraithWeb.Endpoint)[:secret_key_base] ||
      raise("secret_key_base is not configured")
  end
end
