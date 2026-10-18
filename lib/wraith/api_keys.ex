defmodule Wraith.ApiKeys do
  @moduledoc """
  Keys for the JSON APIs. Two kinds, as in Ghost:

    * `"content"` — read-only, public content (`/api/content/*`), passed as
      `?key=` like Ghost's Content API key
    * `"admin"` — full access (`/api/admin/*`), sent as
      `Authorization: Bearer <key>`

  A key is `<id>:<secret>`; only the SHA-256 of the secret is stored.
  """
  alias Wraith.Store
  alias Wraith.Store.Keys

  @kinds ~w(content admin)

  def list,
    do: Store.all(Keys.api_keys_index(), index: :gsi1) |> Enum.map(&Map.drop(&1, ["secret_hash"]))

  @doc "Create a key; the raw key is returned once."
  @spec create(String.t(), String.t()) :: {:ok, String.t(), map()} | {:error, String.t()}
  def create(label, kind) when kind in @kinds do
    id = Store.id() |> String.replace("-", "") |> String.slice(0, 24)
    secret = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    {pk, sk} = Keys.api_key(id)

    :ok =
      Store.put(%{
        "pk" => pk,
        "sk" => sk,
        "gsi1pk" => Keys.api_keys_index(),
        "gsi1sk" => Store.now() <> "#" <> id,
        "id" => id,
        "label" => to_string(label),
        "kind" => kind,
        "secret_hash" => hash(secret),
        "last_used_at" => nil
      })

    {:ok, id <> ":" <> secret, Store.get(pk, sk) |> elem(1) |> Map.drop(["secret_hash"])}
  end

  def create(_label, _kind), do: {:error, "kind must be content or admin"}

  def delete(id) do
    {pk, sk} = Keys.api_key(id)
    Store.delete(pk, sk)
  end

  @doc "The key record a raw `<id>:<secret>` identifies, if it is live and of `kind`."
  @spec verify(String.t() | nil, String.t()) :: {:ok, map()} | :error
  def verify(raw, kind) when is_binary(raw) do
    with [id, secret] <- String.split(raw, ":", parts: 2),
         {pk, sk} = Keys.api_key(id),
         {:ok, %{"kind" => ^kind, "secret_hash" => h} = key} <- Store.get(pk, sk),
         true <- Plug.Crypto.secure_compare(h, hash(secret)) do
      Store.update(pk, sk, &Map.put(&1, "last_used_at", Store.now()))
      {:ok, Map.drop(key, ["secret_hash"])}
    else
      _ -> :error
    end
  end

  def verify(_raw, _kind), do: :error

  defp hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
end
