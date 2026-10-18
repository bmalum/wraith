defmodule Wraith.Widgets.Builtin.Countdown do
  @moduledoc "Days / hours / minutes until a date. `{{widget countdown to=2027-01-01 label=\"Launch\"}}`."
  @behaviour Wraith.Widgets.Widget

  @impl true
  def describe,
    do: %{
      name: "Countdown",
      description: "Time left until a date; everyone sees the same clock.",
      props: [
        %{
          "name" => "to",
          "type" => "date",
          "required" => true,
          "help" => "ISO date or datetime, e.g. 2027-01-01 or 2027-01-01T18:00:00Z"
        },
        %{"name" => "label", "type" => "string", "help" => "What happens then"}
      ]
    }

  @impl true
  def init(_props), do: %{}

  @impl true
  def render(_state, props, _meta) do
    label = esc(props["label"] || "")

    case parse(props["to"]) do
      {:ok, target} ->
        secs = DateTime.diff(target, DateTime.utc_now())

        if secs <= 0 do
          ~s(<div class="w-countdown is-done"><span class="w-countdown-label">#{label}</span><strong>It's here.</strong></div>)
        else
          d = div(secs, 86_400)
          h = div(rem(secs, 86_400), 3_600)
          m = div(rem(secs, 3_600), 60)

          ~s(<div class="w-countdown" data-until="#{DateTime.to_iso8601(target)}"><span class="w-countdown-label">#{label}</span>) <>
            cell(d, "days") <> cell(h, "hours") <> cell(m, "min") <> "</div>"
        end

      :error ->
        ~s(<div class="w-countdown is-error">countdown: give me <code>to=YYYY-MM-DD</code></div>)
    end
  end

  @impl true
  def handle(state, _event, _payload, _meta), do: state

  defp cell(n, unit),
    do: ~s(<span class="w-countdown-cell"><b>#{n}</b><small>#{unit}</small></span>)

  defp parse(nil), do: :error

  defp parse(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} ->
        {:ok, dt}

      _ ->
        case Date.from_iso8601(str) do
          {:ok, d} -> {:ok, DateTime.new!(d, ~T[00:00:00], "Etc/UTC")}
          _ -> :error
        end
    end
  end

  defp parse(_), do: :error

  defp esc(s), do: s |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
