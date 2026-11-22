from pathlib import Path

from common.detail_report import render_detail_report


def test_detail_report_escapes_dataset_and_agent_supplied_html():
    payload = '<img src=x onerror=alert(1)><script>alert(1)</script>'
    report = {
        "overview": [[payload, 1, 1]],
        "schema": {payload: [[payload, "text", "text", payload]]},
        "grains": [payload],
        "keys": [],
        "relationships": [],
        "relationship_notes": [],
        "missing": [],
        "duplicates": [payload],
        "duplicate_analysis": {},
        "duplicate_impact": {},
        "invalid_dates": [],
        "formula_findings": [],
        "ranges": [],
        "inconsistencies": [],
        "categorical_values": [],
        "category_mismatches": [],
        "numeric_profiles": {},
        "date_profiles": {},
        "issue_register": [[payload, payload, payload, "HIGH", payload, payload]],
        "fact_tables": [],
        "dimension_tables": [],
        "star_schema": {},
        "measures": [],
        "fact_grain": "unknown",
        "dimension_attributes": {},
        "star_links": [],
        "kpi_readiness": [],
        "assumptions": [payload],
        "next_steps": [payload],
    }
    result = {
        "detail_report": report,
        "dataset_count": 1,
        "diagnostics": {"ai_used": False},
        "agent_analysis": {"executive_summary": payload},
        "model_readiness": {"status": payload, "evidence": payload},
        "ignored_files": [payload],
    }

    rendered = render_detail_report(result)
    assert "&lt;img" in rendered
    assert "&lt;script&gt;" in rendered
    assert "<img src=x" not in rendered
    assert "<script>alert(1)</script>" not in rendered


def test_frontend_uses_allowlist_sanitizer_before_inserting_report_markup():
    root = Path(__file__).resolve().parents[1]
    source = (root / "frontend" / "app.js").read_text(encoding="utf-8")

    assert "function sanitizeReportHtml(untrustedHtml)" in source
    assert "new DOMParser().parseFromString" in source
    assert "REPORT_HTML_TAGS.has(tag)" in source
    assert "output.replaceChildren(sanitizeReportHtml(formatted.__detailHtml))" in source
    assert "output.innerHTML =" not in source
    assert "safeUrl.protocol !== \"https:\"" in source
    assert "safeUrl.href" in source
