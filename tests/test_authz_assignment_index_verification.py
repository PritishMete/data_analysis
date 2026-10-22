"""Regression tests for the exact PostgreSQL assignment-context index contract."""

import unittest

from tools.run_authz_migrations import verify_assignment_indexes


VALID_INDEX = (
    "CREATE UNIQUE INDEX uq_active_assignment_context "
    "ON public.organizational_assignments USING btree "
    "(organization_id, principal_id, COALESCE(location_id, ''::text), "
    "COALESCE(section_id, ''::text), role_id) WHERE (status = 'active'::text)"
)


class AssignmentIndexVerificationTests(unittest.TestCase):
    def test_expected_complete_index_passes(self):
        verify_assignment_indexes({"uq_active_assignment_context": VALID_INDEX})

    def test_each_required_assignment_key_is_enforced(self):
        invalid_keys = {
            "organization_id": "principal_id, COALESCE(location_id, ''::text), COALESCE(section_id, ''::text), role_id",
            "principal_id": "organization_id, COALESCE(location_id, ''::text), COALESCE(section_id, ''::text), role_id",
            "location_id": "organization_id, principal_id, COALESCE(section_id, ''::text), role_id",
            "section_id": "organization_id, principal_id, COALESCE(location_id, ''::text), role_id",
            "role_id": "organization_id, principal_id, COALESCE(location_id, ''::text), COALESCE(section_id, ''::text)",
        }
        for missing_key, keys in invalid_keys.items():
            with self.subTest(missing_key=missing_key):
                definition = (
                    "CREATE UNIQUE INDEX uq_active_assignment_context "
                    "ON public.organizational_assignments USING btree ("
                    + keys
                    + ") WHERE (status = 'active'::text)"
                )
                with self.assertRaisesRegex(RuntimeError, "incorrect assignment keys"):
                    verify_assignment_indexes({"uq_active_assignment_context": definition})

    def test_identifier_substrings_do_not_satisfy_required_keys(self):
        definition = VALID_INDEX.replace("organization_id", "not_organization_id")
        with self.assertRaisesRegex(RuntimeError, "incorrect assignment keys"):
            verify_assignment_indexes({"uq_active_assignment_context": definition})

    def test_non_unique_index_fails(self):
        definition = VALID_INDEX.replace("CREATE UNIQUE INDEX", "CREATE INDEX", 1)
        with self.assertRaisesRegex(RuntimeError, "must be a unique index"):
            verify_assignment_indexes({"uq_active_assignment_context": definition})

    def test_incorrect_active_predicate_fails(self):
        for predicate in (
            "status = 'inactive'::text",
            "status = 'active'::text OR status = 'inactive'::text",
            "role_id = 'manager' AND status = 'active'::text",
        ):
            with self.subTest(predicate=predicate):
                definition = VALID_INDEX.rsplit(" WHERE ", 1)[0] + " WHERE (" + predicate + ")"
                with self.assertRaisesRegex(RuntimeError, "must apply exactly"):
                    verify_assignment_indexes({"uq_active_assignment_context": definition})

    def test_retired_manager_only_index_is_rejected_as_stale_schema(self):
        with self.assertRaisesRegex(RuntimeError, "Obsolete uq_active_manager_per_location"):
            verify_assignment_indexes({
                "uq_active_manager_per_location": (
                    "CREATE UNIQUE INDEX uq_active_manager_per_location "
                    "ON organizational_assignments USING btree (organization_id, location_id) "
                    "WHERE (status = 'active'::text AND role_id = 'manager'::text)"
                ),
                "uq_active_assignment_context": VALID_INDEX,
            })

    def test_multiple_managers_are_allowed_by_schema_contract(self):
        # The context index is per principal/branch/section/role; there is no
        # longer a location-wide unique Manager index.
        verify_assignment_indexes({"uq_active_assignment_context": VALID_INDEX})

    def test_missing_index_fails(self):
        with self.assertRaisesRegex(RuntimeError, "Missing uq_active_assignment_context"):
            verify_assignment_indexes({})


if __name__ == "__main__":
    unittest.main()
