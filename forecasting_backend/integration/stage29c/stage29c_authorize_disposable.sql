\set ON_ERROR_STOP on

-- WRITE SCRIPT FOR AN EXPRESSLY APPROVED DISPOSABLE DATABASE ONLY.
-- Never run this against project pzotcznujkuzymndluwl.
-- The integration suite cannot create this marker itself; an operator must
-- review the connected project ref and deliberately authorize fixture writes.

\if :{?stage29c_test_project_ref}
\else
\echo 'stage29c_test_project_ref is required'
\quit
\endif

\if :{?stage29c_write_confirmation}
\else
\echo 'stage29c_write_confirmation is required'
\quit
\endif

begin;

set local inventory_plus.stage29c_test_project_ref =
  :'stage29c_test_project_ref';
set local inventory_plus.stage29c_write_confirmation =
  :'stage29c_write_confirmation';

do $guard$
begin
  if current_setting('inventory_plus.stage29c_test_project_ref') =
      'pzotcznujkuzymndluwl' then
    raise exception 'Refusing to authorize the protected Inventory Plus project';
  end if;
  if current_setting('inventory_plus.stage29c_write_confirmation') <>
      'I_APPROVE_STAGE29C_WRITES_ON_THIS_DISPOSABLE_DATABASE' then
    raise exception 'Disposable write confirmation is invalid';
  end if;
end;
$guard$;

create table private.stage29c_isolated_environment (
  marker text primary key,
  project_ref text not null,
  purpose text not null,
  allow_schema_writes boolean not null default false,
  authorized_at timestamptz not null default clock_timestamp()
);

insert into private.stage29c_isolated_environment (
  marker, project_ref, purpose, allow_schema_writes
) values (
  'inventory-plus-stage29c',
  current_setting('inventory_plus.stage29c_test_project_ref'),
  'inventory-plus-stage29c-isolated-integration',
  true
);

revoke all on table private.stage29c_isolated_environment
  from public, anon, authenticated, service_role;

commit;
