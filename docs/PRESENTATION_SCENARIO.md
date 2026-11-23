# Inventory Plus: Simultaneous Four-Member Presentation Scenario

## The situation

A customer buys a box of screws and several bags of cement. The screws must be picked from a shelf; the cement must be loaded onto a truck. The customer asks for a discount and will pay through GCash. While the order is being fulfilled, staff find a damaged product and a low-stock product. The four presenters work in the system **at the same time**, as four store employees would during a normal day.

**Suggested duration:** 20–25 minutes for the live story, then 5 minutes for additional features and questions. Use four devices or four separate browser profiles. If there is one projector, show one role at a time while the other three continue working; announce each screen switch.

| Member | Account | Screen and live responsibility |
| --- | --- | --- |
| **1** | **Cashier** | Search items, build the cart, request a discount, create the order, monitor fulfillment, inspect loading proof, take payment, show receipt and history. |
| **2** | **Helper** | Receive or claim the order, use the store map, scan the screw shelf QR, verify picking, send a damaged-stock request. |
| **3** | **Bodegero** | Receive the same order, find and scan the cement, load it, capture the truck and goods photos, send a low-stock request. |
| **4** | **Administrator** | Monitor all roles and order progress, approve the discount and stock requests, inspect inventory and activity, then present analytics and forecasting. |

## Prepare before the live demo

- Sign in to four **different demo accounts** on separate devices or browser profiles. Check that all accounts belong to the same demo store and that the Helper and Bodegero are available for assignment.
- Put **Box of Screws** (light item) and **Cement Bag** (heavy item) in the catalog with sufficient stock, prices, SKUs, images, and shelf locations. Add a separate damaged item. For the threshold demonstration, prepare a separate low-stock item with 20 units sold in the last seven days and 8 on hand.
- Set up a store map and print or display the QR labels for the shelves to be scanned. Check camera access on both fulfillment devices.
- Configure a primary GCash QR and optional backup QR. Use a unique **test** GCash reference; make no real payment.
- Know the Cashier discount approval threshold. Choose a demo discount above it, and keep the cart unchanged after approval.
- Prepare a truck identifier, a cashier loading note, a truck identifier photo, and a photo of the loaded items and quantities.
- Have existing sales and saved forecast records for the reporting section. Rehearse the exact order flow and reset demo data before presenting.

### Stock threshold setup and explanation

Before presenting, set the demo store's **Critical** threshold to **20%** and **Low stock** threshold to **50%** under **Administrator → Settings → Stock & units**. The critical percentage must be below the low percentage. With 20 units sold in the last seven days, the app calculates:

| Quantity on hand | Status | Calculation |
| ---: | --- | --- |
| 0 | Out of stock | Zero stock always shows Out. |
| 1–4 | Critical | 20% of 20 sales = 4 units. |
| 5–10 | Low | 50% of 20 sales = 10 units. |
| 11 or more | Healthy | Above the Low cutoff. |

The prepared product starts at **8 on hand**, so it appears as **Low**. Member 3 requests **5 more units**; after Member 4 approves, it becomes **13 on hand** and should move to **Healthy**. Use the same product in Settings preview, Inventory's Low filter, the stock request, and the final stock movement. If the actual sales or quantities differ on demo day, use the values shown by the app and recalculate the example. Products with no sales in the last seven days show Healthy when stock is above zero; zero stock still shows Out.

## Live timeline: everyone is active

The table shows what each member does during the **same time window**. The bold checkpoint in the last column tells the team when to move on. Times are guides; wait for the actual system state before advancing.

