defmodule WraithWeb.Themes.Diary do
  @moduledoc "Diary: Dated entries, a wide serif column, handwriting-like headings."
  use WraithWeb.Theme,
    name: "diary",
    label: "Diary",
    description: "Dated entries, a wide serif column, handwriting-like headings.",
    layout: WraithWeb.Themes.Layouts.Journal,
    fonts:
      "https://fonts.googleapis.com/css2?family=Lora:ital,wght@0,400;1,400&family=Caveat:wght@500;700&display=swap",
    tokens: %{
      "--heading" => "'Caveat', cursive",
      "--body" => "'Lora', Georgia, serif",
      "--paper" => "#fffef8",
      "--paper-2" => "#f8f4e6",
      "--rule" => "#ece5cf",
      "--ink" => "#2c2a24",
      "--ink-2" => "#5a564c",
      "--ink-3" => "#8e887a",
      "--accent" => "#2f6f9f",
      "--radius" => "6px"
    }
end
