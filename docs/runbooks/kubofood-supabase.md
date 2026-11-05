# Runbook: kubofood, Supabase Cloud → self-hosted Supabase on the platform server

Status: **rehearsal in progress** (2026-11-05). The staging copy is restored and verified; production is untouched.

## Why

Supabase Cloud runs in us-west-2 (Oregon). The app runs in Campinas, so every query
takes about 240 ms; self-hosted on the same machine, it takes about 1 ms. This also
consolidates infra and cost on the platform server.

## What kubofood uses (mapped 2026-11-05)

| Supabase feature | Usage | Notes |
| --- | --- | --- |
| PostgREST | 1,623 `.from()` call sites on 167 tables, 180 distinct `rpc()` functions | Mostly server-side with the service-role key |
| Realtime | Broadcast only (order tracking, kitchen, queue, totem, tab), 5 browser subscribers; the server sends through the REST broadcast endpoint | Public channels; no postgres_changes, no realtime RLS |
| Storage | 6 buckets: menu-item-images, restaurant-logos and menu-item-videos (public); fiscal-xml, stock-receipts and checklist-photos (private, signed URLs/uploads). 638 objects, 52 MB | **488 public URLs are stored in DB rows** (menu_items.image_url ×446, story_* ×31, banners, logos, locations, restaurants.metadata) |
| Auth (GoTrue) | Admin API only (create/list/delete users backing next-auth). 20 users, 20 identities | No end-user Supabase sessions |
| Database | Postgres **17.6**; 177 public tables (23 MB), 314 functions (272 SECURITY DEFINER), 119 triggers, 47 RLS policies | Extensions: btree_gist, pg_cron 1.6.4, pg_net 0.19.5, pg_stat_statements, pgcrypto, supabase_vault 0.3.1, uuid-ossp |
| pg_cron + pg_net | 20 jobs; 7 functions POST to the app (fiscal worker every minute, marketplace poll every 30 s, …) | They read `app_url` and `fiscal_cron_secret` from Vault |
| Vault | 2 secrets | Encrypted with the project's root key, so they must be **re-created**, not dumped |
| Image transforms / Edge Functions | Not used | No imgproxy, no functions runtime |

Rewriting onto plain Postgres would mean rewriting 1,623 query sites and 180 RPC call
sites and rebuilding realtime and storage. We are not doing that. Target: **full
Supabase, self-hosted**, with no application code changes beyond configuration.

## Target architecture

A Coolify "Docker Compose" resource `kubofood-supabase`, built from
`stacks/supabase/` in this repository (adapted from the official
`supabase/docker/docker-compose.yml`), with pinned versions verified against the
cloud project's schema migrations:

| Service | Image | Why this version |
| --- | --- | --- |
| db | `supabase/postgres:17.6.1.136` | Same major/minor as cloud (17.6) |
| auth | `supabase/gotrue:v2.197.0` | Contains cloud's latest auth migration `20260831180000` |
| rest | `postgrest/postgrest:v14.18` | Official compose pin |
| realtime | `supabase/realtime:v2.143.3` | Latest tenant migration == cloud's (`20261009120000`) |
| storage | `supabase/storage-api:v1.89.12` | **First pin that contains `lifecycle-writer-coordination`** (v1.81.0 from the official compose does not) |
| meta | `supabase/postgres-meta:v0.100.0` | Needed by Studio |
| api gateway | envoy/kong as in the official compose | Routes /rest, /auth, /realtime, /storage |
| studio | official pin | **Not public**: SSH tunnel only |

Left out: imgproxy, edge functions, supavisor, analytics/vector.

- Public endpoint: only the API gateway, through Traefik at `https://api.kubofood.app`
  (the browser needs it for realtime and public images). Postgres, Studio and meta
  are never exposed.
- JWT: `JWT_SECRET` is the cloud project's **legacy JWT secret**, so `ANON_KEY` and
  `SERVICE_ROLE_KEY` stay byte-identical and no app key changes.
