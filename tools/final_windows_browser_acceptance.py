from __future__ import annotations

import argparse
import atexit
import hashlib
import json
import re
import sys
import time
from pathlib import Path
from urllib.parse import urljoin, urlparse

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
    ("boolean_seed", "Which region is the most profitable?", ["North"]),
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

SUITE_SECONDS = 480


def progress_start(name: str, page=None) -> float:
    url = page.url if page is not None else "<no page>"
    print(f"[START] {name} url={url}", flush=True)
    return time.perf_counter()


def progress_end(name: str, started: float, passed: bool, reason: str = "") -> None:
    status = "PASS" if passed else "FAIL"
    suffix = f" {reason}" if reason else ""
    print(f"[{status}] {name} ({time.perf_counter() - started:.1f}s){suffix}", flush=True)


def remaining_timeout_ms(deadline: float, cap_ms: int) -> int:
    remaining = int((deadline - time.perf_counter()) * 1000)
    if remaining <= 0:
        raise TimeoutError("browser acceptance suite deadline exceeded")
    return max(1, min(cap_ms, remaining))


def capture_failure(
    page,
    artifacts: Path,
    name: str,
    error: Exception,
    console_errors=(),
    failed_requests=(),
) -> None:
    safe_name = re.sub(r"[^a-z0-9_-]+", "_", name.lower()).strip("_") or "scenario"
    try:
        page.screenshot(path=str(artifacts / f"{safe_name}.png"), full_page=False, timeout=2500)
    except Exception:
        pass
    try:
        # Capture structural diagnostics only; do not persist rendered dataset values.
        dom = page.evaluate("""() => ({
          url: location.pathname,
          title: document.title,
          semantic_nodes: document.querySelectorAll('flt-semantics').length,
          canvases: document.querySelectorAll('canvas').length,
          scroll_height: document.documentElement.scrollHeight,
          client_height: document.documentElement.clientHeight
        })""")
        (artifacts / f"{safe_name}.html").write_text(json.dumps(dom, indent=2), encoding="utf-8")
    except Exception:
        pass
    (artifacts / f"{safe_name}-error.txt").write_text(
        f"{type(error).__name__}: {str(error)[:300]}", encoding="utf-8"
    )
    (artifacts / f"{safe_name}-console.txt").write_text(
        "\n".join(str(item)[:500] for item in console_errors[:30]), encoding="utf-8"
    )
    (artifacts / f"{safe_name}-network.txt").write_text(
        "\n".join(str(item)[:500] for item in failed_requests[:30]), encoding="utf-8"
    )


def body_text(page):
    parts = []
    for frame in page.frames:
        try:
            value = frame.locator("body").inner_text(timeout=3000)
            if value.strip():
                parts.append(value[:300_000])
        except Exception:
            pass
        try:
            # CanvasKit keeps rendered copy in semantics, not body.innerText.
            # Batch extraction to avoid one Playwright call per semantic node.
            value = frame.evaluate("""() => {
              const nodes = Array.from(document.querySelectorAll('flt-semantics'));
              const selected = nodes.length <= 12000
                ? nodes
                : [...nodes.slice(0, 9000), ...nodes.slice(-3000)];
              return selected.map(node =>
                node.getAttribute('aria-label') || node.textContent || ''
              ).join('\\n').slice(0, 300000);
            }""")
            if value.strip():
                parts.append(value)
        except Exception:
            pass
    if not parts:
        return ""
    return "\n".join(parts)


def scroll_metrics(page):
    offsets = []
    scrollable_count = 0
    for frame in page.frames:
        try:
            state = frame.evaluate("""() => {
              const nodes = Array.from(document.querySelectorAll('*')).filter(el => {
                const style = getComputedStyle(el);
                return el.scrollHeight > el.clientHeight + 4 && ['auto', 'scroll'].includes(style.overflowY);
              });
              const semantics = Array.from(document.querySelectorAll('flt-semantics'))
                .map(el => el.getBoundingClientRect())
                .filter(rect => rect.width > 0 && rect.height > 0)
                .map(rect => Math.round(rect.top));
              return {offsets: [...nodes.map(el => el.scrollTop), ...semantics], count: nodes.length};
            }""")
            offsets.extend(state["offsets"])
            scrollable_count += state["count"]
        except Exception:
            continue
    return offsets, scrollable_count


def find_query_box(page):
    composer = page.locator("textarea[aria-label^='Ask about your data']")
    try:
        if composer.count() and composer.first.is_visible():
            return composer.first
    except Exception:
        pass
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
    candidates = page.locator("flt-semantics").evaluate_all("""nodes => {
      const h = window.innerHeight;
      const found = [];
      for (let i = nodes.length - 1; i >= Math.max(0, nodes.length - 300); i--) {
        const el = nodes[i];
        const r = el.getBoundingClientRect();
        if (el.getAttribute('role') !== 'button'
            && getComputedStyle(el).pointerEvents === 'all'
            && r.width >= 180 && r.height >= 35 && r.height <= 80
            && r.bottom >= h - 180) found.push(i);
      }
      return found;
    }""")
    if candidates:
        return page.locator("flt-semantics").nth(candidates[0])
    return None


def query_box_enabled(page) -> bool:
    box = find_query_box(page)
    if box is None:
        return False
    try:
        return bool(box.evaluate("""el => !el.hasAttribute('disabled')
          && el.getAttribute('aria-disabled') !== 'true'
          && getComputedStyle(el).pointerEvents !== 'none'"""))
    except Exception:
        return False


