from pathlib import Path

from fastapi.testclient import TestClient

from main import app


def _csv(name: str, body: str):
    return ("files", (name, body.encode("utf-8"), "text/csv"))


def test_detail_analysis_accepts_multiple_multipart_csv_files():
    client = TestClient(app)
    response = client.post(
        "/v2/detail-analysis",
        files=[
            _csv("orders.csv", "order_id,amount\nO1,10\n"),
            _csv("customers.csv", "customer_id,name\nC1,A\n"),
            _csv("products.csv", "product_id,name\nP1,Widget\n"),
            _csv("regions.csv", "region_id,name\nR1,North\n"),
        ],
    )

    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    assert {item["name"] for item in body["datasets"]} == {"orders", "customers", "products", "regions"}


def test_powerbi_detail_analysis_uses_shared_read_only_contract():
    client = TestClient(app)
    response = client.post(
        "/powerbi/detail-analysis",
        files=[
            _csv("orders.csv", "order_id,amount\nO1,10\n"),
            _csv("customers.csv", "customer_id,name\nC1,A\n"),
        ],
    )

    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    assert body["source_platform"] == "power_bi"
    assert {item["name"] for item in body["datasets"]} == {"orders", "customers"}


def test_powerbi_detail_analysis_rejects_missing_files_cleanly():
    response = TestClient(app).post("/powerbi/detail-analysis")
    assert response.status_code == 200
    assert response.json() == {"success": False, "error": "No files submitted for detail analysis."}


def test_powerbi_customer_clean_returns_new_dimension_without_source_write():
    response = TestClient(app).post(
        "/powerbi/customer-clean",
        files=[_csv("customers.csv", "customer_id,name\nC1,A\nC1,A\n")],
    )
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    assert body["dimension_name"] == "dim_customer"
    assert body["summary"]["clean_rows"] == 1
    assert body["summary"]["final_duplicate_key_groups"] == 0
    assert body["read_only"] is True


def test_powerbi_product_clean_returns_new_dimension():
    response = TestClient(app).post(
        "/powerbi/product-clean",
        files=[_csv("products.csv", "product_id,category,sub_category\nP1, Electronics ,Phones\nP2,electronics,Phones\n")],
    )
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    assert body["dimension_name"] == "dim_product"
    assert body["summary"]["clean_rows"] == 2


def test_powerbi_order_clean_returns_reconciled_fact_without_source_write():
    response = TestClient(app).post(
        "/powerbi/order-clean",
        files=[
            _csv("orders.csv", "transaction_id,transaction_date,customer_id,quantity,sales\nT1,2025-01-01,C1,-1,10\nT1,2025-01-01,C1,-1,10\nT2,bad,,2,20\n"),
            _csv("customers.csv", "customer_id\nC1\n"),
        ],
    )
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    assert body["fact_name"] == "fact_orders"
    assert body["summary"]["clean_rows"] == 2
    assert body["summary"]["exact_duplicates_removed"] == 1
    assert body["summary"]["is_return_true"] == 1
    assert body["summary"]["invalid_date_rows"] == 1
    assert body["raw_source_unchanged"] is True


def test_powerbi_date_dimension_builds_from_prompt4_fact():
    response = TestClient(app).post(
        "/powerbi/date-dimension",
        files=[
            _csv("orders.csv", "order_id,order_date,customer_id,quantity\nO1,2024-02-29,C1,1\nO2,bad,C1,2\nO3,2025-01-01,C1,3\n"),
            _csv("customers.csv", "customer_id\nC1\n"),
        ],
    )
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    assert body["source_fact"] == "fact_orders"
    assert body["summary"]["unique_valid_dates"] == 2
    assert body["summary"]["invalid_fact_date_rows_excluded"] == 1
    assert body["relationship"]["valid_fact_date_coverage"] == 1.0
    assert body["raw_source_unchanged"] is True


def test_powerbi_business_analysis_returns_structured_chapter6_outputs():
    response = TestClient(app).post(
        "/powerbi/business-analysis",
        files=[
            _csv("orders.csv", "order_id,order_date,customer_id,product_id,region_id,quantity,sales_amount,profit\nO1,2025-01-01,C1,P1,R1,1,100,10\nO2,2025-02-01,C1,P1,R1,1,50,5\n"),
            _csv("customers.csv", "customer_id\nC1\n"),
            _csv("products.csv", "product_id,product_name\nP1,Alpha\n"),
            _csv("regions.csv", "region_id,region\nR1,North\n"),
        ],
    )
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    assert body["reconciliation"]["all_reconciled"] is True
    assert len(body["top_products_by_revenue"]["rows"]) == 1
    assert body["regional_profit"]["rows"][0]["region"] == "North"
    assert body["monthly_performance"]["rows"][0]["month_key"] == "2025-01"
    assert body["source_data_unchanged"] is True


def test_powerbi_dashboard_returns_filterable_kpis_and_preserves_sources():
    response = TestClient(app).post(
        "/powerbi/dashboard",
        data={"year": "2025", "region": "North", "category": "Electronics"},
        files=[
            _csv("orders.csv", "order_id,order_date,customer_id,product_id,region_id,quantity,sales_amount,profit\nO1,2025-01-01,C1,P1,R1,1,100,20\nO2,2024-01-01,C1,P1,R1,1,50,5\n"),
            _csv("customers.csv", "customer_id,name\nC1,A\n"),
            _csv("products.csv", "product_id,product_name,category\nP1,Phone,Electronics\n"),
            _csv("regions.csv", "region_id,region\nR1,North\n"),
        ],
    )
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    assert body["kpis"] == {"revenue": 100.0, "profit": 20.0, "orders": 1, "customers": 1, "profit_margin": 0.2, "return_rate": 0.0}
    assert body["active_filters"] == {"year": 2025, "region": "North", "category": "Electronics"}
    assert body["reconciliation"]["all_reconciled"] is True
    assert body["read_only"] is True
    assert body["source_data_unchanged"] is True


def test_detail_analysis_rejects_empty_and_unsupported_uploads_cleanly():
    client = TestClient(app)

    empty = client.post("/v2/detail-analysis")
    assert empty.status_code == 200
    assert empty.json() == {"success": False, "error": "No files submitted for detail analysis."}

    unsupported = client.post(
        "/v2/detail-analysis",
        files=[("files", ("notes.txt", b"not a dataset", "text/plain"))],
    )
    assert unsupported.status_code == 200
    assert unsupported.json()["success"] is False
    assert "unsupported files: notes.txt" in unsupported.json()["error"]


def test_detail_upload_contract_uses_multi_file_browser_state():
    root = Path(__file__).resolve().parent.parent
    html = (root / "frontend" / "index.html").read_text(encoding="utf-8")
    javascript = (root / "frontend" / "app.js").read_text(encoding="utf-8")

    assert 'id="detailFiles" type="file" multiple' in html
    assert "webkitdirectory" not in html
    assert "detailFileStatus" in html
    assert "selectedDetailFiles = Array.from(files || [])" in javascript
    assert 'form.append("files", file, file.name)' in javascript
