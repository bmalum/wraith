-- name: Poll
-- description: One question, a few options, live results. {{widget poll question="Tabs or spaces?" options="Tabs|Spaces|Both"}}

function init(props)
  return { votes = {}, voters = {} }
end

function render(state, props, meta)
  local options = wraith.split(props.options or "Yes|No", "|")
  local total = 0
  for _, o in ipairs(options) do total = total + (state.votes[o] or 0) end

  local voted = meta.visitor and state.voters[meta.visitor]
  local html = '<div class="w-poll"><div class="w-poll-q">' .. wraith.escape(props.question or "What do you think?") .. '</div>'

  for i, o in ipairs(options) do
    local n = state.votes[o] or 0
    local pct = total > 0 and math.floor(n * 100 / total + 0.5) or 0
    if voted then
      local mine = (voted == o) and " is-mine" or ""
      html = html .. '<div class="w-poll-row' .. mine .. '"><span class="w-poll-bar" style="width:' .. pct .. '%"></span>'
        .. '<span class="w-poll-opt">' .. wraith.escape(o) .. '</span><span class="w-poll-pct">' .. pct .. '%</span></div>'
    else
      html = html .. '<button class="w-poll-row w-poll-choice" ' .. wraith.action("vote", { option = o }) .. '>'
        .. '<span class="w-poll-opt">' .. wraith.escape(o) .. '</span></button>'
    end
  end

  html = html .. '<div class="w-poll-total">' .. wraith.format(total) .. (total == 1 and ' vote' or ' votes') .. '</div></div>'
  return html
end

function handle(state, event, payload, meta)
  if event == "vote" and payload.option and meta.visitor then
    if state.voters[meta.visitor] then
      return state -- one vote per reader
    end
    state.votes[payload.option] = (state.votes[payload.option] or 0) + 1
    state.voters[meta.visitor] = payload.option
  end
  return state
end
