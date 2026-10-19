defmodule WraithWeb.LocaleTest do
  @moduledoc "The public site follows the site's `lang`."
  use WraithWeb.ConnCase, async: false

  setup do
    owner = owner_fixture()
    post_fixture(owner)
    :ok = Wraith.Search.rebuild()
    :ok
  end

  test "English by default", %{conn: conn} do
    {:ok, _, html} = live(conn, ~p"/subscribe")
    assert html =~ "New posts in your inbox"
    assert html =~ ~s(lang="en")
  end

  test "German when the site says so — pages, components, plurals", %{conn: conn} do
    {:ok, _} = Wraith.Settings.update(%{"lang" => "de", "comments_enabled" => true})

    {:ok, _, html} = live(conn, ~p"/subscribe")
    assert html =~ ~s(lang="de")
    assert html =~ "Neue Beiträge direkt im Postfach"
    assert html =~ ">Abonnieren<"

    {:ok, _, html} = live(conn, ~p"/hello-world")
    assert html =~ "Min. Lesezeit"
    assert html =~ "Kommentare"

    {:ok, _, html} = live(conn, ~p"/search?q=hello")
    assert html =~ "1 Treffer"

    {:ok, _, html} = live(conn, ~p"/tag/news")
    assert html =~ "1 Beitrag"
  end

  test "regional tags and unknown languages fall back sensibly", %{conn: conn} do
    {:ok, _} = Wraith.Settings.update(%{"lang" => "de-AT"})
    {:ok, _, html} = live(conn, ~p"/subscribe")
    assert html =~ "Abonnieren"

    {:ok, _} = Wraith.Settings.update(%{"lang" => "xx"})
    {:ok, _, html} = live(conn, ~p"/subscribe")
    assert html =~ "New posts in your inbox"
  end

  test "the themed 404 is translated too" do
    {:ok, _} = Wraith.Settings.update(%{"lang" => "de"})
    Gettext.put_locale(WraithWeb.Gettext, WraithWeb.Locale.locale())
    html = Phoenix.Template.render_to_string(WraithWeb.ErrorHTML, "404", "html", [])
    assert html =~ "Seite nicht gefunden"
  end
end
