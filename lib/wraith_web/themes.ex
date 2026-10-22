defmodule WraithWeb.Themes do
  @moduledoc "The installed themes (18, from six layouts) and the one the site uses."

  @themes [
    WraithWeb.Themes.Paper,
    WraithWeb.Themes.Broadsheet,
    WraithWeb.Themes.Gallery,
    WraithWeb.Themes.Ink,
    WraithWeb.Themes.Ledger,
    WraithWeb.Themes.Terminal,
    WraithWeb.Themes.Studio,
    WraithWeb.Themes.Polaroid,
    WraithWeb.Themes.Slate,
    WraithWeb.Themes.Review,
    WraithWeb.Themes.Weekend,
    WraithWeb.Themes.Tabloid,
    WraithWeb.Themes.Plain,
    WraithWeb.Themes.Mono,
    WraithWeb.Themes.Zen,
    WraithWeb.Themes.Diary,
    WraithWeb.Themes.Letters,
    WraithWeb.Themes.Nightshift
  ]
  @default "paper"

  def all, do: @themes
  def names, do: Enum.map(@themes, & &1.info().name)
  def infos, do: Enum.map(@themes, & &1.info())
  def default, do: @default

  @doc "Themes grouped by layout, for the picker."
  def by_layout, do: infos() |> Enum.group_by(& &1.layout_name)

  @doc "Hand the core (`Wraith.Config`) the installed names and infos (called at boot)."
  def register do
    Application.put_env(:wraith, :themes, names())
    Application.put_env(:wraith, :theme_infos, infos())
  end

  @spec get(String.t() | nil) :: module()
  def get(name), do: Enum.find(@themes, hd(@themes), &(&1.info().name == name))

  @doc "The theme the settings name (or the default)."
  def current, do: get(Wraith.Settings.get()["theme"])
end
