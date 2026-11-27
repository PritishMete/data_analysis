ALTER TABLE platform_backend_events
  ADD COLUMN IF NOT EXISTS error_stack TEXT;
