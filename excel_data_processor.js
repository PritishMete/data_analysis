// web/excel_data_processor.js
// -------------------------------------------------------------------
// Business logic module running calculations independently of sheet UI.
// -------------------------------------------------------------------

/**
 * Calculates column-level metrics from a raw 2D array (including headers).
 * Returns a 2D array formatted for Excel range insertion.
 */
function calculateAggregations(matrix, selectedOps, selectedCols) {
    if (!matrix || matrix.length < 2) return [];

    const headers  = matrix[0];
    const rows     = matrix.slice(1);
    const ops      = selectedOps  || ["count","sum","average","min","max","unique_count"];
    const colFilter= selectedCols ? new Set(selectedCols) : null;
    const summary  = [];

    for (let colIdx = 0; colIdx < headers.length; colIdx++) {
        const colName = String(headers[colIdx] || "").trim();
        if (!colName) continue;
        if (colFilter && !colFilter.has(colName)) continue;

        const allVals  = rows.map(r => r[colIdx]);
        const nonEmpty = allVals.filter(v => v !== null && v !== undefined && v !== "");
        const nums     = nonEmpty.map(v => Number(v)).filter(n => !isNaN(n));
        const uniques  = new Set(nonEmpty.map(v => String(v)));

        const isNumeric = nums.length > 0;
        const result = { column: colName, type: isNumeric ? "NUMERIC" : "TEXT" };

        for (const op of ops) {
            switch (op) {
                case "count":
                    result.count = nonEmpty.length;
                    break;
                case "counta":
                    result.counta = nonEmpty.length;
                    break;
                case "sum":
                    result.sum = isNumeric ? nums.reduce((a, b) => a + b, 0) : "N/A";
                    break;
                case "average":
                    result.average = isNumeric && nums.length > 0
                        ? (nums.reduce((a, b) => a + b, 0) / nums.length)
                        : "N/A";
                    break;
                case "min":
                    result.min = isNumeric ? Math.min(...nums) : "N/A";
                    break;
                case "max":
                    result.max = isNumeric ? Math.max(...nums) : "N/A";
                    break;
                case "unique_count":
                    result.unique_count = uniques.size;
                    break;
                case "product":
                    result.product = isNumeric ? nums.reduce((a, b) => a * b, 1) : "N/A";
                    break;
                case "stdev": {
                    if (!isNumeric || nums.length < 2) { result.stdev = "N/A"; break; }
                    const mean = nums.reduce((a, b) => a + b, 0) / nums.length;
                    const variance = nums.reduce((a, b) => a + Math.pow(b - mean, 2), 0) / (nums.length - 1);
                    result.stdev = Math.sqrt(variance);
                    break;
                }
                case "median": {
                    if (!isNumeric) { result.median = "N/A"; break; }
                    const sorted = [...nums].sort((a, b) => a - b);
                    const mid = Math.floor(sorted.length / 2);
                    result.median = sorted.length % 2 !== 0
                        ? sorted[mid]
                        : (sorted[mid - 1] + sorted[mid]) / 2;
                    break;
                }
                case "blank_count":
                    result.blank_count = allVals.length - nonEmpty.length;
                    break;
                case "non_blank":
                    result.non_blank = nonEmpty.length;
                    break;
                default:
                    result[op] = "N/A";
            }
        }
        summary.push(result);
    }

    if (summary.length === 0) return [];
    const outputHeaders = ["METRIC_PROPERTY", ...summary.map(s => s.column)];
    const out2DMatrix = [outputHeaders];
    out2DMatrix.push(["DATA_TYPE", ...summary.map(s => s.type)]);

    ops.forEach(op => {
        const row = [op.toUpperCase()];
        summary.forEach(s => {
            row.push(s[op] !== undefined ? s[op] : "N/A");
        });
        out2DMatrix.push(row);
    });

    return out2DMatrix;
}

function evaluateCondition(val, config) {
    if (val === null || val === undefined) return false;
    const strVal    = String(val).trim().toLowerCase();
    const targetStr = String(config.value).trim().toLowerCase();

    function parseNum(v) {
        if (typeof v === "number") return isNaN(v) ? null : v;
        const cleaned = String(v).replace(/[₹$€£,\s]/g, "").trim();
        const n = Number(cleaned);
        return isNaN(n) ? null : n;
    }
    const numVal    = parseNum(val);
    const targetNum = parseNum(config.value);

    switch (config.type) {
        case "equals":             return strVal === targetStr;
        case "not_equals":
            if (strVal === "") return false;
            if (numVal !== null && targetNum !== null) return numVal !== targetNum;
            return strVal !== targetStr;
        case "contains":           return strVal.includes(targetStr);
        case "greater_than":       return numVal !== null && targetNum !== null && numVal > targetNum;
        case "less_than":          return numVal !== null && targetNum !== null && numVal < targetNum;
        case "greater_than_equal": return numVal !== null && targetNum !== null && numVal >= targetNum;
        case "less_than_equal":    return numVal !== null && targetNum !== null && numVal <= targetNum;
        case "between": {
            const targetNum2 = parseNum(config.value2);
            return numVal !== null && targetNum !== null && targetNum2 !== null
                && numVal >= targetNum && numVal <= targetNum2;
        }
        case "top_n":
        case "bottom_n":
            return true;
        default: return true;
    }
}

