-- INVENTORY PLUS - STAGE 2.9C RECOMMENDATION TRACKING DRY RUN
-- MANUAL SQL EDITOR CHECK ONLY. This transaction always rolls back.
-- It creates and verifies the reviewed objects transiently without retaining
-- schema or data changes.
--
-- Verified live-schema rules reflected here:
--   * products.id and transaction_history.id are uuid;
--   * profiles.id is bigint and locations.id is uuid;
--   * transaction_history has no unit column;
--   * a stock_in quantity_change is already expressed in the product's
--     canonical inventory unit by the existing inventory write paths;
--   * transaction_history.product_id currently cascades on product deletion;
--   * recommendation history therefore uses immutable identity snapshots and
--     intentionally has no FK to products, locations, profiles, or receipts;
--   * only internal recommendation tables reference one another;
--   * every write RPC is service-role-only and also validates an Admin app
--     session. Flutter/anon must never call these RPCs directly;
--   * no inventory, receipt, purchase-order, forecast, or product row is
--     changed by this proposal.

begin;

set local lock_timeout = '10s';
set local statement_timeout = '5min';

do $preflight$
declare
  v_missing text;
  v_conflicts text;
begin
  if current_setting('server_version_num')::integer < 150000 then
    raise exception 'Stage 2.9C requires PostgreSQL 15 or newer.';
  end if;

  select string_agg(format('%I.%I.%I expected %s, found %s',
      required.schema_name, required.table_name, required.column_name,
      required.expected_udt, coalesce(actual.udt_name, '<missing>')), ', ')
    into v_missing
  from (values
    ('public','products','id','uuid'),
    ('public','products','sku','text'),
    ('public','products','product_name','text'),
    ('public','products','unit','text'),
    ('public','products','product_quantity','numeric'),
    ('public','products','location_id','uuid'),
    ('public','products','is_active','bool'),
    ('public','transaction_history','id','uuid'),
    ('public','transaction_history','product_id','uuid'),
    ('public','transaction_history','location_id','uuid'),
    ('public','transaction_history','transaction_type','text'),
    ('public','transaction_history','quantity_change','numeric'),
    ('public','transaction_history','created_at','timestamptz'),
    ('public','transaction_history','operation_id','text'),
    ('public','transaction_history','operation_scope','text'),
    ('public','locations','id','uuid'),
    ('public','profiles','id','int8'),
    ('public','profiles','role','text'),
    ('public','profiles','location_id','uuid'),
    ('public','approval_requests','transaction_id','uuid'),
    ('public','approval_requests','product_id','uuid'),
    ('public','approval_requests','request_type','text'),
    ('public','approval_requests','status','text'),
    ('public','approval_requests','unit','text'),
    ('public','approval_requests','reviewed_at','timestamptz')
  ) required(schema_name, table_name, column_name, expected_udt)
  left join information_schema.columns actual
    on actual.table_schema = required.schema_name
   and actual.table_name = required.table_name
   and actual.column_name = required.column_name
  where actual.column_name is null
     or actual.udt_name <> required.expected_udt;

  if v_missing is not null then
    raise exception 'Stage 2.9C schema compatibility failed: %', v_missing;
  end if;

  if to_regclass('private.app_sessions') is null
      or to_regprocedure('private.require_app_session_v1(text)') is null
      or to_regprocedure('extensions.digest(bytea,text)') is null
      or to_regprocedure('pg_catalog.trim_scale(numeric)') is null then
    raise exception
      'Stage 2.9C requires private app sessions, session validation, digest and trim_scale.';
  end if;

  if not exists (
    select 1
    from pg_proc
    where oid = to_regprocedure('private.require_app_session_v1(text)')
      and prosecdef
      and provolatile = 's'
  ) then
    raise exception
      'Stage 2.9C requires the verified STABLE SECURITY DEFINER session validator.';
  end if;

  if not exists (select 1 from pg_roles where rolname = 'anon')
      or not exists (select 1 from pg_roles where rolname = 'authenticated')
      or not exists (select 1 from pg_roles where rolname = 'service_role')
      or not exists (select 1 from pg_roles where rolname = 'postgres') then
    raise exception 'Stage 2.9C required Supabase roles are missing.';
  end if;

  if not exists (
    select 1 from public.profiles
    where lower(role) = 'admin' and location_id is not null
  ) then
    raise exception 'Stage 2.9C requires an Admin assigned to a location.';
  end if;

  if exists (
    select 1 from public.transaction_history
    where transaction_type = 'stock_in'
      and (
        quantity_change is null or quantity_change <= 0
        or product_id is null or location_id is null
      )
  ) then
    raise exception 'Stage 2.9C found malformed stock_in receipt rows.';
  end if;

  select string_agg(format('%I.%I (%s)', conflict.schema_name,
      conflict.object_name, conflict.object_kind), ', ')
    into v_conflicts
  from (
    select n.nspname as schema_name, c.relname as object_name,
           c.relkind::text as object_kind
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('public', 'private')
      and c.relname in (
        'forecast_recommendation_snapshots',
        'forecast_recommendation_receipt_allocations',
        'forecast_recommendation_reconciliations',
        'forecast_recommendation_snapshots_id_seq',
        'forecast_recommendation_receipt_allocations_id_seq',
        'forecast_recommendation_reconciliations_id_seq',
        'forecast_recommendation_snapshots_product_created_idx',
        'forecast_recommendation_receipts_recommendation_idx',
        'forecast_recommendation_receipts_transaction_idx'
      )
    union all
    select n.nspname, p.proname, 'function'
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private')
      and p.proname in (
        'forecast_recommendation_snapshot_by_request_v1',
        'save_forecast_recommendation_snapshot_v1',
        'match_forecast_recommendation_receipt_v1',
        'reconcile_forecast_recommendation_v1',
        'forecast_recommendation_tracking_v1',
        'reject_forecast_recommendation_mutation_v1'
      )
    union all
    select n.nspname, t.tgname, 'trigger'
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where not t.tgisinternal
      and t.tgname in (
        'forecast_recommendation_snapshots_immutable_v1',
        'forecast_recommendation_receipts_immutable_v1',
        'forecast_recommendation_reconciliations_immutable_v1'
      )
  ) conflict;

  if v_conflicts is not null then
    raise exception 'Stage 2.9C object conflict: %', v_conflicts;
  end if;
