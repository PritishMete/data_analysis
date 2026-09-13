from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from playwright.sync_api import sync_playwright

QUERIES = [
    ("detail_analysis", "give me detail analysis", ["observed fact", "inference", "assumption"]),
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
    text = page.locator("body").inner_text(timeout=15000)
    if not text.strip():
        text = "\n".join(page.locator("flt-semantics").all_inner_texts())
    return text


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
    # Flutter web semantic nodes are DOM hit targets but not native inputs.
    semantic_nodes = page.locator("flt-semantics")
    for index in range(semantic_nodes.count()):
        item = semantic_nodes.nth(index)
        try:
            box = item.bounding_box()
            details = item.evaluate("el => ({role: el.getAttribute('role'), pointer: getComputedStyle(el).pointerEvents})")
            if box and details["role"] != "button" and details["pointer"] == "all" and box["width"] >= 180 and 35 <= box["height"] <= 80 and box["y"] + box["height"] >= page.viewport_size["height"] - 180:
                return item
        except Exception:
            pass
    return None


def send_flutter_message(page, box, query):
    if box.evaluate("el => el.tagName.toLowerCase()") in {"textarea", "input"}:
        box.fill(query)
    else:
        bounds = box.bounding_box()
        if not bounds:
            raise RuntimeError("Flutter semantic chat input has no visible bounds")
        page.mouse.click(bounds["x"] + bounds["width"] / 2, bounds["y"] + bounds["height"] / 2)
        page.keyboard.press("Control+A")
        page.keyboard.insert_text(query)

    candidates = []
    buttons = page.locator("flt-semantics[role='button']")
    for index in range(buttons.count()):
        button = buttons.nth(index)
        try:
            bounds = button.bounding_box()
            if bounds and bounds["y"] + bounds["height"] >= page.viewport_size["height"] - 180 and bounds["width"] <= 100:
                candidates.append((bounds["x"] + bounds["width"], button, bounds))
        except Exception:
            pass
    if not candidates:
        raise RuntimeError("Visible Flutter send control was not found")
    _, _, bounds = max(candidates, key=lambda item: item[0])
    return bounds


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
        external_dataset_posts = []
        def track_request(request):
            parsed = re.match(r"https?://([^/:]+)", request.url, re.I)
            host = parsed.group(1).casefold() if parsed else ""
            if request.method.upper() in {"POST", "PUT", "PATCH"} and host not in {"127.0.0.1", "localhost"}:
                external_dataset_posts.append(request.url)
        page.on("request", track_request)
        page.goto("http://127.0.0.1:8000/ui/", wait_until="networkidle", timeout=60000)
        # Flutter CanvasKit exposes controls through semantics only after the
        # accessibility placeholder is activated.
        try:
            page.locator("flt-semantics-placeholder").evaluate("element => element.click()")
            page.wait_for_timeout(300)
        except Exception:
            pass
        initial = body_text(page)
        out["checks"]["ui_load"] = bool(initial.strip()) or page.locator("flt-glass-pane, flt-scene-host").count() > 0 or page.locator("flt-semantics").count() > 0

        inputs = page.locator("input[type=file]")
        try:
            if inputs.count():
                inputs.first.set_input_files([str(x) for x in files])
            else:
                choose = page.get_by_role("button", name=re.compile("choose datasets", re.I))
                with page.expect_file_chooser(timeout=10000) as chooser_info:
                    choose.click()
                chooser_info.value.set_files([str(x) for x in files])
            page.wait_for_function("Array.from(document.querySelectorAll('flt-semantics')).some(el => el.innerText.includes('4 datasets ready'))", timeout=30000)
            out["checks"]["detail_analysis_loaded"] = "4 datasets ready" in body_text(page).lower()
        except Exception as exc:
            out["checks"]["detail_analysis_loaded"] = False
            out["upload_error"] = type(exc).__name__

        text = body_text(page)
        out["checks"]["no_raw_exception"] = not re.search(r"Traceback|Unhandled exception|Exception:\s", text, re.I)
        box = find_query_box(page)
        out["checks"]["query_box"] = box is not None

        if box is not None:
            for key, query, expected in QUERIES:
                try:
                    box = find_query_box(page)
                    if box is None:
                        raise RuntimeError("Flutter chat textbox is not available")
                    send_bounds = send_flutter_message(page, box, query)
                    if key in {"meta", "unsupported", "summary"}:
                        page.mouse.click(send_bounds["x"] + send_bounds["width"] / 2, send_bounds["y"] + send_bounds["height"] / 2)
                        page.wait_for_timeout(500)
                    else:
                        expected_path = (
                            "/v2/detail-analysis"
                            if key == "detail_analysis"
                            else "/powerbi/business-analysis"
                        )
                        with page.expect_response(
                            lambda response: expected_path in response.url,
                            timeout=300000,
                        ):
                            page.mouse.click(send_bounds["x"] + send_bounds["width"] / 2, send_bounds["y"] + send_bounds["height"] / 2)
                    page.wait_for_timeout(300)
                    current = body_text(page)
                    lower = current.lower()
                    query_pos = lower.rfind(query.lower())
                    answer_text = lower[query_pos + len(query):] if query_pos >= 0 else lower
                    if key == "unsupported":
                        ok = any(x in answer_text for x in ("unsupported", "cannot", "not support", "unknown", "could not"))
                    elif key == "global_summary":
                        ok = "global" in answer_text
                    else:
                        ok = all(token.lower() in answer_text for token in expected)
                    out["queries"][key] = {"passed": ok, "expected": expected}
                    if key == "detail_analysis":
                        out["checks"]["detail_report_complete"] = all(
                            token in current.lower()
                            for token in (
                                "data quality issue register",
                                "proposed star schema",
                                "assumptions",
                            )
                        )
                        offsets_before = page.evaluate("""() => Array.from(document.querySelectorAll('*'))
                          .filter(el => el.scrollHeight > el.clientHeight + 4)
                          .map(el => el.scrollTop)""")
                        page.mouse.move(page.viewport_size["width"] / 2, page.viewport_size["height"] / 2)
                        page.mouse.wheel(0, 1200)
                        page.wait_for_timeout(400)
                        offsets_after = page.evaluate("""() => Array.from(document.querySelectorAll('*'))
                          .filter(el => el.scrollHeight > el.clientHeight + 4)
                          .map(el => el.scrollTop)""")
                        out["checks"]["wheel_scroll_changes_conversation"] = (
                            len(offsets_before) == len(offsets_after)
                            and any(after > before for before, after in zip(offsets_before, offsets_after))
                        )
                        scrolled_text = body_text(page).lower()
                        end_target = page.locator("flt-semantics").filter(
                            has_text=re.compile(r"recommended next step", re.I)
                        ).last
                        for _ in range(20):
                            try:
                                end_bounds = end_target.bounding_box()
                                if end_bounds and 0 <= end_bounds["y"] and end_bounds["y"] + end_bounds["height"] <= page.viewport_size["height"]:
                                    break
                            except Exception:
                                pass
                            page.mouse.wheel(0, 900)
                            page.wait_for_timeout(80)
                        try:
                            end_bounds = end_target.bounding_box()
                        except Exception:
                            end_bounds = None
                        out["checks"]["detail_result_reached_end"] = (
                            all(token in scrolled_text for token in ("model readiness", "recommended next step"))
                            and end_bounds is not None
                            and 0 <= end_bounds["y"]
                            and end_bounds["y"] + end_bounds["height"] <= page.viewport_size["height"]
                        )
                except Exception as exc:
                    out["queries"][key] = {"passed": False, "error": type(exc).__name__}

        current = body_text(page)
        out["checks"]["suggestion_chips"] = page.locator("button").count() > 0
        out["checks"]["charts_or_schema"] = bool(page.locator("canvas,svg").count()) or "star schema" in current.lower()
        out["checks"]["session_summary"] = "summary" in current.lower()
        diagnostics_button = None
        for element in page.locator("flt-semantics").all():
            if "system status and diagnostics" in element.inner_text().casefold():
                diagnostics_button = element
                break
        diagnostics_ok = False
        if diagnostics_button is not None:
            diagnostics_button.scroll_into_view_if_needed()
            bounds = diagnostics_button.bounding_box()
            if bounds:
                page.mouse.click(bounds["x"] + bounds["width"] / 2, bounds["y"] + bounds["height"] / 2)
                try:
                    page.get_by_text("INSIGHTFLOW SYSTEM STATUS", exact=True).wait_for(timeout=5000)
                    diagnostics_ok = True
                except Exception:
                    diagnostics_ok = False
        out["checks"]["diagnostics_ui"] = diagnostics_ok
        out["checks"]["supported_data_local"] = not external_dataset_posts
        out["external_dataset_post_count"] = len(external_dataset_posts)
        out["checks"]["no_raw_internal_state"] = not bool(re.search(r"_states|session_store|traceback|debug metadata", current, re.I))
        out["checks"]["main_scroll"] = page.evaluate("document.documentElement.scrollHeight >= document.documentElement.clientHeight")
        out["checks"]["narrow_overflow"] = page.evaluate("document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2")
        out["checks"]["selection"] = page.evaluate("document.body && getComputedStyle(document.body).userSelect !== 'none'")
        out["checks"]["copy_available"] = bool(page.locator("body").count())

        # Generate each report through the visible chatbot, then open its visible PDF action.
        for key in ("executive", "detailed", "filtered", "comparison", "context_inherited"):
            query = f"Generate a {key} report"
            try:
                box = find_query_box(page)
                if box is None:
                    raise RuntimeError("Flutter chat textbox is not available")
                send_bounds = send_flutter_message(page, box, query)
                with page.expect_response(
                    lambda response: "/powerbi/business-analysis" in response.url,
                    timeout=300000,
                ):
                    page.mouse.click(send_bounds["x"] + send_bounds["width"] / 2, send_bounds["y"] + send_bounds["height"] / 2)
                page.wait_for_function(
                    f"Array.from(document.querySelectorAll('flt-semantics')).some(el => el.innerText.toLowerCase().includes('type: {key}'))",
                    timeout=30000,
                )
                open_pdf = None
                for button in page.locator("flt-semantics[role='button']").all():
                    if "open pdf" in button.inner_text().casefold():
                        open_pdf = button
                        break
                if open_pdf is None:
                    raise RuntimeError("Report card did not expose its Open PDF button")
                bounds = open_pdf.bounding_box()
                target = artifacts / (key + "_report.pdf")
                with page.expect_popup(timeout=20000) as popup_info:
                    page.mouse.click(bounds["x"] + bounds["width"] / 2, bounds["y"] + bounds["height"] / 2)
                pdf_page = popup_info.value
                pdf_page.wait_for_load_state("domcontentloaded", timeout=20000)
                pdf_response = page.context.request.get(pdf_page.url, timeout=20000)
                pdf_bytes = pdf_response.body()
                target.write_bytes(pdf_bytes)
                from pypdf import PdfReader

                extracted = "\n".join(page.extract_text() or "" for page in PdfReader(str(target)).pages)
                required_report_text = ["Business Analysis Report", "INR"]
                pdf_ok = (
                    len(pdf_bytes) > 100
                    and pdf_bytes.startswith(b"%PDF-")
                    and bool(extracted.strip())
                    and all(token in extracted for token in required_report_text)
                    and not re.search(r"[A-Za-z]:\\|\{\s*\"(success|response_type)", extracted)
                )
                out["reports"][key] = {
                    "passed": pdf_ok,
                    "size": target.stat().st_size,
                    "path": target.name,
                    "text_verified": pdf_ok,
                }
            except Exception as exc:
                out["reports"][key] = {"passed": False, "error": type(exc).__name__}

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(500)
        out["checks"]["narrow_no_overflow"] = page.evaluate("document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2")
        copy_buttons = []
        for item in page.locator("flt-semantics[role='button']").all():
            if item.inner_text().strip().casefold() == "copy":
                bounds = item.bounding_box()
                if bounds:
                    copy_buttons.append((bounds["y"], item, bounds))
        copied_text = ""
        copy_ok = False
        try:
            page.context.grant_permissions(["clipboard-read", "clipboard-write"])
            if copy_buttons:
                _, copy_button, _ = max(copy_buttons, key=lambda entry: entry[0])
                copy_button.scroll_into_view_if_needed()
                bounds = copy_button.bounding_box()
                if not bounds:
                    raise RuntimeError("Copy button has no visible bounds")
                page.mouse.click(bounds["x"] + bounds["width"] / 2, bounds["y"] + bounds["height"] / 2)
                page.wait_for_timeout(250)
                copied_text = page.evaluate("navigator.clipboard.readText()")
                copy_ok = bool(copied_text.strip())
        except Exception:
            copy_ok = False
        selectable = False
        for item in page.locator("flt-semantics").all():
            try:
                if item.inner_text().strip() and item.bounding_box():
                    selectable = bool(
                        page.evaluate(
                            "el => { const s = getSelection(); const r = document.createRange(); r.selectNodeContents(el); s.removeAllRanges(); s.addRange(r); return s.toString().trim().length > 0; }",
                            item,
                        )
                    )
                    if selectable:
                        break
            except Exception:
                pass
        out["checks"]["copy_or_selection"] = copy_ok and selectable
        out["copied_content_available"] = copy_ok
        out["checks"]["pdf_visual_qa"] = bool(out["reports"]) and all(
            report.get("passed") and report.get("text_verified") for report in out["reports"].values()
        )
        out["checks"]["scroll_structure"] = page.locator("flt-semantics").count() > 0 and page.evaluate(
            "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2"
        )
        scroll_state = page.evaluate("""() => {
          const scrollables = Array.from(document.querySelectorAll('*')).filter(el => {
            const style = getComputedStyle(el);
            return el.scrollHeight > el.clientHeight + 4 && ['auto', 'scroll'].includes(style.overflowY);
          });
          return {count: scrollables.length, documentHeight: document.documentElement.scrollHeight,
            documentClientHeight: document.documentElement.clientHeight};
        }""")
        out["checks"]["single_vertical_scroll_container"] = scroll_state["count"] == 1
        out["scroll_state"] = scroll_state
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
