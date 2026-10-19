defmodule WraithWeb.ErrorHTMLTest do
  use WraithWeb.ConnCase, async: false

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "404 wears the site's theme" do
    html = render_to_string(WraithWeb.ErrorHTML, "404", "html", [])
    assert html =~ "<!DOCTYPE html>"
    assert html =~ ~s(id="error-page")
    assert html =~ "Page not found"
    assert html =~ ~s(href="/themes/base.css")
    assert html =~ ~s(data-skin="paper")
    assert html =~ ~s(name="robots" content="noindex")
    # the theme's chrome is there: masthead/nav from the editorial layout
    assert html =~ "masthead"
  end

  test "500 wears the theme too" do
    html = render_to_string(WraithWeb.ErrorHTML, "500", "html", [])
    assert html =~ "Something went wrong"
    assert html =~ ~s(href="/themes/base.css")
  end

  test "a real 404 through the endpoint is themed", %{conn: conn} do
    owner_fixture()
    {:ok, _} = Wraith.Settings.update(%{"theme" => "ink"})

    # in test the endpoint re-raises; assert_error_sent captures what the
    # error handler would have sent
    assert {404, _headers, body} =
             assert_error_sent(404, fn -> get(conn, ~p"/no-such-post-anywhere") end)

    assert body =~ ~s(data-skin="ink")
    assert body =~ "Page not found"
  end
end
