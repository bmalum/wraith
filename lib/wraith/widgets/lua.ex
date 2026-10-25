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
  # `check/1` compiles owner-written source on save (and the shipped built-ins
  # at boot); it never runs for a reader. The first call after boot also loads
  # luerl's modules, which on a cold, busy box (CI) can take longer than a
  # render is allowed. Bounded, but not by the per-render budget.
  @check_timeout_ms 2_000
  # the Lua process heap (words). A chunk that builds tables past this is
  # killed by the VM, not by us running out of memory. 50M words ≈ 400 MB on
  # 64-bit — generous for a widget, far below "take the node down".
  @max_heap_words 50_000_000
  # strings are refc binaries and live OFF the process heap, so max_heap_size
  # can't see them; the string builders Lua offers are capped instead
  @max_string_bytes 256 * 1024
  @max_output_bytes 256 * 1024
  @removed ~w(os io package require load loadfile loadstring dofile collectgarbage print eprint)

  @type result :: {:ok, term()} | {:error, String.t()}

  @spec call(String.t(), String.t(), [term()], map()) :: result()
  def call(source, function, args, meta \\ %{}) do
    task =
      sandboxed(fn ->
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
                {:ok, result |> from_lua() |> capped_output()}

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
      sandboxed(fn ->
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

    case Task.yield(task, @check_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, "lua: check timed out"}
    end
  end

  # ---- the sandbox ------------------------------------------------------------------

  # A Lua run is a supervised task with a hard heap ceiling; the kill is the
  # VM's, so a runaway table allocation ends one widget render, not the node.
  # Concurrency is bounded by the supervisor's max_children (set in
  # Wraith.Application), which also caps the total memory N renders can take.
  defp sandboxed(fun) do
    Task.Supervisor.async_nolink(Wraith.Widgets.Sandbox, fun,
      spawn_opt: [max_heap_size: %{size: @max_heap_words, kill: true, error_logger: false}]
    )
  end

  # a render that returns megabytes of HTML would be broadcast to every reader
  defp capped_output(html) when is_binary(html) and byte_size(html) > @max_output_bytes,
    do: binary_part(html, 0, @max_output_bytes) <> "<!-- output truncated -->"

  defp capped_output(other), do: other

  # luerl's string.rep builds the whole result in one allocation and
  # string.format has no size limit; both are shadowed with bounded versions.
  # (string.rep("x", 2e9) is one 2 GB allocation in a few ms otherwise.)
  defp cap_string_library(st) do
    rep = fn
      [s, n | rest], st ->
        s = to_string(s)
        n = n |> to_number() |> trunc() |> max(0)

        sep =
          case rest,
            do: (
              [sep | _] -> to_string(sep)
              [] -> ""
            )

        total = n * (byte_size(s) + byte_size(sep))

        if total > @max_string_bytes,
          do: :luerl_lib.lua_error({:illegal_value, "string.rep", "result too large"}, st),
          else: {[Enum.map_join(1..n//1, sep, fn _ -> s end)], st}

      _, st ->
        {[""], st}
    end

    {:ok, st} = :luerl.set_table_keys_dec(["string", "rep"], rep, st)
    st
  end

  defp to_number(n) when is_number(n), do: n

  defp to_number(b) when is_binary(b),
    do:
      case(Float.parse(b),
        do: (
          {f, _} -> f
          _ -> 0
        )
      )

  defp to_number(_), do: 0

  defp boot(source, meta) do
    st = :luerl.init() |> cap_string_library()

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
