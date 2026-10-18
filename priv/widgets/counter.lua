-- name: Counter
-- description: A shared number everyone can bump. {{widget counter label="High fives"}}

function init(props)
  return { count = 0 }
end

function render(state, props, meta)
  local label = wraith.escape(props.label or "Clicks")
  return '<div class="w-counter">'
    .. '<button class="w-btn" ' .. wraith.action("inc") .. ' aria-label="Add one">+1</button>'
    .. '<span class="w-counter-value">' .. wraith.format(state.count or 0) .. '</span>'
    .. '<span class="w-counter-label">' .. label .. '</span>'
    .. '</div>'
end

function handle(state, event, payload, meta)
  if event == "inc" then
    state.count = (state.count or 0) + 1
  end
  return state
end
