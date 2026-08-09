// web/excel_quality_report_generator.js
// ─────────────────────────────────────────────────────────────────────────────
// Exports a full, professional, multi-section "Quality_Report" worksheet built
// directly from the SAME analysis result already shown inside the AI Report
// tab's "DATA QUALITY" card (AiReport.dataQuality), plus the sibling fields
// on that same backend response (statistics, outliers, recommendations,
// executive_summary, chart_recommendation) and a small amount of dataset
// overview context (name / row & column counts) supplied by the Flutter
// layer from state that's already on hand.
//
// This module performs NO analysis of its own. It never calls the backend,
// never recomputes a metric, and never invents a number. Every value it
// writes is either:
//   (a) read directly off the payload handed to it, under one of a small
//       set of known/likely key aliases (backend field naming has varied
//       slightly across endpoints in this project, e.g. "duplicate_rows"
//       vs "duplicates": {"count": n} — see _pick()/_pickCount()), or
//   (b) a short, clearly-labelled presentational fallback (e.g. a generic
//       "Impute or review" suggestion for a column with no backend-supplied
//       suggested_treatment) that is never used in place of real backend
//       data when real backend data is present.
//
// Any key present in `dataQuality` that isn't recognised by one of the
// named sections below still gets surfaced, verbatim, in the "Additional
// Quality Metrics" table at the end of Section 2 — so nothing silently
// disappears just because this file doesn't have a label for it yet.
//
// Called from Dart via jsWriteQualityReportWorksheet(optionsJson), which is
// wired to writeQualityReportWorksheet() in
// lib/core/interop/excel_interop_web.dart. See DataScreenState
// .exportQualityReportToExcel() in lib/features/dashboard/data_screen.dart
// for how the payload is assembled from AiReport.
// ─────────────────────────────────────────────────────────────────────────────

