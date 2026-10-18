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
end
