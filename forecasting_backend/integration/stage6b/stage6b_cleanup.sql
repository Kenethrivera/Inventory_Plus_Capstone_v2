\set ON_ERROR_STOP on

\if :{?stage6b_expected_project_ref}
\else
\echo 'stage6b_expected_project_ref is required'
\quit
\endif

begin;
set local inventory_plus.stage6b_expected_project_ref = :'stage6b_expected_project_ref';

do $guard$
begin
  if to_regclass('private.stage6b_isolated_environment') is null or not exists (
    select 1 from private.stage6b_isolated_environment
    where marker = 'inventory-plus-stage6b'
      and allow_fixture_writes is true
      and project_ref = current_setting(
        'inventory_plus.stage6b_expected_project_ref')
      and purpose = 'inventory-plus-stage6b-isolated-integration'
  ) then
    raise exception 'Stage 6B cleanup guard: isolated identity is not authorized';
  end if;
end;
$guard$;

delete from public.order_history
where order_id like 'stage6b-%';

delete from private.app_sessions
where profile_id in (-61001, -61002, -61003, -61004);

delete from public.products
where id in (
  '61a00000-0000-4000-8000-000000000001',
  '61a00000-0000-4000-8000-000000000002',
  '61b00000-0000-4000-8000-000000000001'
);

delete from public.profiles
where id in (-61001, -61002, -61003, -61004);

delete from public.locations
where id in (
  '61000000-0000-4000-8000-000000000001',
  '61000000-0000-4000-8000-000000000002'
);

commit;
