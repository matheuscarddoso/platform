#!/usr/bin/env bash
# Register an app repository on the platform. Idempotent; re-running rotates
# the deploy key.
#
#   PLATFORM_HOST=<ip> scripts/onboard-app.sh <owner/repo> [options]
#
# Options:
#   --domain <url>     Public URL(s), comma-separated (https://example.com). Default: sslip.io
#   --memory <limit>   Container memory limit (default 768m)
#   --port <port>      Port the app listens on (default 3000)
#
# What it does:
#   1. creates the Coolify application (Docker image from GHCR) if missing;
#   2. records the app -> Coolify UUID binding in /etc/ci-deploy/apps/<app>.env;
#   3. generates a fresh ed25519 key bound to that app only (forced command);
#   4. stores the key, host and pinned host key in the GitHub repository.
# The private key exists only in memory/tmpfs and in GitHub's secret store.
set -Eeuo pipefail

die() { echo "error: $*" >&2; exit 1; }

HOST="${PLATFORM_HOST:-}"
[[ -n "$HOST" ]] || die "set PLATFORM_HOST"
REPO="${1:-}"; shift || true
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "usage: $0 <owner/repo> [--domain url] [--memory 768m] [--port 3000]"

DOMAIN="" MEMORY="768m" PORT="3000"
while (($#)); do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --port)   PORT="$2";   shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done

APP="$(basename "$REPO" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
IMAGE="ghcr.io/$(tr '[:upper:]' '[:lower:]' <<<"$REPO")"
command -v gh >/dev/null || die "gh CLI is required"
gh repo view "$REPO" --json name >/dev/null || die "cannot access $REPO with gh"

echo "→ $REPO as '$APP' ($IMAGE)"

# --- 1+2. Coolify application and binding (runs on the server) -------------
# ssh flattens argv into one string; %q keeps empty and spaced args intact.
UUID="$(ssh "root@$HOST" "bash -s -- $(printf '%q ' "$APP" "$IMAGE" "$DOMAIN" "$MEMORY" "$PORT")" <<'REMOTE'
set -Eeuo pipefail
app="$1" image="$2" domain="$3" memory="$4" port="$5"
envf="/etc/ci-deploy/apps/$app.env"
if [[ -f "$envf" ]]; then sed -n 's/^COOLIFY_APP_UUID=//p' "$envf"; exit 0; fi

T="$(cat /etc/ci-deploy/coolify.token)"
api() { curl -fsS --max-time 30 -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -H 'Accept: application/json' "$@"; }
B=http://127.0.0.1:8000/api/v1

project="$(api "$B/projects" | jq -r '.[] | select(.name=="production") | .uuid' | head -1)"
[[ -n "$project" ]] || project="$(api -X POST "$B/projects" -d '{"name":"production","description":"Production apps deployed from GitHub Actions"}' | jq -r .uuid)"
server="$(api "$B/servers" | jq -r '.[] | select(.name=="localhost") | .uuid' | head -1)"

body="$(jq -cn --arg p "$project" --arg s "$server" --arg n "$app" --arg i "$image" \
  --arg d "$domain" --arg m "$memory" --arg port "$port" '{
    project_uuid: $p, server_uuid: $s, environment_name: "production",
    name: $n, docker_registry_image_name: $i, docker_registry_image_tag: "main",
    ports_exposes: $port, instant_deploy: false,
    health_check_enabled: true, health_check_path: "/", health_check_port: $port,
    health_check_host: "127.0.0.1", health_check_method: "GET", health_check_return_code: 200,
    health_check_scheme: "http", health_check_interval: 2, health_check_timeout: 3,
    health_check_retries: 15, health_check_start_period: 1,
    rolling_update_drain_seconds: 3,
    limits_memory: $m
  } + (if $d == "" then {autogenerate_domain: true} else {domains: $d} end)')"
uuid="$(api -X POST "$B/applications/dockerimage" -d "$body" | jq -r '.uuid // empty')"
[[ -n "$uuid" ]] || { echo "failed to create application" >&2; exit 1; }
umask 027
printf 'COOLIFY_APP_UUID=%s\n' "$uuid" > "$envf"
chgrp deploy "$envf"
echo "$uuid"
REMOTE
)"
[[ -n "$UUID" ]] || die "no Coolify application UUID"
echo "  coolify app: $UUID"

# --- 3. Per-repo deploy key bound to this app --------------------------------
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
ssh-keygen -q -t ed25519 -N '' -C "ci:$REPO" -f "$tmp/key"
pub="$(cat "$tmp/key.pub")"
ssh "root@$HOST" "bash -s -- $(printf '%q ' "$APP" "$REPO")" <<REMOTE
set -Eeuo pipefail
ak=/home/deploy/.ssh/authorized_keys
awk -v c="ci:\$2" '\$NF != c' "\$ak" > "\$ak.new"
printf 'restrict,command="/usr/local/bin/ci-deploy %s" %s\n' "\$1" "$pub" >> "\$ak.new"
chown deploy:deploy "\$ak.new"; chmod 600 "\$ak.new"; mv "\$ak.new" "\$ak"
REMOTE
echo "  deploy key installed (forced command: ci-deploy $APP)"

# --- 4. GitHub configuration -------------------------------------------------
known="$(ssh "root@$HOST" cat /etc/ssh/ssh_host_ed25519_key.pub | awk -v h="$HOST" '{print h, $1, $2}')"
gh secret set DEPLOY_SSH_KEY -R "$REPO" < "$tmp/key"
gh variable set DEPLOY_HOST -R "$REPO" --body "$HOST"
gh variable set DEPLOY_KNOWN_HOSTS -R "$REPO" --body "$known"
if [[ -n "$DOMAIN" ]]; then gh variable set APP_URL -R "$REPO" --body "${DOMAIN%%,*}"; fi
echo "✓ $REPO onboarded. Add templates/deploy.yml as .github/workflows/deploy.yml and push to main."
