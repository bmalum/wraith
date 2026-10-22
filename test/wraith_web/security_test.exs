defmodule WraithWeb.SecurityTest do
  use WraithWeb.ConnCase, async: false
  import Swoosh.TestAssertions

  alias Wraith.RateLimit

  setup do
    set_swoosh_global()
    %{owner: owner_fixture()}
  end

  test "token bucket" do
    assert :ok = RateLimit.check(:t, "k", 2, 60_000)
    assert :ok = RateLimit.check(:t, "k", 2, 60_000)
    assert {:error, ms} = RateLimit.check(:t, "k", 2, 60_000)
    assert ms > 0 and ms <= 60_000
    assert :ok = RateLimit.check(:t, "other", 2, 60_000), "per key"
    RateLimit.reset(:t, "k")
    assert :ok = RateLimit.check(:t, "k", 2, 60_000)
  end

  test "login is limited per ip", %{owner: owner} do
    bad = fn conn ->
      post(conn, ~p"/admin/login", user: %{email: owner["email"], password: "wrong"})
    end

    for _ <- 1..5, do: assert(redirected_to(bad.(build_conn())) == ~p"/admin/login")
    conn = bad.(build_conn())
    assert conn.status == 302
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many attempts"
    assert get_resp_header(conn, "retry-after") != []

    # a forged X-Forwarded-For does NOT buy a fresh bucket: with no trusted
    # proxy configured the header is ignored and the socket address counts
    conn = build_conn() |> put_req_header("x-forwarded-for", "10.9.8.7, 1.2.3.4") |> bad.()
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many attempts"
  end

  test "magic links are limited per address and per client" do
    {:ok, _} = Wraith.Members.create(%{email: "m@x.io"})

    request = fn ->
      {:ok, view, _} = live(build_conn(), ~p"/members")
      view |> form("#member-login-form", %{email: "m@x.io"}) |> render_submit()
    end

    for _ <- 1..3, do: request.()
    assert request.() =~ "Too many sign-in links"
    # exactly three mails went out
    for _ <- 1..3, do: assert_email_sent(subject: "Sign in to Wraith")
    refute_email_sent()
  end

  test "subscribe is limited per client" do
    subscribe = fn email ->
      {:ok, view, _} = live(build_conn(), ~p"/subscribe")
      view |> form("#subscribe-form", %{email: email, name: ""}) |> render_submit()
    end

    for i <- 1..5, do: subscribe.("r#{i}@x.io")
    assert subscribe.("r6@x.io") =~ "Too many sign-ups"
    assert Wraith.Members.get_by_email("r6@x.io") == nil
  end

  test "api keys cannot be brute-forced; api calls are limited" do
    for _ <- 1..20,
        do: assert(json_response(get(build_conn(), "/api/content/posts?key=a:b"), 401))

    assert json_response(get(build_conn(), "/api/content/posts?key=a:b"), 429)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))

    assert conn.status == 429,
           "mcp shares the failed-auth budget: got #{conn.status} #{conn.resp_body}"
  end

  test "comments are limited per member", %{owner: owner} do
    {:ok, _} = Wraith.Settings.update(%{comments_enabled: true})
    post = post_fixture(owner)
    {:ok, m} = Wraith.Members.create(%{email: "c@x.io", name: "C"})
    token = Wraith.Members.create_session(m)

    conn =
      build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:member_token, token)
      |> Plug.Conn.put_session(:visitor, "v")

    {:ok, view, _} = live(conn, ~p"/#{post["slug"]}")
    for i <- 1..10, do: view |> form("#comment-form", %{body: "c#{i}"}) |> render_submit()
    html = view |> form("#comment-form", %{body: "c11"}) |> render_submit()
    assert html =~ "commenting too fast"
    assert Wraith.Comments.count(post["id"]) == 10
  end

  test "/health answers 200 with the store and 503 without" do
    conn = get(build_conn(), ~p"/health")
    # ok/degraded only — no version, node name or backend error text for the internet
    assert %{"status" => "ok"} = json_response(conn, 200)
    refute Map.has_key?(json_response(conn, 200), "version")
    conn = get(build_conn(), ~p"/health/live")
    assert response(conn, 200) == "ok"
  end
end
