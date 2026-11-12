# Stage 6B.6 Flutter database-access audit

Status date: 2026-11-05 (Asia/Manila)

Scope: every Flutter `from`, storage `from`, `rpc`, and Realtime `channel`
call under `lib/`. No `.stream()` table query is present. This is a source audit,
not proof of deployed database behavior.

## Identity and authorization boundary

Inventory Plus authenticates with a custom opaque token held in
`private.app_sessions`. The Flutter Supabase client still connects as the
Supabase `anon` database role. The opaque token is an RPC argument; it is not a
Supabase Auth JWT and does not populate `auth.uid()`.

Consequences:

- Client filters such as `.eq('location_id', activeLocationId)` are not access
  control. An altered client can remove them.
- RLS policies based on `auth.uid()` cannot identify the Inventory Plus user.
- A safe direct operation must be replaced by a `SECURITY DEFINER` function
  that calls `private.require_app_session_v1`, derives profile and location on
  the server, enforces the application role, and exposes only required fields.
- Postgres Changes subscriptions authenticate only as `anon`. Channel names and
  client-side filters do not make them session-authorized.

## Direct table and storage dependency matrix

`Implemented locally` means an additive RPC and a gated Flutter replacement
exist, but have not been applied or behaviorally verified in Supabase. The
gate `INVENTORY_PLUS_SECURE_ACCESS_V1` defaults off so an undeployed RPC cannot
break the current application. It may be enabled only in an isolated build
after the additive migration is installed.

| Domain / call site | Direct resource and operation | Current consumers / role | Current location or authorization | Required replacement | Status |
|---|---|---|---|---|---|
| Password recovery (`auth_service.dart`) | Formerly `profiles` SELECT email/role/id and UPDATE password | Logged-out user | Insecure client path removed | Server-side, rate-limited recovery challenge with one-time, expiring token and non-enumerating responses; password update only after challenge verification | Fail-closed locally; working self-service remains blocked on a verified delivery provider |
| Inventory snapshot (`inventory_controller.dart`) | `products` SELECT | Admin, Cashier/staff, Helper | Client-supplied active location | `inventory_snapshot_v1(token)` | Implemented locally |
| Operational order snapshot | `orders` SELECT | Admin monitors, Cashier POS, Helper queue, dashboard | Client location and time filters | `operational_orders_snapshot_v1(token, boundaries)`; Helper receives only eligible pending orders | Implemented locally |
| Current profile snapshot | `profiles` SELECT safe fields | All signed-in roles | Client user/location filters | `current_profile_snapshot_v1(token)` | Implemented locally |
| Staff configuration snapshot | `profiles` SELECT `*` | Admin settings / assignment dialogs | Client role check and location filter; password hash was included | `staff_configuration_snapshot_v1(token)`; Admin-only and password omitted | Implemented locally |
| Staff create/update/detail/delete | `profiles` INSERT/UPDATE/SELECT/DELETE | Admin | UI role checks; delete/update ID supplied by client | Admin-only `staff_create_v1`, `staff_update_role_v1`, `staff_profile_v1`, `staff_delete_v1`; target must share server-derived location; hash password server-side | Implemented locally |
| User profile update | `profiles` UPDATE | Signed-in user | Client supplies user ID | `current_profile_update_v1`; always update session profile only | Implemented locally |
| Product update/disable/restore/delete | `products` UPDATE/DELETE | Admin inventory management | UI checks and product ID only | Admin-only product mutation RPCs; target location equality; delete checks open orders atomically | Implemented locally behind product-access gate |
| Product shelf/bin and map assignment | `products` UPDATE | Admin | Client product and location assumptions | Admin-only location-detail/map-assignment RPCs | Implemented locally behind product-access gate |
| Open-order product check | `orders` SELECT items | Admin before product removal | No server authorization | Moved inside product-disable/delete RPC transaction | Implemented locally behind product-access gate |
| Inventory adjustment journal fallback | `transaction_history` INSERT | Inventory controller | Client builds actor/location fields | Remove fallback after `adjust_inventory_quantity_v1` is mandatory; journal stays in transactional RPC | Required |
| Inventory baselines and product history | `transaction_history` SELECT, joined product/profile reads | Inventory detail / analytics | Client product/location filters | Session-scoped product-history and analytics RPCs with role-dependent staff identity fields | Required |
| Legacy transaction/order history | `transaction_history`, `order_history`, `profiles` SELECT; transaction DELETE | Older controller methods | Client location and role checks | Use existing `history_page_v1`, `history_order_detail_v1`, `history_export_sales_v1`; remove/disable destructive clear-history UI unless an explicit audited Admin retention RPC is approved | Required; pagination path already uses secure RPCs |
| Legacy forecasting controller | `transaction_history` SELECT | No current Forecasting page call found; obsolete Stage 4-style controller | Product filter only, no location | Remove after call-site verification; Stage 5D API + `forecast_daily_demand_v1` is canonical | Required cleanup; production API product lookup now has an additive session-scoped RPC |
| Threshold settings | `threshold` SELECT/UPSERT | All read; Admin write | Global table, permissive anon policy | `runtime_settings_snapshot_v1`; Admin-only threshold mutation RPC | Required |
| Measurements | `measurements` SELECT/INSERT/UPDATE/DELETE | Admin configuration; inventory presentation | Global table, permissive anon policy | Session read RPC and Admin-only mutation RPCs | Required |
| Payment settings | `store_settings` SELECT | Admin/Cashier | Client location filter | Session-scoped settings snapshot; writes already use `update_store_payment_settings_v1` and `update_cashier_discount_limit_v1` | Read replacement required |
| GCash asset lifecycle | Storage buckets `store_assets` upload/remove/public URL | Admin settings | Storage policy, path convention, and UI role | Signed upload/delete RPC or backend storage endpoint; verify object ownership and location prefix before delete | Required; public URL can remain only if QR image is intentionally public |
| Product image lifecycle | Storage bucket `product_images` upload/public URL | Admin inventory | Storage policy and UI role | Signed upload policy or backend endpoint with location-owned path; write image URL through product RPC | Required |
| Map snapshot | `locations.layout_data` SELECT | All roles viewing map | Client location filter | `map_snapshot_v1(token)`; existing `save_store_map_v1` remains Admin write path | Required |
| Notifications list | `notifications` and `notification_reads` SELECT | All signed-in roles | Client location, target role, and user filters | `notifications_snapshot_v1(token)` derives role/location/user | Required |
| Notification read/delete state | `notification_reads` UPSERT/UPDATE | Current user | Client supplies user ID | `notification_read_state_v1` mutations derive user from token | Required |
| Notification lifecycle updates | `notifications` INSERT/UPDATE | Domain repository | Some paths use secure lifecycle RPCs; legacy paths remain direct | Route all creation/transitions through `upsert_notification_lifecycle_v1` and `transition_stock_notification_v1`; add explicit resolve RPCs | Required |
| Stock notification state | `stock_notification_states` SELECT/UPSERT | Notification domain | Client location | Session/location-scoped snapshot and transition RPC; preferably fold into existing stock transition transaction | Required |
| Presence heartbeat / logout | `staff_presence` UPSERT | All signed-in roles | Client supplies all identity and location fields | `staff_presence_heartbeat_v1(token, module, online)` derives identity/location | Required |
| Active-staff list | `staff_presence` SELECT | Active-staff UI / auto-assignment | Client location and cutoff | `staff_presence_snapshot_v1(token, cutoff)`; redact data by role | Required |
| Staff session audit | `staff_session_logs` INSERT | Login/logout lifecycle | Client supplies actor, role, location | Server-side login/logout hooks or `staff_session_event_v1(token, reason)`; blocked-login events need a non-session, rate-limited auth function | Required |
| Store access settings | `store_access_settings` SELECT/UPSERT | Login gating, MainScreen, Admin settings | Logged-out reads are anonymous; writes UI-guarded | Public pre-login endpoint must accept a non-secret store key and return only access hours; signed-in snapshot derives location; Admin-only update RPC | Required; default-row creation must be server-only |
| Export reminder log | `export_log` SELECT/UPSERT/DELETE | Inventory/history report UIs | Client location only | Session-scoped export-status/write RPC; delete limited to current location and Admin if retained | Required |

