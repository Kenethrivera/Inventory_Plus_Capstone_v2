-- Read-only Stage 6B.5 security preflight. Safe to run against an existing
-- environment; it performs no DDL or DML.

select
  n.nspname as schema_name,
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  has_table_privilege('anon', c.oid, 'SELECT') as anon_select,
  has_table_privilege('anon', c.oid, 'INSERT') as anon_insert,
  has_table_privilege('anon', c.oid, 'UPDATE') as anon_update,
  has_table_privilege('anon', c.oid, 'DELETE') as anon_delete
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('public', 'private')
  and c.relkind in ('r', 'p')
order by n.nspname, c.relname;

select
  p.proname as function_name,
  pg_catalog.pg_get_function_identity_arguments(p.oid) as identity_arguments,
  p.prosecdef as security_definer,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
  position(
    'require_app_session_v1' in pg_catalog.pg_get_functiondef(p.oid)
  ) > 0 as calls_session_validator,
  position(
    'auth.uid()' in pg_catalog.pg_get_functiondef(p.oid)
  ) > 0 as uses_supabase_auth_uid,
  array_to_string(p.proconfig, ',') as runtime_configuration
from pg_catalog.pg_proc p
join pg_catalog.pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.prokind = 'f'
order by p.proname, identity_arguments;

select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_catalog.pg_policies
where schemaname in ('public', 'private')
order by schemaname, tablename, policyname;
