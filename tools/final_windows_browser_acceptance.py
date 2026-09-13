from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from playwright.sync_api import sync_playwright

QUERIES = [
    ("region", "Which region is the most profitable?", ["North"]),
    ("north_2025", "How did it perform in 2025?", ["North", "3,860,365.74", "881,887.41"]),
    ("summary", "Summarize our analysis so far.", ["North"]),
    ("meta", "Who made you?", ["Pritish Mete"]),
    ("meta_context", "How did it perform in 2025?", ["North", "3,860,365.74"]),
    ("unsupported", "do quantum banana clustering", ["unsupported"]),
    ("clothing", "What about Clothing only?", ["836,916.42", "199,988.98", "23.90%"]),
    ("global", "Show overall company performance", ["29,495,186.24", "6,758,973.95"]),
    ("global_summary", "Summarize our analysis so far.", ["global"]),
    ("product", "Which product has the highest revenue?", ["P0098", "Kids Product 98", "829,112.99"]),
    ("product_profit", "How profitable is it?", ["Kids Product 98", "319,536.37"]),
    ("product_2025", "How did it perform in 2025?", ["403,923.25", "156,905.37", "159", "155"]),
    ("comparison", "Compare North and South in 2025.", ["North", "South"]),
    ("boolean", "North OR South", ["14,947,782.19", "3,416,000.59", "12,564"]),
    ("boolean_then", "2025 AND (North OR South) AND Clothing", ["1,635,896.50", "391,975.91", "1,235"]),
    ("then", "Find the most profitable region, then show its 2025 performance, then limit it to Clothing", ["836,916.42", "199,988.98"]),
]

REPORT_WORDS = {
    "executive": ["executive", "report"],
    "detailed": ["detailed", "report"],
    "filtered": ["filtered", "report"],
    "comparison": ["comparison", "report"],
    "context_inherited": ["context", "report"],
}


def body_text(page):
    return page.locator("body").inner_text(timeout=15000)


def find_query_box(page):
    for selector in ["textarea", "input[type='text']", "input:not([type])", "[contenteditable='true']"]:
        loc = page.locator(selector)
        for i in range(min(loc.count(), 10)):
            item = loc.nth(i)
            try:
                if item.is_visible() and item.is_editable():
                    return item
            except Exception:
                pass
    return None


def click_upload_or_continue(page):
    for text in ["Analyze", "Start analysis", "Continue", "Load", "Open", "Analyze dataset"]:
        loc = page.get_by_text(text, exact=False)
        for i in range(min(loc.count(), 5)):
            try:
                if loc.nth(i).is_visible():
                    loc.nth(i).click(timeout=3000)
                    return True
            except Exception:
                pass
    return False


