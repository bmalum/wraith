#!/usr/bin/env bash
# Boot the Wraith site once per theme (memory store, seeded) and capture every
# public view with headless Chrome. Run from the project root:
#   bash priv/screenshots/run.sh            # all 18 themes
#   bash priv/screenshots/run.sh paper ink  # just these
set -euo pipefail
cd "$(dirname "$0")/../.."

PORT=4011
SEED="priv/screenshots/seed.exs"

themes=("$@")
if [ ${#themes[@]} -eq 0 ]; then
  themes=(paper broadsheet gallery ink ledger terminal studio polaroid slate \
          review weekend tabloid plain mono zen diary letters nightshift)
fi

kill_servers() {
  pkill -9 -f "PHX_SERVER=true" 2>/dev/null || true
  pkill -9 -f "remote-debugging-port=9333" 2>/dev/null || true
  # the actual listener is the beam child; kill whatever holds the port
  local pids
  pids=$(lsof -ti tcp:"$PORT" 2>/dev/null || true)
  if [ -n "$pids" ]; then kill -9 $pids 2>/dev/null || true; fi
}

wait_port_free() {
  for _ in $(seq 1 60); do
    if ! lsof -ti tcp:"$PORT" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  echo "!! port $PORT never freed" >&2
  return 1
}

wait_port_up() {
  for _ in $(seq 1 60); do
    if curl -sf -o /dev/null "http://localhost:$PORT/"; then return 0; fi
    sleep 0.5
  done
  echo "!! port $PORT never came up" >&2
  return 1
}

trap kill_servers EXIT

for theme in "${themes[@]}"; do
  echo "== $theme =="
  kill_servers
  wait_port_free

  THEME="$theme" PORT="$PORT" PHX_SERVER=true WRAITH_STORE=memory \
    mix run --no-halt -e "Code.eval_file(\"$SEED\")" > "/tmp/wraith-shot-$theme.log" 2>&1 &
  wait_port_up

  # confirm the server is serving THIS boot's theme before shooting
  layout=$(curl -s "http://localhost:$PORT/" | grep -oE 'data-layout="[a-z]+"' | head -1)
  echo "   serving $layout"

  node priv/screenshots/capture.mjs "$theme" "$PORT"
done

kill_servers
echo "done — see priv/screenshots/<theme>/"
