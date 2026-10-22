defmodule WraithWeb.SiteHooks do
  @moduledoc """
  What every public LiveView needs before it renders: the site settings, the
  theme, and the author directory. One `on_mount` in the two public
  `live_session`s instead of the same twenty lines in seven `mount/3`s.

  `authors` is a map of id → public user, read once per mount; themes and
  components look authors up by id for bylines and cards.
  """
  import Phoenix.Component
  alias Wraith.{Accounts, Settings}
  alias WraithWeb.Themes

  def on_mount(:site, _params, _session, socket) do
    site = Settings.get()

    {:cont,
     socket
     |> assign(:site, site)
     |> assign(:theme, Themes.get(site["theme"]))
     |> assign_new(:authors, fn -> Accounts.list_users() |> Map.new(&{&1["id"], &1}) end)
     |> assign_new(:page_title, fn -> nil end)
     |> assign_new(:meta_description, fn -> nil end)}
  end
end
