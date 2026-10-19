defmodule Wraith.Images do
  @moduledoc """
  Responsive images.

  When a raster image is uploaded, `variants/2` writes resized WebP copies
  beside the original — `<key>.w480.webp`, `<key>.w960.webp`, `<key>.w1600.webp`
  (only the widths smaller than the source) — through the same uploads
  adapter. Nothing is recorded: the variant URLs are *derived* from the
  original's URL, so a template can build a `srcset` from a bare URL with
  `srcset/1`, and an image that pre-dates this (or an SVG, or an external
  URL) just gets no `srcset`.

  `dimensions/1` reads width/height so the editor can save them on the post
  and templates can set `width`/`height` on `<img>` — no layout shift.

  Resizing is best-effort: a failure logs and the original is still used.
  """
  require Logger

  @widths [480, 960, 1600]
  @raster ~w(image/jpeg image/png image/webp image/avif)

  def widths, do: @widths

  @doc "Is this a type we resize? (SVG and GIF are left alone.)"
  def raster?(content_type), do: content_type in @raster

  @doc "Width and height of an image binary, or nil."
  @spec dimensions(binary()) :: %{width: pos_integer(), height: pos_integer()} | nil
  def dimensions(bytes) when is_binary(bytes) do
    case Image.from_binary(bytes) do
      {:ok, img} -> %{width: Image.width(img), height: Image.height(img)}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Write the WebP variants for `key` (the original's storage key) from the
  original bytes. Returns the widths actually written.
  """
  @spec variants(String.t(), binary()) :: [pos_integer()]
  def variants(key, bytes) when is_binary(key) and is_binary(bytes) do
    with {:ok, img} <- Image.from_binary(bytes) do
      source_w = Image.width(img)

      for w <- @widths, w < source_w, reduce: [] do
        acc ->
          with {:ok, small} <- Image.thumbnail(img, w),
               {:ok, webp} <- Image.write(small, :memory, suffix: ".webp", quality: 82),
               {:ok, _} <- Wraith.Uploads.impl().put(variant_key(key, w), webp, "image/webp") do
            [w | acc]
          else
            err ->
              Logger.warning("image variant #{w}w for #{key} failed: #{inspect(err)}")
              acc
          end
      end
      |> Enum.reverse()
    else
      _ -> []
    end
  rescue
    e ->
      Logger.warning("image variants for #{key} failed: #{Exception.message(e)}")
      []
  end

  @doc "The storage key of one variant."
  def variant_key(key, w), do: "#{key}.w#{w}.webp"

  @doc """
  A `srcset` string for an uploaded image URL, or nil when the URL is not one
  of ours (external, SVG, GIF) — the caller then renders a plain `<img>`.

  We can't know which widths exist without a lookup, so every width is
  listed; a missing variant is a 404 the browser falls back from. Variants
  are written for all widths below the source, which for feature images
  (typically ≥1600) is all of them.
  """
  @spec srcset(String.t() | nil) :: String.t() | nil
  def srcset(nil), do: nil

  def srcset(url) when is_binary(url) do
    if resizable_url?(url),
      do: Enum.map_join(@widths, ", ", &"#{url}.w#{&1}.webp #{&1}w"),
      else: nil
  end

  @doc "Default `sizes` for a full-width content image."
  def sizes(:feature), do: "(max-width: 48rem) 100vw, 72rem"
  def sizes(:card), do: "(max-width: 48rem) 100vw, (max-width: 72rem) 50vw, 24rem"
  def sizes(:post), do: "(max-width: 48rem) 100vw, 42rem"

  defp resizable_url?(url) do
    ext =
      url
      |> URI.parse()
      |> Map.get(:path, "")
      |> Kernel.||("")
      |> Path.extname()
      |> String.downcase()

    ours? = String.starts_with?(url, "/uploads/") or uploads_host?(url)
    ours? and ext in ~w(.jpg .jpeg .png .webp .avif)
  end

  defp uploads_host?(url) do
    case Application.get_env(:wraith, Wraith.Uploads, [])[:public_url] do
      base when is_binary(base) and base != "" -> String.starts_with?(url, base)
      _ -> false
    end
  end
end
