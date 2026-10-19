defmodule WraithWeb.Themes.Slate do
  @moduledoc "Slate: Dark slate, cool grey, a crisp sans. Cards glow a little."
  use WraithWeb.Theme,
    name: "slate",
    label: "Slate",
    description: "Dark slate, cool grey, a crisp sans. Cards glow a little.",
    layout: WraithWeb.Themes.Layouts.Grid,
    fonts: "https://fonts.googleapis.com/css2?family=Manrope:wght@400;500;700&display=swap",
    tokens: %{
      "--heading" => "'Manrope', system-ui, sans-serif",
      "--body" => "'Manrope', system-ui, sans-serif",
      "--paper" => "#0f172a",
      "--paper-2" => "#1e293b",
      "--rule" => "#334155",
      "--ink" => "#e2e8f0",
      "--ink-2" => "#a9b4c6",
      "--ink-3" => "#748197",
      "--accent" => "#38bdf8",
      "--radius" => "12px",
      "--scheme" => "dark"
    }
end
