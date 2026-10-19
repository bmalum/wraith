defmodule WraithWeb.Themes.Letters do
  @moduledoc "Letters: Sepia paper and Crimson type: a correspondence, one entry at a time."
  use WraithWeb.Theme,
    name: "letters",
    label: "Letters",
    description: "Sepia paper and Crimson type: a correspondence, one entry at a time.",
    layout: WraithWeb.Themes.Layouts.Journal,
    fonts:
      "https://fonts.googleapis.com/css2?family=Crimson+Pro:ital,wght@0,400;0,600;1,400&display=swap",
    tokens: %{
      "--heading" => "'Crimson Pro', Georgia, serif",
      "--body" => "'Crimson Pro', Georgia, serif",
      "--paper" => "#f6efe3",
      "--paper-2" => "#ede3d1",
      "--rule" => "#d9cbb0",
      "--ink" => "#3a2f22",
      "--ink-2" => "#6a5c4a",
      "--ink-3" => "#756954",
      "--accent" => "#8a5a2b",
      "--radius" => "3px"
    }
end
