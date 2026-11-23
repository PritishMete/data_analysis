"""Source-level guardrails for employee profile PII protection migrations."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def test_id_proof_fingerprint_has_a_unique_partial_organization_index():
    migration = " ".join(
        _read("migrations/0039_encrypt_profile_pii.sql").split()
    ).casefold()

    assert (
        "create unique index if not exists "
        "uq_member_profiles_org_id_proof_fingerprint"
    ) in migration
    assert (
        "on organization_member_profiles "
        "(organization_id, country_code, id_proof_type, id_proof_fingerprint)"
    ) in migration
    assert "where id_proof_fingerprint is not null" in migration


def test_database_duplicate_guard_uses_fingerprint_not_plaintext_identity():
    migration = _read("migrations/0039_encrypt_profile_pii.sql")
    trigger_start = migration.index(
        "CREATE OR REPLACE FUNCTION public.reject_duplicate_employee_id_proof()"
    )
    trigger_end = migration.index("$$;", trigger_start)
    trigger = migration[trigger_start:trigger_end]

    assert "NEW.id_proof_fingerprint" in trigger
    assert "p.id_proof_fingerprint = NEW.id_proof_fingerprint" in trigger
    assert "pg_advisory_xact_lock" in trigger
    assert "NEW.id_proof_number" not in trigger
    assert "p.id_proof_number" not in trigger


def test_legacy_profile_migration_encrypts_before_dropping_plaintext_columns():
    runner = _read("tools/run_authz_migrations.py")
    start = runner.index("def migrate_profile_pii(engine)")
    end = runner.index("def verify_profile_security(engine)", start)
    migration = runner[start:end]

    assert "protect_profile_value" in migration
    assert "phone_e164" in migration
    assert "id_proof_number" in migration
    assert "phone_ciphertext" in migration
    assert "id_proof_ciphertext" in migration
    assert "Profile PII migration left legacy values" in migration
    assert (
        "ALTER TABLE organization_member_profiles DROP COLUMN IF EXISTS "
        "phone_e164, DROP COLUMN IF EXISTS id_proof_number"
    ) in migration

    run_start = runner.index("def run_migrations()")
    run_end = runner.index("\ndef ", run_start + 5)
    startup = runner[run_start:run_end]
    assert startup.index("migrate_profile_pii(engine)") < startup.index(
        "verify_profile_security(engine)"
    )
