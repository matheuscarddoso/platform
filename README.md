# platform

Infrastructure as code for the production server: provisioning, the Coolify
control plane, and the push-to-deploy pipeline every app shares.

```
git push main ──► GitHub Actions ──► GHCR ──► ssh (forced command) ──► Coolify ──► live
                  build on runner     image    ci-deploy <app>          rolling,
                  cached deps + .next          one key per repo         health-checked
```

## Layout

| Path | What |
| --- | --- |
| `server/bootstrap.sh` | Idempotent provisioning: SSH hardening, kernel tuning (BBR), swap, journald, unattended security upgrades, fail2ban, Docker, firewall, CI deploy user. |
| `server/files/` | Every config file the bootstrap installs. Nothing is edited by hand on the host. |
| `server/ci-deploy` | Forced-command entrypoint the CI key can run. Sets the image tag on the Coolify app and waits for the rollout. |
| `.github/workflows/deploy-nextjs.yml` | Reusable workflow: build, package as image, push to GHCR, deploy. |
| `templates/deploy.yml` | The ~20 lines each app repository adds. |
| `scripts/onboard-app.sh` | Registers an app: Coolify resource, per-repo deploy key, GitHub secrets/variables. |

## Security model

- **SSH**: keys only, no passwords. `root` (for Coolify and admins) and `deploy` are the only accounts allowed.
- **Firewall**: ufw allows only 22, 80 and 443 on the host. Docker-published ports go around ufw, so a
  `DOCKER-USER` allowlist (in `ufw/after*.rules`) lets the internet reach containers only on 80/443.
  The Coolify panel (8000), its websockets (6001/6002) and the Traefik dashboard (8080) are reachable
  only through an SSH tunnel.
- **CI**: every repository gets its own key. On the server, that key can only run
  `ci-deploy <its-app>`, with no shell, PTY or forwarding. A leaked key can redeploy one app with
  an image tag from that app's own GHCR repository, and nothing more.
- **Coolify API token** (`/etc/ci-deploy/coolify.token`) has `read`, `write` and `deploy` scope (no `root`).
  Only `root` and the `deploy` group can read it.
- **Build secrets** (`BUILD_ENV`) are exported only for the build step and are never written to
  disk, so they can't leak into the image.
- **Supply chain**: third-party actions are pinned to commit SHAs.

## Operations

```bash
# Re-apply server configuration (safe to run any time)
rsync -a --delete server/ root@$HOST:/opt/platform/ && ssh root@$HOST /opt/platform/bootstrap.sh

# Open the Coolify panel at http://localhost:8000
ssh -N -L 8000:localhost:8000 -L 6001:localhost:6001 -L 6002:localhost:6002 root@$HOST

# Onboard an app
PLATFORM_HOST=$HOST scripts/onboard-app.sh owner/repo --domain https://example.com
```

App requirements: Next.js with `output: "standalone"` in `next.config`. Runtime environment
variables live in Coolify. Build-time variables (`NEXT_PUBLIC_*`) go in the repository secret `BUILD_ENV`.

## Versioning

Apps reference `deploy-nextjs.yml@v1`. Backwards-compatible changes move the `v1` tag;
breaking changes ship as `v2`.
