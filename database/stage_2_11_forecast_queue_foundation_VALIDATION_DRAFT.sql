-- INVENTORY PLUS — STAGE 2.11 FOUNDATION VALIDATION (DRAFT ONLY)
-- Run only after the migration is approved and applied to a disposable,
-- isolated development database. This script creates fixtures inside a single
-- transaction and rolls them back. Do not run against production or shared data.

begin;

do $acl_checks$
declare
  v_table text;
begin
  foreach v_table in array array[
    'private.forecast_input_revisions',
    'private.forecast_jobs',
    'private.forecast_job_attempts',
    'private.forecast_snapshots',
    'private.forecast_snapshot_points',
    'private.forecast_current_pointers'
  ] loop
    if has_table_privilege('anon', v_table, 'SELECT')
        or has_table_privilege('anon', v_table, 'INSERT')
        or has_table_privilege('anon', v_table, 'UPDATE')
        or has_table_privilege('anon', v_table, 'DELETE')
        or has_table_privilege('authenticated', v_table, 'SELECT')
        or has_table_privilege('authenticated', v_table, 'INSERT')
        or has_table_privilege('authenticated', v_table, 'UPDATE')
        or has_table_privilege('authenticated', v_table, 'DELETE')
        or has_table_privilege('service_role', v_table, 'SELECT')
        or has_table_privilege('service_role', v_table, 'INSERT')
        or has_table_privilege('service_role', v_table, 'UPDATE')
        or has_table_privilege('service_role', v_table, 'DELETE') then
      raise exception 'Direct table privileges unexpectedly exist on %', v_table;
    end if;
  end loop;

  if exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'private'
      and c.relname in (
        'forecast_input_revisions', 'forecast_jobs',
        'forecast_job_attempts', 'forecast_snapshots',
        'forecast_snapshot_points', 'forecast_current_pointers'
      )
      and not c.relrowsecurity
  ) then
    raise exception 'Forecast foundation RLS state is incorrect.';
  end if;
end;
$acl_checks$;

do $integrity_checks$
declare
  v_location_a uuid := gen_random_uuid();
  v_location_b uuid := gen_random_uuid();
  v_product_a uuid := gen_random_uuid();
  v_product_b uuid := gen_random_uuid();
  v_job uuid;
  v_snapshot uuid := gen_random_uuid();
  v_as_of date := date '2026-01-02';
  v_hash text := repeat('a', 64);
  v_input_hash text := repeat('b', 64);
