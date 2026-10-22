defmodule Wraith.Uploads do
  @moduledoc """
  Images (and other files) authors upload: feature images, inline post
  images, avatars. One adapter per environment
  (`config :wraith, Wraith.Uploads, adapter: …`):

    * `Wraith.Uploads.Local` — files under `priv/uploads` (dev, tests, a
      single container with a volume), served at `/uploads/<key>`
    * `Wraith.Uploads.S3` — a bucket through ex_aws; the URL is the
      bucket's public URL or a CDN in front of it (`:public_url`)

  Keys are `<yyyy>/<mm>/<uuid>.<ext>`; `store/3` takes the bytes (or a
  path), checks the type and size (10 MB), and returns `{:ok, url}`.
  """

  @max_bytes 10 * 1024 * 1024
  @types %{
    "image/jpeg" => "jpg",
    "image/png" => "png",
    "image/gif" => "gif",
    "image/webp" => "webp",
    "image/avif" => "avif",
    "image/svg+xml" => "svg",
    "application/pdf" => "pdf"
  }

  @callback put(String.t(), binary(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback delete(String.t()) :: :ok | {:error, term()}
  @callback list(keyword()) :: [
              %{
                key: String.t(),
                url: String.t(),
                size: non_neg_integer(),
                modified: String.t() | nil
              }
            ]

  @variant ~r/\.w\d+\.webp$/

  @doc "Is this key a generated variant (not an original)?"
  def variant_key?(key), do: Regex.match?(@variant, key)

  @doc """
  The image library: uploaded originals (never the resized variants), newest
  first. `limit:` (default 60).
  """
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 60)

    impl().list(opts)
    |> Enum.reject(&variant_key?(&1.key))
    |> Enum.filter(&image_key?(&1.key))
    |> Enum.sort_by(&{&1.modified, &1.key}, :desc)
    |> Enum.take(limit)
  end

  defp image_key?(key),
    do: (key |> Path.extname() |> String.downcase()) in ~w(.jpg .jpeg .png .gif .webp .avif .svg)

  def accepted_types, do: Map.keys(@types)
  def accepted_extensions, do: @types |> Map.values() |> Enum.map(&("." <> &1)) |> Enum.uniq()
  def max_bytes, do: @max_bytes

  def impl, do: Application.get_env(:wraith, __MODULE__, [])[:adapter] || __MODULE__.Local

  @doc """
  Store `content` (binary) under a fresh key for `content_type`. `opts[:name]`
  keeps a readable stem.

  The declared type is only trusted after the bytes agree with it: a browser,
  an agent or a remote server can say `image/png` about anything, and an SVG
  (or an HTML file dressed as one) served from our origin would run script
  with our cookies. `sniff/2` checks magic bytes for every raster type and
  the root element for SVG; PDF must start with `%PDF-`.
  """
  @spec store(binary(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def store(content, content_type, opts \\ []) when is_binary(content) do
    cond do
      byte_size(content) > @max_bytes ->
        {:error, "file is larger than #{div(@max_bytes, 1024 * 1024)} MB"}

      not Map.has_key?(@types, content_type) ->
        {:error, "#{content_type} is not an accepted type"}

      not sniff(content, content_type) ->
        {:error, "the file's contents don't look like #{content_type}"}

      content_type == "image/svg+xml" and not safe_svg?(content) ->
        {:error, "SVG with scripts, event handlers or external references is not accepted"}

      true ->
        key = key_for(content_type, opts[:name])

        case impl().put(key, content, content_type) do
          {:ok, url} ->
            # resized WebP copies beside the original, off the request path
            if Wraith.Images.raster?(content_type) and opts[:variants] != false do
              Task.Supervisor.start_child(Wraith.TaskSupervisor, fn ->
                Wraith.Images.variants(key, content)
              end)
            end

            {:ok, url}

          {:error, why} ->
            {:error, "upload failed: #{inspect(why)}"}
        end
    end
  end

  @doc """
  Like `store/3` but also returns the image's dimensions (nil for non-raster
  types), so a feature image's `width`/`height` can be saved with the post.
  """
  @spec store_image(binary(), String.t(), keyword()) ::
          {:ok, String.t(), map() | nil} | {:error, String.t()}
  def store_image(content, content_type, opts \\ []) do
    with {:ok, url} <- store(content, content_type, opts) do
      dims = if Wraith.Images.raster?(content_type), do: Wraith.Images.dimensions(content)
      {:ok, url, dims}
    end
  end

  @doc "Store a file on disk (a LiveView upload entry's path)."
  def store_file(path, content_type, opts \\ []) do
    with {:ok, content} <- File.read(path) do
      store(content, content_type, opts)
    else
      {:error, why} -> {:error, "could not read the upload: #{inspect(why)}"}
    end
  end

  @doc "Store a file on disk and return its dimensions too."
  def store_image_file(path, content_type, opts \\ []) do
    with {:ok, content} <- File.read(path) do
      store_image(content, content_type, opts)
    else
      {:error, why} -> {:error, "could not read the upload: #{inspect(why)}"}
    end
  end

  def delete(key), do: impl().delete(key)

  # ---- does the content match its declared type? -----------------------------------

  @doc false
  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>, "image/jpeg"), do: true
  def sniff(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>, "image/png"), do: true
  def sniff(<<"GIF87a", _::binary>>, "image/gif"), do: true
  def sniff(<<"GIF89a", _::binary>>, "image/gif"), do: true
  def sniff(<<"RIFF", _::32, "WEBP", _::binary>>, "image/webp"), do: true
  # ISO BMFF: a size then "ftyp" then a brand that starts with "avi"
  def sniff(<<_::32, "ftyp", brand::binary-size(4), _::binary>>, "image/avif"),
    do: String.starts_with?(brand, "avi")

  def sniff(<<"%PDF-", _::binary>>, "application/pdf"), do: true

  def sniff(content, "image/svg+xml") do
    # optional BOM, optional XML declaration / comments / doctype, then <svg
    head =
      content |> binary_part(0, min(byte_size(content), 4096)) |> String.trim_leading("\uFEFF")

    Regex.match?(
      ~r/\A\s*(<\?xml[^>]*\?>\s*)?(<!--.*?-->\s*)*(<!DOCTYPE[^>]*>\s*)?<svg[\s>]/is,
      head
    )
  end

  def sniff(_content, _type), do: false

  # An SVG we serve from our own origin must be inert: no <script>, no
  # on* handlers, no javascript: URLs, no <foreignObject> (HTML inside),
  # no external references (xlink:href/href to http(s) or data:text/html).
  @doc false
  def safe_svg?(content) do
    lower = String.downcase(content)

    not (String.contains?(lower, "<script") or
           String.contains?(lower, "<foreignobject") or
           Regex.match?(~r/\son[a-z]+\s*=/, lower) or
           String.contains?(lower, "javascript:") or
           Regex.match?(~r/href\s*=\s*["']\s*(https?:|data:text)/, lower) or
           String.contains?(lower, "<iframe") or String.contains?(lower, "<embed") or
           String.contains?(lower, "<object"))
  end

  defp key_for(content_type, name) do
    now = DateTime.utc_now()

    stem =
      if name,
        do: name |> Path.rootname() |> Wraith.Slug.slugify() |> String.slice(0, 40),
        else: "file"

    "#{now.year}/#{String.pad_leading("#{now.month}", 2, "0")}/#{stem}-#{String.slice(Wraith.Store.id(), -8, 8)}.#{@types[content_type]}"
  end
end
