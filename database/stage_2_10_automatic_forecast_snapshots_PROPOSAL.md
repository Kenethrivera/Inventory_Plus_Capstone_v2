# Stage 2.10 — Broader Forecast Snapshot Coverage (Proposal Only)

Status: **not implemented; no SQL migration is included or authorized**.

## Finding

The deployed `forecast_recommendation_snapshots` records are sufficient for
accurately evaluating the forecasts they contain. They are not sufficient for
complete operational model monitoring because a snapshot is created only when
an owner confirms a genuine restock. Products that are forecast but not
restocked therefore have no immutable prediction to evaluate.

Recommendation tracking must retain its present meaning. Creating fake
recommendations merely to collect forecasts would mix forecast accuracy with
the owner’s replenishment workflow and is rejected.

## Proposed future scope

After separate schema and authorization review, add a dedicated immutable
forecast-observation store whose lifecycle is independent of restocking:

- one server-generated snapshot per location, product, model version,
  forecast origin, and horizon;
- trusted backend calculation only (no client-supplied demand quantity);
- product/location/name/SKU/unit snapshots so product deletion does not erase
  history;
- Manila forecast start/end business dates and source-data cutoff;
- explicit provenance for synthetic versus operational sales;
- service-role writes and existing Admin/location-scoped read RPCs;
- idempotent uniqueness at the logical forecast identity;
- immutable rows, retention rules, and pagination indexes;
- no link to purchase orders, restock receipts, or recommendation variance.

The capture policy should also be reviewed before implementation. A scheduled
daily snapshot provides consistent coverage; saving every UI refresh would
overweight frequently viewed products and create duplicates.

## Deployment gate

Do not prepare or apply a migration until the owner approves:

1. capture cadence and retention period;
2. whether all active products or an explicit monitored subset are included;
3. provenance rules for the current staging simulation products;
4. RLS/RPC authorization and server-only write boundary;
5. storage-volume and evaluation-completeness expectations.

