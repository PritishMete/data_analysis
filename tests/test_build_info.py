from fastapi.testclient import TestClient

from main import app


def test_build_info_identifies_the_deployed_flutter_bundle_without_private_paths():
    payload = TestClient(app).get("/v1/build-info").json()
    assert payload["backend_commit"]
    assert payload["frontend_build_id"]
    assert payload["build_timestamp"]
    assert len(payload["frontend_build_id"]) == 12
    serialized = str(payload)
    assert "data_analysis-main" not in serialized
    assert "InsightFlow" not in serialized
    assert "C:\\" not in serialized
