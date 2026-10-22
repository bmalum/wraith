defmodule WraithWeb.UploadsStatic do
  @moduledoc "Serves `/uploads/*` from `Wraith.Uploads.Local.root/0` when the Local adapter is in use."
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["uploads" | _]} = conn, _opts) do
    if Wraith.Uploads.impl() == Wraith.Uploads.Local do
      opts =
        Plug.Static.init(
          at: "/uploads",
          from: Wraith.Uploads.Local.root(),
          cache_control_for_etags: "public, max-age=31536000",
          headers: [
            # never let the browser guess a type, and give uploaded documents
            # no origin to act from: an SVG or PDF opened directly is sandboxed
            {"x-content-type-options", "nosniff"},
            {"content-security-policy", "default-src 'none'; style-src 'unsafe-inline'; sandbox"}
          ]
        )

      Plug.Static.call(conn, opts)
    else
      conn
    end
  end

  def call(conn, _opts), do: conn
end