end;
$preflight$;

create temporary table _stage29c_existing_data_baseline on commit drop as
select
  (select count(*) from public.products) as products_count,
  (select count(*) from public.transaction_history) as transactions_count,
  (select count(*) from public.locations) as locations_count,
  (select count(*) from public.profiles) as profiles_count;


create table public.forecast_recommendation_snapshots (
  id bigint generated always as identity primary key,
  request_id uuid not null,
  created_at timestamptz not null default clock_timestamp(),

  -- Immutable identity snapshots: deliberately no external foreign keys.
  location_id_snapshot uuid not null,
  product_id_snapshot uuid not null,
  product_name_snapshot text not null,
  product_sku_snapshot text not null,
  inventory_unit_snapshot text not null,
  saved_by_profile_id_snapshot bigint not null,
  saved_by_name_snapshot text not null,

  -- Only the existing approved standard LightGBM path is admissible.
  forecast_model text not null,
  forecast_version text not null,
  training_history_days integer not null,
  experimental_model boolean not null,
  forecast_generated_at timestamptz not null,
  forecast_source_data_as_of timestamptz not null,
  planning_horizon_days integer not null,
  forecast_period_start date not null,
  forecast_period_end date not null,
  predicted_demand numeric not null,
  available_inventory numeric not null,
  recommended_restock_quantity numeric not null,
  assumptions jsonb not null,
  request_payload_sha256 text not null,
  schema_version text not null default 'stage2.9c-v2',

  constraint forecast_recommendation_snapshots_request_unique
    unique (location_id_snapshot, request_id),
  constraint forecast_recommendation_snapshots_model_check
    check (
      forecast_model = 'lightgbm'
      and forecast_version = '1'
      and training_history_days = 365
      and experimental_model = false
    ),
  constraint forecast_recommendation_snapshots_horizon_check
    check (planning_horizon_days = 28),
  constraint forecast_recommendation_snapshots_period_check
    check (
      forecast_period_end =
        forecast_period_start + (planning_horizon_days - 1)
    ),
  constraint forecast_recommendation_snapshots_predicted_check
    check (
      predicted_demand >= 0
      and predicted_demand::text not in ('NaN', 'Infinity', '-Infinity')
    ),
  constraint forecast_recommendation_snapshots_inventory_check
    check (
      available_inventory >= 0
      and available_inventory::text not in ('NaN', 'Infinity', '-Infinity')
    ),
  constraint forecast_recommendation_snapshots_recommended_check
    check (
      recommended_restock_quantity >= 0
      and recommended_restock_quantity::text
        not in ('NaN', 'Infinity', '-Infinity')
      and recommended_restock_quantity = greatest(
        0::numeric,
        ceil(predicted_demand - available_inventory)
      )
    ),
  constraint forecast_recommendation_snapshots_identity_check
    check (
      length(btrim(product_name_snapshot)) > 0
      and length(btrim(product_sku_snapshot)) > 0
      and length(btrim(inventory_unit_snapshot)) > 0
      and length(btrim(saved_by_name_snapshot)) > 0
    ),
  constraint forecast_recommendation_snapshots_assumptions_check
    check (jsonb_typeof(assumptions) = 'array'),
  constraint forecast_recommendation_snapshots_hash_check
    check (request_payload_sha256 ~ '^[0-9a-f]{64}$')
);

create index forecast_recommendation_snapshots_product_created_idx
  on public.forecast_recommendation_snapshots
    (location_id_snapshot, product_id_snapshot, created_at desc, id desc);

alter table public.forecast_recommendation_snapshots enable row level security;
revoke all on table public.forecast_recommendation_snapshots
  from public, anon, authenticated, service_role;
revoke all on sequence public.forecast_recommendation_snapshots_id_seq
  from public, anon, authenticated, service_role;

create table public.forecast_recommendation_receipt_allocations (
  id bigint generated always as identity primary key,
  recommendation_id bigint not null
    references public.forecast_recommendation_snapshots(id) on delete restrict,

  -- Receipt data is copied because the live receipt row can be deleted by the
  -- existing transaction_history.product_id ON DELETE CASCADE relationship.
  transaction_history_id_snapshot uuid not null,
  receipt_created_at_snapshot timestamptz not null,
  receipt_quantity_snapshot numeric not null,
  allocated_inventory_quantity numeric not null,
  receipt_product_id_snapshot uuid not null,
  receipt_location_id_snapshot uuid not null,
  receipt_inventory_unit_snapshot text not null,
  receipt_unit_evidence text not null,
  receipt_operation_id_snapshot text,
  receipt_operation_scope_snapshot text,

  matched_at timestamptz not null default clock_timestamp(),
  matched_by_profile_id_snapshot bigint not null,
  matched_by_name_snapshot text not null,

  constraint forecast_recommendation_receipt_pair_unique
    unique (recommendation_id, transaction_history_id_snapshot),
  constraint forecast_recommendation_receipt_quantity_check
    check (
      receipt_quantity_snapshot > 0
      and allocated_inventory_quantity > 0
      and allocated_inventory_quantity <= receipt_quantity_snapshot
      and receipt_quantity_snapshot::text
        not in ('NaN', 'Infinity', '-Infinity')
      and allocated_inventory_quantity::text
        not in ('NaN', 'Infinity', '-Infinity')
    ),
  constraint forecast_recommendation_receipt_identity_check
    check (
      length(btrim(receipt_inventory_unit_snapshot)) > 0
      and length(btrim(matched_by_name_snapshot)) > 0
    ),
  constraint forecast_recommendation_receipt_unit_evidence_check
    check (
      receipt_unit_evidence in (
        'approved_restock_request_snapshot',
        'current_product_canonical_unit'
      )
    )
);

