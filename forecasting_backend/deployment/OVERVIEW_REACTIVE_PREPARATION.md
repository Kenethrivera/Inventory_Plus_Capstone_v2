# Overview enrichment and reactive preparation

database/stage_7b_overview_history_coverage.sql was installed on project
pzotcznujkuzymndluwl on 2026-11-18 after explicit user approval. Live read-query,
function execution, service-role and client denial checks passed. The matching API
and Flutter rollout remains a separate deployment step. See STAGE7B_DEPLOYMENT_VERIFICATION.md. It adds two service-role-only read RPCs; it does not
replace operational queue, recovery, worker, or maintenance functions.

- forecast_history_coverage_v2(uuid,text,text,text,text,uuid): returns aggregate
  completed-sales evidence and saved model eligibility counts for the whole authorized filter/scope. Missing
  current evidence is not_evaluated, not no_sales. Sales evidence covers the frozen historical window, not lifetime sales or intraday activity.
  A complete bounded scan of completed, nonreturned orders is required for a no_sales classification.
  Scans exceeding 5,000 orders or 100 lines/order, malformed lines, or missing completion timestamps
  leave counts not_evaluated. Model fallback alone never proves sales existence. There are no invented thresholds.
- forecast_snapshot_page_v2(uuid,uuid,text,integer,integer,text,text,boolean,text,uuid):
  copies the existing Stage 5B compact read contract and adds category/product
  filtering before counting/pagination. Check compatibility/freshness against the
  deployed snapshot function before approval. No full inventories or histories
  are returned to the browser.

GET /v1/forecasting/snapshots/overview adds optional scope_category and
scope_product_id query parameters. The API derives location from the Admin
session, enriches at most five completed rows using the existing Product Forecast
read-only current-stock calculators, and adds sales_history_coverage and
 guidance_coverage. It never writes recommendations or fits models.

Guidance is deliberately a bounded evaluated cohort, not a claim to identify the
five highest-priority products in the entire store/page. UI ordering reuses the
existing portfolio priority ordering within that cohort. Missing guidance stays
unavailable. More scalable bulk guidance retrieval would need a separately
reviewed bulk operational-context contract; do not increase per-page fan-out.

Mean28/LightGBM reactive requests use existing authorized one-product bootstrap,
up to five candidates on the visible scope/page. Seasonal uses one. No new batch
endpoint or worker host is introduced. Current snapshots and queued/running work
are reused. Failed/cancelled identities are not automatically retried. Daily Blend
maintenance is unchanged. A client selection ledger prevents repeated requests;
database logical uniqueness remains authoritative across clients/restarts.
Overview polling is bounded to 20 x 15 seconds (Seasonal 40); detail polling is
bounded to 60 x 5 seconds (Seasonal 120). Selection/navigation invalidates callbacks.
Polling expiry does not cancel backend work or imply a worker is online.

Deployment order after SQL compatibility approval: install read RPC draft,
restart/redeploy FastAPI code, rebuild Flutter with existing snapshot mode flags.
Do not change Azure worker concurrency/services or daily maintenance.

Manual acceptance: select each model on a bounded page; verify current rows do
not enqueue, queued rows are reused, missing rows create bounded real jobs,
failed/cancelled jobs stop, and completion refreshes charts. Switch models/units,
pages/tabs during pending reads. Check scope-wide coverage versus page counts,
latest-stock guidance after legitimate inventory movement, product UUID/model
navigation, info/status popover hover/tap/Enter/Escape/outside dismissal at mobile
and desktop widths, and unchanged decimal chart data. Refresh only rereads;
reactive preparation remains deduplicated. No live jobs were run in development.

Tests were updated but not executed at the user's request. Python files received
AST syntax checks only; Dart received source inspection, not analyzer/test runs.

V1 signatures remain untouched. The repository/source V1 snapshot signature is
(uuid,uuid,text,integer,integer,text,text,boolean). Live Supabase inspection confirmed that exact signature on 2026-11-18; there
were no V2 or scope/history V1 overloads installed. The API uses V2 for all Overview pages
so unit-only and category/product pages share the same V2 freshness rules. Product
Forecast continues using V1. Both V2 functions select the latest snapshot/job with
identical revision/unit/date/model/version/history/job-identity checks.

Index review before deployment (no indexes installed by this draft): verify
products(location_id,is_active), forecast results(location_id,product_id,
requested_model_key,horizon_days,as_of_business_date DESC,created_at DESC,id DESC),
jobs(location_id,product_id,requested_model_key,horizon_days,created_at DESC,id DESC),
order_history(location_id,completed_at DESC,order_id), and revision scope primary key.
An existing broad logical unique index does not necessarily cover these sort orders.
The order cap bounds JSON expansion, not the underlying filter/sort scan cost.
Live read-only EXPLAIN ANALYZE validated the current workload and existing index usage.
Repeat scale measurements separately if inventories/history grow substantially. The scope-wide count still examines all matching products; it
returns only aggregate counts and never expands whole forecast bundles.

