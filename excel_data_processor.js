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
    // Blank Excel cells arrive as "" (or occasionally null/undefined), never
    // a literal "null" string — so null/empty checks need to be resolved
    // BEFORE the generic string/number comparisons below, which have no
    // concept of "blank" on their own.
    const isBlank       = val === null || val === undefined || String(val).trim() === "";
    const targetIsBlank = config.value === null || config.value === undefined || String(config.value).trim() === "";

    // Explicit null/empty condition types.
    if (config.type === "is_null" || config.type === "is_empty") return isBlank;
    if (config.type === "is_not_null" || config.type === "is_not_empty") return !isBlank;

    // Some callers express "is null" as `{ type: "equals", value: "" }` (or
    // value: null) rather than a dedicated is_null type — treat that the
    // same way instead of falling through to a plain string comparison,
    // which would incorrectly exclude every blank row.
    if (config.type === "equals" && targetIsBlank) return isBlank;
    if (config.type === "not_equals" && targetIsBlank) return !isBlank;

    // Every other condition type requires an actual value to compare against.
    if (isBlank) return false;

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
        // Unknown condition type — exclude rather than silently pass
        // everything through (the old "default: return true" is what
        // turned an unrecognized "is_null" into a no-op filter).
        default: return false;
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// ╔═══════════════════════════════════════════════════════════════════════════╗
// ║                   NEW: PRICE VALIDATION FUNCTIONS                         ║
// ║              (All code added for price validation feature)               ║
// ╚═══════════════════════════════════════════════════════════════════════════╝
// ═════════════════════════════════════════════════════════════════════════════

/**
 * PRICE VALIDATION FUNCTION
 * ─────────────────────────────────────────────────────────────────────────────
 * Adds a "check" column to validate pricing calculations:
 * - Checks if: quantity * unitPrice = totalPrice (with discount if applicable)
 * - Formula: IF(ABS(totalPrice - (quantity * unitPrice * (1 - discountPct))) <= 0.01, "Match", "Mismatch")
 *
 * CRITICAL NOTE: discountPct should be expressed as a decimal (0-1), not percentage (0-100).
 * For example: 10% discount = 0.1, not 10
 *
 * @param {Array<Array>} matrix - 2D array with headers in first row
 * @param {Object} config - Configuration object with:
 *   - quantityColumn: column name for quantity
 *   - unitPriceColumn: column name for unit price
 *   - totalPriceColumn: column name for total price
 *   - discountColumn: (optional) column name for discount percentage
 * @returns {Array<Array>} Matrix with new "check" column added
 */
function addPriceValidationColumn(matrix, config) {
    if (!matrix || matrix.length < 2) return matrix;

    const headers = matrix[0];
    const rows = matrix.slice(1);

    // Helper to normalize and find column index
    function findColumnIndex(colName) {
        if (!colName) return -1;
        return headers.findIndex(h => String(h).trim().toLowerCase() === String(colName).trim().toLowerCase());
    }

    // Get column indices
    const qtyIdx = findColumnIndex(config.quantityColumn);
    const unitPriceIdx = findColumnIndex(config.unitPriceColumn);
    const totalPriceIdx = findColumnIndex(config.totalPriceColumn);
    const discountIdx = config.discountColumn ? findColumnIndex(config.discountColumn) : -1;

    // Validate that all required columns exist
    if (qtyIdx === -1 || unitPriceIdx === -1 || totalPriceIdx === -1) {
        console.error("Price validation: Missing required columns", {
            quantity: qtyIdx,
            unitPrice: unitPriceIdx,
            totalPrice: totalPriceIdx
        });
        return matrix;
    }

    // Helper to safely parse numeric values (handles currency symbols, commas, etc.)
    function parsePrice(val) {
        if (val === null || val === undefined || val === "") return null;
        const cleaned = String(val).replace(/[₹$€£,\s]/g, "").trim();
        const num = Number(cleaned);
        return isNaN(num) ? null : num;
    }

    // Build new matrix with "check" column
    const newHeaders = [...headers, "check"];
    const newMatrix = [newHeaders];

    for (let i = 0; i < rows.length; i++) {
        const row = rows[i];
        const quantity = parsePrice(row[qtyIdx]);
        const unitPrice = parsePrice(row[unitPriceIdx]);
        const totalPrice = parsePrice(row[totalPriceIdx]);
        const discount = discountIdx !== -1 ? parsePrice(row[discountIdx]) : 0;

        let checkResult = "N/A";

        // Perform validation only if all required values are present and numeric
        if (quantity !== null && unitPrice !== null && totalPrice !== null && discount !== null) {
            // Calculate expected total: quantity * unitPrice * (1 - discount)
            // discount is expected to be in decimal form (0-1)
            const expectedTotal = quantity * unitPrice * (1 - discount);

            // Check if actual totalPrice matches expected total (within 0.01 tolerance)
            const difference = Math.abs(totalPrice - expectedTotal);
            checkResult = difference <= 0.01 ? "Match" : "Mismatch";

            // Debug info can be logged here if needed
            console.log(`Row ${i + 2}: qty=${quantity}, unitPrice=${unitPrice}, discount=${discount}, ` +
                       `expected=${expectedTotal.toFixed(2)}, actual=${totalPrice.toFixed(2)}, ` +
                       `diff=${difference.toFixed(4)}, result=${checkResult}`);
        }

        newMatrix.push([...row, checkResult]);
    }

    return newMatrix;
}

