from pathlib import Path


def test_branch_restriction_preflight_identifies_existing_conflicts_without_mutating_assignments():
    migration = Path(
        "migrations/0032_preflight_existing_branch_assignment_conflicts.sql"
    ).read_text()

    assert "GROUP BY organization_id, principal_id" in migration
    assert "HAVING count(DISTINCT location_id) > 1" in migration
    assert "array_agg(DISTINCT location_id::TEXT" in migration
    assert "array_agg(assignment_id::TEXT" in migration
    assert "organization_id=%s; principal_id=%s; location_ids=%s; assignment_ids=%s" in migration
    assert "Existing cross-branch assignment conflicts must be reviewed" in migration
    assert "Do not choose a branch automatically." in migration
    # A preflight must never silently rewrite users' access assignments.
    assert "UPDATE organizational_assignments" not in migration.upper()
    assert "DELETE FROM organizational_assignments" not in migration.upper()


def test_existing_branch_conflict_preflight_is_in_the_migration_chain():
    migration_names = sorted(
        path.name for path in Path("migrations").glob("[0-9][0-9][0-9][0-9]_*.sql")
    )
    assert "0032_preflight_existing_branch_assignment_conflicts.sql" in migration_names
