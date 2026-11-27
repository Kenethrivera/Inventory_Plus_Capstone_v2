# Inventory Plus Capstone Defense Test Checklist

**Purpose:** Verify the complete implemented workflow before the capstone defense. This is a manual acceptance checklist for the team, not a record that tests have already passed. Run it on the same build, database, devices, and network planned for the defense.

**Test record:** Build/version: ______  Database/project: ______  Date/time: ______  Tester(s): ______  Devices/browsers: ______

**Result key:** P = passed; F = failed; B = blocked; NA = not applicable. For each case, record the result, actual outcome, evidence (screenshot or order/reference ID), and defect ID if needed. Do not mark a case P based only on a screen appearing; check saved state after refresh or on another role where specified.

## 1 Preparation and test data

- [ ] **PRE-01 Environment.** Open the exact defense build on every planned device and browser. **Expected:** App loads without a blank screen or console crash; all devices connect to the same demo store and Supabase project.
- [ ] **PRE-02 Accounts.** Prepare separate Administrator, Cashier, Helper, and Bodegero accounts; sign in to each on separate devices or browser profiles. **Expected:** Each reaches the correct role workspace and sees the same store.
- [ ] **PRE-03 Catalog.** Prepare one light product, one heavy/truck-loading product, one damaged product, and one low-stock product. Record SKU, price, quantity, shelf, level, and image for each. **Expected:** Products are searchable and quantities match the baseline sheet.
- [ ] **PRE-04 Physical/demo assets.** Prepare shelf QR labels, a readable map, camera permissions, a truck identifier, two loading-proof photos, request evidence photos, and a unique test GCash reference. **Expected:** Each file or camera can be opened on the target device; no real payment is made.
- [ ] **PRE-05 Reporting data.** Identify a completed historical order and a product with saved forecast data; record their IDs. **Expected:** Analytics and Forecasting show real saved records where required. Label any enabled sample/demo panels as demo data.
- [ ] **PRE-06 Isolation and reset.** Record initial stock, pending requests, order count, and test references; use a disposable demo store or agreed cleanup method. **Expected:** The team can distinguish this run from earlier demos and restore baseline data after testing.

## 2 Sign in security and access

- [ ] **AUTH-01 Valid sign in and sign out.** Sign in with each role, then sign out one account. **Expected:** Correct role opens; sign out returns to login and protected pages cannot be reopened with Back or a saved URL.
- [ ] **AUTH-02 Invalid credentials.** Submit a wrong password and blank required fields. **Expected:** Helpful error or validation appears; no authenticated screen opens and no session is created.
- [ ] **AUTH-03 Role navigation.** From each account, inspect navigation; try an Administrator URL while signed in as Cashier, Helper, and Bodegero. **Expected:** Only allowed sections are accessible; direct URL navigation resolves to an authorized section.
- [ ] **AUTH-04 Disabled account.** Disable a dedicated test account from Staff, then attempt sign in or refresh its active session. **Expected:** Access is denied or revoked according to the app's session rules; other accounts remain usable. Re-enable afterward.
- [ ] **AUTH-05 Forced password change.** Reset a dedicated staff password and sign in with the issued password. **Expected:** Password change is required before normal work; the new password works and the issued one no longer works.
- [ ] **AUTH-06 Recovery.** Use the configured forgot-password/security-question flow with correct and incorrect answers on a dedicated account. **Expected:** Correct identity checks allow recovery; incorrect answers do not disclose credentials or grant access.
- [ ] **AUTH-07 Store hours.** In a safe test window, test an account outside configured hours and the Administrator exception if enabled. **Expected:** Access follows saved store-hours settings; restore the defense schedule afterward.
- [ ] **AUTH-08 Session persistence.** Refresh or reopen a signed-in client, then sign out and reopen it. **Expected:** Valid session restores to the correct role; signed-out state stays signed out.

## 3 Inventory and product catalog

