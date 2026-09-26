from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "migrations" / "0008_organizational_structure.sql"


def migration_text():
    return MIGRATION.read_text(encoding="utf-8")


def test_organizational_structure_migration_exists_and_is_additive():
    sql = migration_text()
    assert "CREATE TABLE IF NOT EXISTS locations" in sql
    assert "CREATE TABLE IF NOT EXISTS sections" in sql
    assert "CREATE TABLE IF NOT EXISTS organizational_assignments" in sql

    # Existing authorization tables must not be replaced or dropped.
    assert "DROP TABLE" not in sql
    assert "DROP COLUMN" not in sql


def test_locations_and_sections_are_company_scoped():
    sql = migration_text()
    assert (
        "organization_id TEXT NOT NULL\n"
        "        REFERENCES organizations(organization_id) ON DELETE CASCADE"
    ) in sql
    assert "uq_locations_active_name" in sql
    assert "uq_sections_active_name" in sql


def test_assignment_separates_person_from_organizational_context():
    sql = migration_text()
    assert "principal_id TEXT NOT NULL" in sql
    assert "location_id TEXT" in sql
    assert "role_id TEXT NOT NULL" in sql
    assert "section_id TEXT" in sql
    assert "reports_to_assignment_id TEXT" in sql


def test_assignment_rejects_cross_company_location_section_or_parent():
    sql = migration_text()
    assert "fk_assignment_location_same_org" in sql
    assert "fk_assignment_section_same_org" in sql
    assert "fk_assignment_parent_same_org" in sql
    assert "FOREIGN KEY (organization_id, location_id)" in sql
    assert "FOREIGN KEY (organization_id, section_id)" in sql
    assert "FOREIGN KEY (organization_id, reports_to_assignment_id)" in sql


def test_only_one_active_manager_per_location():
    sql = migration_text()
    assert "uq_active_manager_per_location" in sql
    assert "role_id = 'manager'" in sql
    assert "status = 'active'" in sql


def test_same_principal_can_have_multiple_section_assignments():
    sql = migration_text()
    assert "uq_active_assignment_context" in sql
    assert "COALESCE(section_id, '')" in sql
    assert "COALESCE(location_id, '')" in sql


def test_new_tables_have_row_level_security_enabled():
    sql = migration_text()
    assert "ALTER TABLE locations ENABLE ROW LEVEL SECURITY" in sql
    assert "ALTER TABLE sections ENABLE ROW LEVEL SECURITY" in sql
    assert "ALTER TABLE organizational_assignments ENABLE ROW LEVEL SECURITY" in sql