// ── Palette (kept local to this file; matches the app's dark/blue tech theme
//    closely enough for an exported artifact without importing UI code) ────
const _QR_COLORS = {
    titleFill: "#12233F",
    titleFont: "#FFFFFF",
    sectionFill: "#1B3A5C",
    sectionFont: "#FFFFFF",
    headerFill: "#D9E4F1",
    headerFont: "#12233F",
    bandFill: "#F3F6FA",
    borderColor: "#C7D2DE",
    good: "#C6EFCE",
    goodFont: "#256B36",
    warn: "#FFE9B3",
    warnFont: "#8A5A00",
    bad: "#F8C9C9",
    badFont: "#A32020",
    labelFont: "#12233F",
};

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────
async function jsWriteQualityReportWorksheet(optionsJson) {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") {
        return { success: false, sheet: null, rowsWritten: 0, error: "Excel context unallocated" };
    }

    let opts;
    try {
        opts = JSON.parse(optionsJson);
    } catch (err) {
        return { success: false, sheet: null, rowsWritten: 0, error: "Invalid options JSON: " + err.toString() };
    }

    // ── Runtime payload diagnostics (DevTools console) ───────────────────
    // Logs exactly what arrives at the JS layer so dtype-path failures
    // can be diagnosed without adding any new state or API calls.
    console.log("[QualityReport] payload keys:", Object.keys(opts));
    console.log("[QualityReport] columnNames:", (opts.columnNames || []).slice(0, 5), "(first 5)");
    console.log("[QualityReport] describe rows:", Array.isArray(opts.describe) ? opts.describe.length : "none",
        "— index values:", Array.isArray(opts.describe) ? opts.describe.map(r => r["index"]) : []);
    const _diag_dtypeRow = Array.isArray(opts.describe)
        ? opts.describe.find(r => ["dtype","dtypes","Dtype","DType","data type","type"].includes(r["index"]))
        : null;
    console.log("[QualityReport] dtypeRow found:", !!_diag_dtypeRow, _diag_dtypeRow ? "(first 3 cols: " + JSON.stringify(Object.entries(_diag_dtypeRow).slice(0,4)) + ")" : "");
    // These are the EXACT fields the Quality Tab widgets display, passed
    // through verbatim from _buildQualityReportPayload() in data_screen.dart.
    // No analysis is repeated here; these are reads of existing values only.

    // AI Report fields (only populated after /analyze-report is called)
    const dataQuality = (opts.dataQuality && typeof opts.dataQuality === "object") ? opts.dataQuality : {};
    const statistics = (opts.statistics && typeof opts.statistics === "object") ? opts.statistics : {};
    const executiveSummary = (opts.executiveSummary && typeof opts.executiveSummary === "object") ? opts.executiveSummary : {};
    const recommendations = Array.isArray(opts.recommendations) ? opts.recommendations : [];
    const outliers = Array.isArray(opts.outliers) ? opts.outliers : [];
    const chartRecommendation = (opts.chartRecommendation && typeof opts.chartRecommendation === "object") ? opts.chartRecommendation : {};

    // /analyze fields — these ARE available after every scan (Quality Tab source)
    // missing_values: {"ColName": count} — client-side computed, exact Quality Tab source
    const missingValuesByColumn = (opts.missingValuesByColumn && typeof opts.missingValuesByColumn === "object")
        ? opts.missingValuesByColumn : {};
    // unique_values: {"ColName": count} — client-side computed, exact Quality Tab source
    const uniqueValuesByColumn = (opts.uniqueValuesByColumn && typeof opts.uniqueValuesByColumn === "object")
        ? opts.uniqueValuesByColumn : {};
    // columnNames: ordered list from summary.column_names — same as Quality Tab column list
    const columnNames = Array.isArray(opts.columnNames) ? opts.columnNames : [];
    // describe: list of statistic row-maps (the Statistics matrix in Analysis tab)
    const describe = Array.isArray(opts.describe) ? opts.describe : [];
    // duplicatesRaw: full duplicates map from backend (may contain more than just count)
    const duplicatesRaw = (opts.duplicatesRaw && typeof opts.duplicatesRaw === "object") ? opts.duplicatesRaw : {};
    // dtypesByColumn: top-level {"ColName": "dtype"} map from the backend.
    // Secondary dtype source alongside the describe dtype row — whichever
    // is actually populated at runtime wins (describe row takes priority
    // since it's the authoritative pandas output).
    const dtypesByColumn = (opts.dtypesByColumn && typeof opts.dtypesByColumn === "object") ? opts.dtypesByColumn : {};

    const hasAnything =
        Object.keys(dataQuality).length > 0 ||
        Object.keys(statistics).length > 0 ||
        Object.keys(executiveSummary).length > 0 ||
        recommendations.length > 0 ||
        outliers.length > 0 ||
        Object.keys(missingValuesByColumn).length > 0 ||
        Object.keys(uniqueValuesByColumn).length > 0 ||
        columnNames.length > 0 ||
        describe.length > 0 ||
        opts.rows !== undefined || opts.columns !== undefined ||
        opts.missingValues !== undefined || opts.duplicateRows !== undefined;
    if (!hasAnything) {
        return { success: false, sheet: null, rowsWritten: 0, error: "No analysis data available yet." };
    }

    const sheetName = String(opts.sheetName || "Quality_Report").substring(0, 31);
    // Explicit export button leaves this unset (defaults true) so the user
    // sees the sheet they just asked for. The automatic background sync
    // passes activate:false so a routine scan never yanks the user's view
    // away from whatever sheet they're currently looking at.
    const shouldActivate = opts.activate !== false;

    try {
        return await Excel.run(async function (context) {
            const workbook = context.workbook;

            // Only needed when we must restore the view afterwards.
            let previousSheetName = null;
            let previousSelectionAddress = null;
            if (!shouldActivate) {
                const previousSheet = workbook.worksheets.getActiveWorksheet();
                previousSheet.load("name");
                let previousSelection = null;
                try {
                    previousSelection = workbook.getSelectedRange();
                    previousSelection.load("address");
                } catch (_) {
                    previousSelection = null;
                }
                await context.sync();
                previousSheetName = previousSheet.name;
                previousSelectionAddress = previousSelection ? previousSelection.address : null;
            }

            const sheets = workbook.worksheets;
            sheets.load("items/name");
            await context.sync();

            let sheet = null;
            for (const s of sheets.items) {
                if (s.name === sheetName) { sheet = s; break; }
            }
            if (!sheet) {
                sheet = workbook.worksheets.add(sheetName);
            } else {
                const used = sheet.getUsedRangeOrNullObject(true);
                await context.sync();
                if (!used.isNullObject) {
                    used.clear(Excel.ClearApplyTo.all);
                    await context.sync();
                }
            }

            const NUM_COLS = 8; // adjusted to actual max useful columns
            let row = 0;
            const consumedKeys = new Set();

            // ── Title ──────────────────────────────────────────────────────
            row = _writeTitle(sheet, row, "Data Quality Report", NUM_COLS);
            row += 1;

            // ══════════════════════════════════════════════════════════════
            // PIPELINE A — SCAN ANALYSIS (/analyze)
            // Source: analysisData (DataScreenState.analysisData)
            // Available after every "Analyze" action.
            // Fields: rows, columns, missing_values, unique_values,
            //         duplicates.count, summary.column_names, describe
            // These are the exact values the Quality tab displays.
            // ══════════════════════════════════════════════════════════════

            // ── Section 1: Quality Overview (Scan Pipeline) ───────────────
            row = _writeSectionHeader(sheet, row, "1. QUALITY OVERVIEW  ·  Source: Dataset Scan", NUM_COLS);
            row = _writeOverview(sheet, row, opts, dataQuality, statistics, consumedKeys);
            row += 1;

            // ── Section 2: Column Quality (Scan + AI merged) ──────────────
            // Column entries are built from:
            //  • missingValuesByColumn  — client-side computed, exact Quality tab source
            //  • uniqueValuesByColumn   — client-side computed, exact Quality tab source
            //  • columnNames            — ordered list from scan
            //  • dataQuality / statistics column_quality — from AI report, if available
            const columnEntries = _extractColumnEntries(
                dataQuality, statistics, consumedKeys,
                missingValuesByColumn, uniqueValuesByColumn, columnNames);

            row = _writeSectionHeader(sheet, row, "2. COLUMN QUALITY  ·  Source: Dataset Scan (+ AI report if available)", NUM_COLS);
            const colQualityResult = _writeColumnQuality(sheet, row, columnEntries);
            row = colQualityResult.nextRow;
            row += 1;

            // ── Section 3: Missing Value Analysis (Scan Pipeline) ─────────
            row = _writeSectionHeader(sheet, row, "3. MISSING VALUE ANALYSIS  ·  Source: Dataset Scan", NUM_COLS);
            row = _writeMissingValueAnalysis(sheet, row, columnEntries, opts.rows);
            row += 1;

            // ── Section 4: Duplicate Analysis (Scan Pipeline) ─────────────
            row = _writeSectionHeader(sheet, row, "4. DUPLICATE ANALYSIS  ·  Source: Dataset Scan", NUM_COLS);
            row = _writeDuplicateAnalysis(sheet, row, dataQuality, opts, consumedKeys);
            row += 1;

            // ── Section 5: Column Data Types (Scan Pipeline) ─────────────
            // Two sources, tried in priority order:
            //   1. describe dtype row (authoritative pandas output)
            //   2. dtypesByColumn top-level map (some backends return this)
            // The section is ALWAYS written when column names are known,
            // showing "Not available" per column if neither source has data.
            {
                const dtypeRow = describe.length > 0
                    ? (describe.find(r =>
                        r["index"] === "dtype" ||
                        r["index"] === "dtypes" ||
                        r["index"] === "Dtype" ||
                        r["index"] === "DType" ||
                        r["index"] === "data type" ||
                        r["index"] === "type"
                      ) || null)
                    : null;
                console.log("[QualityReport] Section 5 dtypeRow:", dtypeRow ? "found in describe" : "not in describe",
                    "| dtypesByColumn keys:", Object.keys(dtypesByColumn).length);
                if (columnNames.length > 0 || dtypeRow || Object.keys(dtypesByColumn).length > 0) {
                    row = _writeSectionHeader(sheet, row, "5. COLUMN DATA TYPES  ·  Source: Dataset Scan", NUM_COLS);
                    row = _writeColumnDataTypes(sheet, row, dtypeRow, dtypesByColumn, columnNames);
                    row += 1;
                }
            }

            // ── Section 6: Statistics Matrix (Scan Pipeline) ──────────────
            if (describe.length > 0) {
                row = _writeSectionHeader(sheet, row, "6. STATISTICS MATRIX  ·  Source: Dataset Scan", NUM_COLS);
                row = _writeDescribeMatrix(sheet, row, describe);
                row += 1;
            }

            // ══════════════════════════════════════════════════════════════
            // PIPELINE B — AI REPORT (/analyze-report)
            // Source: AiReport (DataScreenState.aiReport)
            // Only available after "Generate Report" is explicitly run.
            // Fields: dataQuality (generic map), statistics (generic map),
            //         outliers, recommendations, executiveSummary,
            //         chartRecommendation
            // These are the values the Report Tab's AI cards display.
            // ══════════════════════════════════════════════════════════════

            const hasAiReport = Object.keys(dataQuality).length > 0 ||
                Object.keys(statistics).length > 0 ||
                Object.keys(executiveSummary).length > 0 ||
                recommendations.length > 0 ||
                outliers.length > 0 ||
                opts.outlierAnalysisPresent === true;

            if (hasAiReport) {
                row = _writeSectionHeader(sheet, row, "AI QUALITY REPORT  ·  Source: AI Analysis (/analyze-report)", NUM_COLS);
                row += 1;

                // ── AI Data Quality (generic key-value from dataQuality map) ──
                if (Object.keys(dataQuality).length > 0) {
                    row = _writeSectionHeader(sheet, row, "AI DATA QUALITY", NUM_COLS);
                    row = _writeAiDataQuality(sheet, row, dataQuality, statistics, opts, consumedKeys);
                    row += 1;
                }

                // ── AI Outlier Analysis ────────────────────────────────────────
                row = _writeSectionHeader(sheet, row, "AI OUTLIER ANALYSIS", NUM_COLS);
                row = _writeOutlierAnalysis(sheet, row, outliers, dataQuality, opts.outlierAnalysisPresent === true, consumedKeys);
                row += 1;

                // ── AI Recommendations ────────────────────────────────────────
                if (recommendations.length > 0) {
                    row = _writeSectionHeader(sheet, row, "AI RECOMMENDATIONS", NUM_COLS);
                    row = _writeRecommendations(sheet, row, recommendations);
                    row += 1;
                }

                // ── AI Executive Summary ──────────────────────────────────────
                if (Object.keys(executiveSummary).length > 0 || (opts.reportText && opts.reportText.trim())) {
                    row = _writeSectionHeader(sheet, row, "EXECUTIVE SUMMARY", NUM_COLS);
                    row = _writeExecutiveSummary(sheet, row, executiveSummary, opts.reportText);
                    row += 1;
                }

                // ── AI Statistics ──────────────────────────────────────────────
                if (Object.keys(statistics).length > 0) {
                    row = _writeSectionHeader(sheet, row, "AI STATISTICS", NUM_COLS);
                    row = _writeKeyValueTable(sheet, row, statistics);
                    row += 1;
                }

                // ── Chart Recommendation ───────────────────────────────────────
                if (Object.keys(chartRecommendation).length > 0) {
                    row = _writeSectionHeader(sheet, row, "AI CHART RECOMMENDATION", NUM_COLS);
                    row = _writeKeyValueTable(sheet, row, chartRecommendation);
                    row += 1;
                }

                // ── Any remaining unconsumed dataQuality keys ──────────────────
                row = _writeLeftovers(sheet, row, dataQuality, consumedKeys, NUM_COLS);
            }

            // ── Sheet-wide formatting ─────────────────────────────────────────
            sheet.freezePanes.freezeRows(1);
            const usedRange = sheet.getUsedRange();
            usedRange.format.autofitColumns();
            usedRange.format.autofitRows();
            try {
                if (colQualityResult.headerRange) {
                    sheet.autoFilter.remove();
                    sheet.autoFilter.apply(colQualityResult.dataRangeForFilter);
                }
            } catch (_) {
                // AutoFilter is a nice-to-have; never fail the export over it.
            }

            if (shouldActivate) {
                sheet.activate();
            } else if (previousSheetName) {
                // Background/automatic sync — restore whatever the user was
                // looking at instead of yanking them onto the report sheet.
                try {
                    const sheetToRestore = workbook.worksheets.getItem(previousSheetName);
                    sheetToRestore.activate();
                    if (previousSelectionAddress) {
                        sheetToRestore.getRange(previousSelectionAddress).select();
                    }
                } catch (_) {
                    // Previous sheet may have been removed/renamed — non-fatal.
                }
            }
            await context.sync();

            return { success: true, sheet: sheetName, rowsWritten: row, error: null };
        });
    } catch (err) {
        console.error("QualityReportGen: Error generating quality report", err.toString());
        return { success: false, sheet: null, rowsWritten: 0, error: err.toString() };
    }
}

