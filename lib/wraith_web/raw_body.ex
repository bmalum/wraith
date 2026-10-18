defmodule WraithWeb.RawBody do
  @moduledoc "A `Plug.Parsers` body reader that keeps the raw bytes of webhook requests in `conn.assigns.raw_body`."

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)

    conn =
      case conn.path_info do
        ["webhooks" | _] ->
          Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> body)

        _ ->
          conn
      end

    {:ok, body, conn}
  end
end