create index forecast_recommendation_receipts_recommendation_idx
  on public.forecast_recommendation_receipt_allocations
    (recommendation_id, receipt_created_at_snapshot, id);
create index forecast_recommendation_receipts_transaction_idx
  on public.forecast_recommendation_receipt_allocations
    (transaction_history_id_snapshot);

alter table public.forecast_recommendation_receipt_allocations
  enable row level security;
revoke all on table public.forecast_recommendation_receipt_allocations
  from public, anon, authenticated, service_role;
revoke all on sequence public.forecast_recommendation_receipt_allocations_id_seq
  from public, anon, authenticated, service_role;

create table public.forecast_recommendation_reconciliations (
  id bigint generated always as identity primary key,
  recommendation_id bigint not null unique
    references public.forecast_recommendation_snapshots(id) on delete restrict,
  request_id uuid not null,
  location_id_snapshot uuid not null,
  confirmed_at timestamptz not null default clock_timestamp(),
  confirmed_by_profile_id_snapshot bigint not null,
  confirmed_by_name_snapshot text not null,
  confirmed_no_receipts boolean not null,
  matched_received_quantity_at_confirmation numeric not null,
  receipt_count_at_confirmation bigint not null,
  first_receipt_date_at_confirmation timestamptz,
  last_receipt_date_at_confirmation timestamptz,
  confirmation_note text,

  constraint forecast_recommendation_reconcile_request_unique
    unique (location_id_snapshot, request_id),
  constraint forecast_recommendation_reconcile_quantity_check
    check (
      matched_received_quantity_at_confirmation >= 0
      and matched_received_quantity_at_confirmation::text
        not in ('NaN', 'Infinity', '-Infinity')
      and receipt_count_at_confirmation >= 0
    ),
  constraint forecast_recommendation_reconcile_receipt_state_check
    check (
      (
        confirmed_no_receipts
        and receipt_count_at_confirmation = 0
        and matched_received_quantity_at_confirmation = 0
        and first_receipt_date_at_confirmation is null
        and last_receipt_date_at_confirmation is null
      )
      or
      (
        not confirmed_no_receipts
        and receipt_count_at_confirmation > 0
        and matched_received_quantity_at_confirmation > 0
        and first_receipt_date_at_confirmation is not null
        and last_receipt_date_at_confirmation is not null
      )
    ),
  constraint forecast_recommendation_reconcile_actor_check
    check (length(btrim(confirmed_by_name_snapshot)) > 0)
);

alter table public.forecast_recommendation_reconciliations
  enable row level security;
revoke all on table public.forecast_recommendation_reconciliations
  from public, anon, authenticated, service_role;
revoke all on sequence public.forecast_recommendation_reconciliations_id_seq
  from public, anon, authenticated, service_role;

create or replace function private.reject_forecast_recommendation_mutation_v1()
returns trigger
language plpgsql
set search_path = public, private, extensions, pg_temp
as $$
begin
  raise exception 'forecast_recommendation_records_are_immutable';
end;
$$;

revoke all on function private.reject_forecast_recommendation_mutation_v1()
  from public, anon, authenticated, service_role;

create trigger forecast_recommendation_snapshots_immutable_v1
before update or delete on public.forecast_recommendation_snapshots
for each row execute function
  private.reject_forecast_recommendation_mutation_v1();

create trigger forecast_recommendation_receipts_immutable_v1
before update or delete on public.forecast_recommendation_receipt_allocations
for each row execute function
  private.reject_forecast_recommendation_mutation_v1();

create trigger forecast_recommendation_reconciliations_immutable_v1
before update or delete on public.forecast_recommendation_reconciliations
for each row execute function
  private.reject_forecast_recommendation_mutation_v1();

create or replace function public.forecast_recommendation_snapshot_by_request_v1(
  p_session_token text,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_profile record;
  v_snapshot public.forecast_recommendation_snapshots%rowtype;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Recommendation session is invalid or expired';
  end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may view recommendation snapshots';
  end if;
  if p_request_id is null then
    raise exception 'recommendation_request_id_invalid';
  end if;

  select snapshot.* into v_snapshot
  from public.forecast_recommendation_snapshots snapshot
  where snapshot.location_id_snapshot = v_profile.location_id
    and snapshot.request_id = p_request_id;
  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'recommendation_id', v_snapshot.id,
    'request_id', v_snapshot.request_id,
    'location_id_snapshot', v_snapshot.location_id_snapshot,
    'product_id_snapshot', v_snapshot.product_id_snapshot,
    'product_name_snapshot', v_snapshot.product_name_snapshot,
    'product_sku_snapshot', v_snapshot.product_sku_snapshot,
    'inventory_unit_snapshot', v_snapshot.inventory_unit_snapshot,
    'forecast_model', v_snapshot.forecast_model,
    'forecast_version', v_snapshot.forecast_version,
    'training_history_days', v_snapshot.training_history_days,
    'experimental_model', v_snapshot.experimental_model,
    'forecast_generated_at', v_snapshot.forecast_generated_at,
    'forecast_source_data_as_of', v_snapshot.forecast_source_data_as_of,
    'planning_horizon_days', v_snapshot.planning_horizon_days,
    'forecast_period_start', v_snapshot.forecast_period_start,
    'forecast_period_end', v_snapshot.forecast_period_end,
    'predicted_demand', v_snapshot.predicted_demand,
    'available_inventory', v_snapshot.available_inventory,
    'recommended_restock_quantity', v_snapshot.recommended_restock_quantity,
    'created_at', v_snapshot.created_at
  );
