defmodule WraithWeb.Themes.Layouts.Magazine do
  @moduledoc "A hero story, a stream of posts beside a sidebar (about, tags, subscribe)."
  use WraithWeb.Theme.Layout, name: "magazine"

  # the sidebar wants the tags and the newest members count
  def sidebar_tags, do: Wraith.Content.list_tags() |> Enum.sort_by(& &1["name"]) |> Enum.take(12)
end
