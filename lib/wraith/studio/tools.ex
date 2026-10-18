defmodule Wraith.Studio.Tools do
  @moduledoc """
  The MCP server the studio agent gets over the bridge: `Wraith.Tools`
  (the one registry every agent sees) with the studio session as context —
  writes are made as the user who opened it. `widget_docs/0` lives here.
  """
  @behaviour Wraith.Kiro.MCP

  # the studio session is the context: writes are made as the user who opened it
  defp ctx(session), do: %{"user_id" => session["user_id"], "scope" => "admin"}

  @impl true
  def server_info(session), do: Wraith.Tools.server_info(ctx(session))

  @impl true
  def tools(session), do: Wraith.Tools.tools(ctx(session))

  @impl true
  def call(session, name, args), do: Wraith.Tools.call(ctx(session), name, args)

  @doc false
  def widget_docs do
    """
    # Writing a Wraith widget (Lua 5.3, sandboxed)

    A widget is one Lua chunk defining three functions. Every embedded *instance*
    shares one state that all readers see live; an event from one browser runs
    `handle`, the new state is saved and every open page re-renders.

        -- name: Clap
        -- description: Readers clap for the post.
        function init(props)                       -- the state a fresh instance starts with
          return { claps = 0 }
        end
        function render(state, props, meta)        -- HTML for a state (a string)
          return '<div class="w-counter">'
            .. '<button class="w-btn" ' .. wraith.action("clap") .. '>👏</button>'
            .. '<span class="w-counter-value">' .. wraith.format(state.claps) .. '</span>'
            .. '<span class="w-counter-label">' .. wraith.escape(props.label or "claps") .. '</span>'
            .. '</div>'
        end
        function handle(state, event, payload, meta)   -- a reader's event → next state
          if event == "clap" then state.claps = state.claps + 1 end
          return state                            -- or error("why") to refuse
        end

    `meta`: `instance`, `visitor` (a stable per-browser id — use it for one-vote-per-reader),
    `presence` (readers on the page now), `post` ({id,title,slug} or nil).
    `props`: the shortcode's key=value pairs as strings (`{{widget clap label="Bravo"}}`).

    Helpers: `wraith.action(event, payload_table)` → the attributes a clickable element
    needs; `wraith.escape(s)`; `wraith.format(n)` (1,234); `wraith.split("a|b", "|")` →
    a table (there is no string.gmatch); `wraith.json(t)`, `wraith.len(t)`, `wraith.keys(t)`.

    Rules: no `os`, `io`, `require`; 250 ms per call; state must be JSON-shaped
    (string keys, numbers, strings, booleans, nested tables). Output is wrapped in
    `<div class="widget">`; use these classes for a native look: `w-btn`,
    `w-counter`/`w-counter-value`/`w-counter-label`, `w-poll-q`/`w-poll-row`/`w-poll-bar`/
    `w-poll-opt`/`w-poll-pct`/`w-poll-choice`/`is-mine`, `w-reactions`/`w-reaction`,
    `w-countdown`/`w-countdown-cell`, `w-visitors`. Inline styles are allowed.

    Test with `widget_test` (source, props, events), save with `widget_save`, embed with
    `{{widget slug key=value}}` on its own line in a post (`id=` names a shared instance).
    """
  end
end