window.jsWriteQualityReportWorksheet = jsWriteQualityReportWorksheet;

// ─────────────────────────────────────────────────────────────────────────────
// Generic payload helpers — no analysis, just careful reading of what's there.
// ─────────────────────────────────────────────────────────────────────────────

// Returns the first defined, non-null value found in `obj` for any key in
// `keys` (case-sensitive first pass, then a case-insensitive pass). Marks the
// matching key as consumed so Section-2/leftover reporting doesn't double-list it.
function _pick(obj, keys, consumedKeys) {
    if (!obj || typeof obj !== "object") return undefined;
    for (const k of keys) {
        if (Object.prototype.hasOwnProperty.call(obj, k) && obj[k] !== null && obj[k] !== undefined) {
            if (consumedKeys) consumedKeys.add(k);
            return obj[k];
        }
    }
    const lowerMap = {};
    for (const realKey of Object.keys(obj)) lowerMap[realKey.toLowerCase()] = realKey;
    for (const k of keys) {
        const realKey = lowerMap[k.toLowerCase()];
        if (realKey !== undefined && obj[realKey] !== null && obj[realKey] !== undefined) {
            if (consumedKeys) consumedKeys.add(realKey);
            return obj[realKey];
        }
    }
    return undefined;
}

// Unwraps shapes like {"count": 12} or {"value": 12} down to a plain number,
// matching how "duplicates" is shaped on at least one existing backend
// response in this project (see _syncQualityReport in data_screen.dart).
function _pickCount(obj, keys, consumedKeys) {
    const v = _pick(obj, keys, consumedKeys);
    if (v === undefined) return undefined;
    if (typeof v === "object" && v !== null) {
        return v.count ?? v.value ?? v.total ?? undefined;
    }
    return v;
}

function _num(v) {
    if (v === null || v === undefined || v === "") return null;
    const n = typeof v === "number" ? v : Number(v);
    return Number.isFinite(n) ? n : null;
}

function _fmtNum(v, decimals) {
    const n = _num(v);
    if (n === null) return "N/A";
    return decimals === undefined ? String(n) : n.toFixed(decimals);
}

function _fmtPct(v) {
    const n = _num(v);
    return n === null ? "N/A" : n.toFixed(2) + "%";
}

// Renders any value (string/number/list/map) as readable text, the same way
// the AI Report tab's generic _resultEntry() renderer does in report_tab.dart,
// so the worksheet never shows "[object Object]".
function _fmtAny(v) {
    if (v === null || v === undefined) return "N/A";
    if (Array.isArray(v)) return v.map(_fmtAny).join(", ");
    if (typeof v === "object") {
        return Object.entries(v).map(([k, val]) => k + ": " + _fmtAny(val)).join("; ");
    }
    return String(v);
}

function _titleCase(key) {
    return String(key)
        .replace(/_/g, " ")
        .replace(/\b\w/g, (c) => c.toUpperCase());
}

// Quality Score/Grade aren't guaranteed to live in one fixed place — this
// project's backend has put related fields directly in `data_quality`, but
// nothing rules out `statistics`, or one level of nesting under a wrapper
// key some backends use (e.g. an "overview"/"summary" sub-object). This is
// the SINGLE lookup used by every section that needs Quality Score/Grade
// (Section 1 Overview and Section 2 Data Quality Summary both call this
// rather than each re-implementing their own search), so there is exactly
// one place that defines "where the score comes from".
const _SCORE_KEYS = ["quality_score", "score", "overall_score", "overall_quality_score"];
const _GRADE_KEYS = ["quality_grade", "grade"];
const _WRAPPER_KEYS = ["overview", "summary", "overall", "quality_overview"];

function _pickQualityScoreAndGrade(dq, statistics, consumedKeys) {
    const sources = [
        { obj: dq, consumed: consumedKeys },
        { obj: statistics, consumed: null },
    ];
    const lookup = (keys) => {
        for (const src of sources) {
            const direct = _pick(src.obj, keys, src.consumed);
            if (direct !== undefined) return direct;
        }
        for (const src of sources) {
            for (const wrapperKey of _WRAPPER_KEYS) {
                const wrapper = src.obj && typeof src.obj === "object" ? src.obj[wrapperKey] : undefined;
                if (wrapper && typeof wrapper === "object") {
                    const nested = _pick(wrapper, keys, null);
                    if (nested !== undefined) return nested;
                }
            }
        }
        return undefined;
    };
    return { score: lookup(_SCORE_KEYS), grade: lookup(_GRADE_KEYS) };
}

// ─────────────────────────────────────────────────────────────────────────────
// Low-level sheet writers
// ─────────────────────────────────────────────────────────────────────────────

function _writeTitle(sheet, row, title, numCols) {
    const range = sheet.getRangeByIndexes(row, 0, 1, numCols);
    range.merge(false);
    const cell = sheet.getRangeByIndexes(row, 0, 1, 1);
    cell.values = [[title]];
    range.format.font.bold = true;
    range.format.font.size = 20;
    range.format.font.color = _QR_COLORS.titleFont;
    range.format.fill.color = _QR_COLORS.titleFill;
    range.format.horizontalAlignment = "Left";
    range.format.verticalAlignment = "Center";
    range.format.rowHeight = 32;
    return row + 1;
}

function _writeSectionHeader(sheet, row, title, numCols) {
    const range = sheet.getRangeByIndexes(row, 0, 1, numCols);
    range.merge(false);
    const cell = sheet.getRangeByIndexes(row, 0, 1, 1);
    cell.values = [[title]];
    range.format.font.bold = true;
    range.format.font.size = 12;
    range.format.font.color = _QR_COLORS.sectionFont;
    range.format.fill.color = _QR_COLORS.sectionFill;
    range.format.rowHeight = 22;
    return row + 1;
}

// Writes a two-column Label | Value block. `pairs` is an array of [label, value].
function _writeKeyValueBlock(sheet, row, pairs, opts) {
    opts = opts || {};
    const values = pairs.map(([label]) => [label]);
    const labelRange = sheet.getRangeByIndexes(row, 0, pairs.length, 1);
    labelRange.values = values;
    labelRange.format.font.bold = true;
    labelRange.format.font.color = _QR_COLORS.labelFont;

    const valRange = sheet.getRangeByIndexes(row, 1, pairs.length, 1);
    valRange.values = pairs.map(([, v]) => [v]);

    if (opts.severity) {
        pairs.forEach(([label, value], i) => {
            const sev = opts.severity(label, value);
            if (sev) _fillCell(sheet, row + i, 1, sev);
        });
    }
    return row + pairs.length;
}

