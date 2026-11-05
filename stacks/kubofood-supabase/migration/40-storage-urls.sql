-- Rewrite stored Storage URLs from Supabase Cloud to the self-hosted API.
-- Generic: every text/varchar/jsonb column in public that mentions the cloud
-- host. Triggers are suspended so the rewrite has no side effects
-- (updated_at bumps, pg_net calls). Fails if any reference remains.
-- psql -v old=https://vtbipnkbejcffxmjtshm.supabase.co -v new=https://api.kubofood.app -f 40-storage-urls.sql
\set ON_ERROR_STOP on
begin;
set local session_replication_role = replica;
select set_config('kubo.old', :'old', true), set_config('kubo.new', :'new', true);
do $$
declare r record; n bigint; total bigint := 0; old text := current_setting('kubo.old'); new text := current_setting('kubo.new');
begin
  for r in
    select c.table_schema, c.table_name, c.column_name, c.data_type
    from information_schema.columns c
    join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
    where c.table_schema = 'public' and c.data_type in ('text', 'character varying', 'jsonb', 'json') and c.is_generated = 'NEVER'
  loop
    if r.data_type in ('jsonb', 'json') then
      execute format('update %I.%I set %I = replace(%I::text, $1, $2)::%s where %I::text like $3',
        r.table_schema, r.table_name, r.column_name, r.column_name, r.data_type, r.column_name) using old, new, '%' || old || '%';
    else
      execute format('update %I.%I set %I = replace(%I, $1, $2) where %I like $3',
        r.table_schema, r.table_name, r.column_name, r.column_name, r.column_name) using old, new, '%' || old || '%';
    end if;
    get diagnostics n = row_count;
    if n > 0 then raise notice 'rewrote %.%: % rows', r.table_name, r.column_name, n; total := total + n; end if;
  end loop;
  raise notice 'total rows rewritten: %', total;
  -- assertion: nothing may still point at the cloud host
  for r in
    select c.table_schema, c.table_name, c.column_name from information_schema.columns c
    join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
    where c.table_schema = 'public' and c.data_type in ('text', 'character varying', 'jsonb', 'json') and c.is_generated = 'NEVER'
  loop
    execute format('select count(*) from %I.%I where %I::text like $1', r.table_schema, r.table_name, r.column_name) into n using '%' || old || '%';
    if n > 0 then raise exception 'still % rows referencing % in %.%', n, old, r.table_name, r.column_name; end if;
  end loop;
end $$;
commit;