- [ ] **INV-01 Create product.** As Administrator, add a product with name, unique SKU, category, unit, price, quantity, image, and shelf/level where applicable. **Expected:** It appears in Inventory and POS search after refresh with the saved fields.
- [ ] **INV-02 Required and duplicate values.** Try missing required fields, invalid price/quantity, and an existing SKU. **Expected:** Invalid data is rejected without creating a partial or duplicate product.
- [ ] **INV-03 Edit and restore.** Edit price, color, image, heavy-item flag, and shelf assignment; test remove/restore using a disposable product. **Expected:** Changes persist and appear in the relevant role screens; restored product is available again.
- [ ] **INV-04 Search/filter/sort.** Search by name and SKU; use category and stock-status filters and sorting. **Expected:** Results match the chosen criteria, empty state is clear, and clearing filters restores the full list.
- [ ] **INV-05 Stock history.** Open a product's stock movement/history before and after an approved adjustment. **Expected:** Quantity delta, reason/source, actor, and time match the approved operation; refresh does not duplicate a movement.
- [ ] **INV-06 Thresholds.** Set Critical to 20% and Low to 50% with a product that sold 20 units in seven days and has 8 on hand. **Expected:** It shows Low; after an approved +5 restock it shows Healthy at 13. Out of stock remains Out at zero. Restore intended settings afterward.
- [ ] **INV-07 QR label.** Generate/print a product or shelf QR and scan it with the intended device. **Expected:** Code is readable and resolves to the correct product or shelf; a wrong code does not verify another item.
- [ ] **INV-08 Concurrent stock.** View the same product on Administrator and Cashier devices, make one authorized stock change, and refresh both. **Expected:** Both converge to the same quantity; no stale client silently overwrites a newer value.

## 4 Store map and location

- [ ] **MAP-01 View location.** Open Store Map as Administrator and map views as Helper/Bodegero; locate the prepared light and heavy products. **Expected:** Shelf, level, and product placement agree with Inventory and the picking/loading task.
- [ ] **MAP-02 Edit map.** On a disposable map area, add or move a shelf/door or assign a product, save, then reopen. **Expected:** Layout and assignment persist; other role map views update.
- [ ] **MAP-03 Unsaved changes.** Change the map and navigate away or choose Discard; then reload. **Expected:** The app warns about unsaved changes and discarded edits do not persist.
- [ ] **MAP-04 View modes and route.** Switch available 2D/3D views and inspect the walking-order route. **Expected:** Both views load, locations remain consistent, and route/order does not omit required items.

## 5 POS cart discount and order creation

- [ ] **POS-01 Product search.** Search the prepared products by name/SKU and, if configured, Object Scanner. **Expected:** Correct catalog items and current prices appear; scanner errors give a recoverable message.
- [ ] **POS-02 Cart math.** Add light and heavy products, change quantities, remove one, then restore it. **Expected:** Line totals, subtotal, discount, and grand total recalculate correctly and never become negative.
- [ ] **POS-03 Stock guard.** Try zero/invalid quantity and quantity above available stock. **Expected:** Invalid quantity cannot produce an order; stock and cart remain unchanged.
- [ ] **POS-04 Discount below limit.** Apply a valid discount within the configured Cashier limit. **Expected:** Total updates and no Administrator approval is required.
- [ ] **POS-05 Discount above limit.** Request a discount above the limit; inspect it on Administrator Approvals and approve it. **Expected:** Request includes the exact cart snapshot and amount; Cashier receives approval and may proceed with that cart.
- [ ] **POS-06 Changed cart after approval.** After approval, alter product, quantity, or discount before Process Order. **Expected:** Old approval cannot authorize a different cart; a new approval is required if the new amount exceeds the limit.
- [ ] **POS-07 Rejected discount.** Reject a second test request with a reason. **Expected:** Cashier sees rejection and cannot use the rejected discount; the request remains traceable.
- [ ] **POS-08 Order creation.** Enter truck identifier and loading note for heavy goods, then select Process Order once. **Expected:** One pending order with a unique reference is saved; it appears in Cashier pending orders, Administrator Orders, Helper queue, and Bodegero queue as applicable.
- [ ] **POS-09 Duplicate action.** Double-click Process Order or retry after a slow response. **Expected:** One customer intent creates one order; no duplicate order or double stock reservation appears.
- [ ] **POS-10 Solo mode.** If used in the defense, run a separate small Process & Pack order. **Expected:** Solo workflow completes according to its own rules without assigning Helper/Bodegero tasks. Mark NA if the team will not present solo mode.