Classification correction: cold_start_reason=no_history never proves zero sales.
A complete, valid scan of completed, nonreturned orders in the frozen window is
required for no_sales. Limited/sufficient classifications also require positive
completed-sales evidence, current snapshot identity/freshness, and existing
model metadata. Known fallback reasons identify limited training history; other
fallback/missing/conflicting metadata remains not_evaluated. Order-item optional
unit fields default exactly as the existing demand RPC does; invalid required
product/quantity fields make the evidence incomplete instead of implying no sales.
The migration guards against missing V1 and conflicting V2 signatures on install.

## Live Stage 7B preflight, 2026-11-18

Project pzotcznujkuzymndluwl, PostgreSQL 17.6. Existing V1 snapshot owner postgres,
SECURITY DEFINER, search_path pg_catalog,pg_temp, service_role-only EXECUTE. Forecast
private tables have RLS enabled and no direct anon/authenticated/service_role reads;
new V2 functions retain the same postgres-owned definer boundary. The existing
public products table has RLS disabled; this is pre-existing and was not changed.
FastAPI still authenticates the application Admin and derives location server-side.

Live columns, constraints, trigger contexts and indexes match the migration.
Existing publication validation, immutability, deferred success/result validation,
revision tracking, recovery and initial-forecast triggers are not modified.

42 eligible products; 1,436 completed/nonreturned orders in 365 days; 3,129 in
1,095 days; maximum 23 lines/order; no invalid arrays/missing completion timestamps.
The old 2,000-order cap was insufficient for Seasonal. It is now 5,000, with an
extra sentinel order; 100 lines/order remains the expansion limit.

Live coverage SELECT bodies (no functions installed):
- Blend: 5 no_sales, 2 limited, 35 sufficient, 0 not_evaluated.
- Mean28/LightGBM/Seasonal: 5 no_sales, 0 limited/sufficient, 37 not_evaluated.
  Their saved results were not current; no Blend predictions were substituted.
- Truncating a read to one real order produced sales_evidence_complete=false,
  0 no_sales, and all 42 not_evaluated. No synthetic records were inserted.

Live page SELECT bodies: page 1=25, page 2=17; pcs=25; specific product=1;
empty location=0. Seasonal returned stale/missing honestly. Compact responses did
not contain complete bundles. Phillips result aed6b562-285d-4f3f-95fc-1d45451e6b78
had 28 saved daily points and exact V1 summary parity (7d 37.08617976031676;
28d 140.18654377923139).

Warm read-only EXPLAIN ANALYZE: coverage execution 167.071 ms (planning 7.103 ms);
page execution 21.545 ms (planning 4.145 ms). These are database timings, not API/UI
latency guarantees. Existing order_history_event_idx, result lookup index, job
logical identity index, and saved-recommendation lookup index were used. No new
indexes are required for this observed workload; future 100/500/1000-product
benchmarks remain separate work.

V1 definition MD5 baselines:
- snapshot: 043bac224858bec4faea7561196e3bc6
- daily demand: bb5c8679ebf2020194c35029a0ae3dc7
The migration checks the snapshot baseline before installation.

After explicit approval: apply only database/stage_7b_overview_history_coverage.sql
through Supabase MCP apply_migration, then execute the read-only
 database/stage_7b_post_deployment_verification.sql role/invariant checks. Verify
V1 fingerprints and table/security metadata remain unchanged. Concurrent legitimate
application/worker writes can change record counts; this migration contains only
new function definitions/grants and no operational table DML. No schema change or
live job execution occurred during this preflight.

Regression tests were updated but not executed under the existing test restriction.
Python AST parsing passed. Function creation and actual V2 role calls are NOT yet
validated because installation requires explicit approval.

## Approved deployment completed

The user approved exact SHA-256
f37d8cfa2361eb86c3b8628f1d647c50f011d9c1b6460bf8ef49ec4f9ee601e3.
MCP apply_migration(stage_7b_overview_history_coverage_v2) succeeded. The previously
pending function-creation and role checks above are now complete. Both installed
function bodies match the approved file byte-for-byte (including CRLF). V1 code
and grants remain unchanged. All six operational table counts and row fingerprints
matched before/after installation. No jobs were executed or transactions modified.
The post-deployment verification SQL ran successfully in read-only transactions.
