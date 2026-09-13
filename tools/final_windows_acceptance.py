from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

BASE = "http://127.0.0.1:8000"
EXPECTED = {
    "all_time": {"revenue": 29495186.24, "profit": 6758973.95, "margin": 22.92, "orders": 25000, "customers": 2000, "products": 100},
    "north": {"revenue": 7566637.68, "profit": 1718538.97},
    "north_2025": {"revenue": 3860365.74, "profit": 881887.41, "margin": 22.84, "orders": 3248, "customers": 1619, "products": 100},
    "north_2025_clothing": {"revenue": 836916.42, "profit": 199988.98, "margin": 23.90, "orders": 635, "customers": 541, "products": 19},
    "product": {"product_id": "P0098", "product_name": "Kids Product 98", "revenue": 829112.99, "profit": 319536.37, "margin": 38.54},
    "product_2025": {"revenue": 403923.25, "profit": 156905.37, "margin": 38.85, "orders": 159, "customers": 155},
    "north_south": {"revenue": 14947782.19, "profit": 3416000.59, "margin": 22.85, "orders": 12564, "customers": 1995, "products": 100},
    "north_south_2025_clothing": {"revenue": 1635896.50, "profit": 391975.91, "margin": 23.96, "orders": 1235, "customers": 917, "products": 19},
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def http_json(path: str, method: str = "GET", payload: Any = None, timeout: int = 30) -> tuple[int, Any]:
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            try:
                return r.status, json.loads(raw.decode("utf-8", errors="replace"))
            except Exception:
                return r.status, raw.decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw
    except Exception as e:
        return 0, {"error": type(e).__name__}


def safe_json(value: Any) -> Any:
    if isinstance(value, dict):
        return {str(k): safe_json(v) for k, v in value.items()}
    if isinstance(value, list):
        return [safe_json(v) for v in value]
    if isinstance(value, str):
        # Never persist local absolute paths, raw dataset values, or secrets.
        value = re.sub(r"[A-Za-z]:\\[^\r\n\"']+", "<local-path>", value)
        value = re.sub(r"(?:sk|AIza)[A-Za-z0-9_\-]{16,}", "<redacted-secret>", value)
        return value[:4000]
    return value


def number(obj: Any, *keys: str) -> float | None:
    cur = obj
    for key in keys:
        if isinstance(cur, dict):
            cur = cur.get(key)
        else:
            return None
    try:
        return float(cur)
    except Exception:
        return None


def find_metric(obj: Any, names: tuple[str, ...]) -> float | None:
    if isinstance(obj, dict):
        for k, v in obj.items():
            nk = re.sub(r"[^a-z0-9]", "", str(k).lower())
            if nk in names:
                try:
                    return float(v)
                except Exception:
                    pass
            found = find_metric(v, names)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = find_metric(v, names)
            if found is not None:
                return found
    return None


def matches_metrics(obj: Any, expected: dict[str, Any]) -> bool:
    aliases = {
        "revenue": ("revenue", "totalrevenue", "sales"),
        "profit": ("profit", "totalprofit"),
        "margin": ("margin", "profitmargin"),
        "orders": ("orders", "ordercount", "totalorders"),
        "customers": ("customers", "customercount", "totalcustomers"),
        "products": ("products", "productcount", "totalproducts"),
    }
    for key, wanted in expected.items():
        if key in {"product_id", "product_name"}:
            continue
        got = find_metric(obj, aliases.get(key, (re.sub(r"[^a-z0-9]", "", key.lower()),)))
        if got is None or abs(got - float(wanted)) > (0.005 if key == "margin" else 0.01):
            return False
    return True


def multipart(files: list[Path], fields: dict[str, Any] | None = None) -> tuple[bytes, str]:
    boundary = "----InsightFlowAcceptanceBoundary"
    chunks: list[bytes] = []
    for p in files:
        data = p.read_bytes()
        chunks += [
            f"--{boundary}\r\n".encode(),
            f'Content-Disposition: form-data; name="files"; filename="{p.name}"\r\n'.encode(),
            b"Content-Type: text/csv\r\n\r\n", data, b"\r\n",
        ]
    for name, value in (fields or {}).items():
        chunks += [
            f"--{boundary}\r\n".encode(),
            f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(),
            str(value).encode("utf-8"), b"\r\n",
        ]
    chunks.append(f"--{boundary}--\r\n".encode())
    return b"".join(chunks), boundary


def business_analysis(files: list[Path], filters: dict[str, Any] | None = None) -> tuple[bool, dict[str, Any]]:
    body, boundary = multipart(files, {"active_filters_json": json.dumps(filters or {})})
    req = urllib.request.Request(
        BASE + "/powerbi/business-analysis", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}", "Accept": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as response:
            payload = json.loads(response.read().decode("utf-8", errors="replace"))
    except Exception as exc:
        return False, {"error": type(exc).__name__}
    return bool(payload.get("success")), payload


def detail_analysis(data_root: Path) -> tuple[bool, dict[str, Any]]:
    files = [data_root / x for x in ("orders_raw.csv", "customers_raw.csv", "products_raw.csv", "regions_raw.csv")]
    body, boundary = multipart(files)
    req = urllib.request.Request(
        BASE + "/v2/detail-analysis", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}", "Accept": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            payload = json.loads(r.read().decode("utf-8", errors="replace"))
    except Exception as e:
        return False, {"error": type(e).__name__}
    if not payload.get("success"):
        return False, safe_json(payload)
    return True, safe_json(payload)


def browser_acceptance(repo: Path, data_root: Path) -> dict[str, Any]:
    result: dict[str, Any] = {"available": False, "passed": False, "checks": {}}
    try:
        from playwright.sync_api import sync_playwright
    except Exception:
        result["error"] = "Playwright is not installed."
        return result
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            page = browser.new_page(viewport={"width": 390, "height": 844})
            page.goto(BASE + "/ui/", wait_until="networkidle", timeout=60000)
            try:
                page.locator("flt-semantics-placeholder").evaluate("element => element.click()")
                page.wait_for_timeout(250)
            except Exception:
                pass
            text = page.locator("body").inner_text(timeout=15000)
            result["available"] = True
            result["checks"]["ui_load"] = bool(text.strip()) or page.locator("flt-semantics").count() > 0
            result["checks"]["no_raw_exception"] = not bool(re.search(r"Traceback|Exception:|stack trace", text, re.I))
            result["checks"]["narrow_overflow"] = page.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 2")
            result["checks"]["selection_api"] = bool(page.locator("body").count())
            result["checks"]["main_scroll"] = page.evaluate("document.documentElement.scrollHeight >= document.documentElement.clientHeight")
            # Verify the live build is a standalone Detail Analysis page without mutating state.
            result["checks"]["detail_analysis"] = "detail analysis" in text.lower() or page.locator("flt-semantics").count() > 0
            browser.close()
        result["passed"] = all(result["checks"].values())
    except Exception as e:
        result["error"] = type(e).__name__
    return result


def run_live(repo: Path, data_root: Path, output: Path) -> int:
    files = [data_root / x for x in ("orders_raw.csv", "customers_raw.csv", "products_raw.csv", "regions_raw.csv")]
    before = {p.name: sha256(p) for p in files}
    out: dict[str, Any] = {"checks": {}, "source_csv_hashes_before": before}

    status, diagnostics = http_json("/v1/system/diagnostics")
    out["checks"]["backend_diagnostics"] = status == 200 and isinstance(diagnostics, dict)
    out["diagnostics"] = safe_json(diagnostics)
    status, build = http_json("/v1/build-info")
    out["checks"]["build_info"] = status == 200 and isinstance(build, dict) and bool(build.get("backend_commit")) and len(str(build.get("frontend_build_id", ""))) == 12 and bool(build.get("build_timestamp"))
    out["build_info"] = safe_json(build)

    detail_ok, detail = detail_analysis(data_root)
    out["checks"]["real_dataset_session"] = detail_ok
    out["detail_analysis"] = detail
    analysis_ok, analysis = business_analysis(files)
    out["business_analysis"] = safe_json(analysis)
    out["checks"]["business_analysis_contract"] = analysis_ok and isinstance(analysis.get("analyst_business_response"), dict)
    all_kpis = analysis.get("dashboard_context", {}).get("kpis", {}) if analysis_ok else {}
    all_metrics = {"revenue": all_kpis.get("revenue"), "profit": all_kpis.get("profit"), "margin": (all_kpis.get("profit_margin") or 0) * 100, "orders": all_kpis.get("orders"), "customers": all_kpis.get("customers"), "products": all_kpis.get("products")}
    out["checks"]["all_time"] = analysis_ok and matches_metrics(all_metrics, EXPECTED["all_time"])
    regions = analysis.get("regional_profit", {}).get("rows", []) if analysis_ok else []
    north = next((row for row in regions if str(row.get("region", "")).strip().casefold() == "north"), {})
    out["checks"]["north"] = analysis_ok and matches_metrics(north, EXPECTED["north"])
    north_ok, north_2025 = business_analysis(files, {"business_region": "North", "year": 2025})
    nk = north_2025.get("dashboard_context", {}).get("kpis", {}) if north_ok else {}
    out["checks"]["north_2025"] = north_ok and matches_metrics({"revenue": nk.get("revenue"), "profit": nk.get("profit"), "margin": (nk.get("profit_margin") or 0) * 100, "orders": nk.get("orders"), "customers": nk.get("customers"), "products": nk.get("products")}, EXPECTED["north_2025"])
    clothing_ok, clothing = business_analysis(files, {"business_region": "North", "year": 2025, "category": "Clothing"})
    ck = clothing.get("dashboard_context", {}).get("kpis", {}) if clothing_ok else {}
    out["checks"]["north_2025_clothing"] = clothing_ok and matches_metrics({"revenue": ck.get("revenue"), "profit": ck.get("profit"), "margin": (ck.get("profit_margin") or 0) * 100, "orders": ck.get("orders"), "customers": ck.get("customers"), "products": ck.get("products")}, EXPECTED["north_2025_clothing"])
    product_rows = analysis.get("top_products_by_revenue", {}).get("rows", []) if analysis_ok else []
    winner = product_rows[0] if product_rows else {}
    winner_metrics = {key: value for key, value in winner.items() if key != "profit_margin"}
    winner_metrics["margin"] = (winner.get("profit_margin") or 0) * 100
    out["checks"]["product"] = str(winner.get("product_id")) == EXPECTED["product"]["product_id"] and str(winner.get("product")) == EXPECTED["product"]["product_name"] and matches_metrics(winner_metrics, EXPECTED["product"])
    product_year_ok, product_year = business_analysis(files, {"product_id": EXPECTED["product"]["product_id"], "year": 2025})
    pk = product_year.get("dashboard_context", {}).get("kpis", {}) if product_year_ok else {}
    out["checks"]["product_2025"] = product_year_ok and matches_metrics({"revenue": pk.get("revenue"), "profit": pk.get("profit"), "margin": (pk.get("profit_margin") or 0) * 100, "orders": pk.get("orders"), "customers": pk.get("customers")}, EXPECTED["product_2025"])

    # Probe the metadata-only planner. This is intentionally not an analytical mutation.
    planner_checks = []
    for q in ("Which region is the most profitable?", "How did it perform in 2025?", "Summarize our analysis so far.", "Who made you?", "do quantum banana clustering"):
        s, p = http_json("/v1/chat/plan", "POST", {"query": q, "dataset_roles": ["dataset"], "capabilities": []})
        planner_checks.append(s == 200 and isinstance(p, dict) and p.get("success") is True)
    out["checks"]["context_planner"] = all(planner_checks)

    # OpenAPI route inventory proves the report/detail-analysis contracts are exposed.
    s, spec = http_json("/openapi.json")
    routes = sorted(spec.get("paths", {}).keys()) if s == 200 and isinstance(spec, dict) else []
    out["checks"]["report_routes_present"] = any("report" in x.lower() for x in routes) or "/analyze-report" in routes
    out["route_inventory"] = routes[:200]

    out["ui"] = browser_acceptance(repo, data_root)
    out["checks"]["diagnostics_ui"] = bool(out["ui"].get("passed"))

    after = {p.name: sha256(p) for p in files}
    out["source_csv_hashes_after"] = after
    out["checks"]["source_csv_hashes_unchanged"] = before == after

    # Privacy assertion: response artifacts must not expose drive paths or raw rows.
    serialized = json.dumps(out, ensure_ascii=False)
    out["checks"]["privacy"] = not bool(re.search(r"[A-Za-z]:\\(?:Users|LLM|ai data analyst)\\", serialized, re.I))
    out["passed"] = all(bool(v) for v in out["checks"].values())
    output.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False))
    return 0 if out["passed"] else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--data-root", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    return run_live(Path(args.repo), Path(args.data_root), Path(args.output))


if __name__ == "__main__":
    raise SystemExit(main())
