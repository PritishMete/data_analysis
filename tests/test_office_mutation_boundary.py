from pathlib import Path

MUTATIONS = {
    "apps/flutter_app/web/excel_helper.js": [
        "processExcelPipeline",
        "jsApplyColorScale",
        "jsAddComputedColumn",
        "jsWriteQueryResultToSheet",
        "jsExecuteLocalFilterQuery",
        "jsWriteRangeBinningFormulas",
        "jsAppendStaticColumn",
        "jsBuildWrapRowsTable",
        "jsSplitColumnPipeline",
    ],
    "apps/flutter_app/web/excel_native_chart.js": ["createNativeExcelChart"],
    "apps/flutter_app/web/excel_synthetic_data.js": ["executeSyntheticData"],
    "apps/flutter_app/web/excel_quality_report_generator.js": ["jsWriteQualityReportWorksheet"],
}


def _function_body(source: str, name: str) -> str:
    marker = f"async function {name}("
    start = source.index(marker)
    next_start = source.find("\nasync function ", start + len(marker))
    return source[start:] if next_start == -1 else source[start:next_start]


def test_every_office_mutation_entry_point_requires_server_authorization():
    for path, names in MUTATIONS.items():
        source = Path(path).read_text(encoding="utf-8")
        for name in names:
            body = _function_body(source, name)
            run_index = body.find("Excel.run")
            guard_index = body.find("insightflowRequireMutationAuthorization")
            assert run_index >= 0, f"{name} must use Excel.run"
            assert 0 <= guard_index < run_index, (
                f"{name} must authorize before the Office.js mutation batch"
            )


def test_mutation_guard_is_loaded_before_mutation_engines():
    html = Path("apps/flutter_app/web/index.html").read_text(encoding="utf-8")
    guard = html.index("excel_authorization_guard.js")
    helper = html.index("excel_helper.js")
    assert guard < helper
