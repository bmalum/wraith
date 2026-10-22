defmodule Wraith.Settings do
  @moduledoc """
  The site: one item, read on every public page. `get/0` returns the
  defaults merged with what was saved, so a fresh table is a working site.
  """
  alias Wraith.Store
  alias Wraith.Store.Keys

  @defaults %{
    "title" => "Wraith",
    "description" => "Thoughts, stories and ideas.",
    "lang" => "en",
    "timezone" => "Etc/UTC",
    "posts_per_page" => 10,
    "accent" => "",
    "theme" => "paper",
    "navigation" => [%{"label" => "Home", "url" => "/"}],
    "footer" => "",
    "members_enabled" => true,
    "powered_by" => true,
    "setup_done" => false
  }

  @editable ~w(title description lang timezone posts_per_page accent theme navigation footer members_enabled powered_by stripe_secret_key stripe_webhook_secret stripe_price_id paid_price_label redirects comments_enabled code_injection_head code_injection_foot logo icon cover_image twitter facebook widget_fetch_hosts)

  # secrets are never stored in the clear: `<name>` in → `<name>_ciphertext` + `<name>_hint` at rest
  @secrets ~w(stripe_secret_key stripe_webhook_secret)
  def secret_fields, do: @secrets

  def defaults, do: @defaults

  @spec get() :: map()
  def get do
    {pk, sk} = Keys.site()

    case Store.get(pk, sk) do
      {:ok, item} -> Map.merge(@defaults, item)
      :error -> Map.merge(@defaults, %{"pk" => pk, "sk" => sk})
    end
  end

  @doc "A secret in the clear (for the code that needs it), or nil."
  @spec secret(String.t()) :: String.t() | nil
  def secret(name) when name in @secrets do
    case get()[name <> "_ciphertext"] do
      nil ->
        nil

      c ->
        case Wraith.Vault.decrypt(c),
          do: (
            {:ok, v} -> v
            :error -> nil
          )
    end
  end

  @doc "Is the secret set? (Its hint, e.g. `sk_…abcd`, for the UI.)"
  def secret_hint(name) when name in @secrets, do: get()[name <> "_hint"]

  @doc "Save the editable fields; unknown keys are dropped, bad values refused."
  @spec update(map()) :: {:ok, map()} | {:error, map()}
  def update(attrs) when is_map(attrs) do
    attrs = attrs |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.take(@editable)

    case validate(attrs) do
      %{} = errors when map_size(errors) > 0 ->
        {:error, errors}

      _ ->
        {pk, sk} = Keys.site()

        Store.update(pk, sk, fn current ->
          Map.merge(current || %{}, normalize(attrs))
        end)
        |> case do
          {:ok, item} -> {:ok, Map.merge(@defaults, item)}
          error -> error
        end
    end
  end

  @doc "Flip the setup flag once the owner exists."
  def mark_setup_done do
    {pk, sk} = Keys.site()
    Store.update(pk, sk, &Map.put(&1 || %{}, "setup_done", true))
  end

  def setup_done?, do: get()["setup_done"] == true

  defp validate(attrs) do
    Enum.reduce(attrs, %{}, fn
      {"title", t}, acc when not is_binary(t) or t == "" ->
        Map.put(acc, "title", "can't be blank")

      {"posts_per_page", n}, acc ->
        case to_int(n) do
          i when is_integer(i) and i in 1..100 -> acc
          _ -> Map.put(acc, "posts_per_page", "must be between 1 and 100")
        end

      {"theme", t}, acc ->
        if t in Application.get_env(:wraith, :themes, [t]),
          do: acc,
          else: Map.put(acc, "theme", "is not an installed theme")

      {"accent", a}, acc when is_binary(a) ->
        if a == "" or Regex.match?(~r/^#[0-9a-fA-F]{6}$/, a),
          do: acc,
          else: Map.put(acc, "accent", "must be a hex colour")

      {"accent", _}, acc ->
        Map.put(acc, "accent", "must be a hex colour")

      # these are evaluated on every request (Redirects plug, nav in every
      # layout); a malformed value would 500 the whole site, admin included
      {"redirects", rules}, acc ->
        if is_list(rules) and Enum.all?(rules, &redirect_rule?/1),
          do: acc,
          else: Map.put(acc, "redirects", "must be a list of {from, to} with /paths, from ≠ to")

      {"navigation", items}, acc ->
        if is_list(items) and Enum.all?(items, &nav_item?/1),
          do: acc,
          else: Map.put(acc, "navigation", "must be a list of {label, url}")

      {"widget_fetch_hosts", hosts}, acc ->
        if is_binary(hosts) and Regex.match?(~r/\A[\w.*,\s-]*\z/u, hosts),
          do: acc,
          else: Map.put(acc, "widget_fetch_hosts", "hostnames only, comma or space separated")

      {"lang", l}, acc ->
        if is_binary(l) and Regex.match?(~r/\A[a-zA-Z]{2,3}([-_][a-zA-Z0-9]{2,8})*\z/, l),
          do: acc,
          else: Map.put(acc, "lang", "must be a language tag like en or pt-BR")

      {field, url}, acc when field in ~w(logo icon cover_image facebook) ->
        if url in [nil, ""] or web_or_local_url?(url),
          do: acc,
          else: Map.put(acc, field, "must be an http(s) URL or an upload path")

      _, acc ->
        acc
    end)
  end

  defp redirect_rule?(%{"from" => from, "to" => to} = r) do
    is_binary(from) and is_binary(to) and String.starts_with?(from, "/") and
      (String.starts_with?(to, "/") or web_or_local_url?(to)) and
      String.trim_trailing(from, "*") != to and
      (not Map.has_key?(r, "permanent") or
         r["permanent"] in [true, false, "true", "false", "on", nil])
  end

  defp redirect_rule?(_), do: false

  defp nav_item?(%{"label" => l, "url" => u}),
    do:
      is_binary(l) and l != "" and is_binary(u) and
        (String.starts_with?(u, "/") or web_or_local_url?(u))

  defp nav_item?(_), do: false

  defp web_or_local_url?("/" <> _), do: true

  defp web_or_local_url?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: s, host: h}} when s in ["http", "https"] -> is_binary(h) and h != ""
      _ -> false
    end
  end

  defp web_or_local_url?(_), do: false

  defp normalize(attrs) do
    attrs
    |> Enum.flat_map(fn
      {"posts_per_page", n} ->
        [{"posts_per_page", to_int(n)}]

      {"members_enabled", v} ->
        [{"members_enabled", v in [true, "true", "on"]}]

      {"comments_enabled", v} ->
        [{"comments_enabled", v in [true, "true", "on"]}]

      {"powered_by", v} ->
        [{"powered_by", v in [true, "true", "on"]}]

      # an empty secret leaves the stored one alone; "clear" removes it
      {name, v} when name in @secrets and v in [nil, ""] ->
        []

      {name, "clear"} when name in @secrets ->
        [{name <> "_ciphertext", nil}, {name <> "_hint", nil}]

      {name, v} when name in @secrets ->
        [
          {name <> "_ciphertext", Wraith.Vault.encrypt(to_string(v))},
          {name <> "_hint", hint(to_string(v))}
        ]

      pair ->
        [pair]
    end)
    |> Map.new()
  end

  defp hint(v) when byte_size(v) > 8, do: String.slice(v, 0, 3) <> "…" <> String.slice(v, -4, 4)
  defp hint(_v), do: "set"

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
