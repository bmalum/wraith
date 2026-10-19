defmodule WraithWeb.Themes.Plain do
  @moduledoc "Plain: System fonts, one column, no decoration. The text is the design."
  use WraithWeb.Theme,
    name: "plain",
    label: "Plain",
    description: "System fonts, one column, no decoration. The text is the design.",
    layout: WraithWeb.Themes.Layouts.Minimal,
    tokens: %{
      "--heading" => "system-ui, -apple-system, 'Segoe UI', sans-serif",
      "--body" => "system-ui, -apple-system, 'Segoe UI', sans-serif",
      "--paper" => "#ffffff",
      "--paper-2" => "#f7f7f7",
      "--rule" => "#e5e5e5",
      "--ink" => "#1a1a1a",
      "--ink-2" => "#555555",
      "--ink-3" => "#888888",
      "--accent" => "#0066cc",
      "--radius" => "6px"
    }
end
