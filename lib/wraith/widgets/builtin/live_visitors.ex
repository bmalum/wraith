defmodule Wraith.Widgets.Builtin.LiveVisitors do
  @moduledoc """
  How many people are reading this page right now. The count comes from
  `WraithWeb.Presence` through `meta.presence`; the widget has no state.
  `{{widget live-visitors}}`
  """
  @behaviour Wraith.Widgets.Widget

  @impl true
  def describe,
    do: %{
      name: "Live visitors",
      description: "Who else is here: the number of readers on this page, live.",
      props: [
        %{
          "name" => "label",
          "type" => "string",
          "help" => "Text after the number (default: reading now)"
        }
      ]
    }

  @impl true
  def init(_props), do: %{}

  @impl true
  def render(_state, props, meta) do
    n = meta[:presence] || 0

    label =
      (props["label"] || "reading now")
      |> to_string()
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()

    ~s(<div class="w-visitors"><span class="w-visitors-dot" aria-hidden="true"></span><b>#{n}</b> #{label}</div>)
  end

  @impl true
  def handle(state, _event, _payload, _meta), do: state
end
