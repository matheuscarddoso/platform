#!/usr/bin/env bash
# Open the Coolify panel through an SSH tunnel (it is never exposed publicly).
#   PLATFORM_HOST=<ip> scripts/panel.sh
# Forwards the UI (8000) and its realtime/terminal websockets (6001/6002).
set -Eeuo pipefail
HOST="${PLATFORM_HOST:?set PLATFORM_HOST}"

ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
  -L 8000:127.0.0.1:8000 -L 6001:127.0.0.1:6001 -L 6002:127.0.0.1:6002 \
  "root@$HOST" &
tunnel=$!
trap 'kill $tunnel 2>/dev/null' EXIT INT TERM

for _ in $(seq 1 40); do nc -z 127.0.0.1 8000 2>/dev/null && break; sleep 0.25; done
echo "Coolify: http://localhost:8000  (Ctrl+C closes the tunnel)"
command -v open >/dev/null && open http://localhost:8000 || true
wait $tunnel
