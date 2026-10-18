defmodule WraithWeb.Themes do
  @moduledoc "The installed themes and the one the site uses."

  @themes [WraithWeb.Themes.Paper, WraithWeb.Themes.Ink]
  @default "paper"

  def all, do: @themes

  @doc "Tell `Wraith.Settings` which names are valid (called at boot)."
  def register, do: Application.put_env(:wraith, :themes, names())
  def names, do: Enum.map(@themes, & &1.info().name)
  def infos, do: Enum.map(@themes, & &1.info())
  def default, do: @default

  @spec get(String.t() | nil) :: module()
  def get(name), do: Enum.find(@themes, hd(@themes), &(&1.info().name == name))

  @doc "The theme the settings name (or the default)."
  def current, do: get(Wraith.Settings.get()["theme"])
end
