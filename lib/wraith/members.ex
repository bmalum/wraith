defmodule Wraith.Members do
  @moduledoc """
  Readers who signed up. A member is `id`, `email`, `name`, `status`
  (`"free" | "paid" | "comped"`), `labels`, `note`, `subscribed`
  (newsletter), `stripe_customer_id`, `last_seen_at`. Emails are unique.

  Members sign in with a magic link (`Wraith.Tokens` `:member_login`,
  mailed by `Wraith.Newsletter.send_login_link/2`); `create_session/1`
  mints the cookie token once the link is opened (`WraithWeb.MemberAuth`).
  """

  @session_days 180
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
      |> Map.take(
        ~w(name status labels note subscribed stripe_customer_id stripe_subscription_id last_seen_at)
      )

    attrs =
      if Map.has_key?(attrs, "subscribed"),
        do: Map.put(attrs, "subscribed", attrs["subscribed"] in [true, "true", "on"]),
        else: attrs

    {pk, sk} = Keys.member(id)

    with {:ok, m} <- Store.update(pk, sk, &Map.merge(&1, attrs)) do
      if cid = attrs["stripe_customer_id"] do
        {spk, ssk} = Keys.stripe_customer(cid)
        Store.put(%{"pk" => spk, "sk" => ssk, "member_id" => id})
      end

      {:ok, m}
    end
  end

  def get_by_stripe_customer(customer_id) do
    {pk, sk} = Keys.stripe_customer(customer_id)

    case Store.get(pk, sk) do
      {:ok, %{"member_id" => id}} -> get(id)
      :error -> nil
    end
  end

  @doc "Every member who gets the newsletter."
  def subscribed,
    do: Store.all(Keys.members_index(), index: :gsi1) |> Enum.filter(&(&1["subscribed"] == true))

  def unsubscribe(%{} = member), do: update(member, %{subscribed: false})

  @doc "Delete a member and everything of theirs: comments, sessions."
  def erase(%{"id" => id} = member) do
    for c <- Wraith.Comments.by_member(id), do: Wraith.Comments.delete(c)
    delete(member)
    :ok
  end

  @doc "Every member as CSV (email, name, status, subscribed, labels, created_at)."
  def to_csv do
    rows = list(limit: 100_000).members

    header = "email,name,status,subscribed,labels,created_at\n"

    header <>
      Enum.map_join(rows, "\n", fn m ->
        [
          m["email"],
          m["name"],
          m["status"],
          to_string(m["subscribed"]),
          Enum.join(m["labels"] || [], ";"),
          m["created_at"]
        ]
        |> Enum.map_join(",", &csv_cell/1)
      end)
  end

  defp csv_cell(nil), do: ""

  defp csv_cell(v) do
    v = to_string(v)

    if String.contains?(v, [",", "\"", "\n"]),
      do: "\"" <> String.replace(v, "\"", "\"\"") <> "\"",
      else: v
  end

  @doc "Members from CSV (header row with at least `email`; name, status, labels, subscribed optional). Existing emails are skipped."
  def from_csv(csv) do
    [header | rows] = csv |> String.split(~r/\r?\n/, trim: true)
    cols = header |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    rows
    |> Enum.map(fn line ->
      vals = String.split(line, ",")
      attrs = cols |> Enum.zip(vals) |> Map.new(fn {k, v} -> {k, String.trim(v)} end)
      attrs = Map.update(attrs, "labels", [], &String.split(&1, ";", trim: true))

      attrs =
        if Map.has_key?(attrs, "subscribed"),
          do: Map.put(attrs, "subscribed", attrs["subscribed"] in ["true", "1", "yes"]),
          else: attrs

      create(Map.take(attrs, ~w(email name status labels subscribed note)))
    end)
    |> Enum.count(&match?({:ok, _}, &1))
  end

  @doc "The confirmation link was opened: the member is now subscribed."
  def confirm(%{"id" => id} = member) do
    {pk, sk} = Keys.member(id)
    _ = member
    Store.update(pk, sk, &Map.merge(&1, %{"subscribed" => true, "confirmed_at" => Store.now()}))
  end

  @doc "May this member read a post of this visibility?"
  def can_read?(_member, "public"), do: true
  def can_read?(nil, _visibility), do: false
  def can_read?(%{}, "members"), do: true
  def can_read?(%{"status" => s}, "paid"), do: s in ["paid", "comped"]
  def can_read?(_, _), do: false

  # ---- sessions ---------------------------------------------------------------------

  @doc "Mint a session token for a member; store its hash. Returns the raw token."
  def create_session(%{"id" => member_id} = member) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    {pk, sk} = Keys.member_session(hash(token))

    expires =
      DateTime.utc_now()
      |> DateTime.add(@session_days, :day)
      |> DateTime.truncate(:millisecond)
      |> DateTime.to_iso8601()

    :ok =
      Store.put(%{
        "pk" => pk,
        "sk" => sk,
        "gsi1pk" => Keys.sessions_index(),
        "gsi1sk" => expires <> "#" <> hash(token),
        "member_id" => member_id,
        "expires_at" => expires,
        "ttl" => System.system_time(:second) + @session_days * 86_400
      })

    {:ok, _} = update(member, %{last_seen_at: Store.now()})
    token
  end

  def member_by_session(token) when is_binary(token) do
    {pk, sk} = Keys.member_session(hash(token))

    with {:ok, %{"member_id" => id, "expires_at" => exp}} <- Store.get(pk, sk),
         {:ok, exp, _} <- DateTime.from_iso8601(exp),
         :gt <- DateTime.compare(exp, DateTime.utc_now()) do
      get(id)
    else
      _ -> nil
    end
  end

  def member_by_session(_), do: nil

  def delete_session(token) when is_binary(token) do
    {pk, sk} = Keys.member_session(hash(token))
    Store.delete(pk, sk)
  end

  def delete_session(_), do: :ok

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)

  def delete(%{"id" => id, "email" => email}) do
    {pk, sk} = Keys.member(id)
    {epk, esk} = Keys.member_email(email)
    Store.transact([{:delete, pk, sk}, {:delete, epk, esk}])
  end
end
