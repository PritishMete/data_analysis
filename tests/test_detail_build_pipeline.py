from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
FLUTTER_ROOT = REPO_ROOT / "flutter_detail_source"
SERVING_ROOT = REPO_ROOT / "frontend" / "flutter_detail"


def test_standalone_build_script_targets_detail_output_without_excel_template():
    script = (FLUTTER_ROOT / "build_detail_analysis.ps1").read_text(encoding="utf-8")
    assert "lib\\detail_analysis_main.dart" in script
    assert "frontend\\flutter_detail" in script
    assert "'--base-href'" in script
    assert "$BaseHref" in script
    assert "'--target'" in script
    assert "$Target" in script
    assert "office\\.js" in script
    assert "excel_helper.js" in script
    assert "native-star-schema" in script


def test_active_standalone_output_is_flutter_only():
    """Validate local/generated deployment output when it is available."""
    index_path = SERVING_ROOT / "index.html"
    if not index_path.is_file():
        pytest.skip(
            "Standalone deployed Flutter output is generated locally and is not present in repository CI."
        )

    index = index_path.read_text(encoding="utf-8")
    assert '<base href="/ui/">' in index
    assert "flutter_bootstrap.js" in index
    assert "office.js" not in index.casefold()
    assert (SERVING_ROOT / "main.dart.js").is_file()
    assert (SERVING_ROOT / "flutter_bootstrap.js").is_file()
    assert "native-star-schema" in (SERVING_ROOT / "main.dart.js").read_text(encoding="utf-8")
    assert not any(
        path.name in {"excel_helper.js", "excel_data_processor.js", "excel_quality_report_generator.js"}
        for path in SERVING_ROOT.rglob("*")
    )
