defmodule WraithWeb.Themes.Ledger do
  @moduledoc "Ledger: The same honest list, on paper: monospace headings, blue links, light."
  use WraithWeb.Theme,
    name: "ledger",
    label: "Ledger",
    description: "The same honest list, on paper: monospace headings, blue links, light.",
    layout: WraithWeb.Themes.Layouts.List,
    fonts:
      "https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600&family=Inter+Tight:wght@400;500&display=swap",
    tokens: %{
      "--heading" => "'JetBrains Mono', ui-monospace, monospace",
      "--body" => "'Inter Tight', system-ui, sans-serif",
      "--mono" => "'JetBrains Mono', ui-monospace, monospace",
      "--paper" => "#fcfcfa",
      "--paper-2" => "#f1f1ee",
      "--rule" => "#d9d9d4",
      "--ink" => "#1b1b1b",
      "--ink-2" => "#4a4a4a",
      "--ink-3" => "#737373",
      "--accent" => "#1d4ed8",
      "--radius" => "3px"
    }
end
