defmodule WraithWeb.Themes.Review do
  @moduledoc "Review: A magazine with a hero story and a sidebar. Baskerville and a deep red."
  use WraithWeb.Theme,
    name: "review",
    label: "Review",
    description: "A magazine with a hero story and a sidebar. Baskerville and a deep red.",
    layout: WraithWeb.Themes.Layouts.Magazine,
    fonts:
      "https://fonts.googleapis.com/css2?family=Libre+Baskerville:ital,wght@0,400;0,700;1,400&family=Lato:wght@400;700&display=swap",
    tokens: %{
      "--heading" => "'Libre Baskerville', Georgia, serif",
      "--body" => "'Lato', system-ui, sans-serif",
      "--paper" => "#fffdf9",
      "--paper-2" => "#f6f1e7",
      "--rule" => "#e6dfd1",
      "--ink" => "#1c1a17",
      "--ink-2" => "#4e4942",
      "--ink-3" => "#857d72",
      "--accent" => "#9b1c1c",
      "--radius" => "2px"
    }
end
