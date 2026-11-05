-- Run on the TARGET, immediately before the statements from acl-export.sql,
-- in the same transaction. Strips every non-owner privilege from schema public
-- (tables, views, sequences, functions) and its default privileges, so the
-- exported cloud ACLs become the only ones.
do $$
declare r record;
begin
  for r in select c.oid::regclass as obj, c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'S', 'f', 'p') loop
    execute format('revoke all on %s %s from public, anon, authenticated, service_role',
                   case when r.relkind = 'S' then 'sequence' else 'table' end, r.obj);
  end loop;
  for r in select p.oid::regprocedure as fn from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', r.fn);
  end loop;
  for r in select distinct pg_get_userbyid(defaclrole) as role from pg_default_acl d join pg_namespace n on n.oid = d.defaclnamespace
           where n.nspname = 'public' loop
    execute format('alter default privileges for role %I in schema public revoke all on tables from public, anon, authenticated, service_role', r.role);
    execute format('alter default privileges for role %I in schema public revoke all on sequences from public, anon, authenticated, service_role', r.role);
    execute format('alter default privileges for role %I in schema public revoke all on functions from public, anon, authenticated, service_role', r.role);
  end loop;
end $$;