## 6 Helper picking and assignment

- [ ] **HELP-01 Availability and assignment.** Set Helper availability, create a light-item order, and inspect auto-assignment or claim action. **Expected:** Eligible Helper receives the correct order; unavailable staff are not assigned contrary to configured rules.
- [ ] **HELP-02 Pick checklist.** Open the order, compare name/SKU/quantity/location with Cashier order, scan the correct shelf QR, and verify each light item. **Expected:** Only correct items advance; progress is visible to Cashier and Administrator.
- [ ] **HELP-03 Wrong or repeated scan.** Scan a different shelf/item and scan the correct code twice. **Expected:** Wrong scan is rejected or flagged; repeated scan does not duplicate quantity or progress.
- [ ] **HELP-04 Incomplete pick.** Try to finish before all required light items are verified. **Expected:** Completion is blocked or remaining items are clearly shown; no false ready state is recorded.
- [ ] **HELP-05 History.** Complete the pick, reopen Helper History/My orders, and search for the reference. **Expected:** Correct order, items, timestamps, and status remain after refresh.

## 7 Bodegero loading and proof

- [ ] **BOD-01 Heavy-task assignment.** Create an order containing heavy goods and open Bodegero Queue. **Expected:** Same order reference, truck identifier/note, and heavy-item quantities appear; light-only work is not incorrectly loaded here.
- [ ] **BOD-02 Shelf verification.** Scan the correct heavy-product shelf QR and mark required quantity loaded. **Expected:** Wrong QR or missing quantity cannot verify a different product; Cashier/Admin see progress.
- [ ] **BOD-03 Required proof.** Attempt completion with no photos, one photo, then both truck-identifier and loaded-goods photos. **Expected:** Completion is prevented until required proof is present; both images are viewable after save.
- [ ] **BOD-04 Photo failure.** Deny camera access or use an unsupported/corrupt file, then retry with valid images. **Expected:** Clear upload error, no false completion, and successful retry without duplicate load record.
- [ ] **BOD-05 Loading history.** Complete loading and inspect Bodegero History and Cashier proof view. **Expected:** Order reference, quantities, staff, time, and the two proof images agree across roles after refresh.

## 8 Stock requests and approvals

- [ ] **REQ-01 Write-off request.** As Helper or Bodegero, submit a damaged-stock write-off with quantity, reason, and photo. **Expected:** Request is Pending, photo opens in Approvals, and stock has not changed before approval.
- [ ] **REQ-02 Restock request.** Request +5 for the prepared low-stock product with reason/photo. **Expected:** Pending request shows before/after quantities to Administrator; current stock remains 8 until approval.
- [ ] **REQ-03 Approval.** Approve the restock and write-off once. **Expected:** Correct stock deltas apply once, request statuses change, movements are recorded, and requester sees the outcome.
- [ ] **REQ-04 Rejection.** Reject a separate request with reason. **Expected:** Reason is visible in requester history; stock and movement log do not change.
- [ ] **REQ-05 Invalid request.** Try zero, negative, excessive write-off, missing required photo, or missing reason. **Expected:** Validation blocks the request without a pending row or stock change.
- [ ] **REQ-06 Duplicate decision.** Have two Administrator sessions open the same pending request; approve in one and click again in the other. **Expected:** Exactly one decision and one stock movement are saved; the second client refreshes to the final state.
- [ ] **REQ-07 Filters and history.** Filter Approvals by type, status, and date; inspect requester history. **Expected:** Counts and records agree, and past decisions remain available after sign out/in.

## 9 Payment receipt and customer tracking