## Existing RPC matrix

The following Flutter operations already use RPCs. Local definitions were
checked for a `private.require_app_session_v1` boundary except the deliberately
unauthenticated login/restore entry points, which validate token hashes or
credentials internally. Deployment parity still requires isolated testing.

| RPC family | Operations | Intended application permission |
|---|---|---|
| Session | `profile_login_v1`, `profile_restore_session_v1`, `profile_logout_v1`, `profile_verify_password_v1`, `profile_change_password_v1`, `profile_admin_reset_password_v1` | Login/restore are public entry points; remaining operations require the current session; reset is Admin-only |
| Inventory | `create_product_v1`, `adjust_inventory_quantity_v1` | Admin create; role rules and approval semantics enforced in function |
| Approval | `create_inventory_approval_request_v2`, `approval_requests_page_v1`, approve/reject functions, discount approval functions | Requester/Admin separation and session-derived location |
| Orders/POS | `create_customer_order_v2`, `cancel_customer_order_v1`, `prepare_customer_order_v1`, `auto_assign_pending_orders_v1`, `assign_order_helper_v1`, `complete_customer_order_v1` | Role and location-specific business transitions |
| History/reporting | `history_page_v1`, `history_order_detail_v1`, `history_export_sales_v1`, `staff_performance_v1` | Session-derived location with role-dependent scope |
| Map/settings | `save_store_map_v1`, `update_store_payment_settings_v1`, `update_cashier_discount_limit_v1` | Admin-only writes |
| Notifications | `upsert_notification_lifecycle_v1`, `transition_stock_notification_v1` | Session-derived location and notification-domain transitions |
| Forecasting | Backend calls `forecast_daily_demand_v1`; Flutter calls the authenticated Python API rather than Supabase directly | Admin and server-validated location |
| Stage 6B.6 additive reads | `inventory_snapshot_v1`, `operational_orders_snapshot_v1`, `current_profile_snapshot_v1`, `staff_configuration_snapshot_v1` | Signed-in session; staff snapshot Admin-only; Helper order scope restricted |

