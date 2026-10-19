defmodule WraithWeb.Themes.Ink do
  @moduledoc "Ink: Dark terminal. Monospace, a plain dated list, posts set in a narrow column."
  use WraithWeb.Theme,
    name: "ink",
    label: "Ink",
    description: "Dark terminal. Monospace, a plain dated list, posts set in a narrow column.",
    layout: WraithWeb.Themes.Layouts.List,
    fonts:
      "https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=Public+Sans:wght@400;500&display=swap",
    tokens: %{
      "--heading" => "'IBM Plex Mono', ui-monospace, monospace",
      "--body" => "'Public Sans', system-ui, sans-serif",
      "--mono" => "'IBM Plex Mono', ui-monospace, monospace",
      "--paper" => "oklch(16% 0.01 260)",
      "--paper-2" => "oklch(21% 0.01 260)",
      "--rule" => "oklch(30% 0.01 260)",
      "--ink" => "oklch(90% 0.01 90)",
      "--ink-2" => "oklch(72% 0.01 260)",
      "--ink-3" => "oklch(58% 0.01 260)",
      "--accent" => "oklch(85% 0.12 150)",
      "--radius" => "2px",
      "--scheme" => "dark"
    }
end