// Renders an arbitrary map as a Label | Value table (used for Executive
// Summary and Chart Recommendation, whose shapes aren't fixed by this file).
function _writeKeyValueTable(sheet, row, map) {
    const entries = Object.entries(map).filter(([, v]) => v !== null && v !== undefined && v !== "");
    if (entries.length === 0) {
        sheet.getRangeByIndexes(row, 0, 1, 1).values = [["No data available."]];
        return row + 1;
    }
    const headerRow = row;
    sheet.getRangeByIndexes(headerRow, 0, 1, 2).values = [["Field", "Value"]];
    _styleHeaderRow(sheet, headerRow, 2);
    row += 1;
    entries.forEach(([k, v], i) => {
        const wrap = typeof v === "string" && v.length > 60;
        const r = sheet.getRangeByIndexes(row + i, 0, 1, 2);
        r.values = [[_titleCase(k), _fmtAny(v)]];
        if (i % 2 === 1) r.format.fill.color = _QR_COLORS.bandFill;
        if (wrap) r.getCell(0, 1).format.wrapText = true;
    });
    return row + entries.length;
}

function _styleHeaderRow(sheet, row, numCols) {
    const header = sheet.getRangeByIndexes(row, 0, 1, numCols);
    header.format.font.bold = true;
    header.format.fill.color = _QR_COLORS.headerFill;
    header.format.font.color = _QR_COLORS.headerFont;
}

function _fillCell(sheet, row, col, severity) {
    const cell = sheet.getRangeByIndexes(row, col, 1, 1);
    if (severity === "bad") {
        cell.format.fill.color = _QR_COLORS.bad;
        cell.format.font.color = _QR_COLORS.badFont;
    } else if (severity === "warn") {
        cell.format.fill.color = _QR_COLORS.warn;
        cell.format.font.color = _QR_COLORS.warnFont;
    } else if (severity === "good") {
        cell.format.fill.color = _QR_COLORS.good;
        cell.format.font.color = _QR_COLORS.goodFont;
    }
}

// Severity classification for "bad-when-high" percentage metrics (missing %,
// duplicate %, outlier %, etc.) — purely a presentation choice about numbers
// the backend already returned, not a new statistic.
function _severityHighIsBad(pct) {
    const n = _num(pct);
    if (n === null) return null;
    if (n > 20) return "bad";
    if (n >= 5) return "warn";
    return "good";
}

// Severity classification for "good-when-high" scores (Quality Score 0-100).
function _severityHighIsGood(score) {
    const n = _num(score);
    if (n === null) return null;
    if (n >= 80) return "good";
    if (n >= 50) return "warn";
    return "bad";
}

// Writes a full table: header row + banded data rows. `columns` is an array
// of {label, key, width?, wrap?, severity? (row => 'good'|'warn'|'bad'|null)}.
// `rows` is an array of plain objects already resolved to display values.
function _writeTable(sheet, row, columns, rows) {
    const numCols = columns.length;
    if (rows.length === 0) {
        sheet.getRangeByIndexes(row, 0, 1, 1).values = [["No data available."]];
        return { nextRow: row + 1, headerRange: null, dataRangeForFilter: null };
    }
    const headerValues = [columns.map((c) => c.label)];
    const headerRange = sheet.getRangeByIndexes(row, 0, 1, numCols);
    headerRange.values = headerValues;
    _styleHeaderRow(sheet, row, numCols);

    const dataStartRow = row + 1;
    const matrix = rows.map((r) => columns.map((c) => (r[c.key] === undefined || r[c.key] === null) ? "" : r[c.key]));
    const dataRange = sheet.getRangeByIndexes(dataStartRow, 0, rows.length, numCols);
    dataRange.values = matrix;

    // Banding + per-column wrap + severity fills.
    for (let i = 0; i < rows.length; i++) {
        if (i % 2 === 1) {
            sheet.getRangeByIndexes(dataStartRow + i, 0, 1, numCols).format.fill.color = _QR_COLORS.bandFill;
        }
        columns.forEach((c, colIdx) => {
            if (c.wrap) {
                sheet.getRangeByIndexes(dataStartRow + i, colIdx, 1, 1).format.wrapText = true;
            }
            if (c.severity) {
                const sev = c.severity(rows[i]);
                if (sev) _fillCell(sheet, dataStartRow + i, colIdx, sev);
            }
        });
    }

    const fullRange = sheet.getRangeByIndexes(row, 0, rows.length + 1, numCols);
    fullRange.format.borders.getItem("EdgeTop").style = "Continuous";
    fullRange.format.borders.getItem("EdgeBottom").style = "Continuous";
    fullRange.format.borders.getItem("EdgeLeft").style = "Continuous";
    fullRange.format.borders.getItem("EdgeRight").style = "Continuous";
    fullRange.format.borders.getItem("InsideHorizontal").style = "Continuous";
    fullRange.format.borders.getItem("InsideVertical").style = "Continuous";

    return { nextRow: dataStartRow + rows.length, headerRange, dataRangeForFilter: fullRange };
}

// ─────────────────────────────────────────────────────────────────────────────
// Section builders
// ─────────────────────────────────────────────────────────────────────────────

function _writeOverview(sheet, row, opts, dq, statistics, consumedKeys) {
    const rowsCount = opts.rows ?? _pick(dq, ["rows", "total_rows", "row_count", "n_rows"], consumedKeys);
    const colsCount = opts.columns ?? _pick(dq, ["columns", "total_columns", "column_count", "n_columns"], consumedKeys);

    // Quality Score/Grade: only shown when the AI report actually contains
    // them. Never shown as N/A — if absent, the row is omitted entirely
    // rather than making the report look broken.
    const { score: qualityScore, grade: qualityGrade } = _pickQualityScoreAndGrade(dq, statistics, consumedKeys);

    const missingValues = opts.missingValues;
    const missingByColumn = (opts.missingValuesByColumn && typeof opts.missingValuesByColumn === "object") ? opts.missingValuesByColumn : {};
    const hasMissingByColumn = Object.keys(missingByColumn).length > 0;
    const columnsWithMissing = Object.values(missingByColumn).filter((v) => (_num(v) ?? 0) > 0).length;

    // duplicateRows comes from analysisData['duplicates']['count'] — always
    // a number (including 0) after a scan. A value of 0 must render as "0",
    // never as N/A. We use explicit null-check, not falsy check, to preserve 0.
    const duplicateRows = opts.duplicateRows !== null && opts.duplicateRows !== undefined
        ? opts.duplicateRows : undefined;
    // Duplicate %: only from the source — never calculated or defaulted.
    const duplicatePct = _pick(dq, ["duplicate_percentage", "duplicate_pct", "duplicate_rate"], consumedKeys);
    const memoryUsage = _pick(dq, ["memory_usage", "memory", "memory_mb", "memory_usage_mb"], consumedKeys);

    // Build pairs — only include rows where we have actual values.
    // Fields with no source are omitted (not shown as N/A) to avoid
    // making the report look broken or fabricated.
    const pairs = [];
    pairs.push(["Dataset Name", opts.datasetName || "Unknown"]);
    pairs.push(["Generated", opts.generatedAt || new Date().toLocaleString()]);
    if (rowsCount !== undefined && rowsCount !== null) pairs.push(["Rows", _fmtNum(rowsCount, 0)]);
    if (colsCount !== undefined && colsCount !== null) pairs.push(["Columns", _fmtNum(colsCount, 0)]);
    // Quality Score/Grade only when a real value exists (from AI report)
    if (qualityScore !== undefined) pairs.push(["Quality Score (AI)", _fmtNum(qualityScore, 1)]);
    if (qualityGrade !== undefined) pairs.push(["Quality Grade (AI)", _fmtAny(qualityGrade)]);
    // Missing values from scan pipeline (always available after scan)
    if (missingValues !== undefined && missingValues !== null) pairs.push(["Total Missing Values", _fmtNum(missingValues, 0)]);
    if (hasMissingByColumn) pairs.push(["Columns With Missing Values", _fmtNum(columnsWithMissing, 0)]);
    // Duplicates — explicit null-check so 0 renders as "0" not N/A
    if (duplicateRows !== undefined) pairs.push(["Duplicate Rows", _fmtNum(duplicateRows, 0)]);
    if (duplicatePct !== undefined) pairs.push(["Duplicate %", _fmtPct(duplicatePct)]);
    if (memoryUsage !== undefined) pairs.push(["Memory Usage", _fmtAny(memoryUsage)]);

    return _writeKeyValueBlock(sheet, row, pairs, {
        severity: (label) => {
            if (label === "Quality Score (AI)" && qualityScore !== undefined) return _severityHighIsGood(qualityScore);
            if (label === "Duplicate %" && duplicatePct !== undefined) return _severityHighIsBad(duplicatePct);
            return null;
        },
    });
}

