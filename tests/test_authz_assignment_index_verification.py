"""Regression tests for organizational assignment schema verification."""

import unittest

from tools.run_authz_migrations import verify_assignment_indexes


class AssignmentIndexVerificationTests(unittest.TestCase):
    def test_schema_after_migration_0033_is_valid(self):
        # Migration 0033 removes the manager-only index; the active assignment
        # context index remains the integrity constraint.
        verify_assignment_indexes({
            "uq_active_assignment_context": (
                "CREATE UNIQUE INDEX uq_active_assignment_context "
                "ON public.organizational_assignments "
                "(organization_id, principal_id, location_id, section_id, role_id) "
                "WHERE (status = 'active'::text)"
            )
        })

    def test_multiple_managers_are_not_rejected_by_schema_verifier(self):
        # The schema no longer has a location-wide uniqueness constraint on
        # Manager. Different principals can therefore be active Managers at
        # the same location while per-person assignment context stays unique.
        verify_assignment_indexes({
            "uq_active_assignment_context": (
                "CREATE UNIQUE INDEX uq_active_assignment_context "
                "ON public.organizational_assignments "
                "(organization_id, principal_id, location_id, section_id, role_id) "
                "WHERE (status = 'active'::text)"
            )
        })

    def test_missing_or_incomplete_integrity_index_fails(self):
        with self.assertRaisesRegex(RuntimeError, "Missing uq_active_assignment_context"):
            verify_assignment_indexes({})

        with self.assertRaisesRegex(RuntimeError, "missing required assignment keys"):
            verify_assignment_indexes({
                "uq_active_assignment_context": (
                    "CREATE UNIQUE INDEX uq_active_assignment_context "
                    "ON organizational_assignments (principal_id) "
                    "WHERE (status = 'active'::text)"
                )
            })

    def test_obsolete_manager_only_index_fails_as_stale_schema(self):
        with self.assertRaisesRegex(RuntimeError, "Obsolete uq_active_manager_per_location"):
            verify_assignment_indexes({
                "uq_active_manager_per_location": (
                    "CREATE UNIQUE INDEX uq_active_manager_per_location "
                    "ON organizational_assignments (location_id) "
                    "WHERE (role_id = 'manager' AND status = 'active')"
                ),
                "uq_active_assignment_context": (
                    "CREATE UNIQUE INDEX uq_active_assignment_context "
                    "ON organizational_assignments "
                    "(organization_id, principal_id, location_id, section_id, role_id) "
                    "WHERE (status = 'active'::text)"
                ),
            })


if __name__ == "__main__":
    unittest.main()
