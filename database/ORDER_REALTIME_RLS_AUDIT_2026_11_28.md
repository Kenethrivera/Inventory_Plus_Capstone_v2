# Order, stock ledger, and Realtime/RLS audit — 28 November 2026

## Scope and evidence

This is a read-only audit of the checked-in Flutter code and SQL definitions. No production data or policies were changed. The Supabase MCP connection used earlier in this conversation is unavailable, but I accessed the live Inventory Plus production SQL Editor for a read-only catalog query. The visible live results are recorded below. Earlier live checks in this conversation also found RLS enabled with no policies on `transaction_history`; `store_access_settings` had a SELECT policy. Those two states were **not reverified** in the current query. The checked-in schema export and migration files are not proof of current production state.

### Live production catalog result

The current SQL Editor result showed RLS **enabled**, an anon SELECT table grant **present**, and **zero RLS policies** for `locations`, `notification_reads`, `notifications`, `profiles`, `staff_presence`, and `staff_session_logs`. The table grant cannot make rows visible when RLS has no applicable policy. `order_history` had RLS on, no anon SELECT grant, and zero policies. `orders` had RLS on, anon SELECT grant, and two policies; `products` had RLS on, anon SELECT grant, and one policy. `order_history_realtime_signals` and `approval_request_realtime_signals` each had RLS on, anon SELECT grant, and one policy. The live query returned 15 rows, but the browser grid only exposed the first 11 before concurrent user input interrupted further inspection. Policy *definitions*, publication membership, trigger status, and order/history row counts still need a current live check.

The repository's `database/stage_6b5_security_target_state_isolated.sql` explicitly says **isolated testing only** and warns that direct client reads and Realtime transport must be migrated first. It must not be applied to production as a repair.

## Where an order is recorded

| Data | Table | Write path | Read path |
| --- | --- | --- | --- |
| Current order, line items, assignment, status, payment and actors | `public.orders` | `create_customer_order_v2` inserts a row; preparation, completion, and cancellation update it | Orders and Payments tabs use `loadActivityOrders()`; operational order views also use a scoped snapshot RPC |
| One current historical snapshot per order | `public.order_history` | `orders_sync_order_history_v1` trigger invokes `sync_order_history_v1()` after every order insert/update | `history_page_v1` Sales History branches |
| One stock movement per affected product | `public.transaction_history` | Checkout inserts a negative `checkout` row per product; cancellation inserts a positive `order_cancelled` row; restocks, write-offs, and adjustments also write rows | Stock movements, product stock history, Activity History, and sales/forecast calculations |

Payment completion changes `orders.status` and payment fields; it does not insert another stock movement. Inventory is decremented when the checkout order is created, before payment completion. A `checkout` movement therefore does **not** by itself prove that payment was collected. `transaction_history` is actively used, but it is a **stock ledger**, not the order ledger. There is no separate `payments` table in the checked-in public schema. The order's payment details are stored on `orders` and mirrored to `order_history`.

The checkout ledger rows use `transaction_history.operation_id = orders.checkout_operation_id`; there is no foreign key between the two tables. `order_history.order_id` is text and is maintained by a trigger, not by an order foreign key. Truncating either table can therefore leave the other logically incomplete. `transaction_history.product_id` has `ON DELETE CASCADE`, so physical product deletion can erase its movements.

Sources: `supabase/schemas/public/functions/create_customer_order_v2.sql:141-194`, `supabase/schemas/public/functions/complete_customer_order_v1.sql:87-105`, `supabase/schemas/public/functions/cancel_customer_order_v1.sql:53-84`, `supabase/schemas/public/tables/orders.sql:83-86`, `supabase/schemas/public/functions/sync_order_history_v1.sql:17-73`, `supabase/schemas/public/tables/transaction_history.sql:1-23`, `lib/logic/inventory_controller.dart:3261,3624,3871-3893`.

## Root cause of stalled Realtime

The app initializes Supabase with its anon key and authenticates users through its own `profile_login_v1` application session. It passes that opaque session token to selected `SECURITY DEFINER` RPCs. Its `RealtimeSyncService`, however, subscribes directly to Postgres Changes on tables as the Supabase anon client. A channel reporting `subscribed` proves a WebSocket subscription, not that the anon role can see rows. Publication membership also does not override RLS or revoked SELECT privileges. Where production RLS has no matching anon SELECT policy, row changes are invisible to these subscriptions even though session RPC reads and writes may succeed.

