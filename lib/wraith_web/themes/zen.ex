defmodule WraithWeb.Themes.Zen do
  @moduledoc "Zen: Garamond, long measure, very little on the page. Breathe."
  use WraithWeb.Theme,
    name: "zen",
    label: "Zen",
    description: "Garamond, long measure, very little on the page. Breathe.",
    layout: WraithWeb.Themes.Layouts.Minimal,
    fonts:
      "https://fonts.googleapis.com/css2?family=EB+Garamond:ital,wght@0,400;0,500;1,400&display=swap",
    tokens: %{
      "--heading" => "'EB Garamond', Georgia, serif",
      "--body" => "'EB Garamond', Georgia, serif",
      "--paper" => "#fdfcf9",
      "--paper-2" => "#f5f3ec",
      "--rule" => "#e8e4d8",
      "--ink" => "#2e2b26",
      "--ink-2" => "#5f5a51",
      "--ink-3" => "#787266",
      "--accent" => "#4a6c5a",
      "--radius" => "0px",
      "--measure" => "46rem"
    }
end
