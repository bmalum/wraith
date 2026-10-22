defmodule WraithWeb.ErrorHTML do
  @moduledoc """
  Error pages that wear the site's theme.

  Phoenix renders these with `layout: false`, outside any LiveView, so this
  module emits a whole document: the theme's `<head>` (fonts, stylesheets,
  tokens), the theme's layout around a short message, and nothing else.

  A 500 may mean the store itself is unreachable, so settings and theme are
  fetched inside a rescue; if that fails the page falls back to a plain,
  unstyled message rather than raising inside the error handler.
  """
  use WraithWeb, :html

  alias WraithWeb.{Layouts, SiteComponents, Themes}

  def render(template, _assigns) do
    status = template |> String.split(".") |> hd() |> String.to_integer()

    # the error path runs outside the router pipelines, so pick the locale
    # here; copy is chosen after that so gettext sees the site's language
    case safe_context() do
      {:ok, site, theme} ->
        Gettext.put_locale(WraithWeb.Gettext, WraithWeb.Locale.locale())
        {title, copy} = copy(status, template)

        # a theme template that raises here would turn a 404 into a crash loop
        try do
          themed(status, title, copy, site, theme)
        rescue
          _ -> plain(status, title, copy)
        end

      :error ->
        {title, copy} = copy(status, template)
        plain(status, title, copy)
    end
  end

  defp copy(404, _),
    do:
      {gettext("Page not found"),
       gettext("That page isn't here. It may have moved, or the link may be old.")}

  defp copy(403, _), do: {gettext("Not allowed"), gettext("You don't have access to this page.")}

  defp copy(500, _),
    do:
      {gettext("Something went wrong"),
       gettext("The site hit an error. It's been noted — try again in a moment.")}

  defp copy(_, template), do: {Phoenix.Controller.status_message_from_template(template), ""}

  defp safe_context do
    site = Wraith.Settings.get()
    {:ok, site, Themes.get(site["theme"])}
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp themed(status, title, copy, site, theme) do
    assigns = %{status: status, title: title, copy: copy, site: site, theme: theme}

    ~H"""
    <!DOCTYPE html>
    <html
      lang={@site["lang"] || "en"}
      data-layout={@theme.info().layout_name}
      data-skin={@theme.info().name}
      data-scheme={@theme.info().tokens["--scheme"] || "light"}
    >
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex" />
        <title>{@title} · {@site["title"]}</title>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <Layouts.theme_head theme={@theme} />
      </head>
      <body>
        <SiteComponents.theme_layout theme={@theme} site={@site}>
          <section class="t-head is-center t-error" id="error-page">
            <p class="t-kicker">{@status}</p>
            <h1 class="t-title">{@title}</h1>
            <p :if={@copy != ""} class="t-lede">{@copy}</p>
            <p class="t-error-actions">
              <a href="/" class="btn-accent">{gettext("Back to the front page")}</a>
              <a href="/search" class="btn-ghost">{gettext("Search")}</a>
            </p>
          </section>
        </SiteComponents.theme_layout>
      </body>
    </html>
    """
  end

  defp plain(status, title, copy) do
    assigns = %{status: status, title: title, copy: copy}

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@status} · {@title}</title>
        <style>
          body { font: 16px/1.5 system-ui, sans-serif; max-width: 36rem; margin: 15vh auto; padding: 0 1.5rem; color: #222; }
          h1 { font-size: 2rem; margin: .25rem 0; } p { color: #555; }
        </style>
      </head>
      <body>
        <p>{@status}</p>
        <h1>{@title}</h1>
        <p>{@copy}</p>
        <p><a href="/">{gettext("Back to the front page")}</a></p>
      </body>
    </html>
    """
  end
end
