defmodule Wraith.Config do
  @moduledoc """
  What the core needs to know about how the site is served, in one place.

  Feeds, newsletter links, the API and the MCP tools build absolute URLs;
  settings validation needs the installed theme names. Those facts live in
  the web layer (the endpoint, the theme registry), so instead of `Wraith.*`
  reaching into `WraithWeb.*` all over, this module is the one seam: prod sets
  `:site_url` in `runtime.exs`, the web layer registers the themes at boot,
  and dev/test fall back to the endpoint's own URL.
  """

  @doc "The public origin of the site, no trailing slash: `https://blog.example.com`."
  @spec site_url() :: String.t()
  def site_url do
    Application.get_env(:wraith, :site_url) || WraithWeb.Endpoint.url()
  end

  @doc "The public hostname (for `noreply@…`)."
  @spec host() :: String.t()
  def host, do: URI.parse(site_url()).host || "localhost"

  @doc "Installed theme names (registered by `WraithWeb.Themes.register/0` at boot)."
  @spec theme_names() :: [String.t()]
  def theme_names, do: Application.get_env(:wraith, :themes, [])

  @doc "Installed themes' info maps (`name`, `label`, `layout_name`, …)."
  @spec theme_infos() :: [map()]
  def theme_infos, do: Application.get_env(:wraith, :theme_infos, [])
end