begin
  insert into public.locations (id, location_name, store_key)
  values
    (v_location_a, 'stage211-isolated-a', 'stage211-' || v_location_a::text),
    (v_location_b, 'stage211-isolated-b', 'stage211-' || v_location_b::text);

  insert into public.products
    (id, sku, product_name, unit, location_id, is_active)
  values
    (v_product_a, 'stage211-' || v_product_a::text, 'Stage 2.11 fixture A',
      'pcs', v_location_a, true),
    (v_product_b, 'stage211-' || v_product_b::text, 'Stage 2.11 fixture B',
      'pcs', v_location_b, true);

  insert into private.forecast_input_revisions
    (location_id, product_id)
  values (v_location_a, v_product_a);

  insert into private.forecast_jobs (
    location_id, product_id, model_key, model_version,
    model_config_sha256, horizon_days, as_of_date,
    sales_revision, product_input_revision, idempotency_sha256
  ) values (
    v_location_a, v_product_a, 'blend', '1', v_hash, 1, v_as_of,
    0, 0, repeat('c', 64)
  ) returning id into v_job;

  -- Duplicate logical work must be rejected even if the idempotency key differs.
  begin
    insert into private.forecast_jobs (
      location_id, product_id, model_key, model_version,
      model_config_sha256, horizon_days, as_of_date,
      sales_revision, product_input_revision, idempotency_sha256
    ) values (
      v_location_a, v_product_a, 'blend', '1', v_hash, 1, v_as_of,
      0, 0, repeat('d', 64)
    );
    raise exception 'Expected duplicate logical job rejection.';
  exception when unique_violation then
    null;
  end;

  -- A product paired with another location must fail the composite FK.
  begin
    insert into private.forecast_input_revisions (location_id, product_id)
    values (v_location_b, v_product_a);
    raise exception 'Expected cross-location revision rejection.';
  exception when foreign_key_violation then
    null;
  end;

  insert into private.forecast_snapshots (
    id, job_id, location_id, product_id, product_name_snapshot,
    product_sku_snapshot, inventory_unit_snapshot, model_key, model_version,
    model_config_sha256, horizon_days, as_of_date, business_timezone,
    forecast_start_date, forecast_end_date, history_start_date,
    history_end_date, source_data_as_of, sales_revision,
    product_input_revision, input_sha256, data_provenance,
    data_quality, model_metadata
  ) values (
    v_snapshot, v_job, v_location_a, v_product_a, 'Stage 2.11 fixture A',
    'stage211-fixture', 'pcs', 'blend', '1', v_hash, 1, v_as_of,
    'Asia/Manila', v_as_of, v_as_of, null, v_as_of - 1,
    timestamptz '2026-01-02 00:00:00+08', 0, 0, v_input_hash, 'real',
    '{}'::jsonb, '{}'::jsonb
  );
  insert into private.forecast_snapshot_points
    (snapshot_id, forecast_date, quantity, inventory_unit)
  values (v_snapshot, v_as_of, 0, 'pcs');

  set constraints forecast_snapshots_complete_v1 immediate;

  -- Point date/unit must match the parent snapshot.
  begin
    insert into private.forecast_snapshot_points
      (snapshot_id, forecast_date, quantity, inventory_unit)
    values (v_snapshot, v_as_of + 1, 1, 'bags');
    raise exception 'Expected snapshot point unit rejection.';
  exception when check_violation then
    null;
  end;

  -- Forecast payloads cannot be updated or deleted.
  begin
    update private.forecast_snapshots
    set product_name_snapshot = 'mutated'
    where id = v_snapshot;
    raise exception 'Expected immutable snapshot update rejection.';
  exception when sqlstate '55000' then
    null;
  end;

  begin
    update private.forecast_snapshot_points
    set quantity = 99
    where snapshot_id = v_snapshot and forecast_date = v_as_of;
    raise exception 'Expected immutable point update rejection.';
  exception when sqlstate '55000' then
    null;
  end;

  -- Pointer fields must match the exact snapshot scope and revision identity.
  insert into private.forecast_current_pointers (
    location_id, product_id, model_key, model_version,
    model_config_sha256, horizon_days, as_of_date,
    sales_revision, product_input_revision, snapshot_id
  ) values (
    v_location_a, v_product_a, 'blend', '1', v_hash, 1, v_as_of,
    0, 0, v_snapshot
  );

  begin
    insert into private.forecast_current_pointers (
      location_id, product_id, model_key, model_version,
      model_config_sha256, horizon_days, as_of_date,
      sales_revision, product_input_revision, snapshot_id
    ) values (
      v_location_b, v_product_b, 'blend', '1', v_hash, 1, v_as_of,
      0, 0, v_snapshot
    );
    raise exception 'Expected cross-scope pointer rejection.';
  exception when foreign_key_violation then
    null;
  end;

  -- Product deletion may remove operational queue rows, but retained snapshot
  -- content must survive with only its job reference detached.
  delete from public.products where id = v_product_a;
  if not exists (
    select 1 from private.forecast_snapshots
    where id = v_snapshot and job_id is null
  ) then
    raise exception 'Snapshot history did not survive product deletion.';
  end if;
  if exists (
    select 1 from private.forecast_current_pointers
    where product_id = v_product_a
  ) then
    raise exception 'Current pointer did not cascade with product deletion.';
  end if;
end;
$integrity_checks$;

rollback;

-- Milestone 2B must add worker-role checks after choosing the actual hosting
-- credential model. At this stage no worker role or privileged job RPC exists;
-- verify service_role has no direct table privileges above. Later checks must
-- assert only the dedicated trusted worker identity can execute claim/read/
-- publish RPCs, and must exercise location/product scope rejection.
