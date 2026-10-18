defmodule WraithWeb.RateLimitPlug do
  @moduledoc """
  `plug WraithWeb.RateLimitPlug, scope: :login` — a `Wraith.RateLimit`
  check keyed by client IP (`x-forwarded-for` first hop when behind a
  proxy). Over the limit answers 429 with `Retry-After`; JSON for API
  paths, a flash + redirect for HTML forms.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    scope = Keyword.fetch!(opts, :scope)

    case Wraith.RateLimit.check(scope, client_ip(conn)) do
      :ok ->
        conn

      {:error, retry_ms} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(retry_ms, 1000) + 1))
        |> too_many(scope)
        |> halt()
    end
  end

  defp too_many(%{path_info: [p | _]} = conn, _scope) when p in ["api", "mcp"] do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      429,
      Jason.encode!(%{
        "errors" => [%{"message" => "too many requests", "type" => "TooManyRequestsError"}]
      })
    )
  end

  defp too_many(conn, _scope) do
    conn
    |> Phoenix.Controller.put_flash(:error, "Too many attempts. Wait a minute and try again.")
    |> Phoenix.Controller.redirect(to: referer_or_root(conn))
  end

  defp referer_or_root(conn) do
    case get_req_header(conn, "referer") do
      [ref] -> URI.parse(ref).path || "/"
      _ -> "/"
    end
  end

  @doc "The client IP as a string; the first `x-forwarded-for` hop when present."
  def client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] -> forwarded |> String.split(",") |> hd() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
