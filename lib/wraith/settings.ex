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
    "accent" => "#5b4bff",
    "theme" => "paper",
    "navigation" => [%{"label" => "Home", "url" => "/"}],
    "footer" => "",
    "members_enabled" => true,
    "setup_done" => false
  }

  @editable ~w(title description lang timezone posts_per_page accent theme navigation footer members_enabled stripe_secret_key stripe_webhook_secret stripe_price_id paid_price_label redirects comments_enabled)

  def defaults, do: @defaults

  @spec get() :: map()
  def get do
    {pk, sk} = Keys.site()

    case Store.get(pk, sk) do
      {:ok, item} -> Map.merge(@defaults, item)
      :error -> Map.merge(@defaults, %{"pk" => pk, "sk" => sk})
    end
  end

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
        if Regex.match?(~r/^#[0-9a-fA-F]{6}$/, a),
          do: acc,
          else: Map.put(acc, "accent", "must be a hex colour")

      _, acc ->
        acc
    end)
  end

  defp normalize(attrs) do
    attrs
    |> Map.new(fn
      {"posts_per_page", n} -> {"posts_per_page", to_int(n)}
      {"members_enabled", v} -> {"members_enabled", v in [true, "true", "on"]}
      pair -> pair
    end)
  end

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
