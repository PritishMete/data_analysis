-- Branch identifiers are opaque user-defined labels.
-- Remove the previous character/length constraint while retaining
-- case-insensitive uniqueness for active branches.

ALTER TABLE locations
    DROP CONSTRAINT IF EXISTS locations_branch_identifier_format;
