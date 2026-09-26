from firebase_authz.routes import router

EXPECTED_ROUTES={
    ("/v1/authz/organizations/locations","GET"),("/v1/authz/organizations/locations","POST"),
    ("/v1/authz/organizations/sections","GET"),("/v1/authz/organizations/sections","POST"),
    ("/v1/authz/organizations/assignments","GET"),("/v1/authz/organizations/assignments","POST"),
}

def test_organizational_structure_routes_exist():
    routes={(r.path,m) for r in router.routes for m in getattr(r,"methods",set())}
    assert EXPECTED_ROUTES <= routes

def test_organizational_structure_routes_use_supabase_provider(monkeypatch):
    from firebase_authz import routes
    calls=[]
    monkeypatch.setattr(routes,"verify_id_token",lambda token:{"uid":"u1","sub":"u1"})
    monkeypatch.setattr(routes,"list_locations",lambda claims,workspace_id,include_inactive:calls.append(("locations",workspace_id)) or {"locations":[]})
    monkeypatch.setattr(routes,"list_sections",lambda claims,workspace_id,include_inactive:calls.append(("sections",workspace_id)) or {"sections":[]})
    monkeypatch.setattr(routes,"list_assignments",lambda claims,workspace_id,include_inactive:calls.append(("assignments",workspace_id)) or {"assignments":[]})
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER","supabase")
    from main import app
    from fastapi.testclient import TestClient
    client=TestClient(app); headers={"Authorization":"Bearer token"}
    assert client.get("/v1/authz/organizations/locations",params={"workspace_id":"org1"},headers=headers).status_code==200
    assert client.get("/v1/authz/organizations/sections",params={"workspace_id":"org1"},headers=headers).status_code==200
    assert client.get("/v1/authz/organizations/assignments",params={"workspace_id":"org1"},headers=headers).status_code==200
    assert calls==[("locations","org1"),("sections","org1"),("assignments","org1")]

def test_organizational_structure_rejects_non_supabase_provider(monkeypatch):
    from firebase_authz import routes
    monkeypatch.setattr(routes,"verify_id_token",lambda token:{"uid":"u1","sub":"u1"})
    monkeypatch.setenv("AUTHZ_PERSISTENCE_PROVIDER","firebase")
    from main import app
    from fastapi.testclient import TestClient
    response=TestClient(app).get("/v1/authz/organizations/locations",params={"workspace_id":"org1"},headers={"Authorization":"Bearer token"})
    assert response.status_code==403
