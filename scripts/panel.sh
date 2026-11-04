#!/usr/bin/env bash
# Open the Coolify panel through an SSH tunnel (it is never exposed publicly).
#   PLATFORM_HOST=<ip> [PANEL_PORT=8800] scripts/panel.sh
#
# The UI is forwarded to localhost:$PANEL_PORT (8800 by default, so it doesn't
# collide with local dev servers on 8000). Coolify's realtime and terminal
# websockets are fixed at 6001/6002; they are forwarded when those local ports
# are free. Without them the panel works but doesn't live-update.
set -Eeuo pipefail
HOST="${PLATFORM_HOST:?set PLATFORM_HOST}"
PORT="${PANEL_PORT:-8800}"

busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

if busy "$PORT"; then
  echo "localhost:$PORT is in use. Pick another: PANEL_PORT=8900 $0" >&2
  exit 1
fi
forwards=(-L "$PORT:127.0.0.1:8000")
for ws in 6001 6002; do
  if busy "$ws"; then
    echo "warning: localhost:$ws is in use, skipping it (no live updates/terminal)" >&2
  else
    forwards+=(-L "$ws:127.0.0.1:$ws")
  fi
done

ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 "${forwards[@]}" "root@$HOST" &
tunnel=$!
trap 'kill $tunnel 2>/dev/null' EXIT INT TERM

for _ in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.25; done
echo "Coolify: http://localhost:$PORT  (Ctrl+C closes the tunnel)"
command -v open >/dev/null && open "http://localhost:$PORT" || true
wait $tunnel
