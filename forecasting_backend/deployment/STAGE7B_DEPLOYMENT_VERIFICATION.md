# Stage 7B live deployment verification - PASS

Date: 2026-11-18. Project: pzotcznujkuzymndluwl. PostgreSQL 17.6.
Explicit user approval received for installation and verification of SHA-256
f37d8cfa2361eb86c3b8628f1d647c50f011d9c1b6460bf8ef49ec4f9ee601e3.
MCP migration: stage_7b_overview_history_coverage_v2; success=true.

## Installed objects and permissions

- public.forecast_snapshot_page_v2(uuid,uuid,text,integer,integer,text,text,boolean,text,uuid)
- public.forecast_history_coverage_v2(uuid,text,text,text,text,uuid)

Both postgres-owned SECURITY DEFINER, fixed search_path=pg_catalog,pg_temp.
service_role EXECUTE passed actual read-only calls. Actual anon and authenticated
calls to both functions were denied with SQLSTATE 42501. No direct private schema
or table privileges were granted. Existing forecast tables retain RLS. Existing
public products RLS configuration was inspected and left unchanged.

Installed function body MD5 matches the approved file's original line endings:
- history coverage: d3c6c455eadf9a5f07d56ead9784bdf1
- snapshot page: 61c98428ef7ecfd54600e19013e92130

V1 snapshot definition MD5 043bac224858bec4faea7561196e3bc6 and daily-demand MD5
bb5c8679ebf2020194c35029a0ae3dc7 stayed unchanged; their grants also stayed unchanged.
No V1 functions were replaced or overloaded. The source migration was not edited
after approval; the deployed checksum remains reproducible.

## Actual query and RPC results

42 active products. Completed/nonreturned orders: 1,436 in 365 days; 3,129 in
1,095 days. Maximum lines/order=23. The source cap was corrected from 2,000 to
5,000 before approval because the live Seasonal window exceeded the old cap.

Actual service_role coverage RPC calls:

| Model | Total | No sales | Limited | Sufficient | Not evaluated |
|---|---:|---:|---:|---:|---:|
| blend | 42 | 5 | 2 | 35 | 0 |
| mean28 | 42 | 5 | 0 | 0 | 37 |
| lightgbm | 42 | 5 | 0 | 0 | 37 |
| seasonal_experimental | 42 | 5 | 0 | 0 | 37 |

No-sales evidence refers to the frozen historical window, not lifetime sales.
Non-Blend results were missing/stale; no Blend substitution was made.
A read-only negative query using the exact coverage body with a deliberately
one-order cap returned sales_evidence_complete=false, no_sales=0 and
not_evaluated=42. The installed body matched that reviewed logic; the installed
RPC's live source did not exceed its actual 5,000-order cap.

Page query bodies returned 25 then 17 products; pcs returned 25; a specific product
returned one; an empty location returned zero. Compactness, location and page-size
assertions also passed via actual installed service_role RPCs. A real category
scope returned one product and matching page/coverage totals. Seasonal retained
its actual stale/missing states.

Phillips Screwdriver (082643c4-0215-4a9a-a6aa-b99c070bddb7): result
aed6b562-285d-4f3f-95fc-1d45451e6b78, 28 daily points, 7-day demand
37.08617976031676, 28-day demand 140.18654377923139. V2 summary equalled V1 exactly.

Live read-only warm EXPLAIN ANALYZE: page execution=21.545 ms; coverage=167.071 ms.
These are DB execution timings, not end-to-end API/browser latency. Existing
order event, result lookup, job identity and recommendation lookup indexes were
used. No indexes were added. Larger-inventory benchmarking remains separate.

## Operational preservation

Counts AND whole-row fingerprints matched before/after:

| Relation | Rows |
|---|---:|
| products | 42 |
| order_history | 3517 |
| forecast_jobs | 155 |
| forecast_execution_results | 136 |
| forecast_input_revisions | 42 |
| forecast_recommendation_snapshots | 3 |

The migration created only V2 read functions and their grants. No operational
records, workers, schedules, RLS policies or forecasting calculations changed.
The existing publication, immutability, recovery, deferred result and revision
triggers were inspected and not modified.

## Verification artifacts and remaining release work

database/stage_7b_post_deployment_verification.sql executed successfully using
read-only transactions, including actual role switching and denial assertions.
Python syntax checks passed; regression tests were updated but not run under the
existing restriction. No Git or Flutter tooling was run.

Database deployment has no remaining blocker. Deploy/restart the matching FastAPI
code and release the matching Flutter build through the normal approved release
process. Verify authorized API retrieval, UI coverage/current guidance and reactive
preparation there; no application deployment or new forecast job was run here.
