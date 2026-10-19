defmodule WraithWeb.Themes.Terminal do
  @moduledoc "Terminal: Green phosphor on black. For people who miss their first computer."
  use WraithWeb.Theme,
    name: "terminal",
    label: "Terminal",
    description: "Green phosphor on black. For people who miss their first computer.",
    layout: WraithWeb.Themes.Layouts.List,
    fonts: "https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500&display=swap",
    tokens: %{
      "--heading" => "'Fira Code', ui-monospace, monospace",
      "--body" => "'Fira Code', ui-monospace, monospace",
      "--mono" => "'Fira Code', ui-monospace, monospace",
      "--paper" => "#050a05",
      "--paper-2" => "#0b150b",
      "--rule" => "#1f3a1f",
      "--ink" => "#9dff9d",
      "--ink-2" => "#6fcf6f",
      "--ink-3" => "#3f8f3f",
      "--accent" => "#e4ff6a",
      "--radius" => "0px",
      "--scheme" => "dark"
    }
end
