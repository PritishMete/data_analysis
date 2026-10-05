from pathlib import Path


def test_manager_and_team_lead_do_not_have_privileged_dataset_management_defaults():
    root = Path(__file__).resolve().parents[1]
    schema = (root / "firebase_authz" / "schema.py").read_text(encoding="utf-8")
    migration = (root / "migrations" / "0028_role_capability_hardening.sql").read_text(encoding="utf-8")

    manager_line = next(
        line for line in schema.splitlines() if '"manager": {' in line
    )
    team_lead_line = next(
        line for line in schema.splitlines() if '"team_lead": {' in line
    )

    for permission in (
        "invitation.manage",
        "working_copy.assign",
        "audit.view",
        "roles.manage",
        "policies.manage",
    ):
        assert permission not in manager_line

    assert "working_copy.assign" not in team_lead_line
    assert "role_id = 'manager'" in migration
    assert "role_id = 'team_lead'" in migration


def test_management_snapshot_and_assignment_profile_use_scoped_authorization():
    root = Path(__file__).resolve().parents[1]
    management_domain = (
        root / "firebase_authz" / "management_domain.py"
    ).read_text(encoding="utf-8")
    provider = (
        root / "firebase_authz" / "supabase_provider.py"
    ).read_text(encoding="utf-8")

    assert "Assignment is outside your management scope." in management_domain
    assert "Only a Branch Head or Organization Owner can assign working copies." in provider
    assert "working_copy_assignments" in provider
    assert "dataset_scope" in provider