// Builds a short plain-language summary purely by narrating numbers already
// on hand (rows/columns/missing/duplicates) — this is string formatting of
// existing values, not a new scoring system or an inferred conclusion. Used
// ONLY as a fallback when Section 2 has no explicit quality-summary metrics
// to show (i.e. the alternative was the generic, less useful "No additional
// quality metrics returned." message). Returns null when there's nothing at
// all to narrate, so the original fallback message still applies.
function _buildOverviewNarrative(opts) {
    const rows = _num(opts.rows);
    const cols = _num(opts.columns);
    const missing = _num(opts.missingValues);
    const missingByColumn = (opts.missingValuesByColumn && typeof opts.missingValuesByColumn === "object") ? opts.missingValuesByColumn : {};
    const columnsWithMissing = Object.values(missingByColumn).filter((v) => (_num(v) ?? 0) > 0).length;
    const dup = _num(opts.duplicateRows);

    if (rows === null && cols === null && missing === null && dup === null) return null;

    const parts = [];
    if (rows !== null && cols !== null) {
        parts.push("The dataset contains " + rows.toLocaleString() + " rows across " + cols.toLocaleString() + " columns.");
    } else if (rows !== null) {
        parts.push("The dataset contains " + rows.toLocaleString() + " rows.");
    }
    if (missing !== null) {
        if (missing === 0) {
            parts.push("No missing values were detected.");
        } else if (columnsWithMissing > 0) {
            const columnWord = columnsWithMissing === 1 ? "column" : "columns";
            parts.push(missing.toLocaleString() + " missing value(s) were detected across " + columnsWithMissing + " " + columnWord + ".");
        } else {
            parts.push(missing.toLocaleString() + " missing value(s) were detected.");
        }
    }
    if (dup !== null) {
        parts.push(dup === 0 ? "No duplicate rows were detected." : dup.toLocaleString() + " duplicate row(s) were detected.");
    }
    return parts.length > 0 ? parts.join(" ") : null;
}

// Every metric the AI Quality tab could plausibly show, each tried against a
// handful of likely backend key names. Anything found is written and marked
// consumed; anything not found is simply skipped (never fabricated).
const _QUALITY_SUMMARY_METRICS = [
    { label: "Missing Cells", keys: ["missing_cells", "missing_count", "total_missing"], pct: false },
    { label: "Missing %", keys: ["missing_percentage", "missing_pct", "missing_rate"], pct: true, badHigh: true },
    { label: "Duplicate Rows", keys: ["duplicate_rows", "duplicate_count"], pct: false },
    { label: "Duplicate %", keys: ["duplicate_percentage", "duplicate_pct", "duplicate_rate"], pct: true, badHigh: true },
    { label: "Constant Columns", keys: ["constant_columns", "constant_column_count"], pct: false },
    { label: "Unique Columns", keys: ["unique_columns", "unique_column_count"], pct: false },
    { label: "Mixed Data Types", keys: ["mixed_data_types", "mixed_type_columns"], pct: false },
    { label: "Empty Columns", keys: ["empty_columns", "empty_column_count"], pct: false },
    { label: "Whitespace Issues", keys: ["whitespace_issues", "whitespace_issue_count"], pct: false },
    { label: "Invalid Values", keys: ["invalid_values", "invalid_value_count"], pct: false },
];

function _writeQualitySummary(sheet, row, dq, statistics, opts, consumedKeys) {
    const pairs = [];
    const severities = [];
    for (const metric of _QUALITY_SUMMARY_METRICS) {
        const v = _pickCount(dq, metric.keys, consumedKeys);
        if (v === undefined) continue;
        pairs.push([metric.label, metric.pct ? _fmtPct(v) : _fmtAny(v)]);
        severities.push(metric.badHigh ? _severityHighIsBad(v) : null);
    }
    // Same shared Quality Grade lookup as Section 1 — one source of truth.
    const { grade } = _pickQualityScoreAndGrade(dq, statistics, consumedKeys);
    if (grade !== undefined) { pairs.push(["Quality Grade", _fmtAny(grade)]); severities.push(null); }
    const summaryText = _pick(dq, ["quality_summary", "summary"], consumedKeys);
    if (summaryText !== undefined) { pairs.push(["Summary", _fmtAny(summaryText)]); severities.push(null); }

    if (pairs.length === 0) {
        // Nothing explicit from the AI report — fall back to narrating the
        // overview numbers we already have (rows/columns/missing/duplicates)
        // which ARE available after every scan (the Quality Tab source).
        const narrative = _buildOverviewNarrative(opts);
        if (narrative) {
            const cell = sheet.getRangeByIndexes(row, 0, 1, 1);
            cell.values = [[narrative]];
            cell.format.wrapText = true;
            return row + 1;
        }
        sheet.getRangeByIndexes(row, 0, 1, 1).values = [["No additional quality metrics returned."]];
        return row + 1;
    }
    return _writeKeyValueBlock(sheet, row, pairs, { severity: (label) => severities[pairs.findIndex(p => p[0] === label)] });
}

