from privacy_policy import LOCAL_ONLY, privacy_status, reject_if_local_only
from ai_privacy import validate_metadata_planner_payload
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


def test_metadata_planner_payload_rejects_workbook_content():
    safe_text, safe_columns, safe_sheets = validate_metadata_planner_payload({
        'text': 'categorize all columns',
        'available_columns': ['Country', 'City'],
        'available_sheets': ['Sheet1'],
    })
    assert safe_text == 'categorize all columns'
    assert safe_columns == ['Country', 'City']
    assert safe_sheets == ['Sheet1']

    for forbidden in (
        {'text': 'categorize', 'rows': [{'Country': 'India'}]},
        {'text': 'categorize', 'values': ['PRIVATE_TEST_VALUE_928371']},
        {'text': 'categorize', 'samples': ['PRIVATE_REVIEW_88127']},
    ):
        try:
            validate_metadata_planner_payload(forbidden)
        except ValueError:
            pass
        else:
            raise AssertionError('expected workbook-shaped payload to be rejected')