/**
 * Excel Formula Generator for Price Validation
 * ─────────────────────────────────────────────────────────────────────────────
 * Generates the Excel formula string that can be placed directly in a cell.
 * This matches the validation logic implemented in addPriceValidationColumn.
 *
 * The formula uses:
 * - ABS: Absolute value to ignore sign
 * - IF: Conditional logic to return "Match" or "Mismatch"
 * - Tolerance of 0.01 to account for rounding in calculations
 *
 * Formula with discount:    =IF(ABS(H2-((F2*E2)*(1-G2)))<=0.01,"Match","Mismatch")
 * Formula without discount: =IF(ABS(H2-(F2*E2))<=0.01,"Match","Mismatch")
 *
 * @param {number} rowNum - Excel row number (1-based, e.g., 2 for first data row)
 * @param {string} quantityCol - Excel column letter for quantity (e.g., "E")
 * @param {string} unitPriceCol - Excel column letter for unit price (e.g., "F")
 * @param {string} totalPriceCol - Excel column letter for total price (e.g., "H")
 * @param {string} discountCol - Excel column letter for discount (e.g., "G"), or null if no discount
 * @returns {string} Excel formula string
 */
function generatePriceValidationFormula(rowNum, quantityCol, unitPriceCol, totalPriceCol, discountCol = null) {
    if (discountCol) {
        // Formula with discount: =IF(ABS(H2-((F2*E2)*(1-G2)))<=0.01,"Match","Mismatch")
        // Where H2 = totalPrice, F2 = unitPrice, E2 = quantity, G2 = discount (in decimal: 0.1 = 10%)
        return `=IF(ABS(${totalPriceCol}${rowNum}-(${unitPriceCol}${rowNum}*${quantityCol}${rowNum})*(1-${discountCol}${rowNum}))<=0.01,"Match","Mismatch")`;
    } else {
        // Formula without discount: =IF(ABS(H2-(F2*E2))<=0.01,"Match","Mismatch")
        return `=IF(ABS(${totalPriceCol}${rowNum}-(${unitPriceCol}${rowNum}*${quantityCol}${rowNum}))<=0.01,"Match","Mismatch")`;
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// ║                         END OF NEW CODE                                   ║
// ═════════════════════════════════════════════════════════════════════════════

// Export functions for use in browser and Node.js
if (typeof window !== "undefined") {
    window.calculateAggregations = calculateAggregations;
    window.evaluateCondition = evaluateCondition;
    window.addPriceValidationColumn = addPriceValidationColumn;
    window.generatePriceValidationFormula = generatePriceValidationFormula;
}