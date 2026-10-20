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
  # only what we started: the seed's mix run, whatever holds our port, our chrome,
  # and any esbuild/tailwind watchers a killed beam left behind.
  # (never `pkill -f PHX_SERVER=true` — that matches the shell running this script)
  pkill -9 -f "mix run --no-halt -e Code.eval_file.*screenshots/seed.exs" 2>/dev/null || true
  pkill -9 -f "remote-debugging-port=9333" 2>/dev/null || true
  pkill -9 -f "esbuild.*--watch" 2>/dev/null || true
  pkill -9 -f "tailwind.*--watch" 2>/dev/null || true
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
  # the seed runs after boot (bcrypt, search index, widgets); a cold BEAM can
  # take a while. Wait for a real 200 — a 302 means setup_done isn't set yet.
  for _ in $(seq 1 240); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" 2>/dev/null || true)
    if [ "$code" = "200" ]; then return 0; fi
    sleep 0.5
  done
  echo "!! port $PORT never answered 200 (last: $code) — see /tmp/wraith-shot-$theme.log" >&2
  return 1
}

trap kill_servers EXIT

# compile + assets once, up front, so no boot in the loop recompiles — a
# recompile under the dev code reloader mid-seed purges modules out from
# under Code.eval_file and the seed stalls silently.
echo "== compiling =="
mix compile > /tmp/wraith-shot-compile.log 2>&1 || { echo "!! compile failed, see /tmp/wraith-shot-compile.log"; exit 1; }
echo "== building assets =="
mix assets.build > /tmp/wraith-shot-assets.log 2>&1 || { echo "!! asset build failed, see /tmp/wraith-shot-assets.log"; exit 1; }
echo "== demo images =="
mix run --no-start -e 'Code.eval_file("priv/screenshots/images.exs")' > /tmp/wraith-shot-images.log 2>&1 || { echo "!! demo images failed"; exit 1; }

for theme in "${themes[@]}"; do
  echo "== $theme =="
  kill_servers
  wait_port_free

  THEME="$theme" PORT="$PORT" PHX_SERVER=true WRAITH_STORE=memory WRAITH_WATCHERS=false \
    mix run --no-halt -e "Code.eval_file(\"$SEED\")" > "/tmp/wraith-shot-$theme.log" 2>&1 &
  wait_port_up

  # confirm the server is serving THIS boot's theme before shooting
  layout=$(curl -s "http://localhost:$PORT/" | grep -oE 'data-layout="[a-z]+"' | head -1)
  echo "   serving $layout"

  node priv/screenshots/capture.mjs "$theme" "$PORT"
done

kill_servers
echo "done — see priv/screenshots/<theme>/"