end;
$$;

revoke all on function public.forecast_recommendation_snapshot_by_request_v1(
  text, uuid
) from public, anon, authenticated;
grant execute on function public.forecast_recommendation_snapshot_by_request_v1(
  text, uuid
) to service_role, postgres;

create or replace function public.save_forecast_recommendation_snapshot_v1(
  p_session_token text,
  p_request_id uuid,
  p_product_id uuid,
  p_forecast_model text,
  p_forecast_version text,
  p_training_history_days integer,
  p_experimental_model boolean,
  p_forecast_generated_at timestamptz,
  p_forecast_source_data_as_of timestamptz,
  p_planning_horizon_days integer,
  p_forecast_period_start date,
  p_forecast_period_end date,
  p_predicted_demand numeric,
  p_available_inventory numeric,
  p_inventory_unit text,
  p_assumptions jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_profile record;
  v_product public.products%rowtype;
  v_existing public.forecast_recommendation_snapshots%rowtype;
  v_snapshot public.forecast_recommendation_snapshots%rowtype;
  v_payload jsonb;
  v_payload_hash text;
  v_recommended numeric;
  v_now timestamptz := clock_timestamp();
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Recommendation session is invalid or expired';
  end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may save recommendation snapshots';
  end if;

  if p_request_id is null
      or p_product_id is null
      or lower(btrim(coalesce(p_forecast_model, ''))) <> 'lightgbm'
      or btrim(coalesce(p_forecast_version, '')) <> '1'
      or p_training_history_days is distinct from 365
      or p_experimental_model is distinct from false
      or p_planning_horizon_days is distinct from 28
      or p_forecast_period_start is null
      or p_forecast_period_end is null
      or p_forecast_period_end < p_forecast_period_start
      or p_forecast_period_end <>
        p_forecast_period_start + (p_planning_horizon_days - 1)
      or p_predicted_demand is null
      or p_predicted_demand < 0
      or p_predicted_demand::text in ('NaN', 'Infinity', '-Infinity')
      or p_available_inventory is null
      or p_available_inventory < 0
      or p_available_inventory::text in ('NaN', 'Infinity', '-Infinity')
      or length(btrim(coalesce(p_inventory_unit, ''))) = 0
      or p_forecast_generated_at is null
      or p_forecast_source_data_as_of is null
      or p_forecast_generated_at < v_now - interval '24 hours'
      or p_forecast_generated_at > v_now + interval '5 minutes'
      or p_forecast_source_data_as_of < v_now - interval '24 hours'
      or p_forecast_source_data_as_of > v_now + interval '5 minutes'
      or p_forecast_source_data_as_of <
        p_forecast_generated_at - interval '24 hours'
      or p_forecast_source_data_as_of >
        p_forecast_generated_at + interval '5 minutes'
      or p_forecast_period_start <>
        (p_forecast_generated_at at time zone 'Asia/Manila')::date
      or jsonb_typeof(coalesce(p_assumptions, '[]'::jsonb)) <> 'array' then
    raise exception 'forecast_recommendation_snapshot_invalid_or_unapproved';
  end if;

  v_payload := jsonb_build_object(
    'product_id', p_product_id,
    'forecast_model', 'lightgbm',
    'forecast_version', '1',
    'training_history_days', 365,
    'experimental_model', false,
    'forecast_generated_at', p_forecast_generated_at,
    'forecast_source_data_as_of', p_forecast_source_data_as_of,
    'planning_horizon_days', 28,
    'forecast_period_start', p_forecast_period_start,
    'forecast_period_end', p_forecast_period_end,
    'predicted_demand', trim_scale(p_predicted_demand),
    'available_inventory', trim_scale(p_available_inventory),
    'inventory_unit', lower(btrim(p_inventory_unit)),
    'assumptions', coalesce(p_assumptions, '[]'::jsonb)
  );
  v_payload_hash := encode(
    extensions.digest(convert_to(v_payload::text, 'UTF8'), 'sha256'),
    'hex'
  );

  -- Serialize the idempotency key before reading or inserting.
  perform pg_advisory_xact_lock(
    hashtextextended(
      'forecast-recommendation:' || v_profile.location_id::text || ':' ||
        p_request_id::text,
      0
    )
  );

  -- Important: the retry check happens before looking at current stock.
  -- Therefore a genuine retry remains idempotent after inventory changes.
  select snapshot.* into v_existing
  from public.forecast_recommendation_snapshots snapshot
  where snapshot.location_id_snapshot = v_profile.location_id
    and snapshot.request_id = p_request_id;
  if found then
    if v_existing.request_payload_sha256 is distinct from v_payload_hash then
      raise exception 'forecast_recommendation_request_conflict';
    end if;
    return jsonb_build_object(
      'recommendation_id', v_existing.id,
      'reused', true
    );
  end if;

  -- First-save freshness is checked against canonical Supabase state. The
  -- trusted FastAPI caller must submit the exact inventory snapshot used by
  -- its approved 365-day LightGBM calculation.
  select product.* into v_product
  from public.products product
  where product.id = p_product_id
    and product.location_id = v_profile.location_id
    and product.is_active = true
  for share;
  if not found then
    raise exception 'Product not found, inactive, or outside the active location';
  end if;
  if v_product.product_quantity is null
      or v_product.product_quantity < 0
      or v_product.product_quantity::text in ('NaN', 'Infinity', '-Infinity') then
    raise exception 'Current saleable inventory is unavailable or invalid';
  end if;
  if v_product.product_quantity is distinct from p_available_inventory then
    raise exception 'forecast_recommendation_inventory_snapshot_is_stale';
  end if;
  if lower(btrim(coalesce(v_product.unit, ''))) <>
      lower(btrim(p_inventory_unit)) then
    raise exception 'forecast_recommendation_inventory_unit_mismatch';
  end if;

  v_recommended := greatest(
    0::numeric,
    ceil(p_predicted_demand - p_available_inventory)
  );

  insert into public.forecast_recommendation_snapshots (
    request_id,
    location_id_snapshot,
    product_id_snapshot,
    product_name_snapshot,
    product_sku_snapshot,
    inventory_unit_snapshot,
    saved_by_profile_id_snapshot,
    saved_by_name_snapshot,
    forecast_model,
    forecast_version,
    training_history_days,
    experimental_model,
    forecast_generated_at,
    forecast_source_data_as_of,
    planning_horizon_days,
    forecast_period_start,
    forecast_period_end,
    predicted_demand,
    available_inventory,
    recommended_restock_quantity,
    assumptions,
    request_payload_sha256
  ) values (
    p_request_id,
    v_profile.location_id,
    v_product.id,
    v_product.product_name,
    v_product.sku,
    v_product.unit,
    v_profile.profile_id,
    v_profile.profile_name,
    'lightgbm',
    '1',
    365,
    false,
    p_forecast_generated_at,
    p_forecast_source_data_as_of,
    28,
    p_forecast_period_start,
    p_forecast_period_end,
    p_predicted_demand,
    p_available_inventory,
    v_recommended,
    coalesce(p_assumptions, '[]'::jsonb),
    v_payload_hash
  ) returning * into v_snapshot;

  return jsonb_build_object(
    'recommendation_id', v_snapshot.id,
    'reused', false
  );
end;
$$;

revoke all on function public.save_forecast_recommendation_snapshot_v1(
  text, uuid, uuid, text, text, integer, boolean, timestamptz, timestamptz,
  integer, date, date, numeric, numeric, text, jsonb
) from public, anon, authenticated;
grant execute on function public.save_forecast_recommendation_snapshot_v1(
  text, uuid, uuid, text, text, integer, boolean, timestamptz, timestamptz,
  integer, date, date, numeric, numeric, text, jsonb
) to service_role, postgres;

create or replace function public.match_forecast_recommendation_receipt_v1(
  p_session_token text,
  p_recommendation_id bigint,
  p_transaction_history_id uuid,
  p_allocated_inventory_quantity numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_profile record;
  v_recommendation public.forecast_recommendation_snapshots%rowtype;
  v_receipt public.transaction_history%rowtype;
  v_existing public.forecast_recommendation_receipt_allocations%rowtype;
  v_allocation public.forecast_recommendation_receipt_allocations%rowtype;
  v_receipt_unit text;
  v_unit_evidence text;
  v_already_allocated numeric;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Recommendation session is invalid or expired';
  end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may match restock receipts';
  end if;
  if p_recommendation_id is null
      or p_transaction_history_id is null
      or p_allocated_inventory_quantity is null
      or p_allocated_inventory_quantity <= 0
      or p_allocated_inventory_quantity::text
        in ('NaN', 'Infinity', '-Infinity') then
    raise exception 'receipt_allocation_invalid';
  end if;

  select snapshot.* into v_recommendation
  from public.forecast_recommendation_snapshots snapshot
  where snapshot.id = p_recommendation_id
    and snapshot.location_id_snapshot = v_profile.location_id;
  if not found then
    raise exception 'Recommendation not found or outside the active location';
  end if;

  -- Recommendation-level serialization prevents a receipt allocation from
  -- racing an owner reconciliation for the same recommendation.
  perform pg_advisory_xact_lock(
    hashtextextended(
      'forecast-recommendation:' || p_recommendation_id::text,
      0
    )
  );
  perform pg_advisory_xact_lock(
    hashtextextended(
      'forecast-receipt-allocation:' || p_transaction_history_id::text,
      0
    )
  );

  -- A retry can still succeed after product/receipt retention changes because
  -- the immutable allocation already contains the original receipt snapshot.
  select allocation.* into v_existing
  from public.forecast_recommendation_receipt_allocations allocation
  where allocation.recommendation_id = p_recommendation_id
    and allocation.transaction_history_id_snapshot = p_transaction_history_id;
  if found then
    if v_existing.allocated_inventory_quantity is distinct from
        p_allocated_inventory_quantity then
      raise exception 'receipt_allocation_conflict';
    end if;
    return jsonb_build_object('allocation_id', v_existing.id, 'reused', true);
  end if;

  if exists (
    select 1
    from public.forecast_recommendation_reconciliations reconciliation
    where reconciliation.recommendation_id = p_recommendation_id
  ) then
    raise exception 'recommendation_is_already_reconciled';
  end if;

  select history.* into v_receipt
  from public.transaction_history history
  where history.id = p_transaction_history_id
  for update;
  if not found
      or v_receipt.location_id is distinct from
        v_recommendation.location_id_snapshot
      or v_receipt.product_id is distinct from
        v_recommendation.product_id_snapshot
      or v_receipt.transaction_type is distinct from 'stock_in'
      or v_receipt.quantity_change is null
      or v_receipt.quantity_change <= 0
      or v_receipt.quantity_change::text
        in ('NaN', 'Infinity', '-Infinity')
      or v_receipt.created_at < v_recommendation.created_at then
    raise exception 'receipt_is_not_an_eligible_later_restock';
  end if;

  -- transaction_history has no unit field. Prefer the approved request's
  -- immutable unit snapshot. Otherwise require the current product unit.
  select approval.unit into v_receipt_unit
  from public.approval_requests approval
  where approval.transaction_id = v_receipt.id
    and approval.request_type = 'restock'
    and approval.status = 'approved'
    and length(btrim(coalesce(approval.unit, ''))) > 0
  order by approval.reviewed_at desc nulls last, approval.id
  limit 1;
  if found then
    v_unit_evidence := 'approved_restock_request_snapshot';
  else
    select product.unit into v_receipt_unit
    from public.products product
    where product.id = v_receipt.product_id
      and product.location_id = v_receipt.location_id
      and length(btrim(coalesce(product.unit, ''))) > 0;
    if not found then
      raise exception 'receipt_inventory_unit_cannot_be_verified';
    end if;
    v_unit_evidence := 'current_product_canonical_unit';
  end if;

  if lower(btrim(v_receipt_unit)) <>
      lower(btrim(v_recommendation.inventory_unit_snapshot)) then
    raise exception 'receipt_inventory_unit_mismatch';
  end if;

  -- No pack conversion occurs here: both quantity_change and allocations are
  -- canonical inventory quantities. Supplier/order-unit conversion belongs to
  -- the existing restock input/write path, before the receipt is recorded.
  select coalesce(sum(allocation.allocated_inventory_quantity), 0)
    into v_already_allocated
  from public.forecast_recommendation_receipt_allocations allocation
  where allocation.transaction_history_id_snapshot = p_transaction_history_id;
  if v_already_allocated + p_allocated_inventory_quantity >
      v_receipt.quantity_change then
    raise exception 'receipt_allocation_exceeds_received_quantity';
  end if;

  insert into public.forecast_recommendation_receipt_allocations (
    recommendation_id,
    transaction_history_id_snapshot,
    receipt_created_at_snapshot,
    receipt_quantity_snapshot,
    allocated_inventory_quantity,
    receipt_product_id_snapshot,
    receipt_location_id_snapshot,
    receipt_inventory_unit_snapshot,
    receipt_unit_evidence,
    receipt_operation_id_snapshot,
    receipt_operation_scope_snapshot,
    matched_by_profile_id_snapshot,
    matched_by_name_snapshot
  ) values (
    v_recommendation.id,
    v_receipt.id,
    v_receipt.created_at,
    v_receipt.quantity_change,
    p_allocated_inventory_quantity,
    v_receipt.product_id,
    v_receipt.location_id,
    v_recommendation.inventory_unit_snapshot,
    v_unit_evidence,
    v_receipt.operation_id,
    v_receipt.operation_scope,
    v_profile.profile_id,
    v_profile.profile_name
  ) returning * into v_allocation;

  return jsonb_build_object('allocation_id', v_allocation.id, 'reused', false);
end;
$$;

revoke all on function public.match_forecast_recommendation_receipt_v1(
  text, bigint, uuid, numeric
) from public, anon, authenticated;
grant execute on function public.match_forecast_recommendation_receipt_v1(
  text, bigint, uuid, numeric
) to service_role, postgres;

create or replace function public.reconcile_forecast_recommendation_v1(
  p_session_token text,
  p_request_id uuid,
  p_recommendation_id bigint,
  p_confirm_no_receipts boolean,
  p_confirmation_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_profile record;
  v_recommendation public.forecast_recommendation_snapshots%rowtype;
  v_existing public.forecast_recommendation_reconciliations%rowtype;
  v_reconciliation public.forecast_recommendation_reconciliations%rowtype;
  v_quantity numeric;
  v_count bigint;
  v_first timestamptz;
  v_last timestamptz;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Recommendation session is invalid or expired';
  end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may reconcile recommendations';
  end if;
  if p_request_id is null
      or p_recommendation_id is null
      or p_confirm_no_receipts is null then
    raise exception 'recommendation_reconciliation_invalid';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'forecast-recommendation-reconcile:' || v_profile.location_id::text ||
        ':' || p_request_id::text,
      0
    )
  );

  select reconciliation.* into v_existing
  from public.forecast_recommendation_reconciliations reconciliation
  where reconciliation.location_id_snapshot = v_profile.location_id
    and reconciliation.request_id = p_request_id;
  if found then
    if v_existing.recommendation_id is distinct from p_recommendation_id
        or v_existing.confirmed_no_receipts is distinct from
          p_confirm_no_receipts
        or v_existing.confirmation_note is distinct from
          nullif(btrim(coalesce(p_confirmation_note, '')), '') then
      raise exception 'recommendation_reconciliation_request_conflict';
    end if;
    return jsonb_build_object(
      'reconciliation_id', v_existing.id,
      'reused', true
    );
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'forecast-recommendation:' || p_recommendation_id::text,
      0
    )
  );
  select snapshot.* into v_recommendation
  from public.forecast_recommendation_snapshots snapshot
  where snapshot.id = p_recommendation_id
    and snapshot.location_id_snapshot = v_profile.location_id;
  if not found then
    raise exception 'Recommendation not found or outside the active location';
  end if;
  if exists (
    select 1
    from public.forecast_recommendation_reconciliations reconciliation
    where reconciliation.recommendation_id = p_recommendation_id
  ) then
    raise exception 'recommendation_is_already_reconciled';
  end if;

  select
    coalesce(sum(allocation.allocated_inventory_quantity), 0),
    count(*),
    min(allocation.receipt_created_at_snapshot),
    max(allocation.receipt_created_at_snapshot)
  into v_quantity, v_count, v_first, v_last
  from public.forecast_recommendation_receipt_allocations allocation
  where allocation.recommendation_id = p_recommendation_id;

  if v_count = 0 and not p_confirm_no_receipts then
    raise exception 'no_receipts_require_explicit_zero_receipt_confirmation';
  end if;
  if v_count > 0 and p_confirm_no_receipts then
    raise exception 'confirmed_no_receipts_conflicts_with_allocations';
  end if;

  insert into public.forecast_recommendation_reconciliations (
    recommendation_id,
    request_id,
    location_id_snapshot,
    confirmed_by_profile_id_snapshot,
    confirmed_by_name_snapshot,
    confirmed_no_receipts,
    matched_received_quantity_at_confirmation,
    receipt_count_at_confirmation,
    first_receipt_date_at_confirmation,
    last_receipt_date_at_confirmation,
    confirmation_note
  ) values (
    p_recommendation_id,
    p_request_id,
    v_profile.location_id,
    v_profile.profile_id,
    v_profile.profile_name,
    p_confirm_no_receipts,
    v_quantity,
    v_count,
    v_first,
    v_last,
    nullif(btrim(coalesce(p_confirmation_note, '')), '')
  ) returning * into v_reconciliation;

  return jsonb_build_object(
    'reconciliation_id', v_reconciliation.id,
    'reused', false
  );
