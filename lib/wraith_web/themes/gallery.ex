defmodule WraithWeb.Themes.Gallery do
  @moduledoc "Gallery: Cream and burgundy, a light display serif, airy cards for image-led posts."
  use WraithWeb.Theme,
    name: "gallery",
    label: "Gallery",
    description: "Cream and burgundy, a light display serif, airy cards for image-led posts.",
    layout: WraithWeb.Themes.Layouts.Editorial,
    fonts:
      "https://fonts.googleapis.com/css2?family=Cormorant+Garamond:ital,wght@0,400;0,600;1,400&family=Jost:wght@300;400;500&display=swap",
    tokens: %{
      "--heading" => "'Cormorant Garamond', Georgia, serif",
      "--body" => "'Jost', system-ui, sans-serif",
      "--paper" => "#fbf7f0",
      "--paper-2" => "#f2ebdf",
      "--rule" => "#e3d9c6",
      "--ink" => "#2b2622",
      "--ink-2" => "#5b524a",
      "--ink-3" => "#756d65",
      "--accent" => "#7a1f2b",
      "--radius" => "4px"
    }
end