- Storage backend: local file storage on a named volume, backed up off-site.
- Resources: about 1.5 to 2 GB RAM expected, with 5.5 GB available on 2026-11-05.

## Prerequisites (blocking)

1. **Off-site backups (Cloudflare R2).** Fiscal XMLs carry a 5-year legal retention
   obligation, so local-only backups are not acceptable. The bucket and keys must be
   configured before cutover.
2. **Legacy JWT secret** from Supabase → Project Settings → JWT Keys.
3. **DNS:** `A api.kubofood.app → 187.41.119.40` (Squarespace, kubofood.app).
4. **Maintenance window:** about 30 min, overnight.


## Rehearsal findings (2026-11-05)

- **Versions:** after first boot, the auth (82 migrations), storage (80) and realtime
  migration heads are identical to cloud's. Postgres 17.6.
- **Dump/restore:** Supabase CLI `db dump` (roles, schema, data with `--use-copy`)
  through the session pooler (direct is IPv6-only; containers have no IPv6), with a
  temporary role from `POST /v1/projects/{ref}/cli/login-role` (TTL 5 min). Restore
  ran in a single transaction with no errors.
- **Data verification:** all 212 tables in public/auth/storage match by row count
  and content md5, along with function/trigger/policy/index counts and sequences.
  The only difference is the row the 30 s marketplace poll touches, which is
  expected on a live source.
- **ACL trap (fixed):** pg_dump records ACLs relative to Postgres' built-in defaults,
  so restored tables picked up self-hosted Supabase's default privileges: ALL for
  anon/authenticated on **180** tables (cloud: **33**). The repo's own SQL tests
  caught it ("anon can't read …"). Fix: `50-acl-reset.sql` followed by
  `acl-export.sql` run on cloud, in one transaction. All 626 ACL entries (tables,
  views, sequences, functions, default privileges) are now identical to cloud's.
- **Storage:** the dump omits the managed `storage` schema's 3 RLS policies, which
  `10-storage-policies.sql` restores. All 638 objects were copied and verified
  (md5 vs eTag, SHA-256 read-back). Cache-Control is preserved as stored (`max-age=…`).
- **Stored URLs:** `40-storage-urls.sql` rewrote 488 rows (generated columns are
  skipped); the assertion confirmed 0 left.
- **DB tests** (`supabase/tests/*.sql`, each a single rolled-back transaction):
  36/38 pass. The 2 failures (055, 056) insert a restaurant without `slug`, which is
  NOT NULL with no default on cloud too; those tests are stale against the schema.
- **Realtime:** a public WSS join with the anon key, plus a REST broadcast with the
  service key, delivered the message in 50 ms.

### Post-restore order (cutover script)

1. `psql --single-transaction -f roles.sql -f schema.sql -c 'SET session_replication_role = replica' -f data.sql`
2. `10-storage-policies.sql` → `20-cron-jobs.sql` (inactive) → `30-vault.sql` (env-specific) →
   `40-storage-urls.sql` → `50-acl-reset.sql` + cloud ACL export (one transaction)
3. `copy_storage.py` (objects), then the fingerprint, ACL diff and SQL tests: all must match
4. Production only: activate crons (`update cron.job set active = true`)

## Phase 1: staging stack (no production impact)

- Deploy the stack (pinned versions, secrets in Coolify). Healthchecks green.
- Check that auth, storage and realtime boot against a **restored copy** without
  attempting downgrade/unknown migrations (their logs, plus the `*_migrations` tables
  matching cloud).

## Phase 2: rehearsal migration (copy of prod → staging)

1. Dump from cloud, following the Supabase project-migration procedure: roles,
   schema and data (`--use-copy`) for `public`, `auth`, `storage` (metadata) and
   `cron`. The dump goes to the server and to the owner's Mac, with sha256 recorded.
2. Restore into the staging db as `supabase_admin`, inside a single transaction
   per step.
3. **Safety first:** immediately after restore, `UPDATE cron.job SET active = false`
   so staging never calls production. Vault `app_url` → the staging app's preview URL.
