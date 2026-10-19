defmodule WraithWeb.Themes.Nightshift do
  @moduledoc "Nightshift: Navy and gold, Spectral type. A journal written after dark."
  use WraithWeb.Theme,
    name: "nightshift",
    label: "Nightshift",
    description: "Navy and gold, Spectral type. A journal written after dark.",
    layout: WraithWeb.Themes.Layouts.Journal,
    fonts:
      "https://fonts.googleapis.com/css2?family=Spectral:ital,wght@0,400;0,600;1,400&display=swap",
    tokens: %{
      "--heading" => "'Spectral', Georgia, serif",
      "--body" => "'Spectral', Georgia, serif",
      "--paper" => "#0b1220",
      "--paper-2" => "#141c2e",
      "--rule" => "#263149",
      "--ink" => "#e9e4d6",
      "--ink-2" => "#b6b0a1",
      "--ink-3" => "#837f74",
      "--accent" => "#e0b84d",
      "--radius" => "4px",
      "--scheme" => "dark"
    }
end