// Builds the canonical column-entry list. Priority order:
// 1. AiReport.dataQuality column_quality / columns (richest, if AI report ran)
// 2. AiReport.statistics column data (fallback)
// 3. Merge per-column missing counts from missingValuesByColumn
//    (client-side computed, exact Quality Tab source) — never overwrites
//    an existing authoritative missing_count
// 4. Merge per-column unique counts from uniqueValuesByColumn
//    (client-side computed, exact Quality Tab source) — never overwrites
// 5. Merge per-column dtypes from a flat dtype map in dataQuality/statistics
// 6. Guarantee every column the scan found (columnNames) has an entry,
//    even if none of the above produced data for it — using the real
//    column name, never a "Column N" placeholder
function _extractColumnEntries(dq, statistics, consumedKeys, missingValuesByColumn, uniqueValuesByColumn, columnNames) {
    const raw = _pick(dq, ["column_quality", "columns_quality", "per_column_quality", "column_details", "columns"], consumedKeys)
        ?? _pick(statistics, ["column_quality", "columns", "per_column"], null);

    let entries;
    if (!raw) {
        entries = [];
    } else if (Array.isArray(raw)) {
        entries = raw.map((entry, i) => {
            if (entry && typeof entry === "object") {
                const name = entry.column ?? entry.name ?? entry.field ?? ("Column " + (i + 1));
                return Object.assign({}, entry, { name });
            }
            return { name: String(entry) };
        });
    } else if (typeof raw === "object") {
        entries = Object.entries(raw).map(([name, entry]) => {
            if (entry && typeof entry === "object") return Object.assign({}, entry, { name });
            return { name, value: entry };
        });
    } else {
        entries = [];
    }

    const buildIndex = () => new Map(entries.map((e) => [String(e.name), e]));

    // Step 3: merge missing counts (Quality Tab source — exact values shown in UI)
    if (missingValuesByColumn && Object.keys(missingValuesByColumn).length > 0) {
        const idx = buildIndex();
        for (const [colName, missingCount] of Object.entries(missingValuesByColumn)) {
            const existing = idx.get(colName);
            if (existing) {
                if (existing.missing_count === undefined && existing.missing === undefined && existing.null_count === undefined) {
                    existing.missing_count = missingCount;
                }
            } else {
                const e = { name: colName, missing_count: missingCount };
                entries.push(e);
                idx.set(colName, e);
            }
        }
    }

    // Step 4: merge unique counts (Quality Tab source — exact values shown in UI)
    if (uniqueValuesByColumn && Object.keys(uniqueValuesByColumn).length > 0) {
        const idx = buildIndex();
        for (const [colName, uniqueCount] of Object.entries(uniqueValuesByColumn)) {
            const existing = idx.get(colName);
            if (existing) {
                if (existing.unique_count === undefined && existing.unique === undefined && existing.n_unique === undefined) {
                    existing.unique_count = uniqueCount;
                }
            } else {
                const e = { name: colName, unique_count: uniqueCount };
                entries.push(e);
                idx.set(colName, e);
            }
        }
    }

    // Step 5: merge a flat dtype map if present
    const rawDtypeMap = _pick(dq, ["data_types", "dtypes", "column_types", "column_dtypes"], consumedKeys)
        ?? _pick(statistics, ["data_types", "dtypes", "column_types", "column_dtypes"], null);
    if (rawDtypeMap && typeof rawDtypeMap === "object" && !Array.isArray(rawDtypeMap)) {
        const idx = buildIndex();
        for (const [colName, dtypeValue] of Object.entries(rawDtypeMap)) {
            if (dtypeValue && typeof dtypeValue === "object") continue;
            const existing = idx.get(colName);
            if (existing) {
                if (existing.dtype === undefined && existing.type === undefined && existing.data_type === undefined && existing.detected_type === undefined) {
                    existing.dtype = dtypeValue;
                }
            } else {
                const e = { name: colName, dtype: dtypeValue };
                entries.push(e);
                idx.set(colName, e);
            }
        }
    }

    // Step 6: guarantee every scanned column appears, in scan order.
    // This ensures Column Quality table matches the Quality Tab column list
    // exactly, even for columns that have zero missing values and no AI data.
    if (columnNames && columnNames.length > 0) {
        const idx = buildIndex();
        // Add any missing columns first (preserving scan order for them)
        for (const colName of columnNames) {
            const name = String(colName);
            if (!idx.has(name)) {
                const e = { name };
                entries.push(e);
                idx.set(name, e);
            }
        }
        // Re-sort entries to match scan order (known columns first, then any
        // AI-report-only columns that didn't appear in the scan list)
        const order = new Map(columnNames.map((c, i) => [String(c), i]));
        entries.sort((a, b) => {
            const ia = order.has(a.name) ? order.get(a.name) : columnNames.length;
            const ib = order.has(b.name) ? order.get(b.name) : columnNames.length;
            return ia - ib;
        });
    }

    return entries;
}

function _writeColumnQuality(sheet, row, columnEntries) {
    if (columnEntries.length === 0) {
        sheet.getRangeByIndexes(row, 0, 1, 1).values = [["No column data available."]];
        return { nextRow: row + 1, headerRange: null, dataRangeForFilter: null };
    }

    // Only include a column in the table if at least one entry has a real
    // value for it — don't show a "Datatype" column if every row is N/A.
    // This prevents the table from looking fabricated.
    const rows = columnEntries.map((c) => {
        const missingCount = _pickCount(c, ["missing_count", "missing", "null_count"]);
        const uniqueCount = _pick(c, ["unique_count", "unique", "n_unique"]);
        const dtype = _pick(c, ["dtype", "type", "data_type", "detected_type"]);
        const missingPct = _pick(c, ["missing_percentage", "missing_pct", "null_pct", "null_percentage"]);
        const dupCount = _pickCount(c, ["duplicate_count", "duplicates"]);
        const issues = c.issues !== undefined ? _fmtAny(c.issues) : undefined;
        const recs = c.recommendations !== undefined ? _fmtAny(c.recommendations)
            : (c.recommendation !== undefined ? _fmtAny(c.recommendation) : undefined);
        return {
            column: _fmtAny(c.name),
            // missingCount and uniqueCount are always present (from scan pipeline)
            missing_count: missingCount !== undefined && missingCount !== null ? _fmtNum(missingCount, 0) : "0",
            unique_count: uniqueCount !== undefined && uniqueCount !== null ? _fmtNum(uniqueCount, 0) : null,
            // dtype, missingPct, dupCount, issues, recs only from AI report
            datatype: dtype !== undefined ? _fmtAny(dtype) : null,
            missing_pct: missingPct !== undefined ? _fmtPct(missingPct) : null,
            duplicate_count: dupCount !== undefined ? _fmtNum(dupCount, 0) : null,
            issues: issues || null,
            recommendations: recs || null,
            _missingPctRaw: missingPct,
        };
    });

    // Determine which columns have at least one non-null value
    const hasAny = (key) => rows.some(r => r[key] !== null && r[key] !== undefined);

    const allColumns = [
        { label: "Column", key: "column", always: true },
        { label: "Missing Count", key: "missing_count", always: true }, // from scan
        { label: "Unique Count", key: "unique_count", always: false },  // from scan
        { label: "Datatype", key: "datatype", always: false },          // AI only
        { label: "Missing %", key: "missing_pct", always: false,        // AI only
          severity: (r) => _severityHighIsBad(r._missingPctRaw) },
        { label: "Duplicate Count", key: "duplicate_count", always: false }, // AI only
        { label: "Issues", key: "issues", always: false, wrap: true },       // AI only
        { label: "Recommendations", key: "recommendations", always: false, wrap: true }, // AI only
    ];

    const activeColumns = allColumns.filter(c => c.always || hasAny(c.key));

    // Fill remaining nulls with "—" for display (only for active columns)
    const displayRows = rows.map(r => {
        const out = {};
        for (const c of activeColumns) {
            out[c.key] = (r[c.key] !== null && r[c.key] !== undefined) ? r[c.key] : "—";
        }
        out._missingPctRaw = r._missingPctRaw;
        return out;
    });

    return _writeTable(sheet, row, activeColumns, displayRows);
}

function _writeMissingValueAnalysis(sheet, row, columnEntries, totalRows) {
    const withMissing = columnEntries
        .map((c) => {
            const missingCount = _pickCount(c, ["missing_count", "missing", "null_count"]);
            let missingPct = _pick(c, ["missing_percentage", "missing_pct", "null_pct", "null_percentage"]);
            // Derive missing % from count/rows only when the source doesn't
            // already supply it — never overwrite an authoritative value.
            // Requires totalRows > 0 to avoid division by zero.
            if (missingPct === undefined && missingCount !== undefined && totalRows !== undefined && totalRows !== null) {
                const totalN = _num(totalRows);
                const countN = _num(missingCount);
                if (totalN !== null && totalN > 0 && countN !== null) {
                    missingPct = (countN / totalN) * 100;
                }
            }
            return {
                column: _fmtAny(c.name),
                missing_count: missingCount,
                missing_pct: missingPct,
                // suggested_treatment: only from AI report — never fabricated.
                // If the backend didn't supply it, the column is omitted from
                // the Suggested Treatment column entirely.
                suggested: _pick(c, ["suggested_treatment", "treatment", "missing_treatment"]),
            };
        })
        .filter((c) => {
            // Only include columns that genuinely have missing values.
            // Use explicit null-check on missing_count: 0 means no missing,
            // undefined means we have no count at all — both are excluded.
            const countN = _num(c.missing_count);
            return countN !== null && countN > 0;
        });

    if (withMissing.length === 0) {
        sheet.getRangeByIndexes(row, 0, 1, 1).values = [["No columns contain missing values."]];
        return row + 1;
    }

    const hasSuggested = withMissing.some(c => c.suggested !== undefined);

    const rows = withMissing.map((c) => ({
        column: c.column,
        missing_count: _fmtNum(c.missing_count, 0),
        missing_pct: c.missing_pct !== undefined ? _fmtPct(c.missing_pct) : "—",
        suggested: hasSuggested ? (c.suggested !== undefined ? _fmtAny(c.suggested) : "—") : undefined,
        _pctRaw: c.missing_pct,
    }));

    const columns = [
        { label: "Column", key: "column" },
        { label: "Missing Count", key: "missing_count" },
        { label: "Missing %", key: "missing_pct", severity: (r) => _severityHighIsBad(r._pctRaw) },
    ];
    // Only add Suggested Treatment column if the AI report provided at least
    // one value — never show a column full of "—" entries.
    if (hasSuggested) {
        columns.push({ label: "Suggested Treatment", key: "suggested", wrap: true });
    }
    return _writeTable(sheet, row, columns, rows).nextRow;
}