- [ ] **PAY-01 Fulfillment gate.** Before Helper and Bodegero finish, try Complete Transaction. **Expected:** Payment cannot finalize until required preparation/loading and proof are complete.
- [ ] **PAY-02 Cash.** On a separate ready test order, select Cash and enter tendered amount below then above the total. **Expected:** Insufficient cash is blocked; valid tender displays correct change and records one completed transaction.
- [ ] **PAY-03 GCash.** On the main order, inspect primary/backup QR destination, enter a unique test reference, and confirm. **Expected:** Selected destination and reference are saved; blank/invalid reference is rejected; order completes once.
- [ ] **PAY-04 Duplicate payment.** Click confirm twice or retry after a slow response. **Expected:** One payment/receipt is recorded, no duplicate charge record, and stock is deducted exactly as designed once.
- [ ] **PAY-05 Receipt.** Open or print the receipt after completion. **Expected:** Order number, items, quantities, unit prices, discount, total, payment method/reference, date, and store details match the saved transaction.
- [ ] **PAY-06 Tracking QR.** Open the order tracking QR immediately after Process Order and during each fulfillment stage. **Expected:** Same link shows the same order and updated stage/progress; it does not expose unrelated orders.
- [ ] **PAY-07 Tracking end states.** Complete one order and cancel a separate test order; open each tracking link and an invalid link. **Expected:** Receipt link appears only for the completed order; cancelled and invalid tokens show appropriate safe states.
- [ ] **PAY-08 Public access review.** Check current deployment/database policy before calling tracking links private. **Expected:** If anonymous broad order reads still exist, log a security defect and avoid claiming order data is private at defense. See `docs/customer_order_tracking.md`.

## 10 Monitoring history notifications and staff

- [ ] **MON-01 Live monitoring.** Watch Administrator Dashboard/Orders & activity and Cashier pending orders while the four roles work. **Expected:** Same reference, assignees, stage, and timestamps converge without manual data edits.
- [ ] **MON-02 Order queue display.** If deployed, open the separate queue display during order creation and completion. **Expected:** It shows the correct store's current orders and updates to the final state; no private staff/payment fields are displayed unnecessarily.
- [ ] **MON-03 Notifications.** Trigger discount approval, assignment, request decision, and completion; inspect recipient bell/badge. **Expected:** Correct role receives each relevant notification once; opening it goes to the relevant record and unread count updates.
- [ ] **MON-04 History and filters.** Find the completed order in Cashier History, Helper History, Bodegero History, Administrator Orders and Transactions. **Expected:** Order reference, amounts, staff, status, payment, and proof are consistent; date filters and pagination find the record.
- [ ] **MON-05 Staff accounts.** Add a disposable staff account, change its role, disable/re-enable it, and reset its password. **Expected:** Changes persist, navigation follows the current role, and disabled access is enforced.
- [ ] **MON-06 Staff performance.** Open Helper, Cashier, and Bodegero performance for a period with activity. **Expected:** Counts/metrics correspond to saved work for that period; empty periods display an honest empty state.
- [ ] **MON-07 Presence.** Toggle availability, sign out, and let a session expire if practical. **Expected:** Presence/availability shown to assignment and Administrator is current, and signed-out staff are not treated as available indefinitely.

## 11 Settings analytics exports and forecasting

- [ ] **SET-01 Store settings.** Change a safe demo setting such as store hours, discount limit, or unit, save, reopen on another Administrator session, then restore it. **Expected:** Saved value is consistent and dependent screens reflect it; invalid values are rejected.
- [ ] **SET-02 GCash settings.** Verify primary and optional backup account/QR configuration on POS; change only in demo configuration. **Expected:** Displayed destination matches the saved account selected for the sale.
- [ ] **ANA-01 Date filters.** Open Analytics for Today, last 7/30 days, and a known custom period. **Expected:** Sales totals, order counts, category/product rankings, and charts change with the period and reconcile with known orders.
- [ ] **ANA-02 Reports.** Export sales and inventory PDF/CSV where offered and open each file. **Expected:** Download succeeds; title, period, store, totals, row counts, and columns match the selected view; no blank/corrupt file.
- [ ] **ANA-03 Empty data.** Select a period with no sales. **Expected:** Clear empty/zero state; no invented sales or divide-by-zero values.
- [ ] **FOR-01 Overview.** Open Forecasting Overview and select a model/scope/search. **Expected:** Saved forecasts show model, timestamp, coverage/status, and demand values; a missing forecast is marked Missing rather than Queued.
- [ ] **FOR-02 Product forecast.** Open a product with saved forecast data and inspect 7/28-day demand, source history, data quality, and restock inputs. **Expected:** Product identity and units match Inventory; changing product/model updates the view without stale results.
- [ ] **FOR-03 Job lifecycle.** Use Prepare/queue action only in demo data, then inspect Forecast Jobs filters/details and refresh until a terminal state. **Expected:** Queued, running, succeeded, retry, or failed states are represented accurately; queued alone is not presented as a completed forecast.
- [ ] **FOR-04 Tracking and accuracy.** Inspect saved restock recommendation records, applied restocks, and accuracy/performance for a product with actual history. **Expected:** Record status and dates are traceable; unavailable accuracy says so. Any sample/demo view is explicitly identified as demo data.
- [ ] **FOR-05 Backend failure.** Temporarily test an unavailable forecasting/classification service or use a controlled failure fixture. **Expected:** UI gives a recoverable error or honest unavailable state; POS and core inventory work continue.
- [ ] **AI-01 Classification/object scan.** With a configured camera/service, scan a known product and a nonmatching object. **Expected:** Match can be reviewed before adding/selecting a product; failed/uncertain result does not silently choose an item. Mark NA if service is not part of the defense deployment.

