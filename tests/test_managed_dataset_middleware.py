from firebase_authz.middleware import (
    MANAGED_DATASET_SERVICE_AUTH_POLICY,
    managed_dataset_route_policy,
)


def test_managed_dataset_list_remains_workspace_scoped():
    assert managed_dataset_route_policy("GET", "/v1/managed-datasets") is None


def test_managed_dataset_reads_use_dataset_resource_authorization():
    expected = ("dataset.view_original", True)
    assert managed_dataset_route_policy("GET", "/v1/managed-datasets/ds_123") == expected
    assert managed_dataset_route_policy("GET", "/v1/managed-datasets/ds_123/profile") == expected
    assert managed_dataset_route_policy("GET", "/v1/managed-datasets/ds_123/rows") == expected
    assert managed_dataset_route_policy("GET", "/v1/managed-datasets/ds_123/download") == expected


def test_managed_dataset_uploads_use_grant_aware_service_authorization():
    # Upload handlers verify the bearer identity, active role, branch assignment,
    # and (for Managers) a live exact-branch upload grant in the service layer.
    assert managed_dataset_route_policy("POST", "/v1/managed-datasets") == MANAGED_DATASET_SERVICE_AUTH_POLICY
    assert managed_dataset_route_policy("POST", "/v1/managed-datasets/ds_123/versions") == MANAGED_DATASET_SERVICE_AUTH_POLICY


def test_managed_dataset_delete_keeps_resource_authorization():
    assert managed_dataset_route_policy("POST", "/v1/managed-datasets/ds_123/working-copies") == (
        "dataset.create_working_copy",
        True,
    )
    assert managed_dataset_route_policy("DELETE", "/v1/managed-datasets/ds_123") == (
        "dataset.delete",
        True,
    )

def test_proposal_and_manager_grant_routes_use_their_service_authorization():
    # These handlers validate Supabase identity, active membership, role and
    # exact branch scope themselves. The generic middleware must not treat
    # fixed route names as dataset IDs or require a generic resource header.
    service_authorized = MANAGED_DATASET_SERVICE_AUTH_POLICY
    routes = [
        ("GET", "/v1/managed-datasets/proposals"),
        ("POST", "/v1/managed-datasets/proposals"),
        ("POST", "/v1/managed-datasets/ds_123/proposals"),
        ("POST", "/v1/managed-datasets/proposals/dsp_123/decision"),
        ("GET", "/v1/managed-datasets/upload-grants"),
        ("POST", "/v1/managed-datasets/upload-grants"),
        ("DELETE", "/v1/managed-datasets/upload-grants/mug_123"),
        ("GET", "/v1/managed-datasets/working-copies/wc_123/profile"),
        ("GET", "/v1/managed-datasets/working-copies/wc_123/rows"),
    ]
    for method, path in routes:
        assert managed_dataset_route_policy(method, path) == service_authorized