function _writeDuplicateAnalysis(sheet, row, dq, opts, consumedKeys) {
    // dupRows: from dataQuality map if present, otherwise from the scan
    // pipeline value (opts.duplicateRows). Uses ?? so 0 is preserved — a
    // value of undefined (no source) falls through to opts, while 0
    // (genuinely zero duplicates) is kept as 0.
    const dupRows = _pickCount(dq, ["duplicate_rows", "duplicates", "duplicate_count"], consumedKeys) ?? opts.duplicateRows;

    // dupPct: source value only — never calculated, never defaulted to 0.
    // If the source doesn't provide it, the field is omitted from the output.
    const dupPct = _pick(dq, ["duplicate_percentage", "duplicate_pct", "duplicate_rate"], consumedKeys);

    // affectedRaw: only from the source — never inferred from dupRows.
    const affectedRaw = _pick(dq, ["affected_columns", "duplicate_affected_columns"], consumedKeys);

    // recommendation: source value only — never generated from dupRows count.
    const recommendation = _pick(dq, ["duplicate_recommendation"], consumedKeys);

    // Build pairs — only include fields where the source provides a value.
    // dupRows is always shown (from scan pipeline, 0 is valid and kept as 0).
    // dupPct, affectedRaw, recommendation only shown when source provides them.
    const pairs = [];
    pairs.push(["Duplicate Rows", dupRows !== null && dupRows !== undefined ? _fmtNum(dupRows, 0) : "N/A"]);
    if (dupPct !== undefined) pairs.push(["Duplicate %", _fmtPct(dupPct)]);
    if (affectedRaw !== undefined) pairs.push(["Affected Columns", _fmtAny(affectedRaw)]);
    if (recommendation !== undefined) pairs.push(["Recommendation", _fmtAny(recommendation)]);

    return _writeKeyValueBlock(sheet, row, pairs, {
        severity: (label) => label === "Duplicate %" ? _severityHighIsBad(dupPct) : null,
    });
}

function _writeOutlierAnalysis(sheet, row, outliers, dq, analysisPresent, consumedKeys) {
    let source = outliers;
    if (!source || source.length === 0) {
        const dqOutliers = _pick(dq, ["outliers", "outlier_analysis"], consumedKeys);
        source = Array.isArray(dqOutliers) ? dqOutliers : [];
    }
    if (source.length === 0) {
        // Distinguish between "the backend ran outlier detection and found
        // none" vs. "the backend never ran / didn't include outlier data".
        // analysisPresent is set from AiReport.outliersAnalysisPresent (see
        // ai_report_model.dart), which captures whether the `outliers` key
        // was actually present in the raw JSON (even if it was []).
        const msg = analysisPresent ? "No outliers detected." : "No outlier analysis available.";
        sheet.getRangeByIndexes(row, 0, 1, 1).values = [[msg]];
        return row + 1;
    }
    const rows = source.map((o) => {
        if (o && typeof o === "object") {
            return {
                column: _fmtAny(_pick(o, ["column", "col", "field"]) ?? "N/A"),
                count: (() => { const c = _pick(o, ["count", "outlier_count", "n"]); return c !== undefined ? _fmtNum(c, 0) : "N/A"; })(),
                pct: (() => { const p = _pick(o, ["percentage", "outlier_pct", "pct"]); return p !== undefined ? _fmtPct(p) : "N/A"; })(),
                method: _fmtAny(_pick(o, ["method", "detection_method", "technique"]) ?? "N/A"),
            };
        }
        return { column: _fmtAny(o), count: "N/A", pct: "N/A", method: "N/A" };
    });
    const columns = [
        { label: "Column", key: "column" },
        { label: "Outlier Count", key: "count" },
        { label: "Outlier %", key: "pct" },
        { label: "Detection Method", key: "method" },
    ];
    return _writeTable(sheet, row, columns, rows).nextRow;
}

function _writeDataTypeAnalysis(sheet, row, columnEntries) {
    const relevant = columnEntries.filter((c) =>
        _pick(c, ["dtype", "type", "data_type", "detected_type"]) !== undefined ||
        _pick(c, ["recommended_type", "suggested_type"]) !== undefined
    );
    if (relevant.length === 0) {
        sheet.getRangeByIndexes(row, 0, 1, 1).values = [["No data type analysis available."]];
        return row + 1;
    }

    // Distribution summary ahead of the per-column detail table — a tally
    // of the dtype values already present on each column entry (not a new
    // inference), so it's easy to see at a glance how many columns are of
    // each type before scanning the full per-column list below.
    const counts = new Map();
    const namesByType = new Map();
    relevant.forEach((c) => {
        const dt = _fmtAny(_pick(c, ["dtype", "type", "data_type", "detected_type"]) ?? "Unknown");
        counts.set(dt, (counts.get(dt) || 0) + 1);
        if (!namesByType.has(dt)) namesByType.set(dt, []);
        namesByType.get(dt).push(_fmtAny(c.name));
    });
    const distRows = Array.from(counts.entries()).map(([dt, n]) => ({
        datatype: dt,
        count: _fmtNum(n, 0),
        columns: namesByType.get(dt).join(", "),
    }));
    const distColumns = [
        { label: "Datatype", key: "datatype" },
        { label: "Column Count", key: "count" },
        { label: "Columns", key: "columns", wrap: true },
    ];
    let nextRow = _writeTable(sheet, row, distColumns, distRows).nextRow;
    nextRow += 1;

    const rows = relevant.map((c) => ({
        column: _fmtAny(c.name),
        detected: _fmtAny(_pick(c, ["dtype", "type", "data_type", "detected_type"]) ?? "N/A"),
        recommended: _fmtAny(_pick(c, ["recommended_type", "suggested_type"]) ?? "—"),
        issues: c.issues !== undefined ? _fmtAny(c.issues) : "—",
    }));
    const columns = [
        { label: "Column", key: "column" },
        { label: "Detected Type", key: "detected" },
        { label: "Recommended Type", key: "recommended" },
        { label: "Issues", key: "issues", wrap: true },
    ];
    return _writeTable(sheet, nextRow, columns, rows).nextRow;
}

// Writes the Column Data Types section.
// `dtypeRow`: single row from analysisData['describe'] where index === "dtype"
//   (or similar), or null when the backend didn't include one.
// `dtypesByColumn`: top-level {"ColName": "dtype"} map from the backend,
//   used as a fallback when dtypeRow is null or missing a particular column.
// `columnNames`: ordered list from summary.column_names.
// Values are the backend's own strings — no normalisation applied.
// When neither source has a dtype for a column, shows "Not available".
function _writeColumnDataTypes(sheet, row, dtypeRow, dtypesByColumn, columnNames) {
    const ordered = [];
    const seen = new Set();

    const getDtype = (key) => {
        // Priority 1: describe dtype row
        if (dtypeRow && dtypeRow[key] !== null && dtypeRow[key] !== undefined && dtypeRow[key] !== "") {
            return String(dtypeRow[key]);
        }
        // Priority 2: top-level dtypes map
        if (dtypesByColumn && dtypesByColumn[key] !== null && dtypesByColumn[key] !== undefined && dtypesByColumn[key] !== "") {
            return String(dtypesByColumn[key]);
        }
        return "Not available";
    };

    // First pass: scan order from columnNames
    if (columnNames && columnNames.length > 0) {
        for (const name of columnNames) {
            const key = String(name);
            if (key === "index") continue;
            seen.add(key);
            ordered.push({ column: key, dtype: getDtype(key) });
        }
    }
    // Second pass: any column in dtypeRow or dtypesByColumn not yet seen
    const extraSources = [
        ...(dtypeRow ? Object.keys(dtypeRow) : []),
        ...Object.keys(dtypesByColumn),
    ];
    for (const key of extraSources) {
        if (key === "index" || seen.has(key)) continue;
        seen.add(key);
        ordered.push({ column: key, dtype: getDtype(key) });
    }

    if (ordered.length === 0) {
        sheet.getRangeByIndexes(row, 0, 1, 1).values = [["No column datatype information available."]];
        return row + 1;
    }
    const tableColumns = [
        { label: "Column Name", key: "column" },
        { label: "Data Type", key: "dtype" },
    ];
    return _writeTable(sheet, row, tableColumns, ordered).nextRow;
}

