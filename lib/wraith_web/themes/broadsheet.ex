defmodule WraithWeb.Themes.Broadsheet do
  @moduledoc "Broadsheet: Black on white, a newspaper serif, hairline rules, a big first story."
  use WraithWeb.Theme,
    name: "broadsheet",
    label: "Broadsheet",
    description: "Black on white, a newspaper serif, hairline rules, a big first story.",
    layout: WraithWeb.Themes.Layouts.Editorial,
    fonts:
      "https://fonts.googleapis.com/css2?family=Playfair+Display:wght@500;700;900&family=Source+Serif+4:opsz,wght@8..60,400;8..60,600&display=swap",
    tokens: %{
      "--heading" => "'Playfair Display', Georgia, serif",
      "--body" => "'Source Serif 4', Georgia, serif",
      "--paper" => "#ffffff",
      "--paper-2" => "#f4f4f2",
      "--rule" => "#111111",
      "--ink" => "#111111",
      "--ink-2" => "#444444",
      "--ink-3" => "#747474",
      "--accent" => "#b00020",
      "--radius" => "0px"
    }
end