## 12 Reliability cross-device and release checks

- [ ] **REL-01 Refresh recovery.** Refresh all four roles mid-order, including one pending request. **Expected:** Saved order, assignments, pick/load progress, proof, and pending decision restore correctly.
- [ ] **REL-02 Network interruption.** Disconnect one device during a save, reconnect, and retry once. **Expected:** Clear failure/retry state; no duplicate order, stock movement, request, or payment; server truth appears after refresh.
- [ ] **REL-03 Simultaneous work.** Run the four-person scenario at the same time with separate sessions. **Expected:** No user is logged out by another account; statuses reach every role within a practical demo interval.
- [ ] **REL-04 Device layout.** Check the actual phone and projector/desktop sizes, including portrait and landscape if used. **Expected:** Buttons, dialogs, tables, photos, scanner, and navigation remain readable with no clipped critical control.
- [ ] **REL-05 Permissions and links.** Test camera, photo picker, print/download, QR link, and receipt link on the actual devices. **Expected:** Each permission prompt and external link works; denial gives a clear fallback.
- [ ] **REL-06 Restart and deployment.** Relaunch app after deployment and verify receipt/status page, order queue display, forecasting API, and Supabase connectivity used by the demo. **Expected:** Correct configuration loads, required services respond, and no screen depends on a developer-only local process.
- [ ] **REL-07 Data separation.** Log in to another test store/location if available and search for the main order/product. **Expected:** No cross-store data appears in role views, reports, or customer links.

## 13 Defense rehearsal and acceptance

1. Run the main scenario in `docs/PRESENTATION_SCENARIO.md` with four presenters and a timer. Capture one reference ID for the order and one ID for each stock request.
2. At each handoff, read the same order reference aloud and confirm the next role sees the expected state before continuing.
3. Save evidence for critical checkpoints: discount approval, created order, Helper pick, Bodegero proof, stock approval/movement, completed payment, receipt, Analytics, and saved Forecasting result.
4. Record every F/B in the defect log below. Fix and rerun the failed case plus its linked end-to-end flow. Use NA only with a reason (for example, a service is outside the defense build).
5. **Ready for defense** when every critical path case is P, no open blocker affects the live story, demo accounts/data and backup media are prepared, and the team completes one timed rehearsal on the final build.

### Test result log

| Case ID | P F B NA | Actual outcome and evidence | Defect ID | Tester and date |
| --- | --- | --- | --- | --- |
| ______ | ______ | ______________________________ | ______ | ______ |
| ______ | ______ | ______________________________ | ______ | ______ |
| ______ | ______ | ______________________________ | ______ | ______ |

### Defect log

| Defect ID | Severity | Steps and expected versus actual | Owner | Fix version and retest |
| --- | --- | --- | --- | --- |
| ______ | Blocker High Medium Low | ______________________________ | ______ | ______ |
| ______ | Blocker High Medium Low | ______________________________ | ______ | ______ |

**Source basis:** Role sections and screens under `lib/navigation` and `lib/ui`; customer tracking page under `receipt_page/status`; order queue display under `order_queue_display`; forecasting API under `forecasting_backend/app/api`; existing test files under `test`; and `docs/PRESENTATION_SCENARIO.md`. This is an acceptance plan derived from repository behavior; it does not assert that any test was executed or passed.
