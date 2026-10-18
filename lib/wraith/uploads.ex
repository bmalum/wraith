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

  def accepted_types, do: Map.keys(@types)
  def accepted_extensions, do: @types |> Map.values() |> Enum.map(&("." <> &1)) |> Enum.uniq()
  def max_bytes, do: @max_bytes

  def impl, do: Application.get_env(:wraith, __MODULE__, [])[:adapter] || __MODULE__.Local

  @doc "Store `content` (binary) under a fresh key for `content_type`. `opts[:name]` keeps a readable stem."
  @spec store(binary(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def store(content, content_type, opts \\ []) when is_binary(content) do
    cond do
      byte_size(content) > @max_bytes ->
        {:error, "file is larger than #{div(@max_bytes, 1024 * 1024)} MB"}

      not Map.has_key?(@types, content_type) ->
        {:error, "#{content_type} is not an accepted type"}

      true ->
        key = key_for(content_type, opts[:name])

        case impl().put(key, content, content_type) do
          {:ok, url} -> {:ok, url}
          {:error, why} -> {:error, "upload failed: #{inspect(why)}"}
        end
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

  def delete(key), do: impl().delete(key)

  defp key_for(content_type, name) do
    now = DateTime.utc_now()

    stem =
      if name,
        do: name |> Path.rootname() |> Wraith.Slug.slugify() |> String.slice(0, 40),
        else: "file"

    "#{now.year}/#{String.pad_leading("#{now.month}", 2, "0")}/#{stem}-#{String.slice(Wraith.Store.id(), -8, 8)}.#{@types[content_type]}"
  end
end
