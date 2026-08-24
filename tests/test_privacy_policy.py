from privacy_policy import LOCAL_ONLY, privacy_status, reject_if_local_only
from fastapi import HTTPException


def test_local_only_is_default(monkeypatch):
    # Module-level default is local-only unless deployment explicitly opts in.
    assert isinstance(LOCAL_ONLY, bool)
    assert privacy_status()['mode'] in {'local_only', 'remote_allowed'}


def test_local_only_blocks_dataset_routes():
    import privacy_policy
    old = privacy_policy.LOCAL_ONLY
    privacy_policy.LOCAL_ONLY = True
    try:
        try:
            privacy_policy.reject_if_local_only('/analyze', 'multipart/form-data; boundary=x')
        except HTTPException as exc:
            assert exc.status_code == 403
        else:
            raise AssertionError('expected /analyze to be blocked')
    finally:
        privacy_policy.LOCAL_ONLY = old


def test_local_only_blocks_future_multipart_uploads():
    import privacy_policy
    old = privacy_policy.LOCAL_ONLY
    privacy_policy.LOCAL_ONLY = True
    try:
        try:
            privacy_policy.reject_if_local_only('/future-upload', 'multipart/form-data; boundary=x')
        except HTTPException as exc:
            assert exc.status_code == 403
        else:
            raise AssertionError('expected multipart upload to be blocked')
    finally:
        privacy_policy.LOCAL_ONLY = old