end;
$$;

revoke all on function public.reconcile_forecast_recommendation_v1(
  text, uuid, bigint, boolean, text
) from public, anon, authenticated;
grant execute on function public.reconcile_forecast_recommendation_v1(
  text, uuid, bigint, boolean, text
) to service_role, postgres;

create or replace function public.forecast_recommendation_tracking_v1(
  p_session_token text,
  p_product_id uuid default null
)
returns table (
  recommendation_id bigint,
  product_id_snapshot uuid,
  product_name_snapshot text,
  product_sku_snapshot text,
  inventory_unit text,
  recommendation_date timestamptz,
  forecast_period_start date,
  forecast_period_end date,
  predicted_demand numeric,
  available_inventory numeric,
  suggested_quantity numeric,
  evaluation_status text,
  matched_received_quantity numeric,
  signed_quantity_difference numeric,
  absolute_difference numeric,
  percentage_variance numeric,
  first_receipt_date timestamptz,
  last_receipt_date timestamptz,
  receipt_count bigint,
  reconciled_at timestamptz
)
language plpgsql
security definer
stable
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_profile record;
begin
  select * into v_profile
  from private.require_app_session_v1(p_session_token);
  if not found then
    raise exception 'Recommendation session is invalid or expired';
  end if;
  if v_profile.role <> 'admin' then
    raise exception 'Only Admin accounts may view recommendation tracking';
  end if;

  return query
  select
    snapshot.id,
    snapshot.product_id_snapshot,
    snapshot.product_name_snapshot,
    snapshot.product_sku_snapshot,
    snapshot.inventory_unit_snapshot,
    snapshot.created_at,
    snapshot.forecast_period_start,
    snapshot.forecast_period_end,
    snapshot.predicted_demand,
    snapshot.available_inventory,
    snapshot.recommended_restock_quantity,
    case
      when reconciliation.id is not null then 'reconciled'
      when allocation.receipt_count > 0 then 'partially_received'
      else 'pending'
    end,
    case
      when reconciliation.id is not null then
        reconciliation.matched_received_quantity_at_confirmation
      when allocation.receipt_count > 0 then allocation.matched_quantity
      else null
    end,
    case
      when reconciliation.id is not null then
        reconciliation.matched_received_quantity_at_confirmation -
          snapshot.recommended_restock_quantity
      when allocation.receipt_count > 0 then
        allocation.matched_quantity - snapshot.recommended_restock_quantity
      else null
    end,
    case
      when reconciliation.id is not null then abs(
        reconciliation.matched_received_quantity_at_confirmation -
          snapshot.recommended_restock_quantity
      )
      when allocation.receipt_count > 0 then abs(
        allocation.matched_quantity - snapshot.recommended_restock_quantity
      )
      else null
    end,
    case
      when snapshot.recommended_restock_quantity > 0
          and reconciliation.id is not null then
        (
          reconciliation.matched_received_quantity_at_confirmation -
            snapshot.recommended_restock_quantity
        ) / snapshot.recommended_restock_quantity * 100
      when snapshot.recommended_restock_quantity > 0
          and allocation.receipt_count > 0 then
        (
          allocation.matched_quantity -
            snapshot.recommended_restock_quantity
        ) / snapshot.recommended_restock_quantity * 100
      else null
    end,
    case
      when reconciliation.id is not null then
        reconciliation.first_receipt_date_at_confirmation
      else allocation.first_receipt_date
    end,
    case
      when reconciliation.id is not null then
        reconciliation.last_receipt_date_at_confirmation
      else allocation.last_receipt_date
    end,
    case
      when reconciliation.id is not null then
        reconciliation.receipt_count_at_confirmation
      else coalesce(allocation.receipt_count, 0)
    end,
    reconciliation.confirmed_at
  from public.forecast_recommendation_snapshots snapshot
  left join lateral (
    select
      sum(receipt.allocated_inventory_quantity) as matched_quantity,
      count(*) as receipt_count,
      min(receipt.receipt_created_at_snapshot) as first_receipt_date,
      max(receipt.receipt_created_at_snapshot) as last_receipt_date
    from public.forecast_recommendation_receipt_allocations receipt
    where receipt.recommendation_id = snapshot.id
  ) allocation on true
  left join public.forecast_recommendation_reconciliations reconciliation
    on reconciliation.recommendation_id = snapshot.id
  where snapshot.location_id_snapshot = v_profile.location_id
    and (p_product_id is null or snapshot.product_id_snapshot = p_product_id)
  order by snapshot.created_at desc, snapshot.id desc;