def wait_for_query_box_enabled(page, timeout_ms: int = 20000) -> None:
    page.wait_for_function(
        """() => Array.from(document.querySelectorAll('textarea[aria-label^="Ask about your data"]')).some(el => {
          const label = (el.getAttribute('aria-label') || '').toLowerCase();
          return (label.includes('ask about your data') || label.includes('upload datasets to begin'))
            && !el.disabled && el.getAttribute('aria-disabled') !== 'true';
        }) || Array.from(document.querySelectorAll('flt-semantics')).some(el => {
          const r = el.getBoundingClientRect();
          const role = (el.getAttribute('role') || '').toLowerCase();
          const label = (el.getAttribute('aria-label') || '').toLowerCase();
          const isComposer = role === 'textbox'
            || label.includes('ask about your data')
            || label.includes('upload datasets to begin');
          return isComposer && r.width >= 180 && r.height >= 25 && r.height <= 100
            && r.bottom >= innerHeight - 180
            && getComputedStyle(el).pointerEvents === 'all'
            && !el.hasAttribute('disabled')
            && el.getAttribute('aria-disabled') !== 'true';
        })""",
        timeout=timeout_ms,
    )


def _expected_token_present(token: str, answer: str) -> bool:
    if token.casefold() in answer.casefold():
        return True
    numeric = token.strip().replace(",", "").rstrip("%")
    if not re.fullmatch(r"[-+]?\d+(?:\.\d+)?", numeric):
        return False
    expected = float(numeric)
    for candidate in re.findall(r"(?<![A-Za-z0-9])[-+]?\d[\d,]*(?:\.\d+)?%?", answer):
        try:
            observed = float(candidate.replace(",", "").rstrip("%"))
        except ValueError:
            continue
        if abs(observed - expected) <= max(0.01, abs(expected) * 1e-9):
            return True
    return False


def _response_evidence(response) -> str:
    """Return transient JSON evidence for assertions without persisting data."""
    try:
        return json.dumps(response.json(), ensure_ascii=False, sort_keys=True)
    except Exception:
        return ""


def _screenshot_changed(before: bytes, after: bytes) -> bool:
    return hashlib.sha256(before).digest() != hashlib.sha256(after).digest()


def wait_for_visible_answer(
    page,
    query: str,
    expected: list[str],
    baseline_text: str,
    timeout_ms: int,
    *,
    alternatives=(),
):
    deadline = time.perf_counter() + timeout_ms / 1000
    rendered = ""
    evidence = ""
    while time.perf_counter() < deadline:
        rendered = body_text(page)
        if rendered.startswith(baseline_text):
            evidence = rendered[len(baseline_text):]
        else:
            prompt_position = rendered.casefold().rfind(query.casefold())
            evidence = (
                rendered[prompt_position + len(query):]
                if prompt_position >= 0
                else rendered
            )
        matches = [_expected_token_present(token, evidence) for token in expected]
        answer_changed = rendered != baseline_text
        alternatives_found = alternatives and any(
            term in evidence.casefold() for term in alternatives
        )
        if answer_changed and (all(matches) or alternatives_found):
            return evidence, matches
        time.sleep(0.15)
    flags = [_expected_token_present(token, evidence) for token in expected]
    return evidence, flags


def reset_conversation_and_upload(page, files, deadline: float) -> None:
    page.reload(wait_until="commit", timeout=remaining_timeout_ms(deadline, 5000))
    page.locator("flt-semantics-placeholder").wait_for(
        state="visible", timeout=remaining_timeout_ms(deadline, 10000)
    )
    page.locator("flt-semantics-placeholder").evaluate("element => element.click()")
    page.wait_for_function(
        "document.querySelectorAll('flt-semantics').length > 0",
        timeout=remaining_timeout_ms(deadline, 10000),
    )
    with page.expect_file_chooser(timeout=remaining_timeout_ms(deadline, 5000)) as chooser_info:
        page.get_by_role("button", name=re.compile("choose datasets", re.I)).click(timeout=3000)
    chooser_info.value.set_files([str(item) for item in files])
    page.wait_for_function(
        "Array.from(document.querySelectorAll('flt-semantics')).some(el => (el.textContent || '').includes('4 datasets ready'))",
        timeout=remaining_timeout_ms(deadline, 30000),
    )


def send_flutter_message(page, box, query):
    if not query_box_enabled(page):
        raise RuntimeError("Chat composer is disabled; refusing to wait for an unsent request")
    if box.evaluate("el => el.tagName.toLowerCase()") in {"textarea", "input"}:
        box.fill(query)
    else:
        bounds = box.bounding_box()
        if not bounds:
            raise RuntimeError("Flutter semantic chat input has no visible bounds")
        page.mouse.click(bounds["x"] + bounds["width"] / 2, bounds["y"] + bounds["height"] / 2)
        page.keyboard.press("Control+A")
        page.keyboard.insert_text(query)
    # Let Flutter publish the updated semantics tree before resolving Send.
    page.wait_for_timeout(75)

    candidate = page.locator("flt-semantics[role='button']").evaluate_all("""nodes => {
      const h = window.innerHeight;
      const send = nodes.findIndex(el =>
        ((el.getAttribute('aria-label') || '').trim().toLowerCase() === 'send')
        && el.getBoundingClientRect().width > 0
        && el.getBoundingClientRect().bottom >= h - 180
      );
      if (send >= 0) {
        const r = nodes[send].getBoundingClientRect();
        return {index:send, x:r.x, y:r.y, width:r.width, height:r.height, right:r.right, accessible:true};
      }
      let best = null;
      nodes.forEach((el, index) => {
        const r = el.getBoundingClientRect();
        if (r.width > 0 && r.height > 0 && r.bottom >= h - 180 && r.width <= 100
            && (!best || r.right > best.right)) {
          best = {index, x:r.x, y:r.y, width:r.width, height:r.height, right:r.right, accessible:false};
        }
      });
      return best;
    }""")
    if not candidate:
        raise RuntimeError("Visible Flutter send control was not found")
    return candidate


