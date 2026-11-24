# Customer order tracking rollout

The cashier's **Process Order** action creates a pending order. One tracking QR appears immediately afterward and opens a page under the existing receipt Netlify site. After completion, that page reveals a **View Receipt** button. The receipt remains a separate page reached through the same QR link.

## Release order

1. Review and apply [`database/customer_order_tracking.sql`](../database/customer_order_tracking.sql) to the same Supabase project used by the POS. It creates a private token for each order, a session-checked token lookup for the cashier, and a read-only customer status function.
   If you already applied an earlier copy, rerun this updated script before deploying the page so the status function includes the receipt link after completion.
2. Deploy the entire [`receipt_page`](../receipt_page) directory to the existing `inventoryplusreceipt.netlify.app` site. Verify that `/status/` loads and `/config.js` is present. Deploying the new file alone would leave the status page without its configuration.
3. Release the Flutter cashier app. It calls `customer_order_tracking_token_v1` after a successful non-solo Process Order. A tracking failure does not undo the saved order. The later cashier receipt dialog can show the same tracking QR again.
4. Create a test order, scan the QR, mark one item picked, then prepare and complete the order. Verify that the page refreshes the stage and progress without changing the QR link, and that **View Receipt** appears only after completion. Check an invalid token and a cancelled order as well.

The page polls every five seconds while visible and refreshes when the customer returns to it. The token is stored separately from the order row. The customer function returns the order number, status, timestamps, assignment flag, and item progress; it also returns the receipt order ID after completion.

## Existing access to address

The current `public.orders` schema grants anonymous `SELECT` of all order rows, and the existing receipt reads `select('*')` by order ID. The tracking function limits *its own* response, but it does not close those older public read paths. Before describing tracking links as private, migrate the receipt and other direct order readers to narrowly scoped read functions, then remove the broad anonymous orders policy and grant. That access change needs its own regression test across the POS, receipt, and admin order queue.
