# Bodegero loading test

Apply `phase_bodegero_loading.sql` to a test database before launching the updated app. Use two accounts in the same store: a Helper and a Bodegero. Add a light product and mark cement as **Heavy / truck loading required** in Inventory.

1. Create an order containing only cement. It should appear in the Bodegero queue and not the Helper queue. If no Bodegero account was active at checkout, sign in as one and claim the unassigned task.
2. Scan a different shelf QR. Verification should fail. Scan cement's QR; the item should show **QR verified**.
3. Try a wrong loaded quantity, or leave the truck identifier or photo blank. Confirmation should be blocked. Enter the ordered quantity, truck identifier, and take a photo. Confirm loading.
4. The order should become **Ready**. In **Orders & activity**, open its details and view the saved truck identifier, loaded counts, and photo. Check that stock was deducted once at checkout and did not change again during loading.
5. Create one mixed order with cement and a light product. Confirm the **same order number** appears in the Helper and Bodegero queues. The Helper sees and scans only the light product; the Bodegero sees and scans only cement. Each queue shows the other worker's progress.
6. Finish the Helper side first. It should say it is waiting for Bodegero, and the order must stay pending. Then finish the Bodegero scan, quantity, truck, and photo steps. The order should become **Ready**. Repeat with Bodegero finishing first; the order must stay pending until the Helper finishes. If the Helper checklist is still open when the order becomes Ready, its button should return to the queue without trying to prepare the order again.
7. Reset the Bodegero password as Admin. At next sign-in, the Bodegero should be required to change it and then reach the loading queue.

The migration keeps existing orders light-only. Changing a product's Heavy setting affects newly created orders; an existing order keeps its checkout snapshot.