`supabase/schemas/_cluster/publications.sql` lists `staff_presence`, `notifications`, `notification_reads`, `transaction_history`, `orders`, `products`, `locations`, `profiles`, `store_access_settings`, `store_settings`, `threshold`, and signal tables. `lib/services/realtime/realtime_sync_service.dart:161-888` subscribes to these direct table changes. The root problem is the mismatch between an application session understood by RPCs and a Realtime subscription that has no corresponding database identity/row policy.

| Feature | Current code path | Impact under restrictive RLS | Existing fallback |
| --- | --- | --- | --- |
| Cashier helper/bodegero availability | `staff_presence` Postgres Changes cause `StaffPresenceService.refreshActiveStaff()`; that read uses `staff_presence_list_v1` | Other staff login/logout does not trigger a refresh in cashier; candidates can stay missing or stale | Active Staff page polls every 10 seconds, but cashier does not. Own 45-second heartbeat writes presence; it does not refresh other users. |
| Notification bell/feed | `notifications` and `notification_reads` Postgres Changes | No instant cross-user invalidation | `NotificationController` polls `notification_feed_v1` every 10 seconds; read/archive actions use `notification_user_action_v1`. |
| Notification creation/resolution | Several direct `notifications` and `stock_notification_states` reads/writes remain | New notifications may never be saved, or old ones never resolved; feed polling cannot recover a missing row | Some lifecycle paths use secure RPCs; others do not. |
| Store access hours | Direct `store_access_settings` SELECT and Realtime subscription | If SELECT visibility is lost or the row is missing, the client displays default 08:00–21:00 after a successful save RPC. Earlier live checks found a SELECT policy, so this is a code risk, not a confirmed present RLS failure. | Save uses `update_store_access_settings_v1`; read still needs a scoped RPC. |
| Stock movement refresh | Direct `transaction_history` Realtime subscription | Stock movement/history screens may not invalidate automatically | Product detail and paginated stock movements have session RPC reads; other direct reads/fallbacks remain. |
| Orders, inventory, map, staff config, runtime settings | Direct table subscriptions | If anon SELECT is removed or denied, updates stop reaching other clients | Initial/manual refresh exists in some views; no consistent app-wide fallback. |
| Sales history and approvals | Dedicated `order_history_realtime_signals` and `approval_request_realtime_signals` | Work only if their trigger, publication membership, anon grant, and RLS read policy are all deployed | Checked-in definitions include signal policies, but live state needs verification. |

Sources: `lib/main.dart:41-44`, `lib/login/auth_service.dart:18`, `lib/services/realtime/realtime_sync_service.dart:106-116,384-594,664-888`, `lib/services/staff_presence_service.dart:75-108,259-307`, `lib/ui/staff_page.dart:88-96`, `lib/notifications/notification_controller.dart:103-135`, `lib/notifications/notification_repository.dart:81-312`, `lib/services/store_access_service.dart:203-259`.

## Other concrete code and schema gaps

1. `PaymentTotals.fromOrders()` excludes cancelled/returned orders but counts pending and prepared orders as collected Cash/GCash transactions. The Orders & activity Payments summary passes all loaded orders by default. `analytics_summary_v1` similarly includes uncompleted orders in revenue/order count. These are accounting bugs distinct from RLS (`lib/logic/orders_activity_metrics.dart:16-33`, `lib/ui/orders_activity_page.dart:385-386`, `supabase/schemas/public/functions/analytics_summary_v1.sql:25-41`).
2. The explicit bodegero checkout path calls `create_customer_order_with_bodegero_v1`, but this checkout contains no SQL definition for it. This is a versioning/deployment gap; its live presence was not checked (`lib/logic/inventory_controller.dart:4143-4149`).
3. Dormant `loadOrderHistory()` directly reads the RLS-protected `order_history` table and requests `event_at`, a column absent from that table. Its current UI path uses `history_page_v1`; remove or replace the dormant path before reuse (`lib/logic/inventory_controller.dart:3812,3909-3911`, `supabase/schemas/public/tables/order_history.sql:1-34`).
4. Some direct reads of `transaction_history` remain for approved inventory stock, all-history, rolling sales, and legacy paths. A missing `stock_movements_page_v1` RPC falls back to a direct table read that will also fail under the same RLS. `fetchTransactionHistory()` catches a product-history failure and returns an empty list, which can show “no stock history” when the real cause is an RPC error (`lib/logic/inventory_controller.dart:674,1244,3168-3231,3290,3980-3999,5455`).
5. The checked-in `orders` definition includes an anon `SELECT USING (true)` policy and broad anon table grants. If that is deployed, it permits reading orders outside the application's location filter; if it has been removed in production, direct order reads and direct Realtime updates can fail. This must be resolved with a server-authorized read/event design, not by blindly opening sensitive tables to anon (`supabase/schemas/public/tables/orders.sql:88-108`).

