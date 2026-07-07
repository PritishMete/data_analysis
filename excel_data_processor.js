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
 * Mirrors the real Excel formula arguments end-to-end:
 *   =VLOOKUP(lookup_value, table_array, col_index_num, [range_lookup])
 *   =HLOOKUP(lookup_value, table_array, row_index_num, [range_lookup])
 *   =XLOOKUP(lookup_value, lookup_array, return_array, ...)   (same engine as VLOOKUP here)
 *
 * Modes:
 *  - Per-row mode (default): For each source row, looks up the value from
 *    `lookupColumn` in the source sheet against `refMatchColumn` in the
 *    reference sheet (table_array), and appends the resolved return value(s).
 *  - Static search mode: If `searchItemValue` is provided, looks up that one
 *    value instead and returns a small standalone result (key + return cols),
 *    not the whole source sheet.
 *
 * Config fields (sent by the pipeline's "lookupConfig"):
 *  - type:               "vlookup" | "hlookup" | "xlookup"
 *  - lookupColumn:        Column in the SOURCE sheet holding lookup_value
 *  - refMatchColumn:      Column in the REFERENCE sheet to match against
 *                         (VLOOKUP/XLOOKUP — falls back to lookupColumn's name)
 *  - targetSheetData:     JSON-stringified 2D array of table_array (the WHOLE
 *                         reference sheet, as fetched by excel_helper.js)
 *  - tableHasHeaders:     true (default) = row 1 of table_array is a header
 *                         row and is excluded from the searchable data range.
 *                         false = row 1 is real data and is searchable too.
 *                         NOTE: row 1 is still always read as the "labels"
 *                         row used to resolve column names — this only
 *                         controls whether row 1 can also be a MATCH.
 *  - colIndexNum:         1-based column index into table_array (column A of
 *                         the reference sheet = 1) — VLOOKUP/XLOOKUP only.
 *                         Resolved client-side from a header-name picker.
 *  - rowIndexNum:         1-based row index into table_array — HLOOKUP only.
 *  - returnColumnHeader:  Friendly label for the resolved index, used to
 *                         name the appended output column.
 *  - rangeLookup:         false (default/recommended) = exact match only,
 *                         Excel's range_lookup FALSE/0.
 *                         true = approximate match, Excel's range_lookup
 *                         TRUE/1 — requires refMatchColumn to be sorted
 *                         ascending; returns the closest match <= the
 *                         lookup value.
 *  - searchItemValue:     (optional) static string — overrides per-row mode
 *  - returnColumns:       (advanced/optional) explicit list of ref-sheet
 *                         column names to pull back, used only if colIndexNum
 *                         isn't supplied.
 *  - showAllColumns:      VLOOKUP/XLOOKUP only — if true, every ref column
 *                         except the match column is appended instead of a
 *                         single col_index_num result.
 */
function evaluateLookupMutation(matrix, lookupConfig) {
    if (!matrix || matrix.length === 0) return matrix;

    const {
        type,
        lookupColumn,
        refMatchColumn,
        tableHasHeaders,
        colIndexNum,
        rowIndexNum,
        returnColumnHeader,
        rangeLookup,
        targetSheetData,
        searchItemValue,
        returnColumns,
        showAllColumns
    } = lookupConfig;

    // ── Parse reference sheet (table_array) ─────────────────────────────────
    let refMatrix;
    try {
        refMatrix = JSON.parse(targetSheetData);
    } catch (e) {
        console.error("Reference sheet payload parse failure");
        return matrix;
    }
    if (!refMatrix || refMatrix.length === 0) return matrix;

    // Row 1 is always read as the "labels" row for resolving column names to
    // numeric indexes, independent of tableHasHeaders — this mirrors the
    // client-side picker, which reads the same row regardless of the toggle.
    const refLabelRow = refMatrix[0];
    const hasHeaders  = tableHasHeaders !== false; // default true
    // table_array's *searchable* rows: row 1 only counts as a candidate
    // match when the reference sheet genuinely has no header row.
    const dataStart = hasHeaders ? 1 : 0;
    const refDataRows = refMatrix.slice(dataStart);

    const staticMode = !!(searchItemValue && String(searchItemValue).trim() !== "");

    function normKey(v) {
        return String(v === null || v === undefined ? "" : v).trim().toLowerCase();
    }
    function parseNumeric(v) {
        if (typeof v === "number") return isNaN(v) ? null : v;
        const cleaned = String(v).replace(/[₹$€£,\s]/g, "").trim();
        if (cleaned === "") return null;
        const n = Number(cleaned);
        return isNaN(n) ? null : n;
    }

    // Locate the lookup key column in the SOURCE sheet (per-row mode).
    const sourceHeaders = matrix[0];
    const srcKeyColIdx = lookupColumn
        ? sourceHeaders.findIndex(h => normKey(h) === normKey(lookupColumn))
        : -1;

    // ════════════════════════════════════════════════════════════════════════
    // HLOOKUP — real Excel semantics: lookup_value is matched against the
    // FIRST ROW of table_array (the row of column headers/categories), and
    // the result is read from row_index_num within the MATCHED COLUMN.
    // (table_array's first row is, by definition, what HLOOKUP searches —
    // tableHasHeaders doesn't change that.)
    // ════════════════════════════════════════════════════════════════════════
    if (type === "hlookup") {
        const headerSearchRow = refMatrix[0] || [];
        const rowIdx = Math.max(1, parseInt(rowIndexNum, 10) || 2) - 1; // 1-based -> 0-based

        function findColumn(key) {
            const target = normKey(key);
            return headerSearchRow.findIndex(h => normKey(h) === target);
        }
        function valueAt(colIdx) {
            if (colIdx === -1) return null;
            const row = refMatrix[rowIdx];
            return row ? (row[colIdx] !== undefined ? row[colIdx] : "") : null;
        }

        if (staticMode) {
            const colIdx = findColumn(searchItemValue);
            const val = valueAt(colIdx);
            const outLabel = returnColumnHeader || ("Row " + (rowIdx + 1));
            const headers = [colIdx !== -1 ? headerSearchRow[colIdx] : searchItemValue, outLabel];
            const dataRow = [searchItemValue, val === null ? "Not found" : val];
            return [headers, dataRow];
        }

        const outLabel = returnColumnHeader || ("Row " + (rowIdx + 1) + " Value");
        const mutated = [[...sourceHeaders, outLabel]];
        for (let i = 1; i < matrix.length; i++) {
            const row = matrix[i];
            if (srcKeyColIdx === -1) { mutated.push([...row, ""]); continue; }
            const colIdx = findColumn(row[srcKeyColIdx]);
            const val = valueAt(colIdx);
            mutated.push([...row, val === null ? "" : val]);
        }
        return mutated;
    }

    // ════════════════════════════════════════════════════════════════════════
    // VLOOKUP / XLOOKUP — lookup_value is matched down refMatchColumn, and the
    // result is read from colIndexNum (1-based, column A of table_array = 1).
    // ════════════════════════════════════════════════════════════════════════
    const refMatchKey = normKey(refMatchColumn || lookupColumn);
    const refMatchColIdx = refLabelRow.findIndex(h => normKey(h) === refMatchKey);
    if (refMatchColIdx === -1) {
        console.error("Lookup: ref match column not found:", refMatchKey);
        return matrix;
    }

    // ── Determine which ref columns to pull back ────────────────────────────
    let outputColMappings;
    if (showAllColumns) {
        outputColMappings = refLabelRow
            .map((name, idx) => ({ name, idx }))
            .filter(m => m.idx !== refMatchColIdx);
    } else if (colIndexNum) {
        const idx = colIndexNum - 1; // 1-based -> 0-based; column A of table_array = 1
        if (idx < 0 || idx >= refLabelRow.length) {
            console.error("Lookup: col_index_num out of range:", colIndexNum);
            return matrix;
        }
        outputColMappings = [{ name: returnColumnHeader || refLabelRow[idx] || ("Col " + colIndexNum), idx }];
    } else if (Array.isArray(returnColumns) && returnColumns.length > 0) {
        outputColMappings = returnColumns
            .filter(c => normKey(c) !== refMatchKey)
            .map(name => ({ name, idx: refLabelRow.findIndex(h => normKey(h) === normKey(name)) }))
            .filter(m => m.idx !== -1);
    } else {
        console.error("Lookup: no return column resolved (col_index_num / returnColumns / showAllColumns all empty)");
        return matrix;
    }
    if (outputColMappings.length === 0) return matrix;

    // ── EXACT match index: key (normalized) → first matching row ───────────
    const exactIndex = new Map();
    if (!rangeLookup) {
        for (const row of refDataRows) {
            const key = normKey(row[refMatchColIdx]);
            if (!exactIndex.has(key)) exactIndex.set(key, row);
        }
    }

    // ── APPROXIMATE match: refMatchColumn assumed sorted ascending, return
    // the closest row whose key is <= the lookup value (real VLOOKUP/XLOOKUP
    // TRUE-mode behaviour) ───────────────────────────────────────────────────
    let sortedForApprox = null;
    if (rangeLookup) {
        sortedForApprox = refDataRows
            .map(row => ({ raw: row[refMatchColIdx], num: parseNumeric(row[refMatchColIdx]), row }))
            .filter(e => e.raw !== undefined && e.raw !== null && e.raw !== "");
        const allNumeric = sortedForApprox.every(e => e.num !== null);
        sortedForApprox.sort((a, b) => allNumeric
            ? a.num - b.num
            : String(a.raw).localeCompare(String(b.raw)));
        sortedForApprox._numeric = allNumeric;
    }

    function findApprox(targetRaw) {
        if (!sortedForApprox || sortedForApprox.length === 0) return null;
        const numeric = sortedForApprox._numeric;
        const targetNum = parseNumeric(targetRaw);
        let lo = 0, hi = sortedForApprox.length - 1, best = -1;
        while (lo <= hi) {
            const mid = (lo + hi) >> 1;
            const cmp = numeric
                ? (sortedForApprox[mid].num - targetNum)
                : String(sortedForApprox[mid].raw).localeCompare(String(targetRaw));
            if (cmp <= 0) { best = mid; lo = mid + 1; }
            else hi = mid - 1;
        }
        return best === -1 ? null : sortedForApprox[best].row;
    }

    function findMatch(targetRaw) {
        return rangeLookup ? findApprox(targetRaw) : (exactIndex.get(normKey(targetRaw)) || null);
    }

    // ── STATIC SEARCH MODE ───────────────────────────────────────────────────
    // A single value was typed in (e.g. "101"). The result is a small,
    // standalone lookup result — the searched key plus the chosen return
    // columns — NOT the entire source sheet with data glued onto every row.
    if (staticMode) {
        const keyColumnName = refMatchColumn || lookupColumn || refLabelRow[refMatchColIdx];
        const matchedRow = findMatch(searchItemValue);

        const headers = [keyColumnName, ...outputColMappings.map(m => m.name)];
        const dataRow = matchedRow
            ? [matchedRow[refMatchColIdx], ...outputColMappings.map(m => matchedRow[m.idx])]
            : [searchItemValue, ...outputColMappings.map(() => "Not found")];

        return [headers, dataRow];
    }

    // ── PER-ROW MODE ────────────────────────────────────────────────────────
    // No static value: every row of the source sheet looks up its own key
    // column value and gets the resolved reference column(s) appended.
    const newHeaders = [...sourceHeaders];
    outputColMappings.forEach(m => newHeaders.push(m.name));
    const mutatedMatrix = [newHeaders];

    for (let i = 1; i < matrix.length; i++) {
        const row = matrix[i];

        if (srcKeyColIdx === -1) {
            // No key resolvable — append blanks
            mutatedMatrix.push([...row, ...outputColMappings.map(() => "")]);
            continue;
        }

        const matchedRow = findMatch(row[srcKeyColIdx]);
        const appendedData = outputColMappings.map(m => matchedRow ? matchedRow[m.idx] : "");
        mutatedMatrix.push([...row, ...appendedData]);
    }

    return mutatedMatrix;
}