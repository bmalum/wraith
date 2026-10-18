defmodule Wraith.Widgets.Widget do
  @moduledoc """
  What a widget is, whatever language it is written in.

  A widget is a tiny app embedded in a post with `{{widget slug key=value}}`.
  Every *instance* (a slug plus an instance id) has one shared `state`
  (a JSON-shaped map) that every reader sees live: an event from one
  browser runs `handle/4`, the new state is saved and broadcast, and
  every open page re-renders.

    * `init/1` — the state a fresh instance starts with, from the props
    * `render/3` — HTML for a state (`meta` has `instance`, `visitor`,
      `presence`, `post`); output is the widget's own markup, placed
      inside a wrapper that carries the instance id
    * `handle/4` — a reader's event → the next state (or `{:error, why}`
      to refuse it)

  Elixir widgets implement this behaviour and are registered in
  `Wraith.Widgets.builtin_modules/0`; Lua widgets implement the same three
  functions in a sandbox (`Wraith.Widgets.Lua`).
  """

  @type props :: %{optional(String.t()) => term()}
  @type state :: %{optional(String.t()) => term()}
  @type meta :: %{
          instance: String.t(),
          visitor: String.t() | nil,
          presence: non_neg_integer(),
          post: map() | nil
        }

  @callback init(props()) :: state()
  @callback render(state(), props(), meta()) :: String.t()
  @callback handle(state(), String.t(), map(), meta()) :: state() | {:error, String.t()}

  @doc "The one-line description shown in the studio."
  @callback describe() :: %{name: String.t(), description: String.t(), props: [map()]}
end
