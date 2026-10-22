defmodule WraithWeb.ClientIpTest do
  @moduledoc "Rate limits key on an IP the client cannot choose."
  use WraithWeb.ConnCase, async: false

  alias WraithWeb.RateLimitPlug

  setup do
    prev = Application.get_env(:wraith, :trusted_proxies)
    on_exit(fn -> Application.put_env(:wraith, :trusted_proxies, prev || 0) end)
    :ok
  end

  test "with no trusted proxy, X-Forwarded-For is ignored entirely", %{conn: conn} do
    Application.put_env(:wraith, :trusted_proxies, 0)
    conn = put_req_header(conn, "x-forwarded-for", "1.2.3.4, 5.6.7.8")
    assert RateLimitPlug.client_ip(conn) == "127.0.0.1"
  end

  test "with one trusted proxy, only the hop it appended counts", %{conn: conn} do
    Application.put_env(:wraith, :trusted_proxies, 1)
    # the client wrote "1.2.3.4" itself; the balancer appended the real address
    conn = put_req_header(conn, "x-forwarded-for", "1.2.3.4, 203.0.113.9")
    assert RateLimitPlug.client_ip(conn) == "203.0.113.9"

    # a lone forged value with one proxy: the proxy's hop IS the last one
    conn = put_req_header(build_conn(), "x-forwarded-for", "203.0.113.9")
    assert RateLimitPlug.client_ip(conn) == "203.0.113.9"
  end

  test "two proxies: second from the end", %{conn: conn} do
    Application.put_env(:wraith, :trusted_proxies, 2)
    conn = put_req_header(conn, "x-forwarded-for", "9.9.9.9, 203.0.113.9, 10.0.0.1")
    assert RateLimitPlug.client_ip(conn) == "203.0.113.9"
  end

  test "author profile URLs must be http(s)" do
    owner = owner_fixture()

    assert {:error, %{"website" => _}} =
             Wraith.Accounts.update_profile(owner, %{"website" => "javascript:alert(1)"})

    assert {:error, %{"avatar" => _}} =
             Wraith.Accounts.update_profile(owner, %{"avatar" => "data:text/html,hi"})

    assert {:ok, _} =
             Wraith.Accounts.update_profile(owner, %{
               "website" => "https://ada.example",
               "avatar" => "/uploads/x.png"
             })

    assert {:ok, _} = Wraith.Accounts.update_profile(owner, %{"website" => ""})
  end
end
