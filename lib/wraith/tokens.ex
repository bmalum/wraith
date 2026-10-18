defmodule Wraith.Tokens do
  @moduledoc """
  Signed, expiring tokens for links we put in mail: magic sign-in,
  unsubscribe, password reset. `Plug.Crypto.sign/4` under the endpoint's
  secret with a purpose salt, so a token for one purpose is useless for
  another and nothing has to be stored.
  """

  @ttl %{
    member_login: 60 * 60,
    confirm: 7 * 24 * 60 * 60,
    unsubscribe: 365 * 24 * 60 * 60,
    password_reset: 60 * 60,
    comment_reply: 30 * 24 * 60 * 60
  }

  @spec sign(atom(), term()) :: String.t()
  def sign(purpose, data) when is_map_key(@ttl, purpose) do
    Plug.Crypto.sign(secret(), salt(purpose), data, max_age: @ttl[purpose])
  end

  @spec verify(atom(), String.t()) :: {:ok, term()} | {:error, :invalid | :expired}
  def verify(purpose, token) when is_map_key(@ttl, purpose) and is_binary(token) do
    Plug.Crypto.verify(secret(), salt(purpose), token, max_age: @ttl[purpose])
  end

  def verify(_purpose, _token), do: {:error, :invalid}

  defp salt(purpose), do: "wraith.token." <> Atom.to_string(purpose)

  defp secret,
    do:
      Application.get_env(:wraith, WraithWeb.Endpoint)[:secret_key_base] ||
        raise("secret_key_base is not configured")
end
