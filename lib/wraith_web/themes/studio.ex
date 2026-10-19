defmodule WraithWeb.Themes.Studio do
  @moduledoc "Studio: Bold grotesk, white space, electric accent. A portfolio of image cards."
  use WraithWeb.Theme,
    name: "studio",
    label: "Studio",
    description: "Bold grotesk, white space, electric accent. A portfolio of image cards.",
    layout: WraithWeb.Themes.Layouts.Grid,
    fonts: "https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;700&display=swap",
    tokens: %{
      "--heading" => "'Space Grotesk', system-ui, sans-serif",
      "--body" => "'Space Grotesk', system-ui, sans-serif",
      "--paper" => "#ffffff",
      "--paper-2" => "#f5f5f7",
      "--rule" => "#e2e2e6",
      "--ink" => "#0a0a0a",
      "--ink-2" => "#4b4b52",
      "--ink-3" => "#73737c",
      "--accent" => "#ff4d00",
      "--radius" => "14px"
    }
end
