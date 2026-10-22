defmodule Wraith.Tokens do
  @moduledoc """
  Signed, expiring tokens for links we put in mail: magic sign-in,
  unsubscribe, password reset. `Plug.Crypto.sign/4` under the endpoint's
  secret with a purpose salt, so a token for one purpose is useless for
  another.

  Two kinds:

    * `verify/2` — stateless, repeatable within the TTL. Right for
      *unsubscribe* and *comment reply* links, which must keep working.
    * `consume/2` — **single use**. The token's hash is written to the store
      with a conditional put (and a TTL) the first time it is presented; a
      second presentation finds it there and is refused. Right for sign-in,
      confirmation and password-reset links, which a mail scanner or a
      forwarded message must not be able to replay.

  Reset tokens are also bound to the password hash they were minted against
  (`sign(:password_reset, {id, binding})`), so a reset link dies the moment
  the password changes by any route.
  """

  alias Wraith.Store
  alias Wraith.Store.Keys

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

  @doc "Verify only (repeatable within the TTL)."
  @spec verify(atom(), String.t()) :: {:ok, term()} | {:error, :invalid | :expired}
  def verify(purpose, token) when is_map_key(@ttl, purpose) and is_binary(token) do
    Plug.Crypto.verify(secret(), salt(purpose), token, max_age: @ttl[purpose])
  end

  def verify(_purpose, _token), do: {:error, :invalid}

  @doc """
  Verify and burn: a valid token is accepted exactly once. The used-token
  record lives as long as the token could have (its TTL), then expires.
  """
  @spec consume(atom(), String.t()) :: {:ok, term()} | {:error, :invalid | :expired | :used}
  def consume(purpose, token) when is_map_key(@ttl, purpose) and is_binary(token) do
    with {:ok, data} <- verify(purpose, token) do
      {pk, sk} = Keys.used_token(hash(token))
      ttl = System.system_time(:second) + @ttl[purpose] + 60

      expires_at =
        DateTime.utc_now() |> DateTime.add(@ttl[purpose] + 60) |> DateTime.to_iso8601()

      case Store.put(
             %{
               "pk" => pk,
               "sk" => sk,
               "gsi1pk" => Keys.expiring_index(),
               "gsi1sk" => expires_at <> "#" <> sk,
               "purpose" => Atom.to_string(purpose),
               "used_at" => Store.now(),
               "expires_at" => expires_at,
               "ttl" => ttl
             },
             condition: :not_exists
           ) do
        :ok -> {:ok, data}
        {:error, :exists} -> {:error, :used}
      end
    end
  end

  def consume(_purpose, _token), do: {:error, :invalid}

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)

  defp salt(purpose), do: "wraith.token." <> Atom.to_string(purpose)

  defp secret,
    do:
      Application.get_env(:wraith, WraithWeb.Endpoint)[:secret_key_base] ||
        raise("secret_key_base is not configured")
end
