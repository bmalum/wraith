-- name: Reactions
-- description: Emoji reactions under a post, counted live. {{widget reactions set="👏|🔥|💡|🤔"}}

function init(props)
  return { counts = {}, mine = {} }
end

function render(state, props, meta)
  local set = wraith.split(props.set or "👏|🔥|💡|🤔", "|")
  local html = '<div class="w-reactions">'
  for _, e in ipairs(set) do
    local n = state.counts[e] or 0
    local mine = meta.visitor and state.mine[meta.visitor] and state.mine[meta.visitor][e]
    local cls = mine and "w-reaction is-mine" or "w-reaction"
    html = html .. '<button class="' .. cls .. '" ' .. wraith.action("toggle", { emoji = e }) .. '>'
      .. '<span class="w-reaction-emoji">' .. wraith.escape(e) .. '</span>'
      .. '<span class="w-reaction-n">' .. wraith.format(n) .. '</span></button>'
  end
  return html .. '</div>'
end

function handle(state, event, payload, meta)
  if event ~= "toggle" or not payload.emoji or not meta.visitor then return state end
  local e = payload.emoji
  state.mine[meta.visitor] = state.mine[meta.visitor] or {}
  if state.mine[meta.visitor][e] then
    state.mine[meta.visitor][e] = nil
    state.counts[e] = math.max((state.counts[e] or 1) - 1, 0)
  else
    state.mine[meta.visitor][e] = true
    state.counts[e] = (state.counts[e] or 0) + 1
  end
  return state
end
