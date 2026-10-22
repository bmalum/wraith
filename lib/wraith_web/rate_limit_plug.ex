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

  @doc """
  The client IP as a string.

  `X-Forwarded-For` is a list the *client* starts and each proxy appends to,
  so the first hop is whatever the client wrote — trusting it lets anyone
  pick their own rate-limit bucket (or someone else's, to lock them out).
  Only the hop appended by our own load balancer is trustworthy: with
  `:trusted_proxies` = N, that is the N-th address from the end. With no
  trusted proxies configured, the socket address is the truth.
  """
  def client_ip(conn) do
    trusted = Application.get_env(:wraith, :trusted_proxies, 0)

    with n when n > 0 <- trusted,
         [forwarded | _] <- get_req_header(conn, "x-forwarded-for"),
         hops = forwarded |> String.split(",") |> Enum.map(&String.trim/1),
         ip when is_binary(ip) and ip != "" <- Enum.at(hops, -n) do
      ip
    else
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
