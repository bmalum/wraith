defmodule WraithWeb.Themes.Mono do
  @moduledoc "Mono: A light monospace column. Reads like a README."
  use WraithWeb.Theme,
    name: "mono",
    label: "Mono",
    description: "A light monospace column. Reads like a README.",
    layout: WraithWeb.Themes.Layouts.Minimal,
    fonts: "https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&display=swap",
    tokens: %{
      "--heading" => "'IBM Plex Mono', ui-monospace, monospace",
      "--body" => "'IBM Plex Mono', ui-monospace, monospace",
      "--mono" => "'IBM Plex Mono', ui-monospace, monospace",
      "--paper" => "#fafaf9",
      "--paper-2" => "#f0f0ee",
      "--rule" => "#dcdcd8",
      "--ink" => "#202020",
      "--ink-2" => "#505050",
      "--ink-3" => "#717171",
      "--accent" => "#2563eb",
      "--radius" => "4px",
      "--measure" => "38rem"
    }
end