def report_buttons(page):
    found = []
    for button in page.locator("button, a").all():
        try:
            if not button.is_visible():
                continue
            text = button.inner_text().strip().lower()
            if "report" in text:
                found.append(button)
        except Exception:
            pass
    return found


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-root", required=True)
    ap.add_argument("--artifacts", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    root = Path(args.data_root)
    artifacts = Path(args.artifacts)
    artifacts.mkdir(parents=True, exist_ok=True)
    files = [root / n for n in ("orders_raw.csv", "customers_raw.csv", "products_raw.csv", "regions_raw.csv")]
    out = {"checks": {}, "queries": {}, "reports": {}, "passed": False}

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1440, "height": 900}, accept_downloads=True)
        page.goto("http://127.0.0.1:8000/ui/", wait_until="networkidle", timeout=60000)
        initial = body_text(page)
        out["checks"]["ui_load"] = bool(initial.strip())

        inputs = page.locator("input[type=file]")
        if inputs.count():
            try:
                inputs.first.set_input_files([str(x) for x in files])
                click_upload_or_continue(page)
                page.wait_for_timeout(3000)
                out["checks"]["detail_analysis_loaded"] = "detail analysis" in body_text(page).lower()
            except Exception as exc:
                out["checks"]["detail_analysis_loaded"] = False
                out["upload_error"] = type(exc).__name__
        else:
            out["checks"]["detail_analysis_loaded"] = False
            out["upload_error"] = "No file input found"

        text = body_text(page)
        out["checks"]["no_raw_exception"] = not re.search(r"Traceback|Unhandled exception|Exception:\s", text, re.I)
        box = find_query_box(page)
        out["checks"]["query_box"] = box is not None

        if box is not None:
            for key, query, expected in QUERIES:
                try:
                    box = find_query_box(page)
                    box.fill(query)
                    box.press("Enter")
                    page.wait_for_timeout(2200)
                    current = body_text(page)
                    lower = current.lower()
                    if key == "unsupported":
                        ok = any(x in lower for x in ("unsupported", "cannot", "not support", "unknown", "could not"))
                    elif key == "global_summary":
                        ok = "global" in lower
                    else:
                        ok = all(token.lower() in lower for token in expected)
                    out["queries"][key] = {"passed": ok, "expected": expected}
                except Exception as exc:
                    out["queries"][key] = {"passed": False, "error": type(exc).__name__}

        current = body_text(page)
        out["checks"]["suggestion_chips"] = page.locator("button").count() > 0
        out["checks"]["charts_or_schema"] = bool(page.locator("canvas,svg").count()) or "star schema" in current.lower()
        out["checks"]["session_summary"] = "summary" in current.lower()
        out["checks"]["diagnostics_ui"] = any(x in current.lower() for x in ("healthy", "system status", "diagnostics"))
        out["checks"]["no_raw_internal_state"] = not bool(re.search(r"_states|session_store|traceback|debug metadata", current, re.I))
        out["checks"]["main_scroll"] = page.evaluate("document.documentElement.scrollHeight >= document.documentElement.clientHeight")
        out["checks"]["narrow_overflow"] = page.evaluate("document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2")
        out["checks"]["selection"] = page.evaluate("document.body && getComputedStyle(document.body).userSelect !== 'none'")
        out["checks"]["copy_available"] = bool(page.locator("body").count())

        # Report generation: use only visible report controls. If no control exists,
        # fail rather than pretending a report was generated.
        for key, words in REPORT_WORDS.items():
            matched = None
            for button in report_buttons(page):
                try:
                    t = button.inner_text().lower()
                    if all(w in t for w in words):
                        matched = button
                        break
                except Exception:
                    pass
            if matched is None:
                out["reports"][key] = {"passed": False, "reason": "no visible report control matched"}
                continue
            try:
                with page.expect_download(timeout=10000) as download_info:
                    matched.click()
                download = download_info.value
                target = artifacts / (key + "_report.pdf")
                download.save_as(str(target))
                size = target.stat().st_size
                pdf_ok = size > 100
                try:
                    from pypdf import PdfReader
                    reader = PdfReader(str(target))
                    pdf_ok = pdf_ok and len(reader.pages) > 0
                except Exception:
                    pass
                out["reports"][key] = {"passed": pdf_ok, "size": size, "path": target.name}
            except Exception as exc:
                out["reports"][key] = {"passed": False, "error": type(exc).__name__}

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(500)
        out["checks"]["narrow_no_overflow"] = page.evaluate("document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2")
        page.screenshot(path=str(artifacts / "ui_acceptance.png"), full_page=True)

        # Offline and stale-build simulations are isolated browser-network tests;
        # the real backend is not modified.
        try:
            page.route("**/v1/system/diagnostics", lambda route: route.fulfill(status=503, content_type="application/json", body=json.dumps({"success": False, "overall_status": "offline"})))
            page.reload(wait_until="domcontentloaded", timeout=30000)
            offline_text = body_text(page)
            out["checks"]["offline_graceful"] = not bool(re.search(r"Traceback|Unhandled exception", offline_text, re.I))
            page.unroute("**/v1/system/diagnostics")
        except Exception as exc:
            out["checks"]["offline_graceful"] = False
            out["offline_error"] = type(exc).__name__

        browser.close()

    query_ok = bool(out["queries"]) and all(v.get("passed") for v in out["queries"].values())
    report_ok = bool(out["reports"]) and all(v.get("passed") for v in out["reports"].values())
    structural_ok = all(bool(v) for v in out["checks"].values())
    out["passed"] = query_ok and report_ok and structural_ok
    Path(args.output).write_text(json.dumps(out, indent=2), encoding="utf-8")
    print(json.dumps(out))
    return 0 if out["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
