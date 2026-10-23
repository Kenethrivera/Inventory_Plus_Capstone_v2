SELECT cron.schedule_in_database('delete-old-receipts', '0 0 * * *', ' DELETE FROM orders WHERE created_at < NOW() - INTERVAL ''2 days''; ', 'postgres', NULL, true);
