defmodule Wraith.Slug do
  @moduledoc "URL slugs: lowercase ASCII, hyphens, nothing else."

  @spec slugify(String.t()) :: String.t()
  def slugify(text) when is_binary(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\x00-\x7F]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "untitled"
      slug -> String.slice(slug, 0, 80)
    end
  end

  def slugify(_), do: "untitled"

  @doc "Is this something a user typed as a slug acceptable as one?"
  def valid?(slug), do: is_binary(slug) and Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, slug)
end
