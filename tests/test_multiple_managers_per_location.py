from pathlib import Path


def test_migration_removes_single_manager_per_location_constraint():
    migration = Path(
        "migrations/0033_allow_multiple_managers_per_location.sql"
    ).read_text()

    assert "DROP INDEX IF EXISTS uq_active_manager_per_location" in migration
    assert "uq_active_assignment_context" in migration


def test_manager_assignment_allows_distinct_managers_in_same_location():
    source = Path("firebase_authz/management_domain.py").read_text()
    start = source.index("def assign_manager(")
    end = source.index("\ndef replace_manager(", start)
    assign_manager = source[start:end]

    assert "This location already has an active manager" not in assign_manager
    assert "principal_id=:principal" in assign_manager
    assert "role_id='manager' AND status='active'" in assign_manager
    assert "management.manager.assigned" in assign_manager


def test_location_summary_exposes_all_active_managers():
    source = Path("firebase_authz/management_domain.py").read_text()
    start = source.index("def _location_summary(")
    end = source.index("\ndef ", start + 5)
    summary = source[start:end]

    assert '"managers": [dict(manager) for manager in managers]' in summary
    assert '"manager_count": len(managers)' in summary
    # Keep the original singular field for existing API consumers.
    assert '"manager": dict(managers[0]) if managers else None' in summary


def test_manager_replacement_does_not_arbitrarily_replace_one_of_many():
    source = Path("firebase_authz/management_domain.py").read_text()
    start = source.index("def replace_manager(")
    end = source.index("\ndef request_team_lead_assignment(", start)
    replacement = source[start:end]

    assert "if len(current_rows) > 1:" in replacement
    assert "replacement requires selecting a specific manager" in replacement
