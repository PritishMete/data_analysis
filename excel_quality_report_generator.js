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

    const dataQuality = (opts.dataQuality && typeof opts.dataQuality === "object") ? opts.dataQuality : {};
    const statistics = (opts.statistics && typeof opts.statistics === "object") ? opts.statistics : {};
    const executiveSummary = (opts.executiveSummary && typeof opts.executiveSummary === "object") ? opts.executiveSummary : {};
    const recommendations = Array.isArray(opts.recommendations) ? opts.recommendations : [];
    const outliers = Array.isArray(opts.outliers) ? opts.outliers : [];
    const chartRecommendation = (opts.chartRecommendation && typeof opts.chartRecommendation === "object") ? opts.chartRecommendation : {};

    // This is the single worksheet-writing implementation for both the
    // automatic per-scan sync (analyzeData() → _syncQualityReport(), which
    // only ever has overview-level numbers — rows/missing/duplicates — since
    // it fires before any AI report exists) and the explicit "Export Full
    // Quality Report" button (which has the complete AiReport). We only
    // refuse to write when there is truly nothing to show at all — the
    // overview-only case from the automatic sync is expected and valid.
    const hasAnything =
        Object.keys(dataQuality).length > 0 ||
        Object.keys(statistics).length > 0 ||
        Object.keys(executiveSummary).length > 0 ||
        recommendations.length > 0 ||
        outliers.length > 0 ||
        Object.keys(chartRecommendation).length > 0 ||
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

            const NUM_COLS = 10; // widest section (Column Quality) — used for merges/banding
            let row = 0;
            const consumedKeys = new Set();

            // ── Title ──────────────────────────────────────────────────────
            row = _writeTitle(sheet, row, "Data Quality Report", NUM_COLS);
            row += 1;

            // ── Section 1: Quality Overview ──────────────────────────────────
            row = _writeSectionHeader(sheet, row, "1. QUALITY OVERVIEW", NUM_COLS);
            row = _writeOverview(sheet, row, opts, dataQuality, consumedKeys);
            row += 1;

            // ── Section 2: Data Quality Summary ──────────────────────────────
            row = _writeSectionHeader(sheet, row, "2. DATA QUALITY SUMMARY", NUM_COLS);
            row = _writeQualitySummary(sheet, row, dataQuality, consumedKeys);
            row += 1;

            // ── Column-level source shared by Sections 3/4/7 ─────────────────
            const columnEntries = _extractColumnEntries(dataQuality, statistics, consumedKeys);

            // ── Section 3: Column Quality ─────────────────────────────────────
            row = _writeSectionHeader(sheet, row, "3. COLUMN QUALITY", NUM_COLS);
            const colQualityResult = _writeColumnQuality(sheet, row, columnEntries);
            row = colQualityResult.nextRow;
            row += 1;

            // ── Section 4: Missing Value Analysis ────────────────────────────
            row = _writeSectionHeader(sheet, row, "4. MISSING VALUE ANALYSIS", NUM_COLS);
            row = _writeMissingValueAnalysis(sheet, row, columnEntries);
            row += 1;

            // ── Section 5: Duplicate Analysis ────────────────────────────────
            row = _writeSectionHeader(sheet, row, "5. DUPLICATE ANALYSIS", NUM_COLS);
            row = _writeDuplicateAnalysis(sheet, row, dataQuality, consumedKeys);
            row += 1;

            // ── Section 6: Outlier Analysis ──────────────────────────────────
            row = _writeSectionHeader(sheet, row, "6. OUTLIER ANALYSIS", NUM_COLS);
            row = _writeOutlierAnalysis(sheet, row, outliers, dataQuality, consumedKeys);
            row += 1;

            // ── Section 7: Data Type Analysis ────────────────────────────────
            row = _writeSectionHeader(sheet, row, "7. DATA TYPE ANALYSIS", NUM_COLS);
            row = _writeDataTypeAnalysis(sheet, row, columnEntries);
            row += 1;

            // ── Section 8: AI Recommendations ────────────────────────────────
            row = _writeSectionHeader(sheet, row, "8. AI RECOMMENDATIONS", NUM_COLS);
            row = _writeRecommendations(sheet, row, recommendations);
            row += 1;

            // ── Section 9: Executive Summary ─────────────────────────────────
            row = _writeSectionHeader(sheet, row, "9. EXECUTIVE SUMMARY", NUM_COLS);
            row = _writeExecutiveSummary(sheet, row, executiveSummary);
            row += 1;

            // ── Any dataQuality keys nothing above consumed ──────────────────
            row = _writeLeftovers(sheet, row, dataQuality, consumedKeys, NUM_COLS);

            // ── Statistics (surfaced in full — this is the same `r.statistics`
            //    map rendered generically by the STATISTICS card in the Report
            //    tab; only a subset of it is consumed above as a column-quality
            //    fallback, so the rest must be written explicitly or it would
            //    silently disappear from the export while still being visible
            //    on screen) ────────────────────────────────────────────────────
            if (Object.keys(statistics).length > 0) {
                row = _writeSectionHeader(sheet, row, "STATISTICS (from AI report)", NUM_COLS);
                row = _writeKeyValueTable(sheet, row, statistics);
                row += 1;
            }

            // ── Chart recommendation (surfaced as-is, never redrawn) ─────────
            if (Object.keys(chartRecommendation).length > 0) {
                row = _writeSectionHeader(sheet, row, "CHART RECOMMENDATION (from AI report — not regenerated)", NUM_COLS);
                row = _writeKeyValueTable(sheet, row, chartRecommendation);
                row += 1;
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

function _writeOverview(sheet, row, opts, dq, consumedKeys) {
    const rowsCount = opts.rows ?? _pick(dq, ["rows", "total_rows", "row_count", "n_rows"], consumedKeys);
    const colsCount = opts.columns ?? _pick(dq, ["columns", "total_columns", "column_count", "n_columns"], consumedKeys);
    const qualityScore = _pick(dq, ["quality_score", "score", "overall_score", "overall_quality_score"], consumedKeys);
    const missingValues = _pickCount(dq, ["missing_cells", "missing_count", "total_missing", "missing_values"], consumedKeys) ?? opts.missingValues;
    const duplicateRows = _pickCount(dq, ["duplicate_rows", "duplicates", "duplicate_count"], consumedKeys) ?? opts.duplicateRows;
    const memoryUsage = _pick(dq, ["memory_usage", "memory", "memory_mb", "memory_usage_mb"], consumedKeys);

    const pairs = [
        ["Dataset Name", opts.datasetName || "N/A"],
        ["Generated", opts.generatedAt || new Date().toLocaleString()],
        ["Rows", rowsCount !== undefined && rowsCount !== null ? _fmtNum(rowsCount, 0) : "N/A"],
        ["Columns", colsCount !== undefined && colsCount !== null ? _fmtNum(colsCount, 0) : "N/A"],
        ["Quality Score", qualityScore !== undefined ? _fmtNum(qualityScore, 1) : "N/A"],
        ["Missing Values", missingValues !== undefined ? _fmtNum(missingValues, 0) : "N/A"],
        ["Duplicate Rows", duplicateRows !== undefined ? _fmtNum(duplicateRows, 0) : "N/A"],
        ["Memory Usage", memoryUsage !== undefined ? _fmtAny(memoryUsage) : "N/A"],
    ];
    return _writeKeyValueBlock(sheet, row, pairs, {
        severity: (label, value) => {
            if (label === "Quality Score" && qualityScore !== undefined) return _severityHighIsGood(qualityScore);
            return null;
        },
    });
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

function _writeQualitySummary(sheet, row, dq, consumedKeys) {
    const pairs = [];
    const severities = [];
    for (const metric of _QUALITY_SUMMARY_METRICS) {
        const v = _pickCount(dq, metric.keys, consumedKeys);
        if (v === undefined) continue;
        pairs.push([metric.label, metric.pct ? _fmtPct(v) : _fmtAny(v)]);
        severities.push(metric.badHigh ? _severityHighIsBad(v) : null);
    }
    // Also fold in a free-text quality_summary/quality_grade, if present,
    // matching the fields the earlier minimal exporter already surfaced.
    const grade = _pick(dq, ["quality_grade"], consumedKeys);
    if (grade !== undefined) { pairs.push(["Quality Grade", _fmtAny(grade)]); severities.push(null); }
    const summaryText = _pick(dq, ["quality_summary", "summary"], consumedKeys);
    if (summaryText !== undefined) { pairs.push(["Summary", _fmtAny(summaryText)]); severities.push(null); }

    if (pairs.length === 0) {
        sheet.getRangeByIndexes(row, 0, 1, 1).values = [["No additional quality metrics returned."]];
        return row + 1;
    }
    return _writeKeyValueBlock(sheet, row, pairs, { severity: (label, value) => severities[pairs.findIndex(p => p[0] === label)] });
}

// Finds the per-column detail structure the backend already computed
// (whatever it's called), normalising it to a flat array of
// { name, ...rest } objects without altering any values.
function _extractColumnEntries(dq, statistics, consumedKeys) {
    const raw = _pick(dq, ["column_quality", "columns_quality", "per_column_quality", "column_details", "columns"], consumedKeys)
        ?? _pick(statistics, ["column_quality", "columns", "per_column"], null);
    if (!raw) return [];

    if (Array.isArray(raw)) {
        return raw.map((entry, i) => {
            if (entry && typeof entry === "object") {
                const name = entry.column ?? entry.name ?? entry.field ?? ("Column " + (i + 1));
                return Object.assign({}, entry, { name });
            }
            return { name: String(entry) };
        });
    }
    if (typeof raw === "object") {
        return Object.entries(raw).map(([name, entry]) => {
            if (entry && typeof entry === "object") return Object.assign({}, entry, { name });
            return { name, value: entry };
        });
    }
    return [];
}

function _writeColumnQuality(sheet, row, columnEntries) {
    const rows = columnEntries.map((c) => {
        const missingCount = _pickCount(c, ["missing_count", "missing", "null_count"]);
        const missingPct = _pick(c, ["missing_percentage", "missing_pct", "null_pct", "null_percentage"]);
        const issues = c.issues !== undefined ? _fmtAny(c.issues) : "";
        const recs = c.recommendations !== undefined ? _fmtAny(c.recommendations) : (c.recommendation !== undefined ? _fmtAny(c.recommendation) : "");
        return {
            column: _fmtAny(c.name),
            datatype: _fmtAny(_pick(c, ["dtype", "type", "data_type", "detected_type"]) ?? "N/A"),
            missing_count: missingCount !== undefined ? _fmtNum(missingCount, 0) : "N/A",
            missing_pct: missingPct !== undefined ? _fmtPct(missingPct) : "N/A",
            unique_count: (() => { const u = _pick(c, ["unique_count", "unique", "n_unique"]); return u !== undefined ? _fmtNum(u, 0) : "N/A"; })(),
            duplicate_count: (() => { const d = _pickCount(c, ["duplicate_count", "duplicates"]); return d !== undefined ? _fmtNum(d, 0) : "N/A"; })(),
            memory: (() => { const m = _pick(c, ["memory", "memory_usage"]); return m !== undefined ? _fmtAny(m) : "N/A"; })(),
            null_pct: missingPct !== undefined ? _fmtPct(missingPct) : "N/A",
            issues: issues || "—",
            recommendations: recs || "—",
            _missingPctRaw: missingPct,
        };
    });

    const columns = [
        { label: "Column", key: "column" },
        { label: "Datatype", key: "datatype" },
        { label: "Missing Count", key: "missing_count" },
        { label: "Missing %", key: "missing_pct", severity: (r) => _severityHighIsBad(r._missingPctRaw) },
        { label: "Unique Count", key: "unique_count" },
        { label: "Duplicate Count", key: "duplicate_count" },
        { label: "Memory", key: "memory" },
        { label: "Null %", key: "null_pct" },
        { label: "Issues", key: "issues", wrap: true },
        { label: "Recommendations", key: "recommendations", wrap: true },
    ];
    return _writeTable(sheet, row, columns, rows);
}

function _writeMissingValueAnalysis(sheet, row, columnEntries) {
    const withMissing = columnEntries
        .map((c) => ({
            column: _fmtAny(c.name),
            missing_count: _pickCount(c, ["missing_count", "missing", "null_count"]),
            missing_pct: _pick(c, ["missing_percentage", "missing_pct", "null_pct", "null_percentage"]),
            suggested: _pick(c, ["suggested_treatment", "treatment", "missing_treatment"]),
        }))
        .filter((c) => (_num(c.missing_count) ?? 0) > 0 || (_num(c.missing_pct) ?? 0) > 0);

    const rows = withMissing.map((c) => {
        let suggestion = c.suggested !== undefined ? _fmtAny(c.suggested) : null;
        if (!suggestion) {
            // Presentational fallback only — used solely when the backend
            // didn't already supply a suggested_treatment for this column.
            const pct = _num(c.missing_pct);
            if (pct === null) suggestion = "Review manually";
            else if (pct > 50) suggestion = "Consider dropping column";
            else if (pct > 10) suggestion = "Impute (median/mode) or flag";
            else suggestion = "Impute or leave as-is";
        }
        return {
            column: c.column,
            missing_count: c.missing_count !== undefined ? _fmtNum(c.missing_count, 0) : "N/A",
            missing_pct: c.missing_pct !== undefined ? _fmtPct(c.missing_pct) : "N/A",
            suggested: suggestion,
            _pctRaw: c.missing_pct,
        };
    });

    const columns = [
        { label: "Column", key: "column" },
        { label: "Missing Count", key: "missing_count" },
        { label: "Missing %", key: "missing_pct", severity: (r) => _severityHighIsBad(r._pctRaw) },
        { label: "Suggested Treatment", key: "suggested", wrap: true },
    ];
    return _writeTable(sheet, row, columns, rows).nextRow;
}

function _writeDuplicateAnalysis(sheet, row, dq, consumedKeys) {
    const dupRows = _pickCount(dq, ["duplicate_rows", "duplicates", "duplicate_count"], consumedKeys);
    const dupPct = _pick(dq, ["duplicate_percentage", "duplicate_pct", "duplicate_rate"], consumedKeys);
    const affected = _pick(dq, ["affected_columns", "duplicate_affected_columns"], consumedKeys);
    const recommendation = _pick(dq, ["duplicate_recommendation"], consumedKeys)
        ?? ((_num(dupRows) ?? 0) > 0 || (_num(dupPct) ?? 0) > 0 ? "Review and remove duplicate rows before downstream analysis." : "No action needed.");

    const pairs = [
        ["Duplicate Rows", dupRows !== undefined ? _fmtNum(dupRows, 0) : "N/A"],
        ["Duplicate %", dupPct !== undefined ? _fmtPct(dupPct) : "N/A"],
        ["Affected Columns", affected !== undefined ? _fmtAny(affected) : "N/A"],
        ["Recommendation", _fmtAny(recommendation)],
    ];
    return _writeKeyValueBlock(sheet, row, pairs, {
        severity: (label) => label === "Duplicate %" ? _severityHighIsBad(dupPct) : null,
    });
}

function _writeOutlierAnalysis(sheet, row, outliers, dq, consumedKeys) {
    let source = outliers;
    if (!source || source.length === 0) {
        const dqOutliers = _pick(dq, ["outliers", "outlier_analysis"], consumedKeys);
        source = Array.isArray(dqOutliers) ? dqOutliers : [];
    }
    if (source.length === 0) {
        sheet.getRangeByIndexes(row, 0, 1, 1).values = [["No outlier analysis available."]];
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
    return _writeTable(sheet, row, columns, rows).nextRow;
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

function _writeExecutiveSummary(sheet, row, executiveSummary) {
    const narrative = _pick(executiveSummary, ["summary", "text", "narrative", "overview"]);
    let nextRow = row;
    if (narrative !== undefined) {
        const cell = sheet.getRangeByIndexes(nextRow, 0, 1, 1);
        cell.values = [[_fmtAny(narrative)]];
        cell.format.wrapText = true;
        sheet.getRangeByIndexes(nextRow, 0, 1, 6).merge(false);
        sheet.getRangeByIndexes(nextRow, 0, 1, 6).format.rowHeight = 60;
        nextRow += 1;
    }
    const rest = Object.assign({}, executiveSummary);
    ["summary", "text", "narrative", "overview"].forEach((k) => delete rest[k]);
    if (Object.keys(rest).length > 0) {
        nextRow = _writeKeyValueTable(sheet, nextRow, rest);
    } else if (narrative === undefined) {
        sheet.getRangeByIndexes(nextRow, 0, 1, 1).values = [["No executive summary available."]];
        nextRow += 1;
    }
    return nextRow;
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