## Repair order

1. **Choose one identity model for the entire client.** Either use Supabase Auth/custom JWT claims with narrowly scoped RLS for Postgres Changes, or keep the opaque app session and replace sensitive direct Postgres Changes with a session-authorized event service. Do not add blanket anon SELECT policies to sensitive tables.
2. **Stabilize presence immediately.** Poll `staff_presence_list_v1` from the shared `StaffPresenceService` on every active signed-in client, including cashier, at a short bounded interval; stop on logout. Keep the expiry logic. This gives cross-user helper availability while a secure event transport is built.
3. **Finish notification RPC migration.** Route remaining create, lookup, update, rearm, resolve, and stock-state operations through session-validating RPCs. Surface write errors instead of showing a successful order notification when its side effect failed. Keep feed polling until secure event delivery is verified.
4. **Replace remaining protected direct reads.** In particular, add a session-scoped store-access read (plus a minimal pre-login schedule read), migrate remaining `transaction_history` reads and fallback paths, and make “not visible/denied” distinct from a genuinely empty result.
5. **Audit every Realtime table against deployed RLS, grants, and publication.** Preserve the two signal-table triggers/policies only as a temporary design if their information leakage is acceptable; otherwise use authorized events. Add a two-client test: staff signs in/out while cashier watches, notification create/read across roles, and order/stock/settings changes across sessions.
6. **Correct accounting and repository drift.** Count completed orders only in collected payments/revenue; version the bodegero RPC in SQL; remove dormant broken history readers. Consider replacing cascading product deletion with soft deletion so stock history remains durable.

`TRUNCATE` removes table rows, not triggers, functions, policies, or publication definitions. It can remove settings, session, order, history, notification, and presence rows, creating empty-state problems. Restrictive RLS and direct anon access are a separate, demonstrated failure pattern. Current production object state needs a fresh read-only catalog check.

## Read-only live Supabase checks to complete

Run these in the Supabase SQL editor with a read-capable administrator session. They do not mutate data:

```sql
select c.relname as table_name, c.relrowsecurity as rls_enabled,
       has_table_privilege('anon', c.oid, 'SELECT') as anon_can_select
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r', 'p')
  and c.relname in ('orders','order_history','transaction_history',
    'staff_presence','staff_session_logs','notifications','notification_reads',
    'stock_notification_states','store_access_settings','products','profiles',
    'locations','store_settings','order_history_realtime_signals',
    'approval_request_realtime_signals')
order by c.relname;

select tablename, policyname, roles, cmd, qual
from pg_policies where schemaname = 'public'
  and tablename in ('orders','order_history','transaction_history',
    'staff_presence','notifications','notification_reads',
    'store_access_settings','products','profiles','locations',
    'order_history_realtime_signals','approval_request_realtime_signals')
order by tablename, policyname;

select tablename from pg_publication_tables
where pubname = 'supabase_realtime' and schemaname = 'public'
order by tablename;

select c.relname as table_name, t.tgname as trigger_name, t.tgenabled
from pg_trigger t join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and not t.tgisinternal
  and c.relname in ('orders','order_history','approval_requests')
order by c.relname, t.tgname;

select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and proname in
  ('create_customer_order_v2','create_customer_order_with_bodegero_v1',
   'complete_customer_order_v1','history_page_v1','stock_movements_page_v1',
   'product_stock_history_v1','staff_presence_list_v1',
   'staff_presence_write_v1','notification_feed_v1',
   'notification_user_action_v1','update_store_access_settings_v1')
order by proname;

select count(*) as orders_missing_history
from public.orders o left join public.order_history h
  on h.order_id = o.id::text
where h.order_id is null;

select count(*) as checkout_movements_missing_order
from public.transaction_history t left join public.orders o
  on o.checkout_operation_id = t.operation_id
 and o.location_id = t.location_id
where t.operation_scope = 'checkout' and t.operation_id is not null
  and o.id is null;
```

If rows are present, compare `orders.id` with `order_history.order_id`, and join checkout movements by `orders.checkout_operation_id = transaction_history.operation_id` to test ledger completeness. Do this read-only before attempting any backfill.
