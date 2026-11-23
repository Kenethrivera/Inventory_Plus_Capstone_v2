-- Apply in the Supabase SQL editor to update the existing daily cleanup job.
SELECT cron.schedule_in_database(
  'delete-old-receipts',
  '0 0 * * *',
  'DELETE FROM orders WHERE created_at < NOW() - INTERVAL ''1 month'';',
  'postgres',
  NULL,
  true
);