end;
$$;

revoke all on function public.forecast_recommendation_tracking_v1(text, uuid)
  from public, anon, authenticated;
grant execute on function public.forecast_recommendation_tracking_v1(text, uuid)
  to service_role, postgres;

comment on table public.forecast_recommendation_snapshots is
  'Immutable owner-saved demand-minus-stock recommendation snapshots; no external FKs so product deletion does not erase or block history.';
comment on table public.forecast_recommendation_receipt_allocations is
  'Explicit immutable allocations of genuine stock_in receipt snapshots to earlier recommendations; not backorders or forecast accuracy.';
comment on table public.forecast_recommendation_reconciliations is
  'Explicit owner confirmation that a recommendation-to-receipt comparison is complete.';

comment on function private.reject_forecast_recommendation_mutation_v1() is
  'Inventory Plus Stage 2.9C recommendation tracking.';
comment on function public.forecast_recommendation_snapshot_by_request_v1(
  text, uuid
) is 'Inventory Plus Stage 2.9C recommendation tracking.';
comment on function public.save_forecast_recommendation_snapshot_v1(
  text, uuid, uuid, text, text, integer, boolean, timestamptz, timestamptz,
  integer, date, date, numeric, numeric, text, jsonb
) is 'Inventory Plus Stage 2.9C recommendation tracking.';
comment on function public.match_forecast_recommendation_receipt_v1(
  text, bigint, uuid, numeric
) is 'Inventory Plus Stage 2.9C recommendation tracking.';
comment on function public.reconcile_forecast_recommendation_v1(
  text, uuid, bigint, boolean, text
) is 'Inventory Plus Stage 2.9C recommendation tracking.';
comment on function public.forecast_recommendation_tracking_v1(
  text, uuid
) is 'Inventory Plus Stage 2.9C recommendation tracking.';

