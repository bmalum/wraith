defmodule Wraith.Accounts do
  @moduledoc """
  Who writes here. The first user is the owner (created at `/setup`);
  owners add authors. Passwords are bcrypt; a login mints a random session
  token whose SHA-256 is the key of a session item (60 days).

  A user is a plain map: `id`, `email`, `name`, `slug`, `role`
  (`"owner" | "author"`), `bio`, `password_hash`.
  """
  alias Wraith.{Slug, Store}
  alias Wraith.Store.Keys

  @session_days 60

  # ---- users -----------------------------------------------------------------------

  def get_user(id) when is_binary(id) do
    {pk, sk} = Keys.user(id)

    case Store.get(pk, sk) do
      {:ok, u} -> u
      :error -> nil
    end
  end

  def get_user_by_email(email) when is_binary(email) do
    {pk, sk} = Keys.user_email(email)

    case Store.get(pk, sk) do
      {:ok, %{"user_id" => id}} -> get_user(id)
      :error -> nil
    end
  end

  def get_user_by_slug(slug) do
    Enum.find(list_users(), &(&1["slug"] == slug))
  end

  def list_users, do: Store.all(Keys.users_index(), index: :gsi1) |> Enum.map(&public/1)

  def any_users?,
    do: match?({:ok, %{items: [_ | _]}}, Store.query(Keys.users_index(), index: :gsi1, limit: 1))

  @doc "Create a user. The email is unique (a transaction with the email item)."
  @spec create_user(map()) :: {:ok, map()} | {:error, map()}
  def create_user(attrs) do
    attrs = stringify(attrs)
    email = attrs["email"] |> to_string() |> String.trim() |> String.downcase()
    name = attrs["name"] |> to_string() |> String.trim()
    password = attrs["password"] |> to_string()

    errors =
      %{}
      |> put_error(
        "email",
        not Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email),
        "is not an email"
      )
      |> put_error("name", name == "", "can't be blank")
      |> put_error("password", String.length(password) < 10, "must be at least 10 characters")

    if map_size(errors) > 0 do
      {:error, errors}
    else
      id = Store.id()
      {pk, sk} = Keys.user(id)
      {epk, esk} = Keys.user_email(email)

      user = %{
        "pk" => pk,
        "sk" => sk,
        "gsi1pk" => Keys.users_index(),
        "gsi1sk" => email,
        "id" => id,
        "email" => email,
        "name" => name,
        "slug" => Slug.slugify(name),
        "role" => if(attrs["role"] in Wraith.Policy.roles(), do: attrs["role"], else: "author"),
        "bio" => attrs["bio"] || "",
        "password_hash" => Bcrypt.hash_pwd_salt(password)
      }

      case Store.transact([
             {:put, user, condition: :not_exists},
             {:put, %{"pk" => epk, "sk" => esk, "user_id" => id}, condition: :not_exists}
           ]) do
        :ok -> {:ok, Store.get(pk, sk) |> elem(1)}
        {:error, e} when e in [:exists, :conflict] -> {:error, %{"email" => "is already taken"}}
        {:error, e} -> {:error, %{"base" => inspect(e)}}
      end
    end
  end

  @doc "Create the owner and mark setup done. Refused once any user exists."
  def setup_owner(attrs) do
    if any_users?() do
      {:error, %{"base" => "the site already has an owner"}}
    else
      with {:ok, user} <- create_user(Map.put(stringify(attrs), "role", "owner")) do
        {:ok, _} = Wraith.Settings.mark_setup_done()
        {:ok, user}
      end
    end
  end

  @doc "Name, bio, avatar URL, website and social handles."
  def update_profile(%{"id" => id}, attrs) do
    attrs =
      stringify(attrs) |> Map.take(~w(name bio avatar website twitter github mastodon location))

    # these render as href/src on the public site; only web URLs (or our own
    # uploads for the avatar) may go there — never javascript: or data:
    case Enum.find(~w(website mastodon avatar), &(not web_url?(attrs[&1], &1 == "avatar"))) do
      nil ->
        {pk, sk} = Keys.user(id)

        Store.update(pk, sk, fn u ->
          u = Map.merge(u, attrs)

          if attrs["name"] in [nil, ""],
            do: u,
            else: Map.put(u, "slug", Slug.slugify(attrs["name"]))
        end)

      field ->
        {:error, %{field => "must be an http(s) URL"}}
    end
  end

  # nil/"" are fine (clearing); otherwise http(s), or a site-relative upload path
  defp web_url?(nil, _), do: true
  defp web_url?("", _), do: true
  defp web_url?("/uploads/" <> _, true), do: true
  defp web_url?("/images/" <> _, true), do: true

  defp web_url?(url, _) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _ ->
        false
    end
  end

  defp web_url?(_, _), do: false

  @doc "Change a user's role (the caller's right to do so is the caller's business — `Wraith.Policy`)."
  def set_role(%{"id" => id}, role) when role in ["admin", "editor", "author", "contributor"] do
    {pk, sk} = Keys.user(id)
    Store.update(pk, sk, &Map.put(&1, "role", role))
  end

  def set_role(_user, role), do: {:error, %{"role" => "#{role} is not a role you can assign"}}

  @doc "Remove a staff member (never the owner). Their posts stay, attributed to them."
  def delete_user(%{"role" => "owner"}), do: {:error, %{"base" => "the owner cannot be removed"}}

  def delete_user(%{"id" => id, "email" => email}) do
    {pk, sk} = Keys.user(id)
    {epk, esk} = Keys.user_email(email)
    Store.transact([{:delete, pk, sk}, {:delete, epk, esk}])
  end

  @doc "Change the password: the current one must match, the new one must be long enough."
  def change_password(%{"id" => id} = user, current, new) do
    cond do
      not Bcrypt.verify_pass(to_string(current), user["password_hash"]) ->
        {:error, %{"current_password" => "is wrong"}}

      String.length(to_string(new)) < 10 ->
        {:error, %{"password" => "must be at least 10 characters"}}

      true ->
        {pk, sk} = Keys.user(id)
        Store.update(pk, sk, &Map.put(&1, "password_hash", Bcrypt.hash_pwd_salt(new)))
    end
  end

  @doc "Set a new password from a reset link (`Wraith.Tokens` `:password_reset`)."
  def reset_password(token, new) do
    with {:ok, id} <- Wraith.Tokens.verify(:password_reset, token),
         %{} = user <- get_user(id) || {:error, :invalid},
         true <-
           String.length(to_string(new)) >= 10 ||
             {:error, %{"password" => "must be at least 10 characters"}} do
      {pk, sk} = Keys.user(user["id"])
      Store.update(pk, sk, &Map.put(&1, "password_hash", Bcrypt.hash_pwd_salt(new)))
    else
      {:error, %{} = errors} -> {:error, errors}
      {:error, :expired} -> {:error, %{"token" => "has expired"}}
      _ -> {:error, %{"token" => "is not valid"}}
    end
  end

  @doc "Mail a reset link if the address belongs to an author. Always :ok (no enumeration)."
  def request_password_reset(email) do
    case get_user_by_email(to_string(email)) do
      %{} = user -> Wraith.Newsletter.send_password_reset(user)
      nil -> :ok
    end

    :ok
  end

  @social ~w(website twitter github mastodon)
  def social_fields, do: @social

  # ---- passwords & sessions -----------------------------------------------------

  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    case get_user_by_email(email) do
      %{"password_hash" => hash} = user ->
        if Bcrypt.verify_pass(password, hash), do: {:ok, user}, else: {:error, :invalid}

      nil ->
        Bcrypt.no_user_verify()
        {:error, :invalid}
    end
  end

  @doc "Mint a session token for the user; store its hash. Returns the raw token."
  def create_session(%{"id" => user_id}) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    {pk, sk} = Keys.session(hash(token))

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
        "user_id" => user_id,
        "expires_at" =>
          DateTime.utc_now() |> DateTime.add(@session_days, :day) |> DateTime.to_iso8601(),
        "ttl" => System.system_time(:second) + @session_days * 86_400
      })

    token
  end

  @doc "The user behind a session token, or nil."
  def user_by_session(token) when is_binary(token) do
    {pk, sk} = Keys.session(hash(token))

    with {:ok, %{"user_id" => id, "expires_at" => exp}} <- Store.get(pk, sk),
         {:ok, exp, _} <- DateTime.from_iso8601(exp),
         :gt <- DateTime.compare(exp, DateTime.utc_now()) do
      get_user(id)
    else
      _ -> nil
    end
  end

  def user_by_session(_), do: nil

  def delete_session(token) when is_binary(token) do
    {pk, sk} = Keys.session(hash(token))
    Store.delete(pk, sk)
  end

  def delete_session(_), do: :ok

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)

  # ---- helpers ----------------------------------------------------------------------

  @doc "A user without the password hash (for templates and the agent)."
  def public(user), do: Map.drop(user, ["password_hash", "pk", "sk", "gsi1pk", "gsi1sk"])

  defp put_error(errors, _k, false, _msg), do: errors
  defp put_error(errors, k, true, msg), do: Map.put(errors, k, msg)

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
