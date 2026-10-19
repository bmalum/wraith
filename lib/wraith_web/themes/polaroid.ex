defmodule WraithWeb.Themes.Polaroid do
  @moduledoc "Polaroid: Soft pastel, rounded everything, friendly sans. Cards like prints on a fridge."
  use WraithWeb.Theme,
    name: "polaroid",
    label: "Polaroid",
    description: "Soft pastel, rounded everything, friendly sans. Cards like prints on a fridge.",
    layout: WraithWeb.Themes.Layouts.Grid,
    fonts: "https://fonts.googleapis.com/css2?family=Nunito:wght@400;600;800&display=swap",
    tokens: %{
      "--heading" => "'Nunito', system-ui, sans-serif",
      "--body" => "'Nunito', system-ui, sans-serif",
      "--paper" => "#fff8f3",
      "--paper-2" => "#ffeee4",
      "--rule" => "#f3d9c8",
      "--ink" => "#3b2f2a",
      "--ink-2" => "#6b5a52",
      "--ink-3" => "#7e6e66",
      "--accent" => "#e0607e",
      "--radius" => "22px"
    }
end
