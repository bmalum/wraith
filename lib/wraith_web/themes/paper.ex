defmodule WraithWeb.Themes.Paper do
  @moduledoc "Paper: Editorial. Warm paper, a serif masthead, generous type, the first post featured."
  use WraithWeb.Theme,
    name: "paper",
    label: "Paper",
    description:
      "Editorial. Warm paper, a serif masthead, generous type, the first post featured.",
    layout: WraithWeb.Themes.Layouts.Editorial,
    fonts:
      "https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,300..800;1,9..144,300..800&family=Public+Sans:wght@400;500;600&display=swap",
    tokens: %{
      "--heading" => "'Fraunces', Georgia, serif",
      "--body" => "'Public Sans', system-ui, sans-serif",
      "--paper" => "oklch(99% 0.004 95)",
      "--paper-2" => "oklch(96.5% 0.006 95)",
      "--rule" => "oklch(88% 0.01 95)",
      "--ink" => "oklch(22% 0.012 60)",
      "--ink-2" => "oklch(45% 0.012 60)",
      "--ink-3" => "oklch(52% 0.01 60)",
      "--accent" => "#5b4bff",
      "--radius" => "10px"
    }
end
