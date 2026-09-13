from pathlib import Path
import tempfile

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
    assert body["analyst_business_response"]["response_type"] == "analyst_business_response"
    assert body["analyst_business_response"]["tables"]["business_regions"]["rows"][0]["region"] == "North"


def test_powerbi_business_analysis_applies_chat_followup_filters():
    response = TestClient(app).post(
        "/powerbi/business-analysis",
        data={"active_filters_json": '{"business_region":"North","year":2025}'},
        files=[
            _csv("orders.csv", "order_id,order_date,customer_id,product_id,region_id,quantity,sales_amount,profit\nO1,2025-01-01,C1,P1,R1,1,100,10\nO2,2024-01-01,C1,P1,R1,1,50,5\nO3,2025-01-01,C1,P2,R2,1,25,3\n"),
            _csv("customers.csv", "customer_id\nC1\n"),
            _csv("products.csv", "product_id,product_name,category\nP1,Alpha,Electronics\nP2,Beta,Books\n"),
            _csv("regions.csv", "region_id,region\nR1,North\nR2,South\n"),
        ],
    )
    body = response.json()
    assert response.status_code == 200
    assert body["success"] is True
    assert body["active_filters"] == {"year": 2025, "business_region": "North"}
    assert body["dashboard_context"]["kpis"]["revenue"] == 100.0
    assert body["dashboard_context"]["kpis"]["orders"] == 1
    assert body["analyst_business_response"]["kpis"][0]["value"] == "100.00"
    assert body["source_data_unchanged"] is True


def test_powerbi_business_analysis_aggregates_multiple_region_keys_by_business_region():
    response = TestClient(app).post(
        "/powerbi/business-analysis",
        files=[
            _csv("orders.csv", "order_id,order_date,customer_id,product_id,region_id,quantity,sales_amount,profit\nO1,2025-01-01,C1,P1,R1,1,100,10\nO2,2025-01-02,C1,P1,R2,1,200,30\nO3,2025-01-03,C1,P1,R3,1,50,15\n"),
            _csv("customers.csv", "customer_id\nC1\n"),
            _csv("products.csv", "product_id,product_name,category\nP1,Alpha,Electronics\n"),
            _csv("regions.csv", "region_id,region\nR1,North\nR2,North\nR3,South\n"),
        ],
    )
    body = response.json()
    assert response.status_code == 200
    assert body["success"] is True
    assert body["regional_profit"]["rows"][0]["region"] == "North"
    assert body["regional_profit"]["rows"][0]["profit"] == 40.0
    assert body["business_region_profit"] == body["regional_profit"]


def test_powerbi_chat_report_request_returns_downloadable_local_pdf():
    client = TestClient(app)
    response = client.post(
        "/powerbi/business-analysis",
        data={"query": "Generate an executive report"},
        files=[
            _csv("orders.csv", "order_id,order_date,customer_id,product_id,region_id,quantity,sales_amount,profit\nO1,2025-01-01,C1,P1,R1,1,100,20\n"),
            _csv("customers.csv", "customer_id\nC1\n"),
            _csv("products.csv", "product_id,product_name,category\nP1,Alpha,Electronics\n"),
            _csv("regions.csv", "region_id,region\nR1,North\n"),
        ],
    )
    body = response.json()
    assert response.status_code == 200
    assert body["report_type"] == "executive"
    assert body["report"]["filename"].endswith(".pdf")
    pdf = client.get(body["download_url"])
    assert pdf.status_code == 200
    assert pdf.headers["content-type"] == "application/pdf"
    assert pdf.content.startswith(b"%PDF-")
    (Path(tempfile.gettempdir()) / "insightflow_reports" / body["filename"]).unlink(missing_ok=True)


def test_context_inherited_report_filename_is_downloadable():
    client = TestClient(app)
    response = client.post(
        "/powerbi/business-analysis",
        data={"query": "Generate a context_inherited report"},
        files=[
            _csv("orders.csv", "order_id,order_date,customer_id,product_id,region_id,quantity,sales_amount,profit\nO1,2025-01-01,C1,P1,R1,1,100,20\n"),
            _csv("customers.csv", "customer_id\nC1\n"),
            _csv("products.csv", "product_id,product_name,category\nP1,Alpha,Electronics\n"),
            _csv("regions.csv", "region_id,region\nR1,North\n"),
        ],
    )
    body = response.json()
    assert response.status_code == 200
    assert body["report_type"] == "context_inherited"
    pdf = client.get(body["download_url"])
    assert pdf.status_code == 200
    assert pdf.content.startswith(b"%PDF-")
    (Path(tempfile.gettempdir()) / "insightflow_reports" / body["filename"]).unlink(missing_ok=True)


def test_powerbi_business_query_handles_region_comparison_or_and_then_scope():
    files = [
        _csv("orders.csv", "order_id,order_date,customer_id,product_id,region_id,quantity,sales_amount,profit\nO1,2025-01-01,C1,P1,R1,1,100,40\nO2,2025-01-02,C1,P1,R2,1,60,20\nO3,2025-01-03,C1,P1,R3,1,50,10\n"),
        _csv("customers.csv", "customer_id\nC1\n"),
        _csv("products.csv", "product_id,product_name,category\nP1,Alpha,Clothing\n"),
        _csv("regions.csv", "region_id,region\nR1,North\nR2,North\nR3,South\n"),
    ]
    client = TestClient(app)
    compared = client.post("/powerbi/business-analysis", data={"query": "Compare North and South in 2025."}, files=files).json()
    assert compared["analyst_business_response"]["response_type"] == "analyst_comparison_response"
    assert compared["analyst_business_response"]["comparison"]["rows"][0]["profit"] == 60.0
    assert compared["comparison_context"]["entities"] == ["North", "South"]

    combined = client.post("/powerbi/business-analysis", data={"query": "North OR South"}, files=files).json()
    assert combined["dashboard_context"]["kpis"]["revenue"] == 210.0
    assert combined["active_filters"]["business_region"] == ["North", "South"]

    then_result = client.post(
        "/powerbi/business-analysis",
        data={"query": "Find the most profitable region, then show its 2025 performance, then limit it to Clothing", "active_filters_json": '{"year":2025,"category":"Clothing"}'},
        files=files,
    ).json()
    assert then_result["active_filters"]["business_region"] == "North"
    assert then_result["dashboard_context"]["kpis"]["revenue"] == 160.0


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
    assert body["kpis"] == {"revenue": 100.0, "profit": 20.0, "orders": 1, "customers": 1, "products": 1, "profit_margin": 0.2, "return_rate": 0.0}
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
