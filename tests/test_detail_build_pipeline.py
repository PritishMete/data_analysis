from pathlib import Path


FLUTTER_ROOT = Path(r"C:\Users\jiban\Downloads\InsightFlow_secure_gemini_metadata_categorization_INR_v4")
SERVING_ROOT = Path(r"C:\Users\jiban\Downloads\data_analysis-main\data_analysis-main")
OUTPUT = SERVING_ROOT / "frontend" / "flutter_detail"


def test_standalone_build_script_targets_detail_output_without_excel_template():
    script = (FLUTTER_ROOT / "build_detail_analysis.ps1").read_text(encoding="utf-8")
    assert "lib\\detail_analysis_main.dart" in script
    assert "frontend\\flutter_detail" in script
    assert "--base-href $BaseHref" in script
    assert "office\\.js" in script
    assert "excel_helper.js" in script
    assert "native-star-schema" in script


def test_active_standalone_output_is_flutter_only():
    index = (OUTPUT / "index.html").read_text(encoding="utf-8")
    assert '<base href="/ui/">' in index
    assert "flutter_bootstrap.js" in index
    assert "office.js" not in index.casefold()
    assert (OUTPUT / "main.dart.js").is_file()
    assert (OUTPUT / "flutter_bootstrap.js").is_file()
    assert "native-star-schema" in (OUTPUT / "main.dart.js").read_text(encoding="utf-8")
    assert not any(path.name in {"excel_helper.js", "excel_data_processor.js", "excel_quality_report_generator.js"} for path in OUTPUT.rglob("*"))
