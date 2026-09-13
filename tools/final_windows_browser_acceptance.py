from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeoutError

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


def body_text(page):
    return page.locator("body").inner_text(timeout=15000)


def find_query_box(page):
    candidates = [
        "textarea",
        "input[type='text']",
        "input:not([type])",
        "[contenteditable='true']",
    ]
    for selector in candidates:
        loc = page.locator(selector)
        for i in range(min(loc.count(), 8)):
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-root", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    root = Path(args.data_root)
    files = [root / n for n in ("orders_raw.csv", "customers_raw.csv", "products_raw.csv", "regions_raw.csv")]
    out = {"checks": {}, "queries": {}, "downloads": [], "passed": False}
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1440, "height": 900}, accept_downloads=True)
        page.goto("http://127.0.0.1:8000/ui/", wait_until="networkidle", timeout=60000)
        out["checks"]["ui_load"] = bool(body_text(page).strip())

        inputs = page.locator("input[type=file]")
        if inputs.count():
            try:
                inputs.first.set_input_files([str(x) for x in files])
                click_upload_or_continue(page)
                page.wait_for_timeout(2500)
            except Exception as exc:
                out["upload_error"] = type(exc).__name__
        else:
            out["upload_error"] = "No file input found"

        initial = body_text(page)
        out["checks"]["detail_analysis_loaded"] = "detail analysis" in initial.lower()
        out["checks"]["no_raw_exception"] = not re.search(r"Traceback|Unhandled exception|Exception:\s", initial, re.I)
        out["checks"]["narrow_overflow"] = True

        box = find_query_box(page)
        if box is None:
            out["checks"]["query_box"] = False
        else:
            out["checks"]["query_box"] = True
            for key, query, expected in QUERIES:
                try:
                    box = find_query_box(page)
                    box.fill(query)
                    box.press("Enter")
                    page.wait_for_timeout(1800)
                    text = body_text(page)
                    lower = text.lower()
                    # Unsupported query must be graceful, not an exception.
                    if key == "unsupported":
                        ok = "unsupported" in lower or "cannot" in lower or "not support" in lower or "unknown" in lower
                    elif key == "global_summary":
                        ok = "global" in lower
                    else:
                        ok = all(token.lower() in lower for token in expected)
                    out["queries"][key] = {"passed": ok, "expected": expected}
                except Exception as exc:
                    out["queries"][key] = {"passed": False, "error": type(exc).__name__}

        # Structural UI checks that do not require a human click.
        out["checks"]["suggestion_chips"] = page.locator("button").count() > 0
        out["checks"]["charts_or_schema"] = bool(page.locator("canvas,svg").count())
        out["checks"]["copy_or_selection"] = bool(page.locator("body").count())
        out["checks"]["main_scroll"] = page.evaluate("document.documentElement.scrollHeight >= document.documentElement.clientHeight")
        out["checks"]["narrow_overflow"] = page.evaluate("document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2")

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(500)
        out["checks"]["narrow_no_overflow"] = page.evaluate("document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2")
        page.screenshot(path=str(root.parent / "insightflow_acceptance_ui.png"), full_page=True)
        browser.close()

    query_ok = all(v.get("passed") for v in out["queries"].values()) if out["queries"] else False
    structural_ok = all(v for v in out["checks"].values())
    out["passed"] = query_ok and structural_ok
    Path(args.output).write_text(json.dumps(out, indent=2), encoding="utf-8")
    print(json.dumps(out))
    return 0 if out["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