/**
 * Advanced Cross-Sheet Lookup Engine (VLOOKUP / HLOOKUP / XLOOKUP)
 *
 * Modes:
 *  - Per-row mode (default): For each source row, looks up the value from
 *    `lookupColumn` in the source sheet against `refMatchColumn` in the
 *    reference sheet, and appends the matched return columns.
 *  - Static search mode: If `searchItemValue` is provided and `lookupColumn`
 *    is null, filters ref sheet for that value and appends to all rows.
 *
 * Config fields:
 *  - type:             "vlookup" | "hlookup" | "xlookup"
 *  - lookupColumn:     Column in SOURCE sheet whose value is the lookup key
 *  - refMatchColumn:   Column in REFERENCE sheet to match against (if omitted,
 *                      falls back to lookupColumn name — same-named column)
 *  - targetSheetData:  JSON-stringified 2D array of the reference sheet
 *  - searchItemValue:  (optional) static string — overrides per-row mode
 *  - returnColumns:    Array of ref-sheet column names to pull back
 *  - showAllColumns:   If true, return all ref columns except the match column
 */
function evaluateLookupMutation(matrix, lookupConfig) {
    if (!matrix || matrix.length === 0) return matrix;

    const {
        type,
        lookupColumn,
        refMatchColumn,
        targetSheetData,
        searchItemValue,
        returnColumns,
        showAllColumns
    } = lookupConfig;

    // ── Parse reference sheet ──────────────────────────────────────────────
    let refMatrix;
    try {
        refMatrix = JSON.parse(targetSheetData);
    } catch (e) {
        console.error("Reference sheet payload parse failure");
        return matrix;
    }
    if (!refMatrix || refMatrix.length === 0) return matrix;

    const refHeaders = refMatrix[0];

    // ── Locate the match column in the REFERENCE sheet ────────────────────
    // Priority: refMatchColumn → lookupColumn (same name in ref sheet)
    const refMatchKey = String(refMatchColumn || lookupColumn || "").trim().toLowerCase();
    const refMatchColIdx = refHeaders.findIndex(
        h => String(h).trim().toLowerCase() === refMatchKey
    );
    if (refMatchColIdx === -1) {
        console.error("Lookup: ref match column not found:", refMatchKey);
        return matrix;
    }

    // ── Locate lookup key column in the SOURCE sheet ───────────────────────
    const sourceHeaders = matrix[0];
    const srcKeyColIdx = lookupColumn
        ? sourceHeaders.findIndex(h => String(h).trim().toLowerCase() === String(lookupColumn).trim().toLowerCase())
        : -1;

    // ── Static mode: single search value provided ──────────────────────────
    const staticMode = !!(searchItemValue && searchItemValue.trim() !== "");

    // ── Build a lookup index from reference sheet (key → first matching row)
    // For XLOOKUP we keep ALL matches; for VLOOKUP/HLOOKUP first match only.
    const refIndex = new Map(); // key (lowercase) → ref row array
    for (let i = 1; i < refMatrix.length; i++) {
        const cellKey = String(refMatrix[i][refMatchColIdx]).trim().toLowerCase();
        if (!refIndex.has(cellKey)) {
            refIndex.set(cellKey, refMatrix[i]);
        }
    }

    // ── Determine which ref columns to append ──────────────────────────────
    let selectedOutputCols = [];
    if (showAllColumns) {
        selectedOutputCols = refHeaders.filter((_, idx) => idx !== refMatchColIdx);
    } else if (Array.isArray(returnColumns) && returnColumns.length > 0) {
        // Keep user-selected columns, excluding the match key itself
        selectedOutputCols = returnColumns.filter(
            c => String(c).trim().toLowerCase() !== refMatchKey
        );
    }

    // Map output column names → ref sheet indexes
    const outputColMappings = selectedOutputCols.map(colName => ({
        name: colName,
        idx: refHeaders.findIndex(h => String(h).trim().toLowerCase() === String(colName).trim().toLowerCase())
    })).filter(m => m.idx !== -1);

    if (outputColMappings.length === 0) return matrix;

    // ── STATIC SEARCH MODE ──────────────────────────────────────────────────
    // A single value was typed in (e.g. "jacket"). The result is a small,
    // standalone lookup result — the searched key plus the chosen return
    // columns — NOT the entire source sheet with data glued onto every row.
    if (staticMode) {
        const staticKey = searchItemValue.trim().toLowerCase();
        const keyColumnName = refMatchColumn || lookupColumn || refHeaders[refMatchColIdx];

        const matchedRow = refIndex.get(staticKey) || null;

        const headers = [keyColumnName, ...outputColMappings.map(m => m.name)];
        const dataRow = matchedRow
            ? [matchedRow[refMatchColIdx], ...outputColMappings.map(m => matchedRow[m.idx])]
            : [searchItemValue, ...outputColMappings.map(() => "Not found")];

        return [headers, dataRow];
    }

    // ── PER-ROW MODE ────────────────────────────────────────────────────────
    // No static value: every row of the source sheet looks up its own key
    // column value and gets the matched reference columns appended.
    const newHeaders = [...sourceHeaders];
    outputColMappings.forEach(m => newHeaders.push(m.name));
    const mutatedMatrix = [newHeaders];

    const baseRows = matrix.slice(1);

    for (let i = 0; i < baseRows.length; i++) {
        const row = baseRows[i];

        // Resolve lookup key for this row
        let lookupKey;
        if (srcKeyColIdx !== -1) {
            lookupKey = String(row[srcKeyColIdx] || "").trim().toLowerCase();
        } else {
            // No key resolvable — append blanks
            mutatedMatrix.push([...row, ...outputColMappings.map(() => "")]);
            continue;
        }

        const matchedRow = refIndex.get(lookupKey) || null;
        const appendedData = outputColMappings.map(m =>
            matchedRow ? matchedRow[m.idx] : ""
        );

        mutatedMatrix.push([...row, ...appendedData]);
    }

    return mutatedMatrix;
}