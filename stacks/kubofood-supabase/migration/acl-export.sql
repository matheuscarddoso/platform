-- Run on the SOURCE (Supabase Cloud). Emits the exact privileges of every
-- object in schema public as GRANT statements, plus the schema's default
-- privileges. Applied on the target after 50-acl-reset.sql.
--
-- Why: pg_dump records ACLs relative to Postgres' built-in defaults, not to
-- Supabase's ALTER DEFAULT PRIVILEGES. Restored objects are therefore born with
-- the target's defaults (ALL to anon/authenticated) and revokes made in cloud
-- are lost. This re-applies cloud's ACLs object by object.
with rel as (
  select format('grant %s on %s %I.%I to %s;',
           string_agg(distinct a.privilege_type, ', '),
           case when c.relkind = 'S' then 'sequence' else 'table' end,
           n.nspname, c.relname,
           case when a.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(a.grantee)) end) as stmt
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  cross join lateral aclexplode(coalesce(c.relacl, acldefault((case when c.relkind = 'S' then 's' else 'r' end)::"char", c.relowner))) a
  where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'S', 'f', 'p') and a.grantee <> c.relowner
  group by n.nspname, c.relname, c.relkind, a.grantee
), fn as (
  select format('grant execute on function %s to %s;', p.oid::regprocedure,
           case when a.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(a.grantee)) end) as stmt
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  cross join lateral aclexplode(coalesce(p.proacl, acldefault('f'::"char", p.proowner))) a
  where n.nspname = 'public' and a.grantee <> p.proowner
), defaults as (
  select format('alter default privileges for role %I in schema public grant %s on %s to %s;',
           pg_get_userbyid(d.defaclrole),
           string_agg(distinct a.privilege_type, ', '),
           case d.defaclobjtype when 'r' then 'tables' when 'S' then 'sequences' when 'f' then 'functions' when 'T' then 'types' end,
           case when a.grantee = 0 then 'public' else quote_ident(pg_get_userbyid(a.grantee)) end) as stmt
  from pg_default_acl d
  join pg_namespace n on n.oid = d.defaclnamespace
  cross join lateral aclexplode(d.defaclacl) a
  where n.nspname = 'public' and d.defaclobjtype in ('r', 'S', 'f', 'T')
  group by d.defaclrole, d.defaclobjtype, a.grantee
)
select stmt from rel union all select stmt from fn union all select stmt from defaults order by 1;
