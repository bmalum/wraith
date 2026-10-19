defmodule WraithWeb.Themes.Weekend do
  @moduledoc "Weekend: The Sunday supplement: warm orange, Lora headlines, a relaxed stream."
  use WraithWeb.Theme,
    name: "weekend",
    label: "Weekend",
    description: "The Sunday supplement: warm orange, Lora headlines, a relaxed stream.",
    layout: WraithWeb.Themes.Layouts.Magazine,
    fonts:
      "https://fonts.googleapis.com/css2?family=Lora:ital,wght@0,400;0,600;1,400&family=Karla:wght@400;500;700&display=swap",
    tokens: %{
      "--heading" => "'Lora', Georgia, serif",
      "--body" => "'Karla', system-ui, sans-serif",
      "--paper" => "#fffaf3",
      "--paper-2" => "#fcefdc",
      "--rule" => "#f1dcc0",
      "--ink" => "#2a2017",
      "--ink-2" => "#5e4f41",
      "--ink-3" => "#948574",
      "--accent" => "#e8600f",
      "--radius" => "8px"
    }
end
