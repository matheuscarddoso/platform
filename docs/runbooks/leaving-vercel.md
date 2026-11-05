# Runbook: leaving Vercel, Neon and Supabase Cloud

Status on 2026-11-05: every app runs from this server. Data stores and old cloud projects are listed below with what still remains.

## Where each app's data lives

| App | Database | Files | Backups on the server |
| --- | --- | --- | --- |
| kubofood | Supabase stack `stacks/kubofood-supabase` | same stack | `/root/backups/kubofood` (hourly ×48, daily ×30, files ×14) |
| craft | Supabase stack `stacks/craft-supabase` | same stack | `/root/backups/craft` (hourly ×48, daily ×30, files ×14) |
| regua | Coolify Postgres `regua-db` | none | Coolify scheduled backups (hourly ×48, daily ×30) |
| grafica | Coolify Postgres `grafica-db` | volume `*-grafica-photos`, at `/srv/data` | Coolify scheduled backups, `/root/backups/grafica/files` (×14) |
| geradoor | Coolify Postgres `geradoor-db` | none | Coolify scheduled backups (hourly ×48, daily ×30) |

**All of these are on the same disk as the data.** There is no off-site copy yet.

## How the moves were done

- **Plain Postgres (regua, grafica):** `stacks/migrations/pg-cutover.sh` rehearses first (dump, restore, compare every table's row count and content), then stops the app, repeats, switches `DATABASE_URL` and starts the app. Any failure before the switch starts the app on the source, which was never written to. Downtime: 10 s and 6 s.
- **Supabase (craft):** `stacks/craft-supabase/migration/cutover.sh`. Same SQL as kubofood. `supabase db dump` leaves out the storage RLS policies, so they are exported from the source and re-created.

## Things that are easy to get wrong

- **Secrets marked sensitive on Vercel cannot be read back.** Before deleting a project, prove that what is on the server is the production value. regua: the private key must derive the public key embedded in `@regua/license`; `REGUA_SECRET` must reproduce the stored `chave_hash` of real licences, or every customer's key stops working.
- **Private databases and CI:** the GitHub runner cannot reach them. An app whose build reads the database needs to render at request time (grafica) with a placeholder `DATABASE_URL` in `BUILD_ENV`.
- **Driver:** `@neondatabase/serverless` talks HTTP to Neon only. It has to be replaced, and `db.batch` with it.
- **`NEXT_PUBLIC_SUPABASE_URL` is inlined at build:** changing it needs a new `BUILD_ENV` and a deploy. craft also prefers `sb_publishable_`/`sb_secret_` keys, which the self-hosted gateway does not know: remove them so it falls back to the legacy JWT keys.
- **Free Supabase projects:** at most 2 active per owner, and a paused project cannot be dumped. Restoring one may require pausing another.
- **`docker exec -i` inside a script piped to `ssh ... bash -s` eats the rest of the script.** Copy the script over and run it as a file, with `</dev/null`.

## Config of the deleted Vercel projects

Saved on the owner's Mac in `~/Backups/vercel-export-20261105`: settings, domains, deployments and env var names, no values.