| Time | Member 1 — Cashier | Member 2 — Helper | Member 3 — Bodegero | Member 4 — Administrator | Shared checkpoint |
| --- | --- | --- | --- | --- | --- |
| **0:00–2:00** | Sign in; open POS; search for screws and cement. Show name/SKU search and, if working, Object Scanner. | Sign in; show Queue, availability, and the empty or existing assigned-order list. Open the Map briefly. | Sign in; show Queue, availability, Map, and loading History. | Sign in; show Overview and stock alerts. Open Settings → Stock & units to show Critical 20%, Low 50%, and the threshold preview; then find the 8-unit product in Inventory's Low filter. | **All four roles are online; the low-stock baseline is visible.** |
| **2:00–4:00** | Add both items and quantities to the cart. Apply a discount above the automatic limit and submit the discount approval request. | Point out the screw shelf on the 2D/3D map and the QR scan action; wait for the order. | Point out the cement location and explain truck-loading proof; wait for the order. | Watch the notification/pending count change. Open Approvals, inspect the cart snapshot and discount amount, then approve the request. | **Cashier sees approval for this cart.** |
| **4:00–6:00** | Enter truck identifier and loading note. Confirm the order and announce its reference. Keep Pending Orders open to watch progress. | Wait for the assigned order to appear; claim it if the configured flow leaves it unassigned. Open its picking checklist. | Wait for the same order in the loading queue. Open its heavy-item checklist and cashier note. | Watch the order enter Overview or Orders & activity. Show who is assigned and its current status. | **Same order reference appears on all four screens.** |
| **6:00–10:00** | Watch item preparation and loading status update. Show notifications and Pending Orders without taking payment yet. | Use the map and walking-order pick list; scan the screw shelf QR; mark the item verified and finish picking. | Use the map; scan the cement shelf QR; mark the heavy items loaded; attach truck identifier and loaded-goods photos; confirm loading. | Follow the live order in Overview and Orders & activity. Point out status changes, staff activity, and any delay alert if one actually occurs. | **Light picking and heavy loading are complete.** |
| **10:00–13:00** | Review the finished order and the Bodegero's two proof photos. Show the payment options but wait for Member 4 to finish the stock review. | In Request, submit a write-off for the separate damaged item with reason and photo. Show its pending status. | In Request, request 5 more units of the 8-unit low-stock item with reason and photo. Show its pending status. | Open both Approvals requests. For the restock, show 8 on hand → +5 → 13; approve it, then return to Inventory to show the product moving from Low to Healthy and the recorded stock movement. Review the write-off evidence and approve it. | **The threshold status and both request outcomes update.** |
| **13:00–16:00** | Select Complete Transaction. Show GCash QR destination, enter the unique test reference, confirm payment, and show the completed order or receipt. | Open History to show the completed picking work and request outcome. | Open loading History to show proof and the completed loading work. | Find the order in Orders & activity and Transaction History. Show order, payment, staff, timeline, GCash reference, and stock movement records. | **One order is paid and traceable end to end.** |
| **16:00–21:00** | Show Cashier History and Requests. If time permits, open a small second demo order to show the Cash payment dialog and calculated change without necessarily submitting it. | Show Helper Inventory and location details; explain how shelf placement supports accurate picking. | Show Bodegero Map, Request history, and profile/availability status. | Show Analytics date filters, sales charts, product rankings, dead stock, and report export. Then open Forecasting Overview, Product Forecast, and Tracking & Accuracy for a product with saved data. | **Each role has shown its remaining main pages.** |
| **21:00–25:00** | Return to the completed order. State what the customer received and how it was paid. | State how the correct light item was verified. | State how heavy goods and truck proof were recorded. | Summarize the transaction, stock decisions, reports, and replenishment view. | **Close together and take questions.** |

## Spoken cues at the critical moments

Use short lines while the screen changes. All members can keep operating; only the person whose screen is projected speaks.

1. **Member 1:** “I have the customer's light and heavy items in the cart. This discount needs the administrator's approval.”
2. **Member 4:** “The request appeared immediately. I can review the exact cart and approve this discount.”
3. **Member 1:** “The order is now **[read the order reference]**. I can see it waiting for picking and loading.”
4. **Member 2:** “The Helper received that same order. I found the shelf on the map and verified the screws by scanning its QR.”
5. **Member 3:** “The Bodegero received the cement task. I scanned the shelf and recorded both the truck and loaded-goods photos.”
6. **Members 2 and 3:** “We also sent a damaged-stock write-off and a low-stock restock request.”
7. **Member 4:** “The requests reached Approvals with photos and proposed quantities. My decisions are reflected in inventory and stock activity.”
   For the threshold example: “This product sold 20 units in seven days. Our Low cutoff is 10, so 8 on hand is Low. Approving 5 more raises it to 13, above the cutoff.”
8. **Member 1:** “I reviewed the loading proof and completed the GCash payment. The order is now in History.”
9. **Member 4:** “The same transaction can be found in orders, payment history, analytics, and replenishment planning.”

## Features that need a brief separate view

The main transaction demonstrates the connected workflow. Show these quickly before the demo, during natural waiting time, or in questions. Do not interrupt a live dependency such as discount approval or order assignment.

| Owner | Feature | Where to show it |
| --- | --- | --- |
| Member 4 | Staff management, roles, account enable/disable, password reset, and performance | Staff page; use demo accounts and avoid changing a presenter's access. |
| Member 4 | Product creation/editing, SKU, image, quantity, stock filters, QR label, stock coverage/history | Inventory and product details. |
| Member 4 | Map layout editing, product shelf assignment, and 3D view | Store map; save only in the disposable demo store. |
| Member 4 | Thresholds, measurement units, store hours and access, discount limit, GCash primary/backup details | Settings. |
| Member 4 | Pending/approved/rejected requests and rejection reason | Approvals; use an extra harmless demo request for rejection. |
| Member 4 | Sales and inventory PDF exports, analytics periods, category sales, top/bottom sellers | Analytics. |
| Member 4 | Saved forecasts, model and data-quality details, 7/28-day demand, restocking inputs, recommendation tracking, accuracy | Forecasting, only where configured services return actual records. |
| Member 1 | Cash tendered and calculated change; primary/backup GCash QR and reference validation | POS payment dialog. |
| Members 1–3 | Notifications, profiles, availability, role-specific histories | Their own role workspaces. |
| Any member | Sign-in, forced password change, forgotten-password recovery and security questions | Login/profile using a dedicated demo account. |

**Forecasting presentation note:** Some Forecasting cards are gated demonstration or sample UI, including example Restock Priorities, Sales History Coverage, and forecast accuracy views. If those appear, call them **demo data**. A queued forecast is not proof that the background worker has run; show the saved result and its status when available.

## Coordination rules

- The **Cashier creates the order only after discount approval**. The Helper and Bodegero start only after the same order reference appears in their queues.
- The **Cashier completes payment only after both fulfillment tasks and the loading proof are visible**. The stock-request branch can run in parallel because it uses separate products.
- Keep the order reference on a cue card. Use it when switching projected screens so the panel knows it is one live transaction.
- If one service is unavailable, show a clearly labeled recording or screenshot for that step and continue with the live roles that still work.

