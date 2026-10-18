defmodule WraithWeb.ConnCase do
  @moduledoc """
  Web tests: a fresh in-memory store per test (so `async: false`), the
  built-in widgets seeded, helpers to create and sign in an owner.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint WraithWeb.Endpoint

      use WraithWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import WraithWeb.ConnCase
    end
  end

  setup _tags do
    Wraith.StoreCase.reset()
    Wraith.RateLimit.reset_all()
    :ok = Wraith.Widgets.seed_builtins()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Create the owner (and finish setup)."
  def owner_fixture(attrs \\ %{}) do
    {:ok, owner} =
      Wraith.Accounts.setup_owner(
        Map.merge(
          %{email: "owner@wraith.test", name: "Owner One", password: "a very long password"},
          attrs
        )
      )

    owner
  end

  @doc "A published post by `author`."
  def post_fixture(author, attrs \\ %{}) do
    {:ok, post} =
      Wraith.Content.create_post(
        Map.merge(
          %{
            title: "Hello World",
            markdown: "# Hi\n\nSome text.",
            author_id: author["id"],
            tags: "news"
          },
          attrs
        )
      )

    {:ok, post} = Wraith.Content.publish_post(post)
    post
  end

  @doc "Sign the conn in as `user`."
  def log_in(conn, user) do
    token = Wraith.Accounts.create_session(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:visitor, "test-visitor")
  end
end