4. Re-create the Vault secrets (`app_url`, `fiscal_cron_secret`).
5. Copy the storage objects (638 files) through the Storage API, preserving
   path, content-type and cache-control; verify count and per-object sha256.
6. Rewrite the stored public URLs
   (`https://vtbipnkbejcffxmjtshm.supabase.co/storage/v1/` →
   staging host) and assert that 0 rows still reference the cloud host.
7. **Verification:** row count + content md5 for every table in public/auth/storage,
   function/trigger/policy/index counts, and a schema diff. All must match the
   cloud snapshot.

## Phase 3: staging app + test matrix

A second Coolify app `kubofood-staging` (preview domain only) with the same code,
`NEXT_PUBLIC_SUPABASE_URL` = staging API, WhatsApp paused, 4Selet Pay **sandbox**
and iFood polling off.

- [ ] Public menu renders; images/videos load from the new storage
- [ ] Login (credentials) and dashboard load; CRUD on menu items, banners, sections
- [ ] Image upload (menu item, banner, avatar) → public URL served by the new storage
- [ ] Order end to end: create → kitchen screen receives the realtime broadcast → status update reaches the tracking page
- [ ] Queue (salão) and totem pickup board live updates
- [ ] Private storage: fiscal XML signed download, stock receipt upload/download, checklist photo signed upload
- [ ] Account deletion path (auth admin deleteUser) on a throwaway user
- [ ] Manual trigger of each pg_net cron function against the staging app (fiscal worker, marketplace poll), checking `net._http_response`
- [ ] Performance: TTFB of the 5 heaviest dashboard pages, before and after

Go/no-go: every box checked, with no errors in app or Supabase logs.

## Phase 4: rehearsal #2 (timed)

Run the cutover script end to end against staging with fresh data and measure the
downtime. Target: under 15 min of write freeze.

## Phase 5: cutover (maintenance window)

1. Build and publish the production image with `NEXT_PUBLIC_SUPABASE_URL=https://api.kubofood.app`
   **before** the window (it's inlined at build).
2. Freeze writes: stop the kubofood app in Coolify; disable every cloud cron
   (`UPDATE cron.job SET active = false` on cloud).
3. Final dump → restore into the production stack (fresh), storage delta sync,
   Vault secrets (`app_url=https://www.kubofood.app`, same `fiscal_cron_secret`),
   URL rewrite → `https://api.kubofood.app/storage/v1/`.
4. Verify fingerprints against the cloud snapshot taken after the freeze. **Any
   mismatch = abort.**
5. Enable the crons locally, point the app env at the new stack, deploy the
   pre-built image, then run the Phase 3 smoke tests.
6. Watch for 30 min: app logs, `net._http_response`, realtime connections, error rate.

## Rollback

Before writes resume on the new stack, roll back by redeploying the previous image
(cloud URL) and re-enabling the cloud crons, with no data loss. After writes
resume, the same switch works, but rows written to the new stack must be replayed
(window-sized, reconciled from a diff). The cloud project stays untouched for 30 days.

## Post-cutover

- Backups: Postgres hourly (keep 48) + daily (keep 30) locally **and** to R2;
  storage volume daily to R2; a restore drill into a scratch stack.
- Supabase updates: pinned versions, reviewed monthly; never `latest`.
- After 30 days: final cloud export archived, then the cloud project is deleted.

## Risks

| Risk | Mitigation |
| --- | --- |
| A component boots against a schema newer than it knows | Versions verified against the cloud migration tables; checked in rehearsal before cutover |
| Staging crons hitting production | Crons disabled in the same transaction as the restore; Vault `app_url` points at staging |
| Vault secrets not portable | Re-created explicitly; cron calls tested in Phase 3 |
| Stored image URLs keep pointing at cloud | Rewrite plus an assertion of 0 remaining references; images tested in Phase 3 |
| Single server = single point of failure | Off-site R2 backups (prerequisite) + documented restore |
| Ops burden of running Supabase | Pinned versions, a monthly review, this runbook |
