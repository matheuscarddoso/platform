-- Vault secrets read by the pg_cron/pg_net functions. Vault values are
-- encrypted with the instance's own key, so they're re-created, never dumped.
-- psql -v app_url=https://www.kubofood.app -v cron_secret=... -f 30-vault.sql
\set ON_ERROR_STOP on
begin;
select vault.create_secret(:'app_url', 'app_url', 'kubofood public URL called by pg_cron/pg_net') where not exists (select 1 from vault.secrets where name = 'app_url');
select vault.update_secret(id, :'app_url') from vault.secrets where name = 'app_url';
select vault.create_secret(:'cron_secret', 'fiscal_cron_secret', 'CRON_SECRET of the app') where not exists (select 1 from vault.secrets where name = 'fiscal_cron_secret');
select vault.update_secret(id, :'cron_secret') from vault.secrets where name = 'fiscal_cron_secret';
commit;
select name, length(decrypted_secret) as len from vault.decrypted_secrets order by name;
