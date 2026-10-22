defmodule WraithWeb.Redirects do
  @moduledoc """
  Site redirects from Settings (`redirects`: `[%{"from", "to", "permanent"}]`).
  `from` is an exact path or a prefix ending in `*` (`/old/*` → `/new/*`
  keeps the rest). Runs before the router; a match answers 301/302.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", request_path: path} = conn, _opts) do
    case match(path, Wraith.Settings.get()["redirects"] || []) do
      nil ->
        conn

      {to, permanent?} ->
        conn
        |> put_resp_header("location", to)
        |> send_resp(if(permanent?, do: 301, else: 302), "")
        |> halt()
    end
  end

  def call(conn, _opts), do: conn

  @doc false
  def match(path, rules) when is_list(rules) do
    Enum.find_value(rules, fn
      %{"from" => from, "to" => to} = r when is_binary(from) and is_binary(to) ->
        match_rule(path, from, to, r)

      # Settings validates the shape; this is the last line of defence so a
      # bad value can never 500 every GET on the site
      _ ->
        nil
    end)
  end

  def match(_path, _rules), do: nil

  defp match_rule(path, from, to, r) do
    permanent? = r["permanent"] in [true, "true", "on", nil]

    cond do
      from == path ->
        {to, permanent?}

      String.ends_with?(from, "*") and
          String.starts_with?(path, String.trim_trailing(from, "*")) ->
        rest = String.replace_prefix(path, String.trim_trailing(from, "*"), "")
        {String.replace(to, "*", rest), permanent?}

      true ->
        nil
    end
  end

  @doc "Parse the settings textarea: one `from to [permanent|temporary]` per line."
  def parse(text) do
    text
    |> to_string()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), ~r/\s+/) do
        [from, to | rest] when from != "" ->
          [%{"from" => from, "to" => to, "permanent" => "temporary" not in rest}]

        _ ->
          []
      end
    end)
  end

  def to_text(rules),
    do:
      Enum.map_join(
        rules || [],
        "\n",
        &"#{&1["from"]} #{&1["to"]}#{if &1["permanent"] == false, do: " temporary", else: ""}"
      )
end
