defmodule Wraith.Uploads.S3 do
  @moduledoc """
  Uploads in an S3 bucket (`:bucket`), URL from `:public_url` (a CDN or the
  bucket's website endpoint) or the virtual-host bucket URL.
  """
  @behaviour Wraith.Uploads

  defp cfg, do: Application.get_env(:wraith, Wraith.Uploads, [])

  @impl true
  def put(key, content, content_type) do
    object = object(key)

    case ExAws.S3.put_object(Keyword.fetch!(cfg(), :bucket), object, content,
           content_type: content_type,
           cache_control: "public, max-age=31536000, immutable"
         )
         |> ExAws.request() do
      {:ok, _} -> {:ok, url(object)}
      {:error, why} -> {:error, why}
    end
  end

  @impl true
  def delete(key) do
    ExAws.S3.delete_object(Keyword.fetch!(cfg(), :bucket), object(key)) |> ExAws.request()
    :ok
  end

  defp object(key), do: (cfg()[:prefix] || "uploads") <> "/" <> key

  defp url(object) do
    case cfg()[:public_url] do
      nil ->
        "https://#{Keyword.fetch!(cfg(), :bucket)}.s3.#{Application.get_env(:ex_aws, :region) || "eu-central-1"}.amazonaws.com/#{object}"

      base ->
        String.trim_trailing(base, "/") <> "/" <> object
    end
  end
end
