defmodule Wraith.Uploads.Local do
  @moduledoc "Uploads on the local disk under `:root` (default `priv/uploads`), served at `/uploads/`."
  @behaviour Wraith.Uploads

  def root do
    Application.get_env(:wraith, Wraith.Uploads, [])[:root] ||
      Path.join(:code.priv_dir(:wraith), "uploads")
  end

  @impl true
  def put(key, content, _content_type) do
    path = Path.join(root(), key)
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, content) do
      :ok -> {:ok, "/uploads/" <> key}
      error -> error
    end
  end

  @impl true
  def delete(key) do
    File.rm(Path.join(root(), key))
    :ok
  end

  @impl true
  def list(_opts) do
    root = root()

    if File.dir?(root) do
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn path ->
        key = Path.relative_to(path, root)
        %File.Stat{size: size, mtime: mtime} = File.stat!(path, time: :posix)

        %{
          key: key,
          url: "/uploads/" <> key,
          size: size,
          modified: mtime |> DateTime.from_unix!() |> DateTime.to_iso8601()
        }
      end)
    else
      []
    end
  end
end
