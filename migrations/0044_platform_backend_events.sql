-- Platform-wide backend request diagnostics. No request bodies, query strings,
-- authorization headers, cookies, tokens, or customer dataset values are stored.
CREATE TABLE IF NOT EXISTS platform_backend_events (
    event_id TEXT PRIMARY KEY,
    request_id TEXT NOT NULL,
    method TEXT NOT NULL,
    route TEXT NOT NULL,
    status_code INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL CHECK (duration_ms >= 0),
    principal_id TEXT REFERENCES principals(principal_id) ON DELETE SET NULL,
    client_version TEXT,
    error_type TEXT,
    error_message TEXT,
    error_fingerprint TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS platform_backend_events_time_idx
  ON platform_backend_events(created_at DESC);
CREATE INDEX IF NOT EXISTS platform_backend_events_status_time_idx
  ON platform_backend_events(status_code, created_at DESC);
CREATE INDEX IF NOT EXISTS platform_backend_events_route_time_idx
  ON platform_backend_events(route, created_at DESC);
CREATE INDEX IF NOT EXISTS platform_backend_events_principal_time_idx
  ON platform_backend_events(principal_id, created_at DESC);
ALTER TABLE platform_backend_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON platform_backend_events FROM anon, authenticated;
