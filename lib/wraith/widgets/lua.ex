defmodule Wraith.Widgets.Lua do
  @moduledoc """
  Scripted widgets: a Lua 5.3 chunk (run by `luerl`, pure Erlang — no
  native code, no OS access) defines

      function init(props) return { count = 0 } end
      function render(state, props, meta) return "<b>" .. state.count .. "</b>" end
      function handle(state, event, payload, meta) state.count = state.count + 1; return state end

  The chunk is compiled once per call into a fresh state (nothing leaks
  between instances or readers), the dangerous libraries are removed
  (`os`, `io`, `package`, `require`, `load*`, `dofile`), and each call is
  cut off after `@timeout_ms`.

  A `wraith` table helps with HTML:

    * `wraith.escape(s)` — HTML-escape a string
    * `wraith.action(event, payload)` — the attributes a clickable element
      needs to send `event` to `handle` (`phx-click` plumbing, instance
      included); e.g. `"<button " .. wraith.action("vote", {option="a"}) .. ">A</button>"`
    * `wraith.json(t)` / `wraith.len(t)` / `wraith.keys(t)` — small table helpers
    * `wraith.split(s, sep)` — `"a|b"` → `{"a", "b"}` (luerl has no `gmatch`)
    * `wraith.format(n)` — `1234` → `"1,234"`
    * `wraith.fetch(url)` — GET a URL (JSON decoded when the answer is JSON,
      else the text); only hosts the owner allowlisted in Settings
      (`widget_fetch_hosts`) and cached for 60 s; nil + an error string otherwise
    * `wraith.now()` — unix seconds
  """

  @timeout_ms 250
  @removed ~w(os io package require load loadfile loadstring dofile collectgarbage)

  @type result :: {:ok, term()} | {:error, String.t()}

  @spec call(String.t(), String.t(), [term()], map()) :: result()
  def call(source, function, args, meta \\ %{}) do
    task =
      Task.async(fn ->
        try do
          with {:ok, st} <- boot(source, meta) do
            case :luerl.call_function_dec(
                   [String.to_atom(function)],
                   Enum.map(args, &to_lua/1),
                   st
                 ) do
              # two values from `handle` are {state, private}
              {:ok, [a, b | _], _st} when function == "handle" ->
                {:ok, {from_lua(a), from_lua(b)}}

              {:ok, [result | _], _st} ->
                {:ok, from_lua(result)}

              {:ok, [], _st} ->
                {:ok, nil}

              {:lua_error, err, st} ->
                {:error, "lua error: " <> format_error(err, st)}

              {:error, errs, _warns} ->
                {:error, "lua: " <> inspect(errs)}
            end
          end
        rescue
          e -> {:error, "lua crashed: " <> Exception.message(e)}
        catch
          kind, reason -> {:error, "lua #{kind}: #{inspect(reason)}"}
        end
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, "lua: took longer than #{@timeout_ms} ms"}
      {:exit, reason} -> {:error, "lua exited: #{inspect(reason)}"}
    end
  end

  @doc "Does the chunk compile, and does it define the three functions? `:ok | {:error, why}`."
  @spec check(String.t()) :: :ok | {:error, String.t()}
  def check(source) do
    task =
      Task.async(fn ->
        with {:ok, st} <- boot(source, %{}) do
          missing =
            Enum.reject(~w(init render handle), fn f ->
              match?({:ok, v, _} when not is_nil(v), :luerl.get_table_keys_dec([f], st))
            end)

          if missing == [],
            do: :ok,
            else: {:error, "missing function(s): " <> Enum.join(missing, ", ")}
        end
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, "lua: check timed out"}
    end
  end

  # ---- the sandbox ------------------------------------------------------------------

  defp boot(source, meta) do
    st = :luerl.init()

    st =
      Enum.reduce(@removed, st, fn name, st ->
        {:ok, st} = :luerl.set_table_keys_dec([name], nil, st)
        st
      end)

    {:ok, st} = :luerl.set_table_keys_dec(["wraith"], helpers(meta), st)

    case :luerl.do(source, st) do
      {:ok, _, st} -> {:ok, st}
      {:lua_error, err, st} -> {:error, "lua error: " <> format_error(err, st)}
      {:error, errs, _warns} -> {:error, "lua: " <> format_compile(errs)}
    end
  end

  defp helpers(meta) do
    instance = meta[:instance] || ""

    %{
      "escape" => fn [s | _], st -> {[escape(to_string(s))], st} end,
      "action" => fn args, st ->
        [event | rest] = args

        payload =
          case rest,
            do: (
              [p | _] -> decode(p, st)
              [] -> %{}
            )

        {[action_attrs(instance, to_string(event), payload)], st}
      end,
      "json" => fn [t | _], st -> {[Jason.encode!(decode(t, st))], st} end,
      "len" => fn [t | _], st -> {[t |> decode(st) |> size()], st} end,
      "keys" => fn [t | _], st -> encoded(t |> decode(st) |> keys(), st) end,
      "format" => fn [n | _], st -> {[format_number(n)], st} end,
      "now" => fn _args, st -> {[System.system_time(:second)], st} end,
      "fetch" => fn [url | _], st ->
        case Wraith.Widgets.Fetch.get(to_string(url)) do
          {:ok, body} -> encoded(body, st)
          {:error, why} -> {[nil, why], st}
        end
      end,
      "split" => fn [s | rest], st ->
        sep =
          case rest,
            do: (
              [sep | _] -> to_string(sep)
              [] -> "|"
            )

        parts =
          s
          |> to_string()
          |> String.split(sep)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        encoded(parts, st)
      end
    }
  end

  # a table handed back from Erlang must be allocated in the Lua state
  defp encoded(term, st) do
    {lua, st} = :luerl.encode(to_lua(term), st)
    {[lua], st}
  end

  # arguments arrive as references into the Lua heap
  defp decode(lua, st), do: lua |> :luerl.decode(st) |> from_lua()

  @doc "The `phx-*` attributes that send an event for an instance."
  def action_attrs(instance, event, payload) do
    ~s(phx-click="widget" phx-value-instance="#{escape(instance)}" phx-value-event="#{escape(event)}" phx-value-payload="#{escape(Jason.encode!(payload || %{}))}")
  end

  # ---- conversions ------------------------------------------------------------------

  @doc "A decoded Luerl table (proplist) → map or list."
  def from_lua(list) when is_list(list) do
    cond do
      list == [] ->
        %{}

      Enum.all?(list, &match?({_, _}, &1)) and sequential?(list) ->
        list |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&from_lua(elem(&1, 1)))

      Enum.all?(list, &match?({_, _}, &1)) ->
        Map.new(list, fn {k, v} -> {to_key(k), from_lua(v)} end)

      true ->
        Enum.map(list, &from_lua/1)
    end
  end

  def from_lua(other), do: other

  defp sequential?(list) do
    keys = list |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    keys == Enum.to_list(1..length(list)) or keys == Enum.map(1..length(list), &(&1 * 1.0))
  end

  defp to_key(k) when is_binary(k), do: k
  defp to_key(k) when is_float(k) and k == trunc(k), do: Integer.to_string(trunc(k))
  defp to_key(k), do: to_string(k)

  @doc "Elixir → what Luerl encodes (maps with string keys, lists become 1-based tables)."
  def to_lua(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), to_lua(v)} end)

  def to_lua(list) when is_list(list),
    do: list |> Enum.with_index(1) |> Map.new(fn {v, i} -> {i, to_lua(v)} end)

  def to_lua(nil), do: nil
  def to_lua(other), do: other

  defp size(%{} = m), do: map_size(m)
  defp size(l) when is_list(l), do: length(l)
  defp size(_), do: 0

  defp keys(%{} = m), do: Map.keys(m)
  defp keys(l) when is_list(l), do: Enum.to_list(1..length(l))
  defp keys(_), do: []

  defp escape(s), do: s |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp format_number(n) when is_float(n) and n == trunc(n), do: format_number(trunc(n))

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(n), do: to_string(n)

  defp format_error(err, _st) do
    :luerl_lib.format_error(err) |> IO.iodata_to_binary()
  rescue
    _ -> inspect(err)
  end

  defp format_compile(errs) do
    errs
    |> List.wrap()
    |> Enum.map(fn
      {line, mod, desc} when is_atom(mod) ->
        "line #{line}: #{mod.format_error(desc) |> IO.iodata_to_binary()}"

      other ->
        inspect(other)
    end)
    |> Enum.join("; ")
  end
end
