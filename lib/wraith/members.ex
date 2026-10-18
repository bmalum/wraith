defmodule Wraith.Members do
  @moduledoc """
  Readers who signed up. A member is `id`, `email`, `name`, `status`
  (`"free" | "paid" | "comped"`), `labels`, `note`, `subscribed` (newsletter).
  Emails are unique.
  """
  alias Wraith.Store
  alias Wraith.Store.Keys

  def get(id) do
    {pk, sk} = Keys.member(id)

    case Store.get(pk, sk) do
      {:ok, m} -> m
      :error -> nil
    end
  end

  def get_by_email(email) do
    {pk, sk} = Keys.member_email(email)

    case Store.get(pk, sk) do
      {:ok, %{"member_id" => id}} -> get(id)
      :error -> nil
    end
  end

  def list(opts \\ []) do
    {:ok, %{items: items, next: next}} =
      Store.query(Keys.members_index(),
        index: :gsi1,
        forward: false,
        limit: Keyword.get(opts, :limit, 50),
        start_key: opts[:cursor]
      )

    %{members: items, next: next}
  end

  def count, do: Store.all(Keys.members_index(), index: :gsi1) |> length()

  @spec create(map()) :: {:ok, map()} | {:error, map()}
  def create(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    email = attrs["email"] |> to_string() |> String.trim() |> String.downcase()

    if not Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email) do
      {:error, %{"email" => "is not an email"}}
    else
      id = Store.id()
      {pk, sk} = Keys.member(id)
      {epk, esk} = Keys.member_email(email)
      now = Store.now()

      member = %{
        "pk" => pk,
        "sk" => sk,
        "gsi1pk" => Keys.members_index(),
        "gsi1sk" => now <> "#" <> id,
        "id" => id,
        "email" => email,
        "name" => attrs["name"] |> to_string() |> String.trim(),
        "status" => attrs["status"] || "free",
        "labels" => List.wrap(attrs["labels"]),
        "note" => attrs["note"] || "",
        "subscribed" => Map.get(attrs, "subscribed", true) in [true, "true", "on"]
      }

      case Store.transact([
             {:put, member, condition: :not_exists},
             {:put, %{"pk" => epk, "sk" => esk, "member_id" => id}, condition: :not_exists}
           ]) do
        :ok ->
          {:ok, get(id)}

        {:error, e} when e in [:exists, :conflict] ->
          {:error, %{"email" => "is already a member"}}

        {:error, e} ->
          {:error, %{"base" => inspect(e)}}
      end
    end
  end

  def update(%{"id" => id}, attrs) do
    attrs =
      Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      |> Map.take(~w(name status labels note subscribed))

    {pk, sk} = Keys.member(id)
    Store.update(pk, sk, &Map.merge(&1, attrs))
  end

  def delete(%{"id" => id, "email" => email}) do
    {pk, sk} = Keys.member(id)
    {epk, esk} = Keys.member_email(email)
    Store.transact([{:delete, pk, sk}, {:delete, epk, esk}])
  end
end
