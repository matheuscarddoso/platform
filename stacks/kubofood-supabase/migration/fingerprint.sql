select kind, name, val from (
  select 'table' as kind, n.nspname || '.' || c.relname as name,
    (xpath('/row/c/text()', query_to_xml(format('select count(*) || '':'' || coalesce(md5(string_agg(t::text, ''|'' order by t::text)), ''empty'') as c from %I.%I t', n.nspname, c.relname), false, true, '')))[1]::text as val
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where c.relkind = 'r' and n.nspname in ('public', 'auth', 'storage')
    and not (n.nspname = 'auth' and c.relname in ('schema_migrations'))
    and not (n.nspname = 'storage' and c.relname in ('migrations'))
  union all select 'count', 'public.functions', count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
  union all select 'count', 'public.triggers', count(*)::text from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal
  union all select 'count', 'public.policies', count(*)::text from pg_policies where schemaname = 'public'
  union all select 'count', 'storage.policies', count(*)::text from pg_policies where schemaname = 'storage'
  union all select 'count', 'public.indexes', count(*)::text from pg_indexes where schemaname = 'public'
  union all select 'count', 'public.views', count(*)::text from pg_views where schemaname = 'public'
  union all select 'seq', schemaname || '.' || sequencename, coalesce(last_value::text, 'null') from pg_sequences where schemaname = 'public'
) x order by kind, name;