do $verify$
declare
  v_count integer;
  v_baseline record;
begin
  if not exists (
    select 1
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'forecast_recommendation_snapshots'
      and c.relkind = 'r' and c.relrowsecurity
  ) or not exists (
    select 1
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'forecast_recommendation_receipt_allocations'
      and c.relkind = 'r' and c.relrowsecurity
  ) or not exists (
    select 1
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'forecast_recommendation_reconciliations'
      and c.relkind = 'r' and c.relrowsecurity
  ) then
    raise exception 'Stage 2.9C verification failed: tables or RLS missing.';
  end if;

  select count(*) into v_count
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and t.tgname in (
      'forecast_recommendation_snapshots_immutable_v1',
      'forecast_recommendation_receipts_immutable_v1',
      'forecast_recommendation_reconciliations_immutable_v1'
    )
    and not t.tgisinternal
    and t.tgenabled in ('O', 'A');
  if v_count <> 3 then
    raise exception
      'Stage 2.9C verification failed: expected 3 enabled immutable triggers, found %.',
      v_count;
  end if;

  select count(*) into v_count
  from (values
    ('public.forecast_recommendation_snapshot_by_request_v1(text,uuid)'),
    ('public.save_forecast_recommendation_snapshot_v1(text,uuid,uuid,text,text,integer,boolean,timestamptz,timestamptz,integer,date,date,numeric,numeric,text,jsonb)'),
    ('public.match_forecast_recommendation_receipt_v1(text,bigint,uuid,numeric)'),
    ('public.reconcile_forecast_recommendation_v1(text,uuid,bigint,boolean,text)'),
    ('public.forecast_recommendation_tracking_v1(text,uuid)')
  ) expected(signature)
  where to_regprocedure(expected.signature) is not null
    and has_function_privilege(
      'service_role', to_regprocedure(expected.signature), 'EXECUTE')
    and not has_function_privilege(
      'anon', to_regprocedure(expected.signature), 'EXECUTE')
    and not has_function_privilege(
      'authenticated', to_regprocedure(expected.signature), 'EXECUTE');
  if v_count <> 5 then
    raise exception
      'Stage 2.9C verification failed: RPC signatures or grants are incorrect.';
  end if;

  select count(*) into v_count
  from pg_constraint
  where conrelid in (
    'public.forecast_recommendation_receipt_allocations'::regclass,
    'public.forecast_recommendation_reconciliations'::regclass
  )
    and contype = 'f'
    and confrelid =
      'public.forecast_recommendation_snapshots'::regclass;
  if v_count <> 2 then
    raise exception
      'Stage 2.9C verification failed: internal foreign keys are incorrect.';
  end if;

  select count(*) into v_count
  from pg_constraint
  where conrelid in (
    'public.forecast_recommendation_snapshots'::regclass,
    'public.forecast_recommendation_receipt_allocations'::regclass,
    'public.forecast_recommendation_reconciliations'::regclass
  )
    and contype = 'f'
    and confrelid <>
      'public.forecast_recommendation_snapshots'::regclass;
  if v_count <> 0 then
    raise exception
      'Stage 2.9C verification failed: unexpected external foreign key.';
  end if;

  if has_table_privilege(
      'service_role', 'public.forecast_recommendation_snapshots', 'SELECT')
      or has_table_privilege(
        'service_role', 'public.forecast_recommendation_receipt_allocations',
        'SELECT')
      or has_table_privilege(
        'service_role', 'public.forecast_recommendation_reconciliations',
        'SELECT')
      or has_table_privilege(
        'anon', 'public.forecast_recommendation_snapshots', 'SELECT')
      or has_table_privilege(
        'authenticated', 'public.forecast_recommendation_snapshots', 'SELECT')
  then
    raise exception
      'Stage 2.9C verification failed: direct table access was granted.';
  end if;

  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'forecast_recommendation_snapshots_product_created_idx'
  ) or not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'forecast_recommendation_receipts_recommendation_idx'
  ) or not exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and indexname = 'forecast_recommendation_receipts_transaction_idx'
  ) then
    raise exception 'Stage 2.9C verification failed: indexes missing.';
  end if;

  if exists (select 1 from public.forecast_recommendation_snapshots)
      or exists (
        select 1 from public.forecast_recommendation_receipt_allocations)
      or exists (select 1 from public.forecast_recommendation_reconciliations)
  then
    raise exception
      'Stage 2.9C verification failed: new tracking tables are not empty.';
  end if;

  select * into v_baseline from _stage29c_existing_data_baseline;
  if v_baseline.products_count <>
        (select count(*) from public.products)
      or v_baseline.transactions_count <>
        (select count(*) from public.transaction_history)
      or v_baseline.locations_count <>
        (select count(*) from public.locations)
      or v_baseline.profiles_count <>
        (select count(*) from public.profiles) then
    raise exception
      'Stage 2.9C verification failed: existing operational row counts changed.';
  end if;
end;
$verify$;

rollback;