// Writes the statistics matrix from analysisData['describe'] — the same
// table the DescribeMatrix widget shows in the Analysis tab's Statistics
// section. `describeList` is a list of row objects, each keyed by column
// name plus an 'index' key for the metric name (count, mean, std, etc.).
function _writeDescribeMatrix(sheet, row, describeList) {
    if (!describeList || describeList.length === 0) {
        sheet.getRangeByIndexes(row, 0, 1, 1).values = [["No statistics matrix available."]];
        return row + 1;
    }
    const headers = Object.keys(describeList[0] || {});
    if (headers.length === 0) {
        sheet.getRangeByIndexes(row, 0, 1, 1).values = [["Statistics matrix has no columns."]];
        return row + 1;
    }
    const numCols = headers.length;
    const displayHeaders = headers.map((h) => h === "index" ? "Metric" : h);
    sheet.getRangeByIndexes(row, 0, 1, numCols).values = [displayHeaders];
    _styleHeaderRow(sheet, row, numCols);
    row += 1;
    describeList.forEach((rowObj, i) => {
        const vals = headers.map((h) => {
            const v = rowObj[h];
            if (v === null || v === undefined) return "";
            const n = typeof v === "number" ? v : Number(v);
            return Number.isFinite(n) ? parseFloat(n.toFixed(4)) : String(v);
        });
        const r = sheet.getRangeByIndexes(row + i, 0, 1, numCols);
        r.values = [vals];
        if (i % 2 === 1) r.format.fill.color = _QR_COLORS.bandFill;
    });
    const fullRange = sheet.getRangeByIndexes(row - 1, 0, describeList.length + 1, numCols);
    fullRange.format.borders.getItem("EdgeTop").style = "Continuous";
    fullRange.format.borders.getItem("EdgeBottom").style = "Continuous";
    fullRange.format.borders.getItem("EdgeLeft").style = "Continuous";
    fullRange.format.borders.getItem("EdgeRight").style = "Continuous";
    fullRange.format.borders.getItem("InsideHorizontal").style = "Continuous";
    fullRange.format.borders.getItem("InsideVertical").style = "Continuous";
    return row + describeList.length;
}

// Renders the AI dataQuality map exactly as _buildMapResultCard does in
// report_tab.dart — generic key-value rendering with no hardcoded field
// names. Any key the backend returns is surfaced; nothing is added that
// wasn't in the original response. Also shows Quality Score/Grade when
// the AI report includes them, labelled as AI-provided.
function _writeAiDataQuality(sheet, row, dq, statistics, opts, consumedKeys) {
    const { score, grade } = _pickQualityScoreAndGrade(dq, statistics, consumedKeys);
    const pairs = [];

    // Quality Score/Grade — only if the AI report actually has them
    if (score !== undefined) pairs.push(["Quality Score (AI)", _fmtNum(score, 1)]);
    if (grade !== undefined) pairs.push(["Quality Grade (AI)", _fmtAny(grade)]);

    // Everything else in dataQuality verbatim (same as UI generic render)
    for (const [k, v] of Object.entries(dq)) {
        if (consumedKeys.has(k)) continue;
        // Skip column-quality sub-objects — those are handled in Column Quality section
        if (k === "column_quality" || k === "columns_quality" || k === "per_column_quality" || k === "column_details") continue;
        // Skip dtype maps — handled in Column Quality section
        if (k === "data_types" || k === "dtypes" || k === "column_types" || k === "column_dtypes") continue;
        pairs.push([_titleCase(k), _fmtAny(v)]);
        consumedKeys.add(k);
    }

    if (pairs.length === 0) {
        sheet.getRangeByIndexes(row, 0, 1, 1).values = [["No structured AI quality data returned."]];
        return row + 1;
    }

    return _writeKeyValueBlock(sheet, row, pairs, {
        severity: (label) => {
            if (label === "Quality Score (AI)" && score !== undefined) return _severityHighIsGood(score);
            return null;
        },
    });
}

function _writeRecommendations(sheet, row, recommendations) {
    if (!recommendations || recommendations.length === 0) {
        sheet.getRangeByIndexes(row, 0, 1, 1).values = [["No recommendations returned."]];
        return row + 1;
    }
    const rows = recommendations.map((r, i) => {
        if (r && typeof r === "object") {
            const text = _pick(r, ["recommendation", "text", "description", "message"]) ?? _fmtAny(r);
            const priority = _pick(r, ["priority", "severity"]);
            return { n: i + 1, text: _fmtAny(text), priority: priority !== undefined ? _fmtAny(priority) : "—" };
        }
        return { n: i + 1, text: _fmtAny(r), priority: "—" };
    });
    const columns = [
        { label: "#", key: "n" },
        { label: "Recommendation", key: "text", wrap: true },
        { label: "Priority", key: "priority" },
    ];
    return _writeTable(sheet, row, columns, rows).nextRow;
}

function _writeExecutiveSummary(sheet, row, executiveSummary, reportText) {
    // First show the free-text AI report if present (same as _buildReportCard
    // in report_tab.dart which renders r.report directly)
    if (reportText && typeof reportText === "string" && reportText.trim()) {
        const cell = sheet.getRangeByIndexes(row, 0, 1, 1);
        cell.values = [[reportText.trim()]];
        cell.format.wrapText = true;
        sheet.getRangeByIndexes(row, 0, 1, 6).merge(false);
        sheet.getRangeByIndexes(row, 0, 1, 6).format.rowHeight = 80;
        row += 1;
    }
    const narrative = _pick(executiveSummary, ["summary", "text", "narrative", "overview"]);
    if (narrative !== undefined) {
        const cell = sheet.getRangeByIndexes(row, 0, 1, 1);
        cell.values = [[_fmtAny(narrative)]];
        cell.format.wrapText = true;
        sheet.getRangeByIndexes(row, 0, 1, 6).merge(false);
        sheet.getRangeByIndexes(row, 0, 1, 6).format.rowHeight = 60;
        row += 1;
    }
    const rest = Object.assign({}, executiveSummary);
    ["summary", "text", "narrative", "overview"].forEach((k) => delete rest[k]);
    if (Object.keys(rest).length > 0) {
        row = _writeKeyValueTable(sheet, row, rest);
    } else if (narrative === undefined && !(reportText && reportText.trim())) {
        sheet.getRangeByIndexes(row, 0, 1, 1).values = [["No executive summary available."]];
        row += 1;
    }
    return row;
}

// Anything in dataQuality that no section above read gets surfaced here so
// the export never silently drops a metric the backend returned.
function _writeLeftovers(sheet, row, dq, consumedKeys, numCols) {
    const leftoverEntries = Object.entries(dq).filter(([k, v]) =>
        !consumedKeys.has(k) && v !== null && v !== undefined &&
        !(Array.isArray(v) && v.length === 0) &&
        !(typeof v === "object" && !Array.isArray(v) && Object.keys(v).length === 0)
    );
    if (leftoverEntries.length === 0) return row;
    row = _writeSectionHeader(sheet, row, "ADDITIONAL QUALITY METRICS", numCols);
    return _writeKeyValueTable(sheet, row, Object.fromEntries(leftoverEntries));
}
