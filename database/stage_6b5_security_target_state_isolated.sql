-- Stage 6B.5 target-state privilege migration.
--
-- ISOLATED TESTING ONLY. DO NOT APPLY TO PRODUCTION. Existing Flutter code
-- still performs direct anonymous table access for several domains. Apply this
-- candidate only after those call sites have been replaced by session-validating
-- RPCs and realtime has a secure identity/transport design.
--
-- The readiness table is deliberately not created here. An isolated-test
-- operator must create `private.stage6b5_security_readiness` with boolean
-- columns `direct_table_calls_migrated` and `realtime_transport_migrated`, then
-- insert an all-true row only after the replacement RPC/client matrix passes.

begin;

do $guard$
begin
  if to_regclass('private.stage6b_isolated_environment') is null then
    raise exception 'Stage 6B.5 guard: isolated environment marker is absent';
  end if;
  if not exists (
    select 1
    from private.stage6b_isolated_environment
    where marker = 'inventory-plus-stage6b'
      and allow_fixture_writes
  ) then
    raise exception 'Stage 6B.5 guard: isolated execution is not authorized';
  end if;
  if to_regclass('private.stage6b5_security_readiness') is null then
    raise exception
      'Stage 6B.5 guard: client and realtime migrations are incomplete';
  end if;
  if not exists (
    select 1
    from private.stage6b5_security_readiness
    where direct_table_calls_migrated
      and realtime_transport_migrated
  ) then
    raise exception
      'Stage 6B.5 guard: client and realtime migrations are incomplete';
  end if;
end;
$guard$;

alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.transaction_history enable row level security;
alter table public.profiles enable row level security;
alter table public.locations enable row level security;
alter table public.notifications enable row level security;
alter table public.notification_reads enable row level security;
alter table public.staff_presence enable row level security;
alter table public.staff_session_logs enable row level security;
alter table public.stock_notification_states enable row level security;
alter table public.store_access_settings enable row level security;
alter table public.store_map enable row level security;
alter table public.store_settings enable row level security;
alter table public.product_forecasts enable row level security;

revoke all on table
  public.products,
  public.orders,
  public.transaction_history,
  public.profiles,
  public.locations,
  public.notifications,
  public.notification_reads,
  public.staff_presence,
  public.staff_session_logs,
  public.stock_notification_states,
  public.store_access_settings,
  public.store_map,
  public.store_settings,
  public.product_forecasts,
  public.export_log,
  public.measurements,
  public.threshold,
  public.order_history,
  public.approval_requests,
  public.order_history_realtime_signals,
  public.approval_request_realtime_signals
from public, anon, authenticated;

-- No auth.uid()-based allow policies are created. Inventory Plus callers use
-- custom opaque application sessions and reach protected data through vetted
-- SECURITY DEFINER functions that call private.require_app_session_v1.

commit;