def click_flutter_send(page, send_button):
    page.keyboard.press("Tab")
    focused = page.evaluate("""() => {
      const element = document.activeElement;
      if (!element || element.tagName !== 'FLT-SEMANTICS'
          || element.getAttribute('role') !== 'button') return null;
      const rect = element.getBoundingClientRect();
      return {x:rect.x, y:rect.y, width:rect.width, height:rect.height};
    }""")
    if focused and all(
        abs(focused[key] - send_button[key]) <= 2
        for key in ("x", "y", "width", "height")
    ):
        page.keyboard.press("Enter")
        return

    button = page.locator("flt-semantics[role='button']").nth(send_button["index"])
    if button.count() and button.is_visible():
        try:
            button.click(timeout=5000)
            return
        except Exception:
            pass
    page.mouse.click(
        send_button["x"] + send_button["width"] / 2,
        send_button["y"] + send_button["height"] / 2,
    )


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


def semantic_button_index(page, label: str) -> int:
    return page.locator("flt-semantics[role='button']").evaluate_all(
        """(nodes, expected) => {
          let bestIndex = -1;
          let bestBottom = -Infinity;
          nodes.forEach((el, index) => {
          const text = ((el.getAttribute('aria-label') || '') + ' ' + (el.textContent || '')).trim().toLowerCase();
          const r = el.getBoundingClientRect();
            const visible = r.width > 0 && r.height > 0
              && r.right > 0 && r.left < innerWidth
              && r.bottom > 0 && r.top < innerHeight;
            if (visible && text.includes(expected) && r.bottom > bestBottom) {
              bestIndex = index;
              bestBottom = r.bottom;
            }
          });
          return bestIndex;
        }""",
        label.casefold(),
    )


def click_semantic_button(page, index: int) -> None:
    if index < 0:
        raise RuntimeError("Expected visible semantic button was not found")
    button = page.locator("flt-semantics[role='button']").nth(index)
    bounds = button.bounding_box()
    if not bounds:
        raise RuntimeError("Visible semantic button has no bounds")
    page.mouse.click(bounds["x"] + bounds["width"] / 2, bounds["y"] + bounds["height"] / 2)


