"""Verify the contract of the deployed Excel-enabled Flutter web build.

This intentionally checks only public build assets and the deployment marker.
It does not read workbook data or call the InsightFlow backend.
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen


REQUIRED_INDEX_SNIPPETS = (
    'https://appsforoffice.microsoft.com/lib/1/hosted/office.js',
    'excel_data_processor.js',
    'excel_helper.js',
    'excel_quality_report_generator.js',
    'meta name="detail-analysis-build-id"',
)

REQUIRED_MAIN_SNIPPETS = (
    "http://127.0.0.1:8000",
    "quality_check",
    "source_mutated",
)


def _assert_build(root: Path, expected_commit: str) -> None:
    index = root / "index.html"
    bootstrap = root / "flutter_bootstrap.js"
    main_js = root / "main.dart.js"

    for path in (index, bootstrap, main_js):
        if not path.is_file():
            raise AssertionError(f"missing required build asset: {path}")

    index_text = index.read_text(encoding="utf-8")
    for snippet in REQUIRED_INDEX_SNIPPETS:
        if snippet not in index_text:
            raise AssertionError(f"index.html missing required Excel asset: {snippet}")

    marker = f'<meta name="detail-analysis-build-id" content="{expected_commit}">'
    if marker not in index_text:
        raise AssertionError("deployment marker does not match the intended source commit")

    main_text = main_js.read_text(encoding="utf-8", errors="ignore")
    for snippet in REQUIRED_MAIN_SNIPPETS:
        if snippet not in main_text:
            raise AssertionError(f"deployed Flutter bundle is missing secure Excel marker: {snippet}")

    if "(?i)\\bout\\s+of\\b" in main_text:
        raise AssertionError("deployed main.dart.js still contains the unsupported Dart regex flag")

    if "__INSIGHTFLOW_BUILD_COMMIT__" in index_text:
        raise AssertionError("build marker placeholder was not replaced")


def _fetch(url: str) -> str:
    request = Request(url, headers={"User-Agent": "InsightFlow-Excel-Deployment-Check/1.0"})
    with urlopen(request, timeout=20) as response:
        return response.read().decode("utf-8", errors="replace")


def _assert_live(base_url: str, expected_commit: str) -> None:
    base = base_url.rstrip("/") + "/"
    index_text = _fetch(base)
    for snippet in REQUIRED_INDEX_SNIPPETS:
        if snippet not in index_text:
            raise AssertionError(f"live taskpane missing required Excel asset reference: {snippet}")

    marker = f'<meta name="detail-analysis-build-id" content="{expected_commit}">'
    if marker not in index_text:
        raise AssertionError("live taskpane is not serving the intended source commit")

    bootstrap = _fetch(base + "flutter_bootstrap.js")
    if "main.dart.js" not in bootstrap:
        raise AssertionError("live Flutter bootstrap does not reference main.dart.js")

    main_text = _fetch(base + "main.dart.js")
    for snippet in REQUIRED_MAIN_SNIPPETS:
        if snippet not in main_text:
            raise AssertionError(f"live Flutter bundle is missing secure Excel marker: {snippet}")
    if "(?i)\\bout\\s+of\\b" in main_text:
        raise AssertionError("live main.dart.js still contains the unsupported Dart regex flag")

    for asset in (
        "excel_data_processor.js",
        "excel_helper.js",
        "excel_quality_report_generator.js",
    ):
        asset_text = _fetch(base + asset)
        if not asset_text.strip():
            raise AssertionError(f"live Excel helper asset is empty: {asset}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--url")
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--retries", type=int, default=1)
    parser.add_argument("--delay", type=float, default=2.0)
    args = parser.parse_args()

    if bool(args.directory) == bool(args.url):
        parser.error("provide exactly one of --directory or --url")

    if args.directory:
        _assert_build(args.directory, args.expected_commit)
        print(f"Excel add-in build contract passed for {args.expected_commit}")
        return 0

    last_error: Exception | None = None
    for attempt in range(1, max(args.retries, 1) + 1):
        try:
            _assert_live(args.url, args.expected_commit)
            print(f"Live Excel taskpane contract passed for {args.expected_commit}")
            return 0
        except (AssertionError, OSError, URLError) as exc:
            last_error = exc
            if attempt < max(args.retries, 1):
                time.sleep(args.delay)

    raise SystemExit(f"live deployment verification failed: {last_error}")


if __name__ == "__main__":
    raise SystemExit(main())
