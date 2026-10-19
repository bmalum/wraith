defmodule WraithWeb.Themes.Tabloid do
  @moduledoc "Tabloid: Loud. Condensed black headlines, yellow highlights, no apologies."
  use WraithWeb.Theme,
    name: "tabloid",
    label: "Tabloid",
    description: "Loud. Condensed black headlines, yellow highlights, no apologies.",
    layout: WraithWeb.Themes.Layouts.Magazine,
    fonts:
      "https://fonts.googleapis.com/css2?family=Archivo+Black&family=Archivo:wght@400;600&display=swap",
    tokens: %{
      "--heading" => "'Archivo Black', Impact, sans-serif",
      "--body" => "'Archivo', system-ui, sans-serif",
      "--paper" => "#ffffff",
      "--paper-2" => "#f0f0f0",
      "--rule" => "#000000",
      "--ink" => "#000000",
      "--ink-2" => "#333333",
      "--ink-3" => "#666666",
      "--accent" => "#ffd400",
      "--radius" => "0px"
    }
end
