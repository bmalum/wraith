defmodule WraithWeb.Locale do
  @moduledoc """
  The public site speaks the site's language.

  `Settings.get()["lang"]` (an IETF tag such as `en`, `de`, `pt-BR`) picks the
  Gettext locale for every public request — the plug for the dead render and
  controllers, the `on_mount` hook for the LiveView process. Unknown or
  untranslated languages fall back to English, which is also the source
  language of every string, so a missing translation is never an empty page.

  Translations live in `priv/gettext/<locale>/LC_MESSAGES/default.po`.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Gettext.put_locale(WraithWeb.Gettext, locale())
    conn
  end

  def on_mount(:put_locale, _params, _session, socket) do
    Gettext.put_locale(WraithWeb.Gettext, locale())
    {:cont, socket}
  end

  @doc "The Gettext locale for the site's `lang`, or `en`."
  def locale do
    (Wraith.Settings.get()["lang"] || "en") |> normalize()
  rescue
    _ -> "en"
  end

  # "de-AT" → "de_AT" if we have it, else "de" if we have it, else "en"
  defp normalize(lang) do
    known = Gettext.known_locales(WraithWeb.Gettext)
    tag = lang |> String.trim() |> String.replace("-", "_")
    base = tag |> String.split("_") |> hd() |> String.downcase()

    cond do
      tag in known -> tag
      base in known -> base
      true -> "en"
    end
  end
end
