from pathlib import Path
import pytest

from tools.migration_reconciliation import (
    QA_DATABASE_HOST,
    QA_PROJECT_REF,
    PRODUCTION_DATABASE_HOST,
    PRODUCTION_PROJECT_REF,
    reconcile,
    repository_manifest,
    validate_dependency_graph,
    validate_manifest,
    load_fixture,
    validate_fixture_target,
)


MIGRATIONS = Path(__file__).parents[1] / "migrations"


def test_maps_existing_excel_history_without_replaying_repository_0037():
    result = reconcile(repository_manifest(MIGRATIONS), [
        "excel_auth_handoff_0037", "excel_auth_pairing_0038",
    ])
    assert result["external_mappings"]["excel_auth_handoff_0037"] == "0037_excel_auth_handoff"
    assert "0037_excel_auth_handoff" not in result["pending_migrations"]
    assert result["external_mappings"]["excel_auth_pairing_0038"] is None
    assert "0038_supabase_function_privilege_hardening" in result["pending_migrations"]


def test_duplicate_prefixes_are_reported_deterministically():
    result = reconcile(repository_manifest(MIGRATIONS), [])
    assert result["duplicate_prefixes"]["0011"] == [
        "0011_allow_unrestricted_branch_identifiers",
        "0011_branch_cleanup_triggers",
    ]


def test_unknown_or_ambiguous_external_history_blocks_plan():
    result = reconcile(repository_manifest(MIGRATIONS), ["excel_auth_pairing_0038", "unknown_0039"])
    assert any(item["migration"] == "unknown_0039" for item in result["blocked_migrations"])


def test_missing_prerequisite_blocks_migration():
    result = reconcile(repository_manifest(MIGRATIONS), [], {
        "0038_supabase_function_privilege_hardening": False,
    })
    assert "0038_supabase_function_privilege_hardening" not in result["proposed_execution_order"]


def test_repository_manifest_contains_both_0037_and_0038_distinctly():
    versions = {item.version for item in repository_manifest(MIGRATIONS)}
    assert "0037_excel_auth_handoff" in versions
    assert "0038_supabase_function_privilege_hardening" in versions


def test_dry_run_rejects_production_target_even_if_declared_as_qa():
    payload = {
        "target": {"project_ref": PRODUCTION_PROJECT_REF, "database_host": PRODUCTION_DATABASE_HOST},
        "external_history": [],
    }
    with pytest.raises(ValueError):
        validate_fixture_target(payload)


def test_dry_run_accepts_only_the_pinned_qa_target():
    validate_fixture_target({
        "target": {"project_ref": QA_PROJECT_REF, "database_host": QA_DATABASE_HOST},
        "external_history": [],
    })


def test_dependency_graph_rejects_direct_self_cycle():
    with pytest.raises(ValueError, match="a -> a"):
        validate_dependency_graph({"a"}, {"a": {"a"}})


def test_dependency_graph_rejects_two_node_cycle():
    with pytest.raises(ValueError, match="a -> b -> a"):
        validate_dependency_graph({"a", "b"}, {"a": {"b"}, "b": {"a"}})


def test_dependency_graph_rejects_three_node_cycle():
    with pytest.raises(ValueError, match="a -> b -> c -> a"):
        validate_dependency_graph({"a", "b", "c"}, {"a": {"b"}, "b": {"c"}, "c": {"a"}})


def test_dependency_graph_accepts_acyclic_graph():
    validate_dependency_graph({"a", "b", "c"}, {"a": {"b"}, "b": {"c"}, "c": set()})


def test_duplicate_history_is_not_executable():
    result = reconcile(repository_manifest(MIGRATIONS), ["excel_auth_handoff_0037"] * 2)
    assert result["plan_executable"] is False
    assert result["proposed_execution_order"] == []


def test_unknown_history_is_not_executable():
    result = reconcile(repository_manifest(MIGRATIONS), ["unknown_external"])
    assert result["plan_executable"] is False
    assert result["proposed_execution_order"] == []


def test_valid_prerequisite_evidence_makes_synthetic_plan_eligible():
    result = reconcile(repository_manifest(MIGRATIONS), [
        "excel_auth_handoff_0037", "excel_auth_pairing_0038",
    ], {"storage:managed-datasets": True, "key:INSIGHTFLOW_PROFILE_PII_KEY": True})
    assert result["plan_executable"] is True
    assert result["proposed_execution_order"]


def test_fixture_rejects_unknown_or_non_boolean_prerequisites(tmp_path):
    import json
    base = {"target": {"project_ref": "xcnjauxmofqkwnpdazpj", "database_host": QA_DATABASE_HOST}, "external_history": []}
    bad = dict(base, prerequisites={"unknown": True})
    path = tmp_path / "bad.json"; path.write_text(json.dumps(bad))
    with pytest.raises(ValueError, match="unknown prerequisite"):
        load_fixture(path)
    bad = dict(base, prerequisites={"storage:managed-datasets": "true"})
    path.write_text(json.dumps(bad))
    with pytest.raises(ValueError, match="boolean"):
        load_fixture(path)


def test_manifest_rejects_duplicate_identity():
    manifest = repository_manifest(MIGRATIONS)
    with pytest.raises(ValueError, match="duplicate"):
        validate_manifest(manifest + [manifest[0]])


def test_manifest_rejects_missing_file():
    manifest = repository_manifest(MIGRATIONS)
    manifest[0] = type(manifest[0])(manifest[0].version, "missing.sql")
    with pytest.raises(ValueError, match="missing"):
        validate_manifest(manifest)


def test_duplicate_external_histories_are_blocked():
    result = reconcile(repository_manifest(MIGRATIONS), ["excel_auth_handoff_0037"] * 2)
    assert any(item["reason"] == "duplicate external migration identity" for item in result["blocked_migrations"])


def test_multiple_duplicate_external_histories_are_all_blocked():
    result = reconcile(repository_manifest(MIGRATIONS), [
        "excel_auth_handoff_0037", "excel_auth_handoff_0037",
        "excel_auth_pairing_0038", "excel_auth_pairing_0038",
    ])
    blocked = {item["migration"] for item in result["blocked_migrations"]}
    assert {"excel_auth_handoff_0037", "excel_auth_pairing_0038"} <= blocked
