-- Allow multiple active Managers to be assigned to the same location.
--
-- The original unique index enforced at most one Manager per location. The
-- application now supports multiple managers; duplicate active assignments
-- for the same person/location/role remain prevented by uq_active_assignment_context.
DROP INDEX IF EXISTS uq_active_manager_per_location;