## Realtime dependency matrix

All channels are owned by `RealtimeSyncService`, which is architecturally
correct for transport ownership. The authorization transport is not yet safe.

| Channel domain | Table / filter | Consumer behavior | Security finding / replacement |
|---|---|---|---|
| Orders | `orders.location_id` | Invalidates canonical order snapshot | Client filter only. Replace with authenticated backend event stream, then refetch via `operational_orders_snapshot_v1`. |
| Inventory | `products.location_id` | Invalidates canonical inventory snapshot | Same; refetch via `inventory_snapshot_v1`. |
| Order history | `order_history_realtime_signals.location_id` | Invalidates paginated history | Signal row still leaks location activity to anon. Backend event stream or Supabase Auth/custom-JWT RLS required. |
| Approval requests | `approval_request_realtime_signals.location_id` | Invalidates approval pages | Same signal-table issue. |
| Notifications | `notifications.location_id`, `notification_reads.user_id` | Refetches notification domain | Exposes business activity/read-state metadata; backend event stream required. |
| Staff presence | `staff_presence.location_id` | Refetches active staff | Presence is sensitive; backend stream required while heartbeat remains time-based. |
| Transaction history | `transaction_history.location_id` | Invalidates history/dashboard/forecasting | Backend invalidation event only; client then invokes authorized RPC/API. |
| Map | `locations.id` | Safe-boundary canonical reload | Backend invalidation; preserve dirty-draft protection. |
| Store access | `store_access_settings.location_id` | Refreshes access schedule | Backend invalidation or signed-in polling at safe boundaries; login preflight remains a separate minimal endpoint. |
| Runtime settings | `threshold.id`, all `measurements`, `store_settings.location_id` | Refetches domain settings | Global table events leak activity; backend invalidation. |
| Staff configuration/current user | `profiles.location_id`, `profiles.id` | Refetches Admin staff/current profile | Profiles must never remain Realtime-readable by anon. Backend stream is mandatory. |

Recommended path while retaining opaque sessions: one authenticated backend
WebSocket/SSE connection per app session. The backend validates the opaque
token, binds the connection to server-derived user/role/location, subscribes
with server-held credentials, emits domain invalidations only, and never sends
service-role credentials to Flutter. `RealtimeSyncService` remains the Flutter
transport coordinator, but its source changes from direct Postgres Changes to
that authenticated stream. A Supabase Auth/custom-JWT migration is an
alternative, larger identity-system change and is not assumed here.

## Unsafe grants observed in the checked-in declarative schema

The local schema grants broad `anon` access to `profiles`, `products`,
`transaction_history`, `notifications`, `notification_reads`, `staff_presence`,
`staff_session_logs`, `stock_notification_states`, `locations`,
`store_access_settings`, `export_log`, `measurements`, and `threshold`.
`orders` grants anonymous SELECT plus mutation privileges other than INSERT.
Several RLS policies are `USING (true)` and therefore do not create application
authorization. These are target-state findings, not a statement that the
Stage 6B.6 migration has changed the deployed project.

## Migration order and rollback

1. Create and mark an isolated project using the existing Stage 6B harness.
2. Apply schema and additive secure RPCs only. Verify signature, grants,
   search paths, role denial, cross-location denial, and expired sessions.
3. Deploy Flutter builds that use the additive RPCs. Keep old grants during
   compatibility testing; monitor RPC errors without logging tokens.
4. Deploy authenticated backend event transport and switch
   `RealtimeSyncService`. Verify reconnect/refetch and role/location isolation.
5. Migrate remaining direct CRUD/storage paths domain by domain. A domain is
   complete only when source search and behavior tests show no direct access.
6. In the isolated project, set both readiness flags and apply
   `stage_6b5_security_target_state_isolated.sql` to revoke table access.
7. Run the full allowed/denied workflow matrix and Flutter regressions.
8. Only after approval, repeat the additive-first sequence in production.

Rollback is forward-compatible: restore the prior application build and table
grants from a reviewed privilege snapshot; do not drop the additive RPCs during
an incident. Revoke execute on a faulty new RPC if necessary. Database rollback
must not restore anonymous access to `profiles.password`; use the previously
captured exact grant/policy manifest, not blanket grants.

## Current blockers

- No isolated Supabase project identity/marker has been supplied, so none of
  the new functions or restrictive grants have been executed.
- Direct Postgres Changes cannot enforce opaque-session identity.
- Logged-out password recovery needs a server-side challenge delivery and
  verification service.
- Storage upload/delete authorization needs isolated bucket-policy tests.
- Five malformed completed-order snapshots remain preserved and unresolved;
  forecasting must fail closed for affected intervals.
- Canonical supplier, purchase-order, safety-stock, and availability-history
  sources remain undefined.

