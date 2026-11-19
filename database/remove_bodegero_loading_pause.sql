-- Stop allowing loading time to be paused. Keep completed orders' historical
-- timing intact, but count the full elapsed time for orders still in progress.
update public.bodegero_loading_clocks
set paused_at = null, paused_seconds = 0
where finished_at is null;

drop function if exists public.set_order_loading_pause_v1(text, uuid, boolean);