def main() -> int:
    from playwright.sync_api import sync_playwright

    ap = argparse.ArgumentParser()
    ap.add_argument("--data-root", required=True)
    ap.add_argument("--artifacts", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    root = Path(args.data_root)
    artifacts = Path(args.artifacts)
    artifacts.mkdir(parents=True, exist_ok=True)
    evidence_dir = artifacts / "browser_acceptance"
    evidence_dir.mkdir(parents=True, exist_ok=True)
    files = [root / n for n in ("orders_raw.csv", "customers_raw.csv", "products_raw.csv", "regions_raw.csv")]
    out = {"checks": {}, "queries": {}, "reports": {}, "passed": False}
    suite_started = time.perf_counter()
    deadline = suite_started + SUITE_SECONDS
    console_errors = []
    page_errors = []
    failed_requests = []

    def checkpoint():
        out["runtime_seconds"] = round(time.perf_counter() - suite_started, 2)
        out["browser_errors"] = {
            "console": console_errors[:50],
            "page": page_errors[:50],
            "requests": failed_requests[:50],
        }
        Path(args.output).write_text(json.dumps(out, indent=2), encoding="utf-8")

    checkpoint()
    atexit.register(checkpoint)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        def close_browser_safely():
            try:
                if browser.is_connected():
                    browser.close()
            except Exception:
                pass

        atexit.register(close_browser_safely)
        context = browser.new_context(viewport={"width": 1440, "height": 900}, accept_downloads=True)
        context.set_default_timeout(5000)
        context.set_default_navigation_timeout(10000)
        context.tracing.start(screenshots=True, snapshots=True, sources=True)
        page = context.new_page()
        page.emulate_media(reduced_motion="reduce")
        external_dataset_posts = []

        def safe_error(message):
            message = re.sub(r"[A-Za-z]:\\[^\r\n\"']+", "<local-path>", str(message))
            message = re.sub(r"(?:sk|AIza)[A-Za-z0-9_\-]{16,}", "<redacted-secret>", message)
            return message[:500]

        def track_request(request):
            parsed = re.match(r"https?://([^/:]+)(/[^?#]*)?", request.url, re.I)
            host = parsed.group(1).casefold() if parsed else ""
            path = parsed.group(2) if parsed else ""
            if request.method.upper() in {"POST", "PUT", "PATCH"} and host not in {"127.0.0.1", "localhost"}:
                external_dataset_posts.append(f"{host}{path}")

        page.on("request", track_request)
        page.on("console", lambda message: console_errors.append(safe_error(message.text)) if message.type == "error" else None)
        page.on("pageerror", lambda error: page_errors.append(safe_error(error)))
        page.on("requestfailed", lambda request: failed_requests.append(
            safe_error(f"{request.method} {request.url.split('?')[0]} {request.failure or ''}")
        ))

        stage_started = progress_start("page_load", page)
        page.goto("http://127.0.0.1:8000/ui/?testMode=1", wait_until="commit", timeout=remaining_timeout_ms(deadline, 5000))
        page.locator("flt-semantics-placeholder").wait_for(state="visible", timeout=remaining_timeout_ms(deadline, 10000))
        # Flutter CanvasKit exposes controls through semantics only after the
        # accessibility placeholder is activated.
        page.locator("flt-semantics-placeholder").evaluate("element => element.click()")
        page.wait_for_function("document.querySelectorAll('flt-semantics').length > 0", timeout=remaining_timeout_ms(deadline, 10000))
        initial = body_text(page)
        out["checks"]["ui_load"] = bool(initial.strip()) or page.locator("flt-glass-pane, flt-scene-host").count() > 0 or page.locator("flt-semantics").count() > 0
        progress_end("page_load", stage_started, out["checks"]["ui_load"], f"semantics={page.locator('flt-semantics').count()}")

        inputs = page.locator("input[type=file]")
        stage_started = progress_start("dataset_upload", page)
        try:
            if inputs.count():
                inputs.first.set_input_files([str(x) for x in files])
            else:
                choose = page.get_by_role("button", name=re.compile("choose datasets", re.I))
                with page.expect_file_chooser(timeout=remaining_timeout_ms(deadline, 10000)) as chooser_info:
                    choose.click()
                chooser_info.value.set_files([str(x) for x in files])
            page.wait_for_function("Array.from(document.querySelectorAll('flt-semantics')).some(el => (el.textContent || '').includes('4 datasets ready'))", timeout=remaining_timeout_ms(deadline, 30000))
            out["checks"]["detail_analysis_loaded"] = "4 datasets ready" in body_text(page).lower()
            progress_end("dataset_upload", stage_started, out["checks"]["detail_analysis_loaded"])
        except Exception as exc:
            out["checks"]["detail_analysis_loaded"] = False
            out["upload_error"] = type(exc).__name__
            capture_failure(page, evidence_dir, "dataset_upload", exc, console_errors, failed_requests)
            progress_end("dataset_upload", stage_started, False, type(exc).__name__)

        text = body_text(page)
        out["checks"]["no_raw_exception"] = not re.search(r"Traceback|Unhandled exception|Exception:\s", text, re.I)
        box = find_query_box(page)
        out["checks"]["query_box"] = box is not None

        if box is not None:
            for key, query, expected in QUERIES:
                stage_name = f"query_{key}"
                stage_started = progress_start(stage_name, page)
                try:
                    if time.perf_counter() >= deadline:
                        for pending_key, _, pending_expected in QUERIES:
                            if pending_key not in out["queries"]:
                                out["queries"][pending_key] = {
                                    "passed": False,
                                    "error": "suite deadline exceeded",
                                    "expected": pending_expected,
                                }
                        progress_end(stage_name, stage_started, False, "suite deadline exceeded; remaining queries recorded")
                        break
                    box = find_query_box(page)
                    if box is None:
                        raise RuntimeError("Flutter chat textbox is not available")
                    text_before_query = body_text(page)
                    send_bounds = send_flutter_message(page, box, query)
                    screenshot_before_result = page.screenshot(timeout=2500)
                    expected_path = {
                        "detail_analysis": "/powerbi/detail-analysis",
                        "summary": "/v1/conversation/summary/",
                        "global_summary": "/v1/conversation/summary/",
                        "meta": "/v1/assistant/meta",
                        "unsupported": "/v1/chat/plan",
                    }.get(key, "/powerbi/business-analysis")
                    response_timeout = 160000 if key == "detail_analysis" else 60000
                    print(f"[WAIT] {stage_name} response={expected_path} timeout_ms={min(response_timeout, max(1, int((deadline-time.perf_counter())*1000)))}", flush=True)
                    with page.expect_response(
                        lambda response: expected_path in response.url,
                        timeout=remaining_timeout_ms(deadline, response_timeout),
                    ) as response_info:
                        click_flutter_send(page, send_bounds)
                    response_evidence = _response_evidence(response_info.value)
                    token_matches = [
                        _expected_token_present(token, response_evidence)
                        for token in expected
                    ]
                    alternatives = (
                        ("unsupported", "cannot", "not support", "unknown", "could not")
                        if key == "unsupported"
                        else ()
                    )
                    wait_for_query_box_enabled(
                        page, timeout_ms=remaining_timeout_ms(deadline, 10000)
                    )
                    screenshot_after_result = page.screenshot(timeout=2500)
                    ok = (
                        response_info.value.status == 200
                        and any(term in response_evidence.casefold() for term in alternatives)
                        if key == "unsupported"
                        else response_info.value.status == 200
                        and all(token_matches)
                    )
                    ok = ok and _screenshot_changed(
                        screenshot_before_result, screenshot_after_result
                    )
                    current = body_text(page)
                    out["queries"][key] = {
                        "passed": ok,
                        "expected_token_matches": token_matches,
                        "http_status": response_info.value.status,
                        "visible_frame_updated": _screenshot_changed(
                            screenshot_before_result, screenshot_after_result
                        ),
                    }
                    if not ok:
                        capture_failure(
                            page,
                            evidence_dir,
                            stage_name,
                            AssertionError("visible response did not contain expected evidence"),
                            console_errors,
                            failed_requests,
                        )
                    progress_end(stage_name, stage_started, ok, "response evidence and rendered frame checked")
                    checkpoint()
                    if key == "detail_analysis":
                        out["checks"]["detail_report_complete"] = all(
                            token in current.lower()
                            for token in (
                                "data quality issue register",
                                "proposed star schema",
                                "assumptions",
                            )
                        )
                        offsets_before, scrollable_before = scroll_metrics(page)
                        page.evaluate("""() => {
                          window.__reportWheelMessageReceived = false;
                          window.addEventListener('message', event => {
                            if (typeof event.data === 'string'
                                && event.data.startsWith('detail-analysis-scroll|')) {
                              window.__reportWheelMessageReceived = true;
                            }
                          });
                        }""")
                        page.mouse.move(page.viewport_size["width"] / 2, page.viewport_size["height"] / 2)
                        screenshot_before_scroll = page.screenshot(timeout=2500)
                        page.mouse.wheel(0, -1600)
                        page.wait_for_timeout(400)
                        screenshot_after_up = page.screenshot(timeout=2500)
                        offsets_after_up, scrollable_after_up = scroll_metrics(page)
                        geometry_changed = len(offsets_before) == len(offsets_after_up) and any(
                            abs(after - before) > 2
                            for before, after in zip(offsets_before, offsets_after_up)
                        )
                        page.mouse.wheel(0, 1600)
                        page.wait_for_timeout(400)
                        offsets_after, scrollable_after = scroll_metrics(page)
                        bridge_message_received = page.evaluate(
                            "Boolean(window.__reportWheelMessageReceived)"
                        )
                        screenshot_after_scroll = page.screenshot(timeout=2500)
                        result_area_wheel_changed = (
                            geometry_changed
                            or _screenshot_changed(screenshot_before_scroll, screenshot_after_up)
                            or _screenshot_changed(screenshot_after_up, screenshot_after_scroll)
                        )
                        gutter_wheel_changed = False
                        if not result_area_wheel_changed:
                            page.mouse.move(275, page.viewport_size["height"] / 2)
                            screenshot_before_gutter = page.screenshot(timeout=2500)
                            page.mouse.wheel(0, -1600)
                            page.wait_for_timeout(400)
                            screenshot_after_gutter = page.screenshot(timeout=2500)
                            gutter_wheel_changed = _screenshot_changed(
                                screenshot_before_gutter, screenshot_after_gutter
                            )
                        out["checks"]["wheel_scroll_changes_conversation"] = (
                            scrollable_before == scrollable_after_up == scrollable_after
                            and bridge_message_received
                            and geometry_changed
                        )
                        out["scroll_probe"] = {
                            "result_area_wheel_changed": result_area_wheel_changed,
                            "gutter_wheel_changed": gutter_wheel_changed,
                            "bridge_message_received": bridge_message_received,
                            "semantics_geometry_changed": geometry_changed,
                            "dom_scrollable_before": scrollable_before,
                            "dom_scrollable_after_first_wheel": scrollable_after_up,
                            "dom_scrollable_after": scrollable_after,
                        }
                        end_target = None
                        for frame in page.frames:
                            candidate = frame.get_by_text(re.compile(r"recommended next step", re.I)).last
                            if candidate.count():
                                end_target = candidate
                                break
                        scroll_deadline = min(deadline, time.perf_counter() + 5)
                        while time.perf_counter() < scroll_deadline:
                            try:
                                end_bounds = end_target.bounding_box() if end_target else None
                                if end_bounds and 0 <= end_bounds["y"] and end_bounds["y"] + end_bounds["height"] <= page.viewport_size["height"]:
                                    break
                            except Exception:
                                pass
                            page.mouse.wheel(0, 900)
                            page.wait_for_timeout(80)
                        screenshot_at_report_end = page.screenshot(timeout=2500)
                        try:
                            end_bounds = end_target.bounding_box() if end_target else None
                        except Exception:
                            end_bounds = None
                        scrolled_text = body_text(page).lower()
                        out["checks"]["detail_result_reached_end"] = (
                            all(token in scrolled_text for token in ("model readiness", "recommended next step"))
                            and (
                                (end_bounds is not None
                                 and 0 <= end_bounds["y"]
                                 and end_bounds["y"] + end_bounds["height"] <= page.viewport_size["height"])
                                or _screenshot_changed(screenshot_after_up, screenshot_at_report_end)
                            )
                        )
                        out["checks"]["charts_or_schema"] = (
                            bool(page.locator("canvas,svg").count())
                            or "star schema" in current.lower()
                        )
                        try:
                            page.screenshot(
                                path=str(evidence_dir / "detail_analysis_rendered.png"),
                                full_page=False,
                                timeout=2500,
                            )
                        except Exception:
                            pass
                        reset_started = progress_start("reset_after_detail", page)
                        try:
                            reset_conversation_and_upload(page, files, deadline)
                            out["checks"]["isolated_followup_session"] = True
                            progress_end("reset_after_detail", reset_started, True, "fresh page; same four datasets re-uploaded")
                        except Exception as reset_error:
                            out["checks"]["isolated_followup_session"] = False
                            capture_failure(page, evidence_dir, "reset_after_detail", reset_error, console_errors, failed_requests)
                            progress_end("reset_after_detail", reset_started, False, type(reset_error).__name__)
                except Exception as exc:
                    out["queries"][key] = {"passed": False, "error": type(exc).__name__}
                    capture_failure(page, evidence_dir, stage_name, exc, console_errors, failed_requests)
                    progress_end(stage_name, stage_started, False, type(exc).__name__)
                    checkpoint()
                    if key == "detail_analysis" and time.perf_counter() < deadline:
                        recovery_started = progress_start("recover_after_detail_timeout", page)
                        try:
                            reset_conversation_and_upload(page, files, deadline)
                            progress_end("recover_after_detail_timeout", recovery_started, True, "fresh session after bounded timeout")
                        except Exception as recovery_error:
                            out["checks"]["detail_timeout_recovery"] = False
                            capture_failure(page, evidence_dir, "recover_after_detail_timeout", recovery_error, console_errors, failed_requests)
                            progress_end("recover_after_detail_timeout", recovery_started, False, type(recovery_error).__name__)

                if key in {"clothing", "global_summary", "product_2025", "comparison"}:
                    reset_started = progress_start(f"reset_after_{key}", page)
                    try:
                        reset_conversation_and_upload(page, files, deadline)
                        progress_end(f"reset_after_{key}", reset_started, True, "fresh chat context and same datasets")
                    except Exception as reset_error:
                        out["checks"][f"reset_after_{key}"] = False
                        capture_failure(page, evidence_dir, f"reset_after_{key}", reset_error, console_errors, failed_requests)
                        progress_end(f"reset_after_{key}", reset_started, False, type(reset_error).__name__)

        stage_started = progress_start("suggestion_followup", page)
        try:
            reset_conversation_and_upload(page, files, deadline)
            box = find_query_box(page)
            if box is None:
                raise RuntimeError("Composer unavailable in isolated suggestions session")
            suggestion_seed = "Which region is the most profitable?"
            send_bounds = send_flutter_message(page, box, suggestion_seed)
            with page.expect_response(
                lambda response: "/powerbi/business-analysis" in response.url,
                timeout=remaining_timeout_ms(deadline, 60000),
            ) as seed_response:
                click_flutter_send(page, send_bounds)
            if seed_response.value.status != 200:
                raise RuntimeError("Suggestion seed query did not succeed")
            wait_for_query_box_enabled(page, timeout_ms=remaining_timeout_ms(deadline, 20000))
            try:
                page.get_by_text("You could also ask", exact=True).wait_for(
                    state="visible", timeout=remaining_timeout_ms(deadline, 10000)
                )
            except Exception:
                pass
            suggestion_info = page.locator("flt-semantics[role='checkbox']").evaluate_all("""nodes => {
              const items = nodes.map((el, index) => {
                const text = ((el.getAttribute('aria-label') || '') + ' ' + (el.textContent || '')).trim();
                const rect = el.getBoundingClientRect();
                return {index, text, visible: rect.width > 0 && rect.height > 0};
              }).filter(item => item.visible && item.text);
              const normalized = items.map(item => item.text.toLowerCase());
              return {
                index: items.length ? items[0].index : -1,
                count: items.length,
                unique: new Set(normalized).size === normalized.length,
                contextual: items.length > 0 && items.every(item => item.text.toLowerCase().includes('north')),
              };
            }""")
            out["checks"]["suggestion_chips"] = (
                suggestion_info["count"] > 0
                and suggestion_info["unique"]
                and suggestion_info["contextual"]
            )
            if not out["checks"]["suggestion_chips"]:
                raise RuntimeError("Contextual suggestion chips were absent or duplicated")
            suggestion = page.locator("flt-semantics[role='checkbox']").nth(suggestion_info["index"])
            bounds = suggestion.bounding_box()
            if not bounds:
                raise RuntimeError("Suggested follow-up chip had no visible bounds")
            response_paths = (
                "/powerbi/business-analysis",
                "/powerbi/detail-analysis",
                "/v1/conversation/summary/",
            )
            with page.expect_response(
                lambda response: any(path in response.url for path in response_paths),
                timeout=remaining_timeout_ms(deadline, 60000),
            ) as suggestion_click_response:
                page.mouse.click(bounds["x"] + bounds["width"] / 2, bounds["y"] + bounds["height"] / 2)
            wait_for_query_box_enabled(page, timeout_ms=remaining_timeout_ms(deadline, 20000))
            out["checks"]["suggestion_click_routes_normally"] = suggestion_click_response.value.status == 200
            progress_end("suggestion_followup", stage_started, True, "visible chip used normal chat submission")
        except Exception as exc:
            out["checks"]["suggestion_chips"] = False
            out["checks"]["suggestion_click_routes_normally"] = False
            capture_failure(page, evidence_dir, "suggestion_followup", exc, console_errors, failed_requests)
            progress_end("suggestion_followup", stage_started, False, type(exc).__name__)

        stage_started = progress_start("rendered_ui_checks", page)
        current = body_text(page)
        out["checks"]["suggestion_chips"] = out["checks"].get("suggestion_chips", False)
        out["checks"]["charts_or_schema"] = out["checks"].get("charts_or_schema", False) or bool(page.locator("canvas,svg").count()) or "star schema" in current.lower()
        out["checks"]["session_summary"] = bool(
            out["queries"].get("summary", {}).get("passed")
            and out["queries"].get("global_summary", {}).get("passed")
        )
        diagnostics_index = page.locator("flt-semantics").evaluate_all("""nodes => nodes.findIndex(el =>
          ((el.getAttribute('aria-label') || '') + ' ' + (el.textContent || '')).toLowerCase().includes('system status and diagnostics'))""")
        diagnostics_ok = False
        if diagnostics_index >= 0:
            diagnostics_button = page.locator("flt-semantics").nth(diagnostics_index)
            diagnostics_button.scroll_into_view_if_needed()
            bounds = diagnostics_button.bounding_box()
            if bounds:
                page.mouse.click(bounds["x"] + bounds["width"] / 2, bounds["y"] + bounds["height"] / 2)
                try:
                    page.get_by_text("INSIGHTFLOW SYSTEM STATUS", exact=True).wait_for(timeout=remaining_timeout_ms(deadline, 5000))
                    diagnostics_text = body_text(page)
                    diagnostics_json = page.context.request.get(
                        "http://127.0.0.1:8000/v1/system/diagnostics",
                        timeout=remaining_timeout_ms(deadline, 5000),
                    ).json()
                    displayed_build = str(
                        (diagnostics_json.get("frontend") or {}).get(
                            "detail_analysis_build_id", ""
                        )
                    )
                    diagnostics_ok = (
                        bool(re.fullmatch(r"[a-fA-F0-9]{12}", displayed_build))
                        and displayed_build.casefold() in diagnostics_text.casefold()
                        and "healthy" in diagnostics_text.casefold()
                    )
                except Exception:
                    diagnostics_ok = False
        out["checks"]["diagnostics_ui"] = diagnostics_ok
        if diagnostics_ok:
            close_index = semantic_button_index(page, "close")
            if close_index >= 0:
                click_semantic_button(page, close_index)
                try:
                    page.get_by_text("INSIGHTFLOW SYSTEM STATUS", exact=True).wait_for(
                        state="hidden", timeout=remaining_timeout_ms(deadline, 3000)
                    )
                except Exception:
                    pass
        reset_conversation_and_upload(page, files, deadline)
        out["checks"]["supported_data_local"] = not external_dataset_posts
        out["external_dataset_post_count"] = len(external_dataset_posts)
        out["checks"]["no_raw_internal_state"] = not bool(re.search(r"_states|session_store|traceback|debug metadata", current, re.I))
        out["checks"]["main_scroll"] = page.evaluate("document.documentElement.scrollHeight >= document.documentElement.clientHeight")
        out["checks"]["narrow_overflow"] = page.evaluate("document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2")
        out["checks"]["selection"] = page.evaluate("document.body && getComputedStyle(document.body).userSelect !== 'none'")
        out["checks"]["copy_available"] = bool(page.locator("body").count())
        progress_end("rendered_ui_checks", stage_started, all(out["checks"].get(k, False) for k in ("suggestion_chips", "charts_or_schema", "session_summary", "diagnostics_ui", "main_scroll", "narrow_overflow")))

        # Generate each report through the visible chatbot, then open its visible PDF action.
        for key in ("executive", "detailed", "filtered", "comparison", "context_inherited"):
            stage_name = f"report_{key}"
            stage_started = progress_start(stage_name, page)
            article = "an" if key.startswith("executive") else "a"
            query = f"Generate {article} {key} report"
            try:
                if time.perf_counter() >= deadline:
                    for pending_key in ("executive", "detailed", "filtered", "comparison", "context_inherited"):
                        if pending_key not in out["reports"]:
                            out["reports"][pending_key] = {"passed": False, "error": "suite deadline exceeded"}
                    progress_end(stage_name, stage_started, False, "suite deadline exceeded; remaining reports recorded")
                    break
                box = find_query_box(page)
                if box is None:
                    raise RuntimeError("Flutter chat textbox is not available")
                send_bounds = send_flutter_message(page, box, query)
                screenshot_before_report = page.screenshot(timeout=2500)
                print(f"[WAIT] {stage_name} response=/powerbi/business-analysis", flush=True)
                with page.expect_response(
                    lambda response: "/powerbi/business-analysis" in response.url,
                    timeout=remaining_timeout_ms(deadline, 60000),
                ) as report_response:
                    click_flutter_send(page, send_bounds)
                report_payload = report_response.value.json()
                if report_response.value.status != 200 or report_payload.get("report_type") != key:
                    raise RuntimeError("Report API response did not match the requested report type")
                wait_for_query_box_enabled(page, timeout_ms=remaining_timeout_ms(deadline, 20000))
                screenshot_after_report = page.screenshot(timeout=2500)
                if not _screenshot_changed(screenshot_before_report, screenshot_after_report):
                    raise RuntimeError("Rendered report card did not change the browser frame")
                try:
                    page.wait_for_function(
                        "Array.from(document.querySelectorAll('flt-semantics[role=button]')).some(el => ((el.getAttribute('aria-label') || '') + ' ' + (el.textContent || '')).toLowerCase().includes('open pdf'))",
                        timeout=remaining_timeout_ms(deadline, 10000),
                    )
                except Exception:
                    pass
                open_pdf_index = semantic_button_index(page, "open pdf")
                if open_pdf_index < 0:
                    raise RuntimeError("Report card did not expose its Open PDF button")
                open_pdf = page.locator("flt-semantics[role='button']").nth(open_pdf_index)
                open_pdf.scroll_into_view_if_needed(timeout=remaining_timeout_ms(deadline, 3000))
                bounds = open_pdf.bounding_box()
                target = artifacts / (key + "_report.pdf")
                with page.expect_popup(timeout=remaining_timeout_ms(deadline, 10000)) as popup_info:
                    page.mouse.click(bounds["x"] + bounds["width"] / 2, bounds["y"] + bounds["height"] / 2)
                pdf_page = popup_info.value
                try:
                    download_path = str(report_payload.get("download_url") or "")
                    pdf_url = urljoin("http://127.0.0.1:8000/", download_path)
                    parsed_pdf_url = urlparse(pdf_url)
                    if parsed_pdf_url.hostname not in {"127.0.0.1", "localhost"}:
                        raise RuntimeError("Report download URL was not local")
                    pdf_response = page.context.request.get(pdf_url, timeout=remaining_timeout_ms(deadline, 10000))
                    pdf_bytes = pdf_response.body()
                finally:
                    pdf_page.close()
                target.write_bytes(pdf_bytes)
                from pypdf import PdfReader

                extracted = "\n".join(page.extract_text() or "" for page in PdfReader(str(target)).pages)
                required_report_text = ["Business Analysis Report", "INR"]
                pdf_ok = (
                    pdf_response.ok
                    and "application/pdf" in pdf_response.headers.get("content-type", "").casefold()
                    and len(pdf_bytes) > 100
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
                progress_end(stage_name, stage_started, pdf_ok, "PDF parsed")
                checkpoint()
            except Exception as exc:
                out["reports"][key] = {"passed": False, "error": type(exc).__name__}
                capture_failure(page, evidence_dir, stage_name, exc, console_errors, failed_requests)
                progress_end(stage_name, stage_started, False, type(exc).__name__)
                checkpoint()

        stage_started = progress_start("narrow_viewport", page)
        page.set_viewport_size({"width": 360, "height": 800})
        page.wait_for_timeout(100)
        no_overflow_360 = page.evaluate("document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2")
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        no_overflow_390 = page.evaluate("document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2")
        out["checks"]["narrow_no_overflow"] = no_overflow_360 and no_overflow_390
        progress_end("narrow_viewport", stage_started, out["checks"]["narrow_no_overflow"], f"360={no_overflow_360} 390={no_overflow_390}")

        stage_started = progress_start("copy_selection", page)
        copy_index = page.locator("flt-semantics[role='button']").evaluate_all("""nodes => {
          let best = -1, bottom = -Infinity;
          nodes.forEach((el, index) => {
            const label = ((el.getAttribute('aria-label') || '') + ' ' + (el.textContent || '')).trim().toLowerCase();
            const r = el.getBoundingClientRect();
            if (label === 'copy' && r.width > 0 && r.height > 0 && r.bottom > bottom) { best=index; bottom=r.bottom; }
          });
          return best;
        }""")
        copied_text = ""
        copy_ok = False
        try:
            page.context.grant_permissions(["clipboard-read", "clipboard-write"])
            if copy_index >= 0:
                copy_button = page.locator("flt-semantics[role='button']").nth(copy_index)
                copy_button.scroll_into_view_if_needed()
                bounds = copy_button.bounding_box()
                if not bounds:
                    raise RuntimeError("Copy button has no visible bounds")
                page.mouse.click(bounds["x"] + bounds["width"] / 2, bounds["y"] + bounds["height"] / 2)
                page.wait_for_timeout(100)
                copied_text = page.evaluate("navigator.clipboard.readText()")
                copy_ok = bool(copied_text.strip())
        except Exception:
            copy_ok = False
        selectable = page.locator("flt-semantics").evaluate_all("""nodes => {
          const el = nodes.find(node => (node.textContent || '').trim().length > 0);
          if (!el) return false;
          const selection = getSelection();
          const range = document.createRange();
          range.selectNodeContents(el);
          selection.removeAllRanges();
          selection.addRange(range);
          return selection.toString().trim().length > 0;
        }""")
        out["checks"]["copy_or_selection"] = copy_ok or selectable
        out["checks"]["selection"] = copy_ok or selectable
        out["copied_content_available"] = copy_ok
        progress_end("copy_selection", stage_started, out["checks"]["copy_or_selection"])
        out["checks"]["pdf_visual_qa"] = bool(out["reports"]) and all(
            report.get("passed") and report.get("text_verified") for report in out["reports"].values()
        )
        out["checks"]["scroll_structure"] = page.locator("flt-semantics").count() > 0 and page.evaluate(
            "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 2"
        )
        _, scrollable_count = scroll_metrics(page)
        scroll_state = {"count": scrollable_count,
                        "documentHeight": page.evaluate("document.documentElement.scrollHeight"),
                        "documentClientHeight": page.evaluate("document.documentElement.clientHeight")}
        # Flutter Web's ListView scroll is canvas/semantics-driven rather than
        # a DOM overflow node. Geometry movement proves that wheel input moved
        # that conversation; no more than one separate DOM vertical scroller is allowed.
        out["checks"]["single_vertical_scroll_container"] = (
            out["checks"].get("wheel_scroll_changes_conversation", False)
            and scroll_state["count"] <= 1
        )
        out["scroll_state"] = scroll_state
        page.screenshot(path=str(artifacts / "ui_acceptance.png"), full_page=False, timeout=5000)

        # Offline and stale-build simulations are isolated browser-network tests;
        # the real backend is not modified.
        try:
            page.route("**/v1/system/diagnostics", lambda route: route.fulfill(status=503, content_type="application/json", body=json.dumps({"success": False, "overall_status": "offline"})))
            stage_started = progress_start("offline_graceful", page)
            page.reload(wait_until="domcontentloaded", timeout=remaining_timeout_ms(deadline, 10000))
            offline_text = body_text(page)
            out["checks"]["offline_graceful"] = not bool(re.search(r"Traceback|Unhandled exception", offline_text, re.I))
            page.unroute("**/v1/system/diagnostics")
            progress_end("offline_graceful", stage_started, out["checks"]["offline_graceful"])
        except Exception as exc:
            out["checks"]["offline_graceful"] = False
            out["offline_error"] = type(exc).__name__
            capture_failure(page, evidence_dir, "offline_graceful", exc, console_errors, failed_requests)
            progress_end("offline_graceful", stage_started, False, type(exc).__name__)

        try:
            context.tracing.stop(path=str(evidence_dir / "trace.zip"))
        except Exception as exc:
            out["trace_error"] = type(exc).__name__
        out["browser_errors"] = {
            "console": console_errors[:50],
            "page": page_errors[:50],
            "requests": failed_requests[:50],
        }
        out["runtime_seconds"] = round(time.perf_counter() - suite_started, 2)
        context.close()
        atexit.unregister(close_browser_safely)
        browser.close()
        out["checks"]["chromium_cleanup"] = (
            not browser.is_connected()
            and not context.pages
        )

    query_ok = bool(out["queries"]) and all(v.get("passed") for v in out["queries"].values())
    report_ok = bool(out["reports"]) and all(v.get("passed") for v in out["reports"].values())
    structural_ok = all(bool(v) for v in out["checks"].values())
    out["passed"] = query_ok and report_ok and structural_ok
    checkpoint()
    atexit.unregister(checkpoint)
    print(f"[RESULT] passed={out['passed']} runtime={out['runtime_seconds']}s", flush=True)
    print(json.dumps(out), flush=True)
    return 0 if out["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
