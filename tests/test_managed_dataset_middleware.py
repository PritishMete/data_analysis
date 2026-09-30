from firebase_authz.middleware import managed_dataset_route_policy


def test_managed_dataset_list_remains_workspace_scoped():
    assert managed_dataset_route_policy("GET", "/v1/managed-datasets") is None


def test_managed_dataset_reads_use_dataset_resource_authorization():
    expected = ("dataset.view_original", True)
    assert managed_dataset_route_policy("GET", "/v1/managed-datasets/ds_123") == expected
    assert managed_dataset_route_policy("GET", "/v1/managed-datasets/ds_123/profile") == expected
    assert managed_dataset_route_policy("GET", "/v1/managed-datasets/ds_123/rows") == expected
    assert managed_dataset_route_policy("GET", "/v1/managed-datasets/ds_123/download") == expected


def test_managed_dataset_mutations_keep_existing_resource_policy():
    assert managed_dataset_route_policy("POST", "/v1/managed-datasets") == ("dataset.upload", False)
    assert managed_dataset_route_policy("POST", "/v1/managed-datasets/ds_123/versions") == ("dataset.upload", False)
    assert managed_dataset_route_policy("POST", "/v1/managed-datasets/ds_123/working-copies") == (
        "dataset.create_working_copy",
        True,
    )
    assert managed_dataset_route_policy("DELETE", "/v1/managed-datasets/ds_123") == (
        "dataset.delete",
        True,
    )
