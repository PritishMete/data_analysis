// web/excel_helper.js
// -------------------------------------------------------------------
// Office.js bridge, sheet management, and pipeline orchestration.
// -------------------------------------------------------------------

window._officeReady = false;
window._officeReadyResolvers = [];

window._onOfficeReady = function () {
    window._officeReady = true;
    window._officeReadyResolvers.forEach(function (resolve) { resolve(); });
    window._officeReadyResolvers = [];
};

window.waitForOfficeReady = function () {
    if (window._officeReady) return Promise.resolve();
    return new Promise(function (resolve) {
        window._officeReadyResolvers.push(resolve);
    });
};

// ── Sheet Management ─────────────────────────────────────────────────────────

async function getWorksheetNames() {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") return [];
    try {
        return await Excel.run(async function (context) {
            const sheets = context.workbook.worksheets;
            sheets.load("items/name");
            await context.sync();
            return sheets.items.map(s => s.name);
        });
    } catch (err) {
        console.error("getWorksheetNames error:", err);
        return [];
    }
}

// Returns the name of whatever worksheet is currently active in the
// workbook. Used by the Enterprise Transformation Engine integration to
// write a transformed dataset back into the sheet the user is already
// looking at, instead of always spawning a new sheet.
async function getActiveWorksheetName() {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") return null;
    try {
        return await Excel.run(async function (context) {
            const sheet = context.workbook.worksheets.getActiveWorksheet();
            sheet.load("name");
            await context.sync();
            return sheet.name;
        });
    } catch (err) {
        console.error("getActiveWorksheetName error:", err);
        return null;
    }
}
window.getActiveWorksheetName = getActiveWorksheetName;

function _isGeneratedInsightFlowWorksheet(name) {
    const n = String(name || "").trim().toLowerCase();
    if (!n) return true;
    return n === "quality_report" ||
        n === "data_quality_report" ||
        n === "query_result" ||
        n.indexOf("query_result") === 0 ||
        n.indexOf("pivot_") === 0 ||
        n.indexOf("pivot ") === 0 ||
        n.indexOf("data_quality") === 0 ||
        n.indexOf("quality_report") === 0 ||
        n.indexOf("temp_source_buffer_") === 0 ||
        n.indexOf("refactored_data") === 0 ||
        n.indexOf("wrapped_table") === 0 ||
        n.indexOf("_split") === n.length - 6;
}

function _parseInsightFlowSourceSetting(value) {
    if (!value) return null;
    try {
        const parsed = JSON.parse(String(value));
        if (parsed && typeof parsed === "object") return parsed;
    } catch (_) {}
    return { name: String(value) };
}

async function getInsightFlowSourceWorksheetName() {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") return null;
    try {
        return await Excel.run(async function(context) {
            const workbook = context.workbook;
            const setting = workbook.settings.getItemOrNullObject("InsightFlow.SourceWorksheet");
            setting.load(["value", "key", "isNullObject"]);
            await context.sync();
            if (setting.isNullObject || !setting.value) return null;

            const source = _parseInsightFlowSourceSetting(setting.value);
            if (!source) return null;

            let sheet = null;
            if (source.id) {
                sheet = workbook.worksheets.getItemOrNullObject(String(source.id));
                sheet.load(["name", "id", "isNullObject"]);
                await context.sync();
                if (!sheet.isNullObject) return sheet.name;
            }
            if (source.name) {
                sheet = workbook.worksheets.getItemOrNullObject(String(source.name));
                sheet.load(["name", "id", "isNullObject"]);
                await context.sync();
                if (!sheet.isNullObject) return sheet.name;
            }
            return null;
        });
    } catch (err) {
        console.error("getInsightFlowSourceWorksheetName error:", err);
        return null;
    }
}

async function setInsightFlowSourceWorksheetName(sheetName) {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") return false;
    const name = String(sheetName || "").trim();
    if (!name || _isGeneratedInsightFlowWorksheet(name)) return false;
    try {
        return await Excel.run(async function(context) {
            const workbook = context.workbook;
            const sheet = workbook.worksheets.getItemOrNullObject(name);
            sheet.load(["name", "id", "isNullObject"]);
            await context.sync();
            if (sheet.isNullObject) return false;
            workbook.settings.add("InsightFlow.SourceWorksheet", JSON.stringify({
                id: sheet.id,
                name: sheet.name,
            }));
            await context.sync();
            return true;
        });
    } catch (err) {
        console.error("setInsightFlowSourceWorksheetName error:", err);
        return false;
    }
}

// Establish the worksheet AND the exact dataset range selected by the user.
// The range is workbook-local metadata only; no cell values are persisted.
async function establishInsightFlowSourceFromActiveWorksheet() {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") return null;
    try {
        return await Excel.run(async function(context) {
            const workbook = context.workbook;
            const sheet = workbook.worksheets.getActiveWorksheet();
            sheet.load(["name", "id"]);
            const selected = workbook.getSelectedRange();
            selected.load(["address", "rowCount", "columnCount"]);
            await context.sync();
            if (_isGeneratedInsightFlowWorksheet(sheet.name)) return null;

            let sourceRange = null;
            try {
                const currentRegion = selected.getCurrentRegion();
                currentRegion.load(["address", "rowCount", "columnCount"]);
                await context.sync();
                if ((currentRegion.rowCount || 0) > 1 &&
                    (currentRegion.columnCount || 0) > 1) {
                    sourceRange = currentRegion;
                }
            } catch (_) {}

            const rangeAddress = sourceRange ? sourceRange.address : selected.address;
            workbook.settings.add("InsightFlow.SourceWorksheet", JSON.stringify({
                id: sheet.id,
                name: sheet.name,
                rangeAddress: rangeAddress,
            }));
            await context.sync();
            console.log("[SOURCE CONTEXT] established analytical source metadata (worksheet/range only).");
            return sheet.name;
        });
    } catch (err) {
        console.error("establishInsightFlowSourceFromActiveWorksheet error:", err);
        return null;
    }
}

async function getInsightFlowSourceData() {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") return null;
    try {
        return await Excel.run(async function(context) {
            const workbook = context.workbook;
            const setting = workbook.settings.getItemOrNullObject("InsightFlow.SourceWorksheet");
            setting.load(["value", "isNullObject"]);
            await context.sync();
            if (setting.isNullObject || !setting.value) return null;
            const source = _parseInsightFlowSourceSetting(setting.value);
            if (!source || !source.name) return null;

            let sheet = null;
            if (source.id) {
                sheet = workbook.worksheets.getItemOrNullObject(String(source.id));
                sheet.load(["name", "id", "isNullObject"]);
                await context.sync();
                if (sheet.isNullObject) sheet = null;
            }
            if (!sheet && source.name) {
                sheet = workbook.worksheets.getItemOrNullObject(String(source.name));
                sheet.load(["name", "id", "isNullObject"]);
                await context.sync();
                if (sheet.isNullObject) return null;
            }
            if (_isGeneratedInsightFlowWorksheet(sheet.name)) return null;

            let matrix;
            if (source.rangeAddress) {
                const localAddress = String(source.rangeAddress).split("!").pop();
                const range = sheet.getRange(localAddress);
                range.load(["values", "address", "rowCount", "columnCount"]);
                await context.sync();
                matrix = _normaliseMatrix(range.values);
                console.log("[SOURCE CONTEXT] reading persisted source range:", range.address,
                    "shape:", _matrixShape(matrix));
            } else {
                const range = await _getLargestTableRange(context, sheet) || await _getUsedRangeData(context, sheet);
                matrix = _normaliseMatrix(range && range.values);
                console.log("[SOURCE CONTEXT] reading persisted source worksheet:", sheet.name,
                    "shape:", _matrixShape(matrix));
            }
            return JSON.stringify(matrix);
        });
    } catch (err) {
        console.error("getInsightFlowSourceData error:", err);
        return JSON.stringify({ __error: (err && err.message) ? err.message : String(err) });
    }
}
window.getInsightFlowSourceWorksheetName = getInsightFlowSourceWorksheetName;
window.setInsightFlowSourceWorksheetName = setInsightFlowSourceWorksheetName;
window.establishInsightFlowSourceFromActiveWorksheet = establishInsightFlowSourceFromActiveWorksheet;
window.getInsightFlowSourceData = getInsightFlowSourceData;

function _isMeaningfulMatrix(matrix) {
    return Array.isArray(matrix) && matrix.length > 0 &&
        matrix.some(row => Array.isArray(row) && row.some(v => v !== null && v !== undefined && String(v).trim() !== ""));
}

function _matrixShape(matrix) {
    if (!Array.isArray(matrix)) return { rows: 0, cols: 0 };
    return {
        rows: matrix.length,
        cols: matrix.reduce((m, row) => Math.max(m, Array.isArray(row) ? row.length : 0), 0)
    };
}

function _normaliseMatrix(matrix) {
    if (!Array.isArray(matrix)) return [];
    const rows = matrix.filter(row => Array.isArray(row));
    if (!rows.length) return [];
    const width = rows.reduce((m, row) => Math.max(m, row.length), 0);
    if (!width) return [];
    return rows.map(row => {
        const out = Array.from(row);
        while (out.length < width) out.push("");
        return out;
    });
}

async function _getLargestTableRange(context, sheet) {
    try {
        const tables = sheet.tables;
        tables.load("items/name");
        await context.sync();
        if (!tables.items || tables.items.length === 0) return null;

        const candidates = tables.items.map(table => {
            const range = table.getRange();
            range.load(["address", "rowCount", "columnCount"]);
            return { table, range };
        });
        await context.sync();

        // Pick the largest table by cell count first — cheap, metadata-only —
        // then read values for just that one table (chunked if it's huge).
        // Loading .values for every table up front, before we even know
        // which one is worth reading, is what used to make this scan huge
        // workbooks: it multiplied the single-read-ceiling problem by the
        // number of tables on the sheet.
        let best = null;
        let bestCells = 0;
        for (const candidate of candidates) {
            const r = candidate.range;
            const cells = (r.rowCount || 0) * (r.columnCount || 0);
            if (cells > bestCells) {
                best = r;
                bestCells = cells;
            }
        }
        if (!best) return null;

        const values = await _readRangeValuesChunked(context, best, best.rowCount, best.columnCount);
        if (!_isMeaningfulMatrix(values)) return null;

        return { address: best.address, rowCount: best.rowCount, columnCount: best.columnCount, values };
    } catch (_) {
        return null;
    }
}

// Excel's JS API has a practical ceiling on how many cells a single
// range.values read can return in one round trip — very large used ranges
// (hundreds of thousands of rows) routinely fail or hang instead of raising
// a useful error. Rather than refusing datasets above this size, we split
// the read into row-chunks that each stay under the ceiling and stitch the
// chunks back into one matrix. This does NOT cap how many rows/cols a sheet
// can have — it just changes a huge sheet from "one request" into "several
// smaller requests."
const _CELL_READ_LIMIT = 2000000;
// How many row-chunks to queue before each context.sync(). Each chunk stays
// under _CELL_READ_LIMIT (so it's still a safe single read), but batching
// several of them into one round trip is what actually cuts wall-clock time —
// network/round-trip latency, not data volume, is the dominant cost once a
// sheet needs more than a couple of chunks.
const _CHUNKS_PER_SYNC = 6;

async function _readRangeValuesChunked(context, range, rowCount, columnCount) {
    const totalRows = rowCount || 0;
    const totalCols = columnCount || 0;
    if (totalRows === 0 || totalCols === 0) return [];

    const totalCells = totalRows * totalCols;
    if (totalCells <= _CELL_READ_LIMIT) {
        range.load("values");
        await context.sync();
        return range.values || [];
    }

    const chunkRows = Math.max(1, Math.floor(_CELL_READ_LIMIT / totalCols));
    const chunkCount = Math.ceil(totalRows / chunkRows);
    const syncCount = Math.ceil(chunkCount / _CHUNKS_PER_SYNC);
    console.log(
        `[LARGE RANGE] ${totalRows.toLocaleString()} rows x ${totalCols.toLocaleString()} cols ` +
        `(${totalCells.toLocaleString()} cells) exceeds the ${_CELL_READ_LIMIT.toLocaleString()}-cell ` +
        `single-read limit — reading in ${chunkCount} row-chunks of up to ${chunkRows.toLocaleString()} rows, ` +
        `batched ${_CHUNKS_PER_SYNC} per round trip (~${syncCount} round trips total).`
    );

    const values = [];
    let batch = [];
    for (let offset = 0; offset < totalRows; offset += chunkRows) {
        const rowsInChunk = Math.min(chunkRows, totalRows - offset);
        // getCell(offset, 0) anchors a 1x1 range at the start of this chunk;
        // getResizedRange expands its bottom-right corner to cover the full
        // chunk (rowsInChunk rows x totalCols cols), all relative to `range`
        // so it works regardless of where on the sheet `range` starts.
        const chunkRange = range.getCell(offset, 0).getResizedRange(rowsInChunk - 1, totalCols - 1);
        chunkRange.load("values");
        batch.push(chunkRange);

        const isLastChunk = offset + chunkRows >= totalRows;
        if (batch.length >= _CHUNKS_PER_SYNC || isLastChunk) {
            await context.sync();
            for (const c of batch) {
                if (Array.isArray(c.values)) {
                    for (const row of c.values) values.push(row);
                }
            }
            batch = [];
        }
    }
    return values;
}

async function _getUsedRangeData(context, sheet) {
    const usedRange = sheet.getUsedRange();
    usedRange.load(["address", "rowCount", "columnCount"]);
    await context.sync();

    const values = await _readRangeValuesChunked(context, usedRange, usedRange.rowCount, usedRange.columnCount);
    return {
        address: usedRange.address,
        rowCount: usedRange.rowCount,
        columnCount: usedRange.columnCount,
        values
    };
}

async function getSheetData(sheetName) {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") return null;
    try {
        return await Excel.run(async function (context) {
            const sheet = context.workbook.worksheets.getItem(sheetName);

            // Prefer a real Excel table when one exists. This avoids sending
            // formatting-only cells or unrelated content on the same sheet.
            let range = await _getLargestTableRange(context, sheet);
            if (!range) range = await _getUsedRangeData(context, sheet);

            const matrix = _normaliseMatrix(range && range.values);
            console.log("[DATA SOURCE] named sheet:", sheetName,
                "range:", range ? range.address : null,
                "shape:", _matrixShape(matrix));
            return JSON.stringify(matrix);
        });
    } catch (err) {
        console.error("getSheetData error:", err);
        return JSON.stringify({ __error: (err && err.message) ? err.message : String(err) });
    }
}

async function getSelectedExcelData() {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") return null;
    try {
        return await Excel.run(async function (context) {
            const selected = context.workbook.getSelectedRange();
            selected.load(["address", "values", "rowCount", "columnCount"]);
            const activeSheet = context.workbook.worksheets.getActiveWorksheet();
            activeSheet.load("name");
            await context.sync();

            // IMPORTANT: the selected cell is a pointer into the dataset, not
            // necessarily the dataset itself. Scan its contiguous region first.
            let sourceRange = null;
            try {
                const currentRegion = selected.getCurrentRegion();
                currentRegion.load(["values", "address", "rowCount", "columnCount"]);
                await context.sync();
                if (_isMeaningfulMatrix(currentRegion.values) &&
                    ((currentRegion.rowCount || 0) > 1 || (currentRegion.columnCount || 0) > 1)) {
                    sourceRange = currentRegion;
                }
            } catch (_) {
                // Some Excel hosts do not expose getCurrentRegion consistently.
            }

            // If the current region is not useful, prefer a real table on the
            // active sheet, then finally the used range.
            if (!sourceRange) {
                sourceRange = await _getLargestTableRange(context, activeSheet);
            }
            if (!sourceRange) {
                sourceRange = await _getUsedRangeData(context, activeSheet);
            }

            const matrix = _normaliseMatrix(sourceRange && sourceRange.values);
            console.log("[DATA SOURCE] active selection:", selected.address,
                "sheet:", activeSheet.name,
                "dataset range:", sourceRange ? sourceRange.address : null,
                "shape:", _matrixShape(matrix));
            return JSON.stringify(matrix);
        });
    } catch (err) {
        console.error("getSelectedExcelData error:", err);
        return JSON.stringify({ __error: (err && err.message) ? err.message : String(err) });
    }
}

async function jsDetectDelimiters(sheetName, columnName) {
    let jsonStr = sheetName ? await getSheetData(sheetName) : await getSelectedExcelData();
    if (!jsonStr) return [];
    try {
        const matrix = JSON.parse(jsonStr);
        if (!matrix || matrix.length < 2) return [];
        const hRow = matrix[0];
        const colIdx = hRow.findIndex(h => String(h).trim() === String(columnName).trim());
        if (colIdx === -1) return [];

        const delims = [",", ";", "|", "-", "/", " ", "\t"];
        const scores = {};
        delims.forEach(d => scores[d] = 0);

        let sampled = 0;
        for (let i = 1; i < matrix.length && sampled < 40; i++) {
            const val = String(matrix[i][colIdx] || "");
            if (!val) continue;
            sampled++;
            delims.forEach(d => {
                const parts = val.split(d).length;
                if (parts > 1) scores[d] += parts;
            });
        }
        return delims.filter(d => scores[d] > 0).sort((a, b) => scores[b] - scores[a]);
    } catch (_) {
        return [];
    }
}

async function jsSplitColumnPipeline(sheetName, columnName, delimiter) {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") return { success: false, processedRows: 0, error: "Excel context unallocated" };

    return await Excel.run(async function (context) {
        const workbook = context.workbook;
        const sheet = sheetName ? workbook.worksheets.getItem(sheetName) : workbook.worksheets.getActiveWorksheet();
        const range = sheet.getUsedRange();
        range.load(["values", "formulas", "numberFormat"]);
        await context.sync();

        const matrix = range.values;
        if (!matrix || matrix.length === 0) return { success: false, processedRows: 0, error: "Empty selection grid" };

        const headers = matrix[0];
        const colIdx = headers.findIndex(h => String(h).trim() === String(columnName).trim());
        if (colIdx === -1) return { success: false, processedRows: 0, error: "Column field targeted missing" };

        let maxSplits = 1;
        const splitRows = [];
        for (let i = 1; i < matrix.length; i++) {
            const cellVal = String(matrix[i][colIdx] ?? "");
            const tokens = cellVal.split(delimiter);
            if (tokens.length > maxSplits) maxSplits = tokens.length;
            splitRows.push(tokens);
        }

        const targetSheetName = (sheet.name + "_Split").substring(0, 31);
        const sheets = workbook.worksheets;
        sheets.load("items/name");
        await context.sync();

        for (let i = 0; i < sheets.items.length; i++) {
            if (sheets.items[i].name === targetSheetName) {
                sheets.items[i].delete();
                break;
            }
        }
        await context.sync();

        const outSheet = workbook.worksheets.add(targetSheetName);
        const outMatrix = [];

        const nextHeaders = [...headers.slice(0, colIdx)];
        for (let k = 0; k < maxSplits; k++) {
            nextHeaders.push(columnName + "_pt" + (k + 1));
        }
        nextHeaders.push(...headers.slice(colIdx + 1));
        outMatrix.push(nextHeaders);

        for (let i = 1; i < matrix.length; i++) {
            const originalRow = matrix[i];
            const tokens = splitRows[i - 1];
            while (tokens.length < maxSplits) tokens.push("");

            const assembledRow = [
                ...originalRow.slice(0, colIdx),
                ...tokens,
                ...originalRow.slice(colIdx + 1)
            ];
            outMatrix.push(assembledRow);
        }

        const outRange = outSheet.getRangeByIndexes(0, 0, outMatrix.length, outMatrix[0].length);
        outRange.values = outMatrix;
        outSheet.activate();
        await context.sync();

        return { success: true, processedRows: outMatrix.length - 1, error: null };
    }).catch(err => {
        return { success: false, processedRows: 0, error: err.toString() };
    });
}

// ── L2 Layout Transformations (WRAPROWS Builder) ──────────────────────────

async function jsBuildWrapRowsTable(optionsJson) {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") return { success: false, processedRows: 0, error: "Office JS layer unreachable." };

    try {
        const opts = JSON.parse(optionsJson);
        return await Excel.run(async function (context) {
            const workbook = context.workbook;
            let sourceSheet = opts.sourceSheetName ? workbook.worksheets.getItem(opts.sourceSheetName) : workbook.worksheets.getActiveWorksheet();

            let sourceRange;
            if (opts.sourceRange) {
                sourceRange = sourceSheet.getRange(opts.sourceRange);
            } else {
                sourceRange = sourceSheet.getUsedRange();
            }

            sourceRange.load(["address", "values"]);
            await context.sync();

            const values = sourceRange.values;
            const flatList = [];
            for (let r = 0; r < values.length; r++) {
                for (let c = 0; c < values[r].length; c++) {
                    if (values[r][c] !== undefined && values[r][c] !== "") flatList.push(values[r][c]);
                }
            }

            if (flatList.length === 0) return { success: false, processedRows: 0, error: "No data discovered in the target range." };

            const colCount = parseInt(opts.columnCount, 10) || 1;
            const rowCount = Math.ceil(flatList.length / colCount);

            const outputMatrix = [];
            for (let i = 0; i < rowCount; i++) {
                const newRow = [];
                for (let j = 0; j < colCount; j++) {
                    const idx = i * colCount + j;
                    newRow.push(idx < flatList.length ? flatList[idx] : "");
                }
                outputMatrix.push(newRow);
            }

            const targetName = (opts.targetSheetName || "Wrapped_Table").substring(0, 31);
            const sheets = workbook.worksheets;
            sheets.load("items/name");
            await context.sync();

            for (let i = 0; i < sheets.items.length; i++) {
                if (sheets.items[i].name === targetName) {
                    sheets.items[i].delete();
                    break;
                }
            }
            await context.sync();

            const targetSheet = workbook.worksheets.add(targetName);
            const finalRange = targetSheet.getRangeByIndexes(0, 0, outputMatrix.length, outputMatrix[0].length);
            finalRange.values = outputMatrix;

            if (opts.hasHeaderRow) {
                const headerRange = targetSheet.getRangeByIndexes(0, 0, 1, colCount);
                headerRange.format.font.bold = true;
                targetSheet.freezePanes.freezeRows(1);
            }

            targetSheet.getUsedRange().format.autofitColumns();
            targetSheet.activate();
            await context.sync();

            return { success: true, processedRows: outputMatrix.length, error: null };
        });
    } catch (err) {
        return { success: false, processedRows: 0, error: err.toString() };
    }
}

// ── Conditional Formatting Layer (Color Scales Alt+H,L,S,M Equivalent) ──────

async function jsApplyColorScale(optionsJson) {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") return { success: false, processedRows: 0, error: "Office JS layer unreachable." };

    try {
        const opts = JSON.parse(optionsJson);
        return await Excel.run(async function (context) {
            const workbook = context.workbook;
            const sheet = opts.sheetName ? workbook.worksheets.getItem(opts.sheetName) : workbook.worksheets.getActiveWorksheet();

            let colIdx = -1;
            let startRow = 0;

            if (opts.hasHeaders) {
                const usedRange = sheet.getUsedRange();
                usedRange.load("values");
                await context.sync();

                const headers = usedRange.values[0];
                colIdx = headers.findIndex(h => String(h).trim() === String(opts.column).trim());
                startRow = 1;
            } else {
                let base = 0;
                const letterStr = String(opts.column).toUpperCase().trim();
                for (let p = 0; p < letterStr.length; p++) {
                    base = base * 26 + (letterStr.charCodeAt(p) - 64);
                }
                colIdx = base - 1;
                startRow = 0;
            }

            if (colIdx === -1) return { success: false, processedRows: 0, error: "Target formatting column reference is invalid." };

            const completeRange = sheet.getUsedRange();
            completeRange.load("rowCount");
            await context.sync();

            const endRow = completeRange.rowCount;
            if (endRow <= startRow) return { success: true, processedRows: 0, error: null };

            const formatRange = sheet.getRangeByIndexes(startRow, colIdx, (endRow - startRow), 1);

            formatRange.conditionalFormats.clearAll();

            const condFormat = formatRange.conditionalFormats.add(Excel.ConditionalFormatType.colorScale);
            const colorScale = condFormat.colorScale;

            if (opts.scaleType === "3-color") {
                colorScale.threeColorScaleCriteria = {
                    minimum: { type: Excel.ConditionalFormatColorCriterionType.lowestValue, color: "#" + opts.minColor },
                    midpoint: { type: Excel.ConditionalFormatColorCriterionType.percentile, value: "50", color: "#" + opts.midColor },
                    maximum: { type: Excel.ConditionalFormatColorCriterionType.highestValue, color: "#" + opts.maxColor }
                };
            } else {
                colorScale.twoColorScaleCriteria = {
                    minimum: { type: Excel.ConditionalFormatColorCriterionType.lowestValue, color: "#" + opts.minColor },
                    maximum: { type: Excel.ConditionalFormatColorCriterionType.highestValue, color: "#" + opts.maxColor }
                };
            }

            await context.sync();
            return { success: true, processedRows: (endRow - startRow), error: null };
        });
    } catch (err) {
        return { success: false, processedRows: 0, error: err.toString() };
    }
}

window.jsBuildWrapRowsTable = jsBuildWrapRowsTable;
window.jsApplyColorScale = jsApplyColorScale;

// ── Row Classification Layer (Add Computed Column) ──────────────────────────

async function jsAddComputedColumn(optionsJson) {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") return { success: false, processedRows: 0, error: "Office JS layer unreachable." };

    try {
        const opts = JSON.parse(optionsJson);
        const config = opts.addColumnConfig || {};

        const isFormulaMode = !!config.rightExpression;

        if (isFormulaMode) {
            if (typeof evaluateFormulaColumnMutation !== "function") {
                return {
                    success: false,
                    processedRows: 0,
                    error: "Formula-column engine not loaded — ensure excel_data_processor.js is included before excel_helper.js in index.html."
                };
            }
        } else if (typeof evaluateAddColumnMutation !== "function") {
            return {
                success: false,
                processedRows: 0,
                error: "Add-column engine not loaded — ensure excel_data_processor.js is included before excel_helper.js in index.html."
            };
        }

        return await Excel.run(async function (context) {
            const workbook = context.workbook;
            const sheet = opts.sheetName ? workbook.worksheets.getItem(opts.sheetName) : workbook.worksheets.getActiveWorksheet();

            const usedRange = sheet.getUsedRange();
            usedRange.load(["values", "rowIndex", "columnIndex"]);
            await context.sync();

            const matrix = usedRange.values;
            if (!matrix || matrix.length === 0) {
                return { success: false, processedRows: 0, error: "Sheet has no data." };
            }

            const newMatrix = isFormulaMode
                ? evaluateFormulaColumnMutation(matrix, config)
                : evaluateAddColumnMutation(matrix, config);
            if (newMatrix === matrix) {
                return {
                    success: false,
                    processedRows: 0,
                    error: isFormulaMode
                        ? "Could not parse leftExpression/rightExpression against this sheet's headers."
                        : "Could not resolve the partitionBy/sourceColumn fields against this sheet's headers."
                };
            }

            const outRange = sheet.getRangeByIndexes(
                usedRange.rowIndex,
                usedRange.columnIndex,
                newMatrix.length,
                newMatrix[0].length
            );
            outRange.values = newMatrix;
            await context.sync();

            if (isFormulaMode) {
                try {
                    const headers = matrix[0];
                    const headerToLetter = {};
                    headers.forEach(function (h, idx) {
                        headerToLetter[String(h).trim().toLowerCase()] =
                            columnIndexToExcelLetter(usedRange.columnIndex + idx);
                    });

                    const dataRowCount = newMatrix.length - 1;
                    if (dataRowCount > 0) {
                        const formulaRows = [];
                        for (let r = 1; r < newMatrix.length; r++) {
                            const excelRow = usedRange.rowIndex + r + 1;
                            formulaRows.push([buildExcelFormulaForRow(config, headerToLetter, excelRow)]);
                        }
                        const newColOffset = headers.length;
                        const formulaRange = sheet.getRangeByIndexes(
                            usedRange.rowIndex + 1,
                            usedRange.columnIndex + newColOffset,
                            dataRowCount,
                            1
                        );

                        formulaRange.numberFormat = formulaRows.map(() => ["General"]);
                        formulaRange.formulas = formulaRows;
                        await context.sync();
                    }
                } catch (err) {
                    console.error("formula_column: failed to write live Excel formulas —", err.message);
                }
            }

            sheet.getUsedRange().format.autofitColumns();
            await context.sync();

            return { success: true, processedRows: newMatrix.length - 1, error: null };
        });
    } catch (err) {
        return { success: false, processedRows: 0, error: err.toString() };
    }
}

window.jsAddComputedColumn = jsAddComputedColumn;

/// Writes a range-binning derived column back to the live sheet as LIVE
/// Excel formulas (a nested IF() chain per column
/// buildRangeBinningFormulaForRow in excel_data_processor.js) instead of a
/// one-time static value, so the column recalculates automatically when the
/// user edits the source cells — same intent, same architecture, as the
/// formula-mode branch of jsAddComputedColumn above. Deliberately only
/// appends the ONE new column via formulas rather than rewriting the whole
/// used range (unlike jsWriteQueryResultToSheet's static full-table
/// write-back): every other cell on the sheet, including the source column
/// the formulas reference, is left exactly as the user has it, which is
/// what "recalculates when source changes" actually requires.
///
/// Expected optionsJson shape:
/// {
///   "sheetName": "Sheet1" | null,
///   "sourceColumn": "Aggregate rating",
///   "newColumn": "Rating_Range",
///   "formulaIntervals": [
///     {"low": 0, "high": 1, "low_open": false, "high_open": false, "label": "0-1"},
///     ...
///   ]
/// }
///
/// Returns {success:false, ...} (never throws) whenever live formulas can't
/// be written — e.g. the source column isn't present on THIS live sheet, or
/// formulaIntervals is missing/empty — so the caller (see
/// lib/features/dashboard/data_screen.dart) can fall back to writing static
/// values via writeQueryResultToSheet instead, per the documented fallback
/// behavior.
async function jsWriteRangeBinningFormulas(optionsJson) {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") return { success: false, processedRows: 0, error: "Office JS layer unreachable." };

    try {
        const opts = JSON.parse(optionsJson);
        const sourceColumn = opts.sourceColumn;
        const newColumn = opts.newColumn;
        const intervals = Array.isArray(opts.formulaIntervals) ? opts.formulaIntervals : [];

        if (!sourceColumn || !newColumn || intervals.length === 0) {
            return {
                success: false,
                processedRows: 0,
                error: "Missing sourceColumn/newColumn/formulaIntervals — cannot write live range-binning formulas."
            };
        }
        if (typeof buildRangeBinningFormulaForRow !== "function") {
            return {
                success: false,
                processedRows: 0,
                error: "Range-binning formula engine not loaded — ensure excel_data_processor.js is included before excel_helper.js in index.html."
            };
        }

        return await Excel.run(async function (context) {
            const workbook = context.workbook;
            const sheet = opts.sheetName ? workbook.worksheets.getItem(opts.sheetName) : workbook.worksheets.getActiveWorksheet();

            const usedRange = sheet.getUsedRange();
            usedRange.load(["values", "rowIndex", "columnIndex"]);
            await context.sync();

            const matrix = usedRange.values;
            if (!matrix || matrix.length === 0) {
                return { success: false, processedRows: 0, error: "Sheet has no data." };
            }

            const headers = matrix[0];
            const normalizedSource = String(sourceColumn).trim().toLowerCase();
            let sourceLetter = null;
            headers.forEach(function (h, idx) {
                if (String(h).trim().toLowerCase() === normalizedSource) {
                    sourceLetter = columnIndexToExcelLetter(usedRange.columnIndex + idx);
                }
            });
            if (!sourceLetter) {
                return {
                    success: false,
                    processedRows: 0,
                    error: "Source column '" + sourceColumn + "' not found on this sheet — cannot write live formulas."
                };
            }

            const dataRowCount = matrix.length - 1;
            if (dataRowCount <= 0) {
                return { success: false, processedRows: 0, error: "Sheet has no data rows." };
            }

            // New column placement matches jsAddComputedColumn's convention:
            // immediately after the last used column.
            const newColIndex = usedRange.columnIndex + headers.length;

            const headerCell = sheet.getRangeByIndexes(usedRange.rowIndex, newColIndex, 1, 1);
            headerCell.values = [[newColumn]];

            const formulaRows = [];
            for (let r = 1; r < matrix.length; r++) {
                const excelRow = usedRange.rowIndex + r + 1;
                formulaRows.push([buildRangeBinningFormulaForRow(intervals, sourceLetter, excelRow)]);
            }
            const formulaRange = sheet.getRangeByIndexes(usedRange.rowIndex + 1, newColIndex, dataRowCount, 1);
            formulaRange.numberFormat = formulaRows.map(() => ["General"]);
            formulaRange.formulas = formulaRows;
            await context.sync();

            sheet.getUsedRange().format.autofitColumns();
            await context.sync();

            return { success: true, processedRows: dataRowCount, error: null };
        });
    } catch (err) {
        return { success: false, processedRows: 0, error: err.toString() };
    }
}

window.jsWriteRangeBinningFormulas = jsWriteRangeBinningFormulas;


/// Append one static column to the current/live worksheet. Unlike
/// jsWriteQueryResultToSheet this never creates a new worksheet and never
/// rewrites the existing table. It is intentionally chunked for large
/// datasets such as 10k+ restaurant reviews.
///
/// Expected optionsJson:
/// {
///   "sheetName": "Sheet1" | null,
///   "columnName": "Sentiment",
///   "values": ["Positive", "Negative", "Neutral", ...]
/// }
async function jsAppendStaticColumn(optionsJson) {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") {
        return { success: false, processedRows: 0, error: "Office JS layer unreachable." };
    }

    let opts;
    try {
        opts = JSON.parse(optionsJson);
    } catch (err) {
        return { success: false, processedRows: 0, error: "Invalid options JSON: " + err.toString() };
    }

    const columnName = String(opts.columnName || "").trim();
    const values = Array.isArray(opts.values) ? opts.values : [];
    if (!columnName) return { success: false, processedRows: 0, error: "Missing columnName." };
    if (values.length === 0) return { success: false, processedRows: 0, error: "No column values supplied." };

    const CHUNK_ROWS = 2000;

    return await Excel.run(async function (context) {
        const workbook = context.workbook;
        const sheet = opts.sheetName
            ? workbook.worksheets.getItem(opts.sheetName)
            : workbook.worksheets.getActiveWorksheet();

        const usedRange = sheet.getUsedRange();
        usedRange.load(["values", "rowIndex", "columnIndex", "rowCount", "columnCount"]);
        await context.sync();

        const matrix = usedRange.values || [];
        if (matrix.length === 0) {
            return { success: false, processedRows: 0, error: "Sheet has no data." };
        }

        const headers = matrix[0] || [];
        const normalized = columnName.toLowerCase();
        let existingIndex = -1;
        for (let i = 0; i < headers.length; i++) {
            if (String(headers[i] ?? "").trim().toLowerCase() === normalized) {
                existingIndex = i;
                break;
            }
        }

        // If Sentiment already exists, replace that column rather than adding
        // Sentiment_1 / Sentiment_2 on repeated client queries.
        const targetColumnIndex = existingIndex >= 0
            ? usedRange.columnIndex + existingIndex
            : usedRange.columnIndex + headers.length;

        const headerCell = sheet.getRangeByIndexes(usedRange.rowIndex, targetColumnIndex, 1, 1);
        headerCell.values = [[columnName]];
        headerCell.format.font.bold = true;

        const dataRowCount = matrix.length - 1;
        const rowsToWrite = Math.min(dataRowCount, values.length);
        for (let start = 0; start < rowsToWrite; start += CHUNK_ROWS) {
            const end = Math.min(start + CHUNK_ROWS, rowsToWrite);
            const chunk = [];
            for (let i = start; i < end; i++) {
                const v = values[i];
                chunk.push([v === null || v === undefined ? "" : v]);
            }
            const range = sheet.getRangeByIndexes(
                usedRange.rowIndex + 1 + start,
                targetColumnIndex,
                chunk.length,
                1
            );
            range.values = chunk;
            await context.sync();
        }

        // If the source range contains more rows than values, explicitly clear
        // the remainder so an older sentiment result cannot survive a rerun.
        if (rowsToWrite < dataRowCount) {
            const clearRange = sheet.getRangeByIndexes(
                usedRange.rowIndex + 1 + rowsToWrite,
                targetColumnIndex,
                dataRowCount - rowsToWrite,
                1
            );
            clearRange.clear("Contents");
            await context.sync();
        }

        sheet.getUsedRange().format.autofitColumns();
        await context.sync();
        return { success: true, processedRows: rowsToWrite, error: null };
    }).catch(function (err) {
        return { success: false, processedRows: 0, error: err.toString() };
    });
}

window.jsAppendStaticColumn = jsAppendStaticColumn;

// ── Orchestrator Pipeline ───────────────────────────────────────────────────

async function processExcelPipeline(optionsJson) {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") {
        return { success: false, processedRows: 0, error: "Office JS layer unreachable inside compilation environment." };
    }

    let opts;
    try {
        opts = JSON.parse(optionsJson);
    } catch (err) {
        return { success: false, processedRows: 0, error: "Malformed payload parsing configuration block." };
    }

    return await Excel.run(async function (context) {
        const workbook = context.workbook;
        let sourceSheet;
        let activeSheetRef = workbook.worksheets.getActiveWorksheet();
        activeSheetRef.load("name");
        await context.sync();

        let resolvedSourceName = activeSheetRef.name;
        if (opts.sourceSheetName) {
            try {
                sourceSheet = workbook.worksheets.getItem(opts.sourceSheetName);
                resolvedSourceName = opts.sourceSheetName;
            } catch(e) {
                return { success: false, processedRows: 0, error: "Source worksheet field designated missing: " + opts.sourceSheetName };
            }
        } else {
            sourceSheet = activeSheetRef;
        }

        const sourceRange = sourceSheet.getUsedRange();
        sourceRange.load(["values", "formulas", "numberFormat"]);
        await context.sync();

        const matrix = sourceRange.values;
        if (!matrix || matrix.length === 0) {
            return { success: false, processedRows: 0, error: "Zero byte matrix boundaries. Populate cell ranges." };
        }

        const sheetName = opts.targetSheetName ? opts.targetSheetName.substring(0, 31) : "Refactored_Data";
        let runningData = [...matrix];

        if (opts.removeDuplicates) {
            const headerRow = runningData[0];
            const indices = Array.isArray(opts.deduplicateColumns) && opts.deduplicateColumns.length > 0
                ? opts.deduplicateColumns.map(c => headerRow.indexOf(c)).filter(idx => idx !== -1)
                : [];

            const seen = new Set();
            const filteredMatrix = [headerRow];

            for (let i = 1; i < runningData.length; i++) {
                const r = runningData[i];
                let signature = "";
                if (indices.length > 0) {
                    signature = indices.map(idx => String(r[idx])).join("❖");
                } else {
                    signature = r.map(cell => String(cell)).join("❖");
                }
                if (!seen.has(signature)) {
                    seen.add(signature);
                    filteredMatrix.push(r);
                }
            }
            runningData = filteredMatrix;
        }

        if (opts.filter) {
            if (typeof evaluateCondition !== "function") {
                return {
                    success: false,
                    processedRows: 0,
                    error: "Filter engine not loaded — ensure excel_data_processor.js is included before excel_helper.js in index.html."
                };
            }
            const headerRow = runningData[0];
            const fCol = opts.filter.columnName;
            const resolver = typeof resolveFilterColumn === "function"
                ? resolveFilterColumn(headerRow, fCol)
                : { index: headerRow.indexOf(fCol), name: fCol };
            const fIdx = resolver.index;

            // Never silently treat an unresolved filter as a successful no-op.
            // The old implementation simply skipped the filter when indexOf()
            // returned -1, which produced a "Transformation completed" message
            // while writing the unfiltered dataset.
            if (fIdx === -1) {
                return {
                    success: false,
                    processedRows: 0,
                    error: "Could not resolve filter column '" + String(fCol || "") + "' against the current worksheet headers."
                };
            }

            const fType = String(opts.filter.type || "equals");
            const allowedFilterTypes = new Set([
                "equals", "not_equals", "contains",
                "greater_than", "less_than",
                "greater_than_equal", "less_than_equal",
                "between", "top_n", "bottom_n",
                "is_null", "is_empty", "is_not_null", "is_not_empty"
            ]);
            if (!allowedFilterTypes.has(fType)) {
                return {
                    success: false,
                    processedRows: 0,
                    error: "Unsupported filter type '" + fType + "'."
                };
            }

            if (fType === "top_n" || fType === "bottom_n") {
                const n = parseInt(opts.filter.value, 10);
                if (!Number.isFinite(n) || n <= 0) {
                    return { success: false, processedRows: 0, error: "Filter row count must be a positive integer." };
                }
                const dataRows = runningData.slice(1);
                dataRows.sort(function (a, b) {
                    const av = parseFloat(String(a[fIdx]).replace(/[₹$€£,\s]/g, "")) || 0;
                    const bv = parseFloat(String(b[fIdx]).replace(/[₹$€£,\s]/g, "")) || 0;
                    return fType === "top_n" ? bv - av : av - bv;
                });
                runningData = [headerRow, ...dataRows.slice(0, n)];
            } else {
                const filteredMatrix = [headerRow];
                for (let i = 1; i < runningData.length; i++) {
                    const row = runningData[i];
                    if (evaluateCondition(row[fIdx], opts.filter)) {
                        filteredMatrix.push(row);
                    }
                }
                runningData = filteredMatrix;
            }
        }

        if (opts.lookupConfig) {
            const lc = opts.lookupConfig;
            try {
                const refSheet = workbook.worksheets.getItem(lc.referenceSheetName);
                const refRange = refSheet.getUsedRange();
                refRange.load("values");
                await context.sync();

                lc.targetSheetData = JSON.stringify(refRange.values);

                if (typeof evaluateLookupMutation === "function") {
                    runningData = evaluateLookupMutation(runningData, lc);
                }
            } catch (err) {
                return { success: false, processedRows: 0, error: "Lookup extraction failed: " + err.toString() };
            }
        }

        if (opts.generateSummarySheet && typeof calculateAggregations === "function") {
            const mc = opts.metricsConfig || {};
            const summarySheetName = (mc.sheetName || "Metrics_Analysis").substring(0, 31);
            const summaryMatrix = calculateAggregations(runningData, mc.operations, mc.columns);

            if (summaryMatrix && summaryMatrix.length > 0) {
                const currentSheets = workbook.worksheets;
                currentSheets.load("items/name");
                await context.sync();
                for (let i = 0; i < currentSheets.items.length; i++) {
                    if (currentSheets.items[i].name === summarySheetName) {
                        currentSheets.items[i].delete();
                        break;
                    }
                }
                await context.sync();
                const mSheet = workbook.worksheets.add(summarySheetName);
                const mRange = mSheet.getRangeByIndexes(0, 0, summaryMatrix.length, summaryMatrix[0].length);
                mRange.values = summaryMatrix;
                mSheet.getUsedRange().format.autofitColumns();
            }
        }

        // A native PivotTable can consume the original worksheet range directly.
        // Do not create a presentation/staging copy for a pure Pivot request:
        // that copy was the source of the misleading "copied dataset" result.
        // A staging worksheet is still used when a preceding transformation
        // genuinely changes the rows the PivotTable must consume.
        const pivotNeedsStaging = !!opts.pivotConfig && (
            !!opts.removeDuplicates ||
            !!opts.filter ||
            !!opts.lookupConfig
        );
        let targetSheet = null;
        let isTempSheet = false;
        let nativePivotCreated = false;
        let pivotSourceSheetForPivot = sourceSheet;
        if (!opts.pivotConfig || pivotNeedsStaging) {
            try {
            if (opts.targetSheetName === null && opts.pivotConfig) {
                targetSheet = workbook.worksheets.add("Temp_Source_Buffer_" + Math.floor(Math.random() * 1000));
                isTempSheet = true;
            } else {
                targetSheet = workbook.worksheets.add(sheetName);
            }

            // Load targetSheet.name to prevent PropertyNotLoaded errors when reading it later
            targetSheet.load("name");
            await context.sync();

            const finalRange = targetSheet.getRangeByIndexes(0, 0, runningData.length, runningData[0].length);
            finalRange.values = runningData;

            if (opts.freezeHeaderRow) {
                targetSheet.freezePanes.freezeRows(1);
            }
            if (opts.enableAutoFilter) {
                targetSheet.autoFilter.apply(finalRange);
            }
            targetSheet.getUsedRange().format.autofitColumns();
            if (pivotNeedsStaging) {
                pivotSourceSheetForPivot = targetSheet;
            }
            } catch (stagingErr) {
                if (isTempSheet && targetSheet) {
                    try {
                        targetSheet.delete();
                        await context.sync();
                    } catch (cleanupErr) {
                        throw new Error(
                            "Pivot staging failed and temporary worksheet cleanup also failed: " +
                            cleanupErr.toString()
                        );
                    }
                }
                throw stagingErr;
            }
        }

        if (opts.pivotConfig) {
            try {
            const pc = opts.pivotConfig;

            function normalizePivotHeader(value) {
                return String(value ?? "")
                    .normalize("NFKC")
                    .trim()
                    .replace(/\s+/g, " ")
                    .toLowerCase();
            }

            function sanitizeWorksheetName(value) {
                const cleaned = String(value || "")
                    .replace(/[\\/:?*\[\]]/g, "_")
                    .replace(/^'+|'+$/g, "")
                    .trim();
                return (cleaned || "Pivot_Output").substring(0, 31);
            }

            function makeUniqueWorksheetName(requestedName, existingNames) {
                const base = sanitizeWorksheetName(requestedName);
                const taken = new Set(existingNames.map(n => String(n).toLowerCase()));
                if (!taken.has(base.toLowerCase())) return base;
                for (let suffix = 2; suffix < 10000; suffix++) {
                    const suffixText = "_" + suffix;
                    const candidate = base.substring(0, Math.max(1, 31 - suffixText.length)) + suffixText;
                    if (!taken.has(candidate.toLowerCase())) return candidate;
                }
                throw new Error("Could not generate a unique PivotTable worksheet name for '" + base + "'.");
            }

            function sanitizePivotTableName(value) {
                const cleaned = String(value || "")
                    .replace(/[^A-Za-z0-9_]/g, "_")
                    .replace(/^\d+/, "_")
                    .trim();
                return (cleaned || "Pivot_InsightFlow").substring(0, 255);
            }

            function makeUniquePivotTableName(requestedName, existingNames) {
                const base = sanitizePivotTableName(requestedName);
                const taken = new Set(existingNames.map(n => String(n).toLowerCase()));
                if (!taken.has(base.toLowerCase())) return base;
                for (let suffix = 2; suffix < 10000; suffix++) {
                    const suffixText = "_" + suffix;
                    const candidate = base.substring(0, Math.max(1, 255 - suffixText.length)) + suffixText;
                    if (!taken.has(candidate.toLowerCase())) return candidate;
                }
                throw new Error("Could not generate a unique PivotTable name for '" + base + "'.");
            }

            const sourceHeaders = Array.isArray(runningData[0]) ? runningData[0].map(v => String(v ?? "")) : [];
            const headerMatches = new Map();
            sourceHeaders.forEach((header, index) => {
                const key = normalizePivotHeader(header);
                if (!headerMatches.has(key)) headerMatches.set(key, []);
                headerMatches.get(key).push({ header, index });
            });

            function resolvePivotField(requested, axis) {
                const wanted = String(requested ?? "");
                const key = normalizePivotHeader(wanted);
                const matches = headerMatches.get(key) || [];
                if (matches.length === 1) return matches[0].header;
                if (matches.length > 1) {
                    throw new Error(
                        "Ambiguous PivotTable " + axis + " field '" + wanted +
                        "'; it matches multiple source headers: " +
                        matches.map(m => "'" + m.header + "'").join(", ") + "."
                    );
                }
                throw new Error(
                    "Could not resolve PivotTable " + axis + " field '" + wanted +
                    "' against the source worksheet headers. Available headers: " +
                    sourceHeaders.map(h => "'" + h + "'").join(", ") + "."
                );
            }

            const requestedRowFields = Array.isArray(pc.rowFields)
                ? pc.rowFields
                : (pc.rowField ? [pc.rowField] : []);
            const requestedColumnFields = Array.isArray(pc.columnFields)
                ? pc.columnFields
                : (pc.columnField ? [pc.columnField] : []);
            const requestedFilterFields = Array.isArray(pc.filterFields)
                ? pc.filterFields
                : (pc.filterField ? [pc.filterField] : []);
            const requestedValueFields = Array.isArray(pc.valueFields) && pc.valueFields.length
                ? pc.valueFields
                : (pc.valueField ? [{ field: pc.valueField, op: pc.valueOperation || "sum" }] : []);

            if (requestedRowFields.length === 0) {
                throw new Error("PivotTable creation requires at least one row field.");
            }
            if (requestedValueFields.length === 0) {
                throw new Error("PivotTable creation requires at least one value field.");
            }

            const resolvedRowFields = requestedRowFields.map(field => resolvePivotField(field, "row"));
            const resolvedColumnFields = requestedColumnFields.map(field => resolvePivotField(field, "column"));
            const resolvedFilterFields = requestedFilterFields.map(field => resolvePivotField(field, "filter"));

            const supportedPivotAggregations = new Set([
                "sum", "average", "count", "counta", "max", "min", "product", "stdev"
            ]);
            const resolvedValueFields = requestedValueFields.map((vf) => {
                const field = vf && vf.field;
                if (!field || !String(field).trim()) {
                    throw new Error("PivotTable value field is missing its field name.");
                }
                const op = String((vf && vf.op) || "sum").trim().toLowerCase();
                if (!supportedPivotAggregations.has(op)) {
                    throw new Error(
                        "Unsupported PivotTable aggregation '" + op +
                        "'. Supported aggregations: " +
                        Array.from(supportedPivotAggregations).join(", ") + "."
                    );
                }
                return { field: resolvePivotField(field, "value"), op };
            });

            // Exactly 20 empty rows between consecutive PivotTables on the
            // same worksheet — see PIVOT_GAP_ROWS usage below. Vertical
            // stacking only; side-by-side/column placement was removed here
            // (previously computed a nextFreeColumnIndex instead).
            const PIVOT_GAP_ROWS = 20;

            const currentSheets = workbook.worksheets;
            currentSheets.load("items/name");
            await context.sync();

            const requestedPivotSheetName = sanitizeWorksheetName(
                pc.sheetName || ("Pivot_" + (sheetName || "Data"))
            );
            let pivotSheetName = requestedPivotSheetName;
            let pivotSheet = currentSheets.items.find(s => s.name.toLowerCase() === pivotSheetName.toLowerCase());
            const sheetAlreadyExisted = !!pivotSheet;
            if (pc.reuseExisting === true && pivotSheet) {
                const existingPivots = pivotSheet.pivotTables;
                existingPivots.load("items/name");
                await context.sync();
                if (!existingPivots.items || existingPivots.items.length === 0) {
                    throw new Error("The existing PivotTable worksheet was found, but no PivotTable could be verified for a safe chart retry.");
                }
                const requestedTableName = String(pc.tableName || "").trim();
                let existingPivot = existingPivots.items[0];
                if (requestedTableName) {
                    const named = existingPivots.items.find(p => p.name === requestedTableName);
                    if (named) existingPivot = named;
                }
                const existingRange = existingPivot.layout.getRange();
                existingRange.load(["address", "rowCount", "columnCount", "rowIndex", "columnIndex"]);
                await context.sync();
                if (!existingRange.address || existingRange.rowCount < 2 || existingRange.columnCount < 2) {
                    throw new Error("The existing PivotTable could not be verified as populated.");
                }
                const existingChartStartColumn = existingRange.columnIndex + existingRange.columnCount + 1;
                function existingExcelColumnName(index) {
                    let n = index + 1, out = "";
                    while (n > 0) {
                        const rem = (n - 1) % 26;
                        out = String.fromCharCode(65 + rem) + out;
                        n = Math.floor((n - 1) / 26);
                    }
                    return out;
                }
                const existingStartColumn = existingExcelColumnName(existingChartStartColumn);
                const existingStartRow = existingRange.rowIndex + 1;
                const existingEndColumn = existingExcelColumnName(existingChartStartColumn + 8);
                pivotSheet.activate();
                await context.sync();
                return {
                    success: true,
                    processedRows: 0,
                    error: null,
                    pivotPlacement: JSON.stringify({
                        mode: "reused_existing_sheet",
                        sheet: pivotSheetName,
                        startingRow: existingStartRow,
                        gapRows: PIVOT_GAP_ROWS,
                        pivotCount: existingPivots.items.length,
                        sheetAlreadyExisted: true,
                        pivotRangeAddress: existingRange.address,
                        pivotRowCount: existingRange.rowCount,
                        pivotColumnCount: existingRange.columnCount,
                        chartStartCell: existingStartColumn + existingStartRow,
                        chartEndCell: existingEndColumn + (existingStartRow + 19),
                    }),
                };
            }
            let destinationCell = "A1";
            let placementMode = "new_sheet";
            let startingRow = 1;

            if (!pc.appendMode || !pivotSheet) {
                if (pivotSheet && pc.reuseExisting !== true) {
                    pivotSheetName = makeUniqueWorksheetName(
                        requestedPivotSheetName,
                        currentSheets.items.map(s => s.name)
                    );
                    pivotSheet = null;
                }
                if (!pivotSheet) {
                    pivotSheet = workbook.worksheets.add(pivotSheetName);
                    placementMode = "new_sheet";
                    startingRow = 1;
                }
            } else {
                placementMode = "append_existing_sheet";
                const usedRange = pivotSheet.getUsedRange(true);
                await context.sync();
                if (usedRange && !usedRange.isNullObject) {
                    usedRange.load(["rowCount", "rowIndex"]);
                    await context.sync();
                    // 0-indexed row where the new table starts: right after
                    // the existing content plus exactly PIVOT_GAP_ROWS blank
                    // rows (e.g. content ends at 0-indexed row 122 (123
                    // rows) -> next table starts at 0-indexed row 142 ->
                    // 1-indexed row 143, leaving rows 124-143 (20 rows)
                    // empty in between).
                    const nextFreeRowIndex = usedRange.rowIndex + usedRange.rowCount + PIVOT_GAP_ROWS;
                    destinationCell = "A" + (nextFreeRowIndex + 1);
                    startingRow = nextFreeRowIndex + 1;
                }
            }

            console.log("PIVOT STEP 1: About to get sourceSheet", pivotNeedsStaging ? targetSheet.name : resolvedSourceName);
            const pivotSourceSheet = pivotSourceSheetForPivot;
            console.log("PIVOT STEP 2: Got sourceSheet");
            
            console.log("PIVOT STEP 3: About to get sourceRange");
            const pivotSourceRange = pivotSourceSheet.getUsedRange();
            console.log("PIVOT STEP 4: Got sourceRange");
            
            pivotSourceRange.load(["rowCount", "columnCount"]);
            console.log("PIVOT STEP 5: Queued sourceRange.load()");
            
            await context.sync();
            console.log("PIVOT STEP 6: Synced after sourceRange load", {
                rowCount: pivotSourceRange.rowCount,
                columnCount: pivotSourceRange.columnCount,
            });

            console.log("PIVOT STEP 7: About to get destinationRange at", destinationCell);
            const destinationRange = pivotSheet.getRange(destinationCell);
            console.log("PIVOT STEP 8: Got destinationRange");
            
            console.log("PIVOT STEP 9: About to call pivotTables.add()");
            const pivotTable = pivotSheet.pivotTables.add(
                pc.tableName || "AI_Generated_PivotTable",
                pivotSourceRange,
                destinationRange
            );
            nativePivotCreated = true;
            console.log("PIVOT STEP 10: Created PivotTable", pc.tableName);

            // ── PivotLayout parity with a MANUALLY-inserted PivotTable ──────
            // Verified against the official Excel JS API reference
            // (Excel.PivotLayout class) and Microsoft's own PivotTable
            // layout documentation before writing this:
            //
            //   - "Compact form is... therefore specified as the default
            //     layout form for PivotTables" AND "Expand and Collapse
            //     buttons are displayed so that you can display or hide
            //     details in COMPACT form" (Microsoft Support: "Design the
            //     layout and format of a PivotTable"). Tabular form does
            //     NOT show +/- buttons at all — this is normal Excel
            //     behavior, not a bug, whenever layoutType ends up Tabular.
            //   - Before this change, `pivotTable.layout` was NEVER read or
            //     set anywhere in this function — the table was left on
            //     whatever layoutType/subtotal/header defaults the Excel
            //     JS API happens to apply internally, which is not
            //     guaranteed to match what a user gets from the ribbon's
            //     Insert > PivotTable. Setting these explicitly removes
            //     that ambiguity entirely rather than relying on an
            //     unverified implicit default.
            //   - subtotalLocation is set to atTop because Excel's
            //     documented Compact-form default shows subtotals "at the
            //     top of every group" — those group/subtotal header rows
            //     are exactly the rows the +/- buttons attach to; a
            //     PivotTable with subtotals off still shows +/- buttons on
            //     genuinely multi-level hierarchies, but matching the
            //     manual default here removes it as a variable entirely.
            //
            // NOTE on properties the task asked to verify that are NOT set
            // here: `showExpandCollapseButtons`, `enableDrilldown`,
            // `showRowHeaders`, `showColumnHeaders` are not members of
            // Excel.PivotTable or Excel.PivotLayout in the JavaScript API
            // (confirmed against the official class reference) —
            // `enableDrilldown` exists ONLY in the legacy VBA/COM object
            // model (Excel.PivotTable.EnableDrilldown), and
            // `showExpandCollapseButtons`-equivalent scripting exists only
            // for PivotCHARTS in VBA (Chart.ShowExpandCollapseEntireFieldButtons),
            // not PivotTables, and not in Office.js at all. Setting them
            // here would either throw at context.sync() or silently no-op;
            // neither is an honest fix, so they're intentionally omitted.
            pivotTable.layout.layoutType = Excel.PivotLayoutType.compact;
            pivotTable.layout.subtotalLocation = Excel.SubtotalLocationType.atTop;
            pivotTable.layout.showFieldHeaders = true;
            pivotTable.layout.showRowGrandTotals = true;
            pivotTable.layout.showColumnGrandTotals = true;
            pivotTable.layout.preserveFormatting = true;
            pivotTable.layout.autoFormat = true;

            console.log("PIVOT STEP 11: About to get hierarchies collection");
            const hierarchies = pivotTable.hierarchies;
            console.log("PIVOT STEP 12: Got hierarchies collection");
            
            hierarchies.load("items/name");
            console.log("PIVOT STEP 13: Queued hierarchies.load()");
            
            await context.sync();
            console.log("PIVOT STEP 14: Synced after hierarchies load", {
                hierarchyCount: hierarchies.items.length,
                hierarchyNames: hierarchies.items.map(h => h.name),
            });

            console.log("PIVOT STEP 15: Building hierMap from", hierarchies.items.length, "hierarchies");
            const hierMap = {};
            for (const h of hierarchies.items) {
                hierMap[h.name.trim().toLowerCase()] = h;
            }
            console.log("PIVOT STEP 16: Built hierMap with keys:", Object.keys(hierMap));

            // Hierarchy names already assigned to ANY axis (row/column/
            // value) during this call — checked by the fuzzy fallback
            // below so that two distinct requested field names (e.g.
            // "Region" and "Region Name") can never both resolve to the
            // SAME underlying hierarchy. Before this fix, that collision
            // was possible: `pivotTable.rowHierarchies.add(rHier)` would
            // effectively be called twice for what Excel treats as one
            // hierarchy, silently collapsing a requested MULTI-level row
            // hierarchy down to a single level — and a single-level row
            // field has nothing to expand/collapse, so Excel correctly
            // shows no +/- buttons for it. This is the most likely
            // code-level (as opposed to Excel-UI-level) cause of "missing"
            // +/- buttons when multiple row fields were actually requested.
            const usedHierarchyNames = new Set();

            function findHier(fieldName) {
                if (!fieldName) return null;
                const key = String(fieldName).trim().toLowerCase();
                if (hierMap[key] && !usedHierarchyNames.has(hierMap[key].name)) {
                    return hierMap[key];
                }
                const normalizedKey = key.replace(/[^a-z0-9]+/g, "");
                const normalizedMatches = Object.entries(hierMap)
                    .filter(([k, v]) =>
                        !usedHierarchyNames.has(v.name) &&
                        k.replace(/[^a-z0-9]+/g, "") === normalizedKey
                    )
                    .map(([, v]) => v);
                return normalizedMatches.length === 1 ? normalizedMatches[0] : null;
            }

            // A value hierarchy may legally reuse a source hierarchy that is
            // already present on the row/column/filter axis (for example,
            // MAX(marked_price) while also grouping by marked_price).
            // Axis hierarchies must remain unique, but data hierarchies do not.
            function findValueHier(fieldName) {
                if (!fieldName) return null;
                const key = String(fieldName).trim().toLowerCase();
                if (hierMap[key]) return hierMap[key];
                const normalizedKey = key.replace(/[^a-z0-9]+/g, "");
                const normalizedMatches = Object.entries(hierMap)
                    .filter(([k]) => k.replace(/[^a-z0-9]+/g, "") === normalizedKey)
                    .map(([, v]) => v);
                return normalizedMatches.length === 1 ? normalizedMatches[0] : null;
            }

            console.log("PIVOT STEP 17: Processing rowFields", pc.rowFields);
            const rowFields = resolvedRowFields;
            console.log("PIVOT STEP 18: Normalized rowFields to array:", rowFields);
            
            let appliedRows = 0;
            for (const rf of rowFields) {
                const rHier = findHier(rf);
                console.log("PIVOT STEP 18a: Found hierarchy for rowField", { field: rf, foundHierarchyName: rHier ? rHier.name : "NOT FOUND" });
                
                if (rHier) {
                    console.log("PIVOT STEP 18b: Queuing rowHierarchies.add() for", rf);
                    pivotTable.rowHierarchies.add(rHier);
                    usedHierarchyNames.add(rHier.name);
                    appliedRows++;
                } else {
                    throw new Error("Could not resolve PivotTable row field '" + String(rf) + "' against the source worksheet headers.");
                }
            }
            if (appliedRows === 0) {
                throw new Error("PivotTable creation requires at least one valid row field.");
            }
            console.log("PIVOT STEP 19: Finished row hierarchies, appliedRows:", appliedRows);

            console.log("PIVOT STEP 20: Processing columnFields", pc.columnFields);
            const columnFields = resolvedColumnFields;
            console.log("PIVOT STEP 21: Normalized columnFields to array:", columnFields);
            
            for (const cf of columnFields) {
                const cHier = findHier(cf);
                console.log("PIVOT STEP 21a: Found hierarchy for columnField", { field: cf, foundHierarchyName: cHier ? cHier.name : "NOT FOUND" });
                
                if (cHier) {
                    console.log("PIVOT STEP 21b: Queuing columnHierarchies.add() for", cf);
                    pivotTable.columnHierarchies.add(cHier);
                    usedHierarchyNames.add(cHier.name);
                } else {
                    throw new Error("Could not resolve PivotTable column field '" + String(cf) + "' against the source worksheet headers.");
                }
            }
            console.log("PIVOT STEP 22: Finished column hierarchies");

            function opToAggFunction(opStr) {
                const op = (opStr || "sum").toLowerCase();
                if (op === "count" || op === "counta")  return Excel.AggregationFunction.count;
                if (op === "average")                    return Excel.AggregationFunction.average;
                if (op === "max")                        return Excel.AggregationFunction.max;
                if (op === "min")                        return Excel.AggregationFunction.min;
                if (op === "product")                    return Excel.AggregationFunction.product;
                if (op === "stdev")                      return Excel.AggregationFunction.standardDeviation;
                throw new Error("Unsupported PivotTable aggregation '" + op + "'.");
            }

            function isNumericPivotValue(value) {
                if (typeof value === "number") return Number.isFinite(value);
                if (value === null || value === undefined || String(value).trim() === "") return false;
                const cleaned = String(value).replace(/[₹$€£,\s]/g, "");
                return cleaned !== "" && Number.isFinite(Number(cleaned));
            }

            function validateMaxField(fieldName) {
                const headerRow = Array.isArray(runningData[0]) ? runningData[0] : [];
                const normalized = String(fieldName || "").trim().toLowerCase().replace(/[^a-z0-9]+/g, "");
                const index = headerRow.findIndex(h =>
                    String(h ?? "").trim().toLowerCase().replace(/[^a-z0-9]+/g, "") === normalized
                );
                if (index < 0) {
                    throw new Error("Could not validate PivotTable MAX value field '" + String(fieldName) + "' against the source worksheet headers.");
                }
                const numericCount = runningData.slice(1).reduce((count, row) =>
                    count + (Array.isArray(row) && isNumericPivotValue(row[index]) ? 1 : 0), 0
                );
                if (numericCount === 0) {
                    throw new Error("PivotTable MAX requires a numeric value field; '" + String(fieldName) + "' contains no numeric values.");
                }
            }

            console.log("PIVOT STEP 23: Processing value fields");
            let lastAddedDataHier = null;
            for (const vf of resolvedValueFields) {
                    console.log("PIVOT STEP 23a: Resolved valueField", { field: vf.field, op: vf.op });
                    const valHier = findValueHier(vf.field);
                    console.log("PIVOT STEP 23c: Found hierarchy for valueField", { field: vf.field, foundHierarchyName: valHier ? valHier.name : "NOT FOUND", op: vf.op });
                    
                    if (valHier) {
                        const valueOp = vf.op;
                        if (valueOp === "max") validateMaxField(vf.field);
                        console.log("PIVOT STEP 23d: Queuing dataHierarchies.add() for", vf.field);
                        const dataHierarchy = pivotTable.dataHierarchies.add(valHier);
                        dataHierarchy.summarizeBy = opToAggFunction(valueOp);
                        lastAddedDataHier = dataHierarchy;
                    } else {
                        throw new Error("Could not resolve PivotTable value field '" + String(vf.field) + "' against the source worksheet headers.");
                    }
            }
            if (!lastAddedDataHier) {
                throw new Error("PivotTable creation requires at least one valid value field.");
            }
            console.log("PIVOT STEP 24: Finished value hierarchies");

            const filterFields = resolvedFilterFields;
            console.log("PIVOT STEP 24f: Processing filterFields", filterFields);
            for (const ff of filterFields) {
                const fHier = findHier(ff);
                if (fHier) {
                    pivotTable.filterHierarchies.add(fHier);
                    usedHierarchyNames.add(fHier.name);
                } else {
                    throw new Error("Could not resolve PivotTable filter field '" + String(ff) + "' against the source worksheet headers.");
                }
            }

            // Combined query support: ranked requests are applied to the
            // real PivotTable field so the PivotTable itself contains the
            // requested top-N set.
            const pivotSortByValue = String(pc.sortByValue || "").toLowerCase();
            const pivotLimit = Number.isFinite(Number(pc.limit))
                ? Math.max(0, Math.floor(Number(pc.limit)))
                : null;
            let pivotFieldForRanking = null;
            if (pivotSortByValue || (pivotLimit != null && pivotLimit > 0)) {
                if (!lastAddedDataHier) {
                    throw new Error("PivotTable ranking requires a configured value hierarchy.");
                }
                const requestedDirection =
                    pivotSortByValue === "asc" || pivotSortByValue === "ascending"
                        ? "Ascending"
                        : "Descending";
                const rankingHierarchy = pivotTable.hierarchies.getItem(rowFields[0]);
                pivotFieldForRanking = rankingHierarchy.fields.getItem(rowFields[0]);
                if (typeof pivotFieldForRanking.sortByValues !== "function") {
                    throw new Error("This Excel runtime does not support PivotTable value sorting (ExcelApi 1.9+ is required for ranked PivotTable requests).");
                }
                pivotFieldForRanking.sortByValues(requestedDirection, lastAddedDataHier);
                await context.sync();
                console.log("PIVOT STEP 24a: Applied value sort", requestedDirection);

                if (pivotLimit != null && pivotLimit > 0) {
                    if (!pivotFieldForRanking.items || typeof pivotFieldForRanking.items.load !== "function") {
                        throw new Error("This Excel runtime does not expose PivotTable items required for a top-N filter.");
                    }
                    pivotFieldForRanking.items.load("items/name");
                    await context.sync();
                    const rankedItems = Array.isArray(pivotFieldForRanking.items.items)
                        ? pivotFieldForRanking.items.items
                        : [];
                    rankedItems.forEach((item, index) => {
                        item.visible = index < pivotLimit;
                    });
                    await context.sync();
                    console.log("PIVOT STEP 24c: Applied top-N item visibility", {
                        limit: pivotLimit,
                        itemCount: rankedItems.length,
                    });
                }
            }

            if (pc.hideGrandTotals === true) {
                pivotTable.layout.showRowGrandTotals = false;
                pivotTable.layout.showColumnGrandTotals = false;
                await context.sync();
                console.log("PIVOT STEP 24d: Disabled grand totals for chart-safe PivotTable output");
            }

            // ── Cleanup ordering (fixes the deferred "InvalidArgument" that
            // surfaced on the NEXT worksheet switch after pivot creation) ──
            //
            // Root cause: `targetSheet` ("Temp_Source_Buffer_<random>",
            // created above) is never explicitly deactivated, and nothing
            // else was ever made active since it was added — by Excel's own
            // default behavior, a newly-added worksheet becomes the active
            // sheet immediately. That means `targetSheet` was STILL the
            // active worksheet at the moment it used to be deleted here,
            // one line before `pivotSheet.activate()` even ran (and that
            // activate call was in a LATER, separate sync batch besides).
            // Deleting the currently-active sheet, then only reassigning
            // the active sheet in a subsequent batch, leaves Excel to
            // internally auto-fall-back to *some* sheet in between — and
            // that transitional state, combined with the PivotTable's row/
            // column/data hierarchies (added just above) not yet having
            // gone through a dedicated sync of their own, meant the
            // PivotTable's cache/field structure wasn't fully settled
            // before a worksheet got deleted in the very same transaction.
            // Excel doesn't always surface that immediately — it can defer
            // resolving the affected internal object graph until the next
            // full recalculation, which is exactly what activating a
            // DIFFERENT worksheet forces. Hence: works right after
            // creation, throws InvalidArgument only once the user switches
            // sheets afterward.
            //
            // Fix, in the exact order required (per the task's point 13 —
            // remove the temp sheet only after the PivotTable is fully
            // committed AND detached from it):
            //   1. Queue pivotSheet.activate() alongside the already-queued
            //      hierarchy adds, then ONE sync commits both together —
            //      every hierarchy add() above (rows/columns/data) is fully
            //      settled AND Excel's active-sheet pointer has moved OFF
            //      targetSheet, atomically, before targetSheet is touched
            //      again. (An earlier version of this fix used two separate
            //      syncs for this; merged into one below — see the note
            //      just above the code for why that reduction matters.)
            //   2. Only now, in its own final isolated batch, delete
            //      targetSheet and sync. By this point nothing — not the
            //      active-sheet pointer, not the PivotTable's hierarchies —
            //      still depends on it in an unsettled way.
            // targetSheet is not referenced again anywhere after this
            // point (verified: no `targetSheet.*` call exists below this
            // block in this function).
            // Queued together and committed in ONE round trip: this is
            // safe because activating a DIFFERENT, non-deleted sheet has no
            // dependency ordering versus the hierarchy adds above — both
            // simply need to be committed before targetSheet is deleted.
            // Merging them (rather than two separate sync round trips, as
            // an earlier version of this fix did) matters beyond
            // efficiency: Excel's native UI is NEVER blocked by this add-in
            // while Excel.run() is executing — nothing in this codebase
            // (searched project-wide) can prevent the user from manually
            // clicking a different worksheet tab while this batch is still
            // in flight, and the Flutter `pipelineProcessing` flag that
            // exists for this screen is set but never actually read by any
            // widget, so it doesn't even disable a button in the task
            // pane. A manual worksheet switch colliding with a still-
            // pending Excel.run() batch is a separate, genuine way to
            // reproduce the same InvalidArgument error class as the
            // ordering bug fixed below — fewer sequential sync round trips
            // means a smaller window for that collision to land in.
            
            console.log("PIVOT STEP 25: About to activate pivotSheet", pivotSheetName);
            try {
                pivotSheet.activate();
                console.log("PIVOT STEP 26: Queued pivotSheet.activate()");
            } catch (e) {
                console.error("PIVOT STEP 26 ERROR: pivotSheet.activate() threw", e.toString());
                throw e;
            }
            
            console.log("PIVOT STEP 27: About to sync after pivotSheet.activate()");
            try {
                await context.sync();
                console.log("PIVOT STEP 28: Successfully synced after activate");
            } catch (e) {
                console.error("PIVOT STEP 28 ERROR: context.sync() after activate threw", e.toString());
                throw e;
            }

            // Temporary staging cleanup is performed exactly once in the finally block below.
            // The original source sheet and any user/output worksheet are never deleted here.

            // Capture the actual PivotTable range after ranking/filter
            // operations have settled. The existing native chart bridge uses
            // this range directly, avoiding a second aggregation.
            const pivotOutputRange = pivotTable.layout.getRange();
            pivotOutputRange.load(["address", "rowCount", "columnCount", "rowIndex", "columnIndex", "values"]);
            await context.sync();
            if (!pivotOutputRange.address || pivotOutputRange.rowCount < 2 || pivotOutputRange.columnCount < 2) {
                throw new Error("PivotTable was created but did not expose a populated two-column output range.");
            }
            if (pivotLimit != null && pivotLimit > 0) {
                const pivotRows = Array.isArray(pivotOutputRange.values)
                    ? pivotOutputRange.values.slice(1).filter(row =>
                        Array.isArray(row) &&
                        row.some(v => v !== null && v !== undefined && String(v).trim() !== ""))
                    : [];
                if (pivotRows.length > pivotLimit) {
                    throw new Error("PivotTable top-N verification failed: the populated PivotTable output contains " + pivotRows.length + " item rows for a requested limit of " + pivotLimit + ".");
                }
            }
            const pivotStartColumn = pivotOutputRange.columnIndex + pivotOutputRange.columnCount + 1;
            function excelColumnName(index) {
                let n = index + 1, out = "";
                while (n > 0) {
                    const rem = (n - 1) % 26;
                    out = String.fromCharCode(65 + rem) + out;
                    n = Math.floor((n - 1) / 26);
                }
                return out;
            }
            const chartStartColumn = excelColumnName(pivotStartColumn);
            const chartStartRow = pivotOutputRange.rowIndex + 1;
            const chartEndColumn = excelColumnName(pivotStartColumn + 8);
            const chartEndRow = chartStartRow + 19;

            // Count PivotTables now on the sheet (including the one just
            // added) so Flutter/backend callers can report an accurate
            // pivotCount without a separate round trip.
            console.log("PIVOT STEP 33: About to load pivotTables on", pivotSheetName);
            const pivotTablesOnSheet = pivotSheet.pivotTables;
            console.log("PIVOT STEP 34: Got pivotTables collection");
            
            try {
                pivotTablesOnSheet.load("items/name");
                pivotTable.rowHierarchies.load("items/name");
                pivotTable.columnHierarchies.load("items/name");
                pivotTable.filterHierarchies.load("items/name");
                pivotTable.dataHierarchies.load("items/name");
                pivotTable.layout.getRange().load(["address", "rowCount", "columnCount", "rowIndex", "columnIndex"]);
                console.log("PIVOT STEP 35: Queued native PivotTable verification");
            } catch (e) {
                console.error("PIVOT STEP 35 ERROR: native PivotTable verification threw", e.toString());
                throw e;
            }

            console.log("PIVOT STEP 36: About to sync for native PivotTable verification");
            try {
                await context.sync();
                console.log("PIVOT STEP 37: Native PivotTable verification sync succeeded", {
                    count: pivotTablesOnSheet.items.length,
                    rows: pivotTable.rowHierarchies.items.map(h => h.name),
                    columns: pivotTable.columnHierarchies.items.map(h => h.name),
                    filters: pivotTable.filterHierarchies.items.map(h => h.name),
                    values: pivotTable.dataHierarchies.items.map(h => h.name),
                });
            } catch (e) {
                console.error("PIVOT STEP 37 ERROR: context.sync() after native PivotTable verification threw", e.toString());
                throw e;
            }

            const expectedRows = resolvedRowFields.map(String);
            const expectedColumns = resolvedColumnFields.map(String);
            const expectedFilters = resolvedFilterFields.map(String);
            const normalizeField = value => String(value ?? "").trim().toLowerCase().replace(/[^a-z0-9]+/g, "");
            const axisMatches = (actual, expected) => {
                if (actual.length !== expected.length) return false;
                return expected.every((wanted, index) => normalizeField(actual[index]) === normalizeField(wanted));
            };
            const actualRows = pivotTable.rowHierarchies.items.map(h => String(h.name));
            const actualColumns = pivotTable.columnHierarchies.items.map(h => String(h.name));
            const actualFilters = pivotTable.filterHierarchies.items.map(h => String(h.name));
            const actualValues = pivotTable.dataHierarchies.items.map(h => String(h.name));
            if (!axisMatches(actualRows, expectedRows)) {
                throw new Error("Native PivotTable verification failed: row hierarchies do not match the requested fields.");
            }
            if (!axisMatches(actualColumns, expectedColumns)) {
                throw new Error("Native PivotTable verification failed: column hierarchies do not match the requested fields.");
            }
            if (!axisMatches(actualFilters, expectedFilters)) {
                throw new Error("Native PivotTable verification failed: filter hierarchies do not match the requested fields.");
            }
            const expectedValues = resolvedValueFields.map(v => String(v.field || ""));
            const valueNamesMatch = actualValues.length === expectedValues.length &&
                expectedValues.every((wanted, index) => {
                    const actual = normalizeField(actualValues[index]);
                    const expected = normalizeField(wanted);
                    return actual === expected || actual.endsWith(expected) || expected.endsWith(actual);
                });
            if (!valueNamesMatch) {
                throw new Error("Native PivotTable verification failed: data hierarchies do not match the requested value fields.");
            }

            console.log("PIVOT STEP 38: Building success response");
            return {
                success: true,
                processedRows: runningData.length,
                error: null,
                // Stringified (not a nested object) so the Dart side can
                // jsonDecode it the same way it already decodes every other
                // JSON payload in this file, rather than introducing a
                // separate JS-object-to-Dart conversion path.
                pivotPlacement: JSON.stringify({
                    mode: placementMode,
                    sheet: pivotSheetName,
                    startingRow: startingRow,
                    gapRows: PIVOT_GAP_ROWS,
                    pivotCount: pivotTablesOnSheet.items.length,
                    sheetAlreadyExisted: sheetAlreadyExisted,
                    pivotRangeAddress: pivotOutputRange.address,
                    pivotRowCount: pivotOutputRange.rowCount,
                    pivotColumnCount: pivotOutputRange.columnCount,
                    nativePivotVerified: true,
                    chartStartCell: chartStartColumn + chartStartRow,
                    chartEndCell: chartEndColumn + chartEndRow,
                }),
            };
        } finally {
            // Only clean up a staging sheet created by this invocation. Once
            // a native PivotTable exists, its PivotCache may depend on that
            // staging source, so retaining it avoids invalidating the editable
            // PivotTable. If staging failed before Pivot creation, cleanup is
            // safe and any cleanup failure is surfaced to the caller.
            if (isTempSheet && targetSheet && !nativePivotCreated) {
                const stagingName = targetSheet.name;
                console.log("FINALLY: Deleting temporary staging worksheet", stagingName);
                targetSheet.delete();
                try {
                    await context.sync();
                    console.log("FINALLY: Successfully deleted temporary staging worksheet", stagingName);
                } catch (cleanupErr) {
                    throw new Error(
                        "Failed to delete temporary staging worksheet '" +
                        stagingName + "': " + cleanupErr.toString()
                    );
                }
            }
        }
        }

        if (targetSheet) {
            await context.sync();
            targetSheet.activate();
            await context.sync();
        }
        return { success: true, processedRows: runningData.length, error: null };

    }).catch(function (err) {
        return { success: false, processedRows: 0, error: err.toString() };
    });
}

/**
 * Fast, generic filter-only query executor.
 *
 * Keeps all workbook data inside Office.js. The caller sends only the filter
 * instructions (including the user-supplied entity value), never workbook
 * rows. All filter steps are combined in one in-memory JS pass and the final
 * result is written to one new worksheet with batched range writes.
 */
async function jsExecuteLocalFilterQuery(optionsJson) {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") {
        return { success: false, processedRows: 0, error: "Excel context unallocated" };
    }

    let opts;
    try { opts = JSON.parse(optionsJson); }
    catch (err) { return { success: false, processedRows: 0, error: "Invalid filter options: " + err.toString() }; }

    const steps = Array.isArray(opts.steps) ? opts.steps : [];
    if (!steps.length) return { success: false, processedRows: 0, error: "No filter steps supplied." };

    const normalize = (v) => String(v ?? "")
        .normalize("NFKC").toLowerCase()
        // Apostrophes are punctuation, not semantic content for entity names.
        // This makes Domino's / Domino’s / Dominos resolve consistently.
        .replace(/[\u0027\u0060\u00B4\u2018\u2019\u201B]/g, "")
        .replace(/[^a-z0-9]+/g, " ").trim().replace(/\s+/g, " ");

    const asBool = (v) => {
        const s = normalize(v);
        if (["yes", "true", "1"].includes(s)) return true;
        if (["no", "false", "0"].includes(s)) return false;
        return null;
    };
    const asNum = (v) => {
        if (typeof v === "number" && Number.isFinite(v)) return v;
        const s = String(v ?? "").replace(/[₹$€£,\s]/g, "");
        const n = Number(s);
        return Number.isFinite(n) ? n : null;
    };

    const evaluate = (cell, operator, raw, raw2) => {
        const op = String(operator || "equals").trim().toLowerCase();
        const cellText = normalize(cell);
        const targetText = normalize(raw);
        const aBool = asBool(cell), bBool = asBool(raw);
        if ((op === "equals" || op === "not_equals") && aBool !== null && bBool !== null) {
            return op === "equals" ? aBool === bBool : aBool !== bBool;
        }
        const aNum = asNum(cell), bNum = asNum(raw);
        if (op === "equals" && aNum !== null && bNum !== null) return aNum === bNum;
        if (op === "not_equals" && aNum !== null && bNum !== null) return aNum !== bNum;
        if (op === "contains") return cellText.includes(targetText);
        if (op === "greater_than") return aNum !== null && bNum !== null && aNum > bNum;
        if (op === "less_than") return aNum !== null && bNum !== null && aNum < bNum;
        if (op === "greater_than_equal") return aNum !== null && bNum !== null && aNum >= bNum;
        if (op === "less_than_equal") return aNum !== null && bNum !== null && aNum <= bNum;
        if (op === "between") {
            const b2 = asNum(raw2);
            return aNum !== null && bNum !== null && b2 !== null && aNum >= bNum && aNum <= b2;
        }
        return op === "equals" ? cellText === targetText : false;
    };

    return await Excel.run(async function(context) {
        let sourceRange;
        if (opts.useActiveSelection) {
            sourceRange = context.workbook.getSelectedRange();
        } else {
            const sourceName = String(opts.sourceSheet || "").trim();
            if (!sourceName) return { success: false, processedRows: 0, error: "No source worksheet selected." };
            const sourceSheet = context.workbook.worksheets.getItem(sourceName);
            sourceRange = sourceSheet.getUsedRange();
        }
        sourceRange.load(["values", "rowCount", "columnCount"]);
        await context.sync();

        const values = sourceRange.values || [];
        if (values.length < 2) return { success: false, processedRows: 0, error: "Dataset too small — needs at least a header row and one data row." };
        const headers = values[0].map(v => String(v ?? "").trim());
        let rows = values.slice(1).filter(row => row.some(v => String(v ?? "").trim() !== ""));

        const resolve = (requested) => {
            const wanted = normalize(requested);
            const names = headers.map(normalize);
            let idx = names.indexOf(wanted);
            if (idx >= 0) return idx;
            const preferred = (list) => {
                for (const p of list) { const i = names.indexOf(normalize(p)); if (i >= 0) return i; }
                return -1;
            };
            if (["rating", "ratings", "aggregate rating", "review rating"].includes(wanted)) {
                idx = preferred(["Aggregate rating", "Rating", "Average rating", "Rating score"]);
                if (idx >= 0) return idx;
                const candidates = names.map((n,i) => /rating/.test(n) && !/color|text/.test(n) ? i : -1).filter(i=>i>=0);
                if (candidates.length) return candidates[0];
            }
            if (["delivery", "online delivery", "has online delivery", "delivery capability"].includes(wanted)) {
                idx = preferred(["Has Online delivery", "Online delivery", "Delivery"]);
                if (idx >= 0) return idx;
            }
            if (["table booking", "online table booking", "has table booking", "booking", "table booking capability"].includes(wanted)) {
                idx = preferred(["Has Table booking", "Online table booking", "Table booking"]);
                if (idx >= 0) return idx;
            }
            if (["city", "location", "geographic area", "locality", "area", "neighborhood", "neighbourhood"].includes(wanted)) {
                idx = preferred(["City", "Location", "Locality", "Area", "Geographic area", "Neighborhood", "Neighbourhood"]);
                if (idx >= 0) return idx;
            }
            const compactWanted = wanted.replace(/\s/g, "");
            idx = names.findIndex(n => n.replace(/\s/g, "") === compactWanted);
            if (idx >= 0) return idx;
            return -1;
        };

        const stepLines = [];
        for (let i = 0; i < steps.length; i++) {
            const step = steps[i] || {};
            const col = resolve(step.column);
            if (col < 0) return { success: false, processedRows: 0, error: `Could not resolve filter column '${step.column}' for step ${i + 1}.` };
            const before = rows.length;
            rows = rows.filter(row => evaluate(row[col], step.operator, step.value, step.value2));
            stepLines.push(`  • Kept rows where ${headers[col]} ${step.operator || "equals"} ${step.value ?? ""} (removed ${before - rows.length} rows).`);
            if (!rows.length) return { success: false, processedRows: 0, error: "No matching data was found for the requested criteria in the current worksheet.\n\n(no rows returned)" };
        }

        const requested = String(opts.requestedSheetName || "Filtered_Result").trim() || "Filtered_Result";
        const sheetName = (requested + "_" + (Date.now() % 100000)).substring(0, 31);
        const sheets = context.workbook.worksheets;
        sheets.load("items/name");
        await context.sync();
        const existing = sheets.items.find(s => s.name === sheetName);
        if (existing) existing.delete();
        const outSheet = sheets.add(sheetName);
        outSheet.getRangeByIndexes(0, 0, 1, headers.length).values = [headers];
        outSheet.getRangeByIndexes(0, 0, 1, headers.length).format.font.bold = true;
        const CHUNK = 10000;
        for (let start = 0; start < rows.length; start += CHUNK) {
            const chunk = rows.slice(start, start + CHUNK);
            outSheet.getRangeByIndexes(1 + start, 0, chunk.length, headers.length).values = chunk.map(r => headers.map((_,i) => r[i] ?? ""));
            await context.sync();
        }
        // Autofitting an entire large result range is surprisingly expensive in
        // Office.js and can make a valid large result appear to be stuck. Keep
        // the filter path deterministic and fast; Excel can still be resized
        // manually by the user.
        outSheet.activate();
        outSheet.getRangeByIndexes(0, 0, Math.min(rows.length + 1, 100), headers.length).select();
        await context.sync();
        return {
            success: true,
            processedRows: rows.length,
            rowCount: rows.length,
            sheetName,
            stepSummary: `Ran ${steps.length} step(s) locally in Excel and wrote the result to '${sheetName}' (${rows.length} rows):\n${stepLines.join("\n")}`,
            error: null
        };
    }).catch(err => ({ success: false, processedRows: 0, error: err.toString() }));
}

window.jsExecuteLocalFilterQuery = jsExecuteLocalFilterQuery;

async function jsWriteQueryResultToSheet(optionsJson) {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") {
        return { success: false, processedRows: 0, error: "Excel context unallocated" };
    }

    let opts;
    try {
        opts = JSON.parse(optionsJson);
    } catch (err) {
        return { success: false, processedRows: 0, error: "Invalid options JSON: " + err.toString() };
    }

    const columns = Array.isArray(opts.columns) ? opts.columns : [];
    const rows = Array.isArray(opts.rows) ? opts.rows : [];
    if (columns.length === 0) {
        return { success: false, processedRows: 0, error: "No columns to write." };
    }

    const CHUNK_ROWS = 2000;

    function rowToArray(row) {
        // Query-result writers historically received rows as objects, but
        // secure-local transformations (categorize/currency conversion)
        // execute entirely in Dart and return matrix rows: [value, value, ...].
        // Treat both shapes as valid. Without this branch an Array indexed by
        // a string column name returns undefined, so the result sheet gets
        // headers but every data cell is blank.
        if (Array.isArray(row)) {
            return columns.map(function (_c, index) {
                const v = index < row.length ? row[index] : undefined;
                return (v === null || v === undefined) ? "" : v;
            });
        }
        return columns.map(function (c) {
            const v = row ? row[c] : undefined;
            return (v === null || v === undefined) ? "" : v;
        });
    }

    return await Excel.run(async function (context) {
        const workbook = context.workbook;
        const sheetName = String(opts.targetSheetName || "Query_Result").substring(0, 31);

        const previousSheet = workbook.worksheets.getActiveWorksheet();
        previousSheet.load("name");
        let previousSelection = null;
        try {
            previousSelection = context.workbook.getSelectedRange();
            previousSelection.load("address");
        } catch (_) {
            previousSelection = null;
        }
        await context.sync();

        const previousSheetName = previousSheet.name;
        const previousSelectionAddress = previousSelection ? previousSelection.address : null;

        const sheets = workbook.worksheets;
        sheets.load("items/name");
        await context.sync();

        for (let i = 0; i < sheets.items.length; i++) {
            if (sheets.items[i].name === sheetName) {
                sheets.items[i].delete();
                break;
            }
        }
        await context.sync();

        const outSheet = workbook.worksheets.add(sheetName);

        const headerRange = outSheet.getRangeByIndexes(0, 0, 1, columns.length);
        headerRange.values = [columns];
        headerRange.format.font.bold = true;
        await context.sync();

        let written = 0;
        for (let start = 0; start < rows.length; start += CHUNK_ROWS) {
            const chunk = rows.slice(start, start + CHUNK_ROWS);
            const matrix = chunk.map(rowToArray);
            const dataRange = outSheet.getRangeByIndexes(1 + start, 0, matrix.length, columns.length);
            dataRange.values = matrix;
            written += matrix.length;
            await context.sync();
        }

        // Apply transformation-provided number formats after writing values.
        // Categorization can include currency conversion (e.g. "currency in INR");
        // the backend returns column -> Excel number format in metadata.
        if (opts.metadata && opts.metadata.number_formats && typeof opts.metadata.number_formats === "object") {
            const formats = opts.metadata.number_formats;
            for (let i = 0; i < columns.length; i++) {
                const columnName = String(columns[i]);
                const fmt = formats[columnName];
                if (!fmt) continue;
                const colRange = outSheet.getRangeByIndexes(1, i, Math.max(rows.length, 1), 1);
                colRange.numberFormat = Array.from({ length: Math.max(rows.length, 1) }, () => [fmt]);
            }
            await context.sync();
        }

        outSheet.getUsedRange().format.autofitColumns();
        await context.sync();

        // Query/filter result sheets are the user's new working dataset.
        // Switch Excel to the newly-created sheet instead of restoring the
        // previous worksheet. This is also used by pivot/query-result flows
        // that write through this helper.
        try {
            outSheet.activate();
            const outUsed = outSheet.getUsedRange();
            outUsed.select();
            await context.sync();
        } catch (_) {
        }

        return { success: true, processedRows: written, error: null };
    }).catch(function (err) {
        return { success: false, processedRows: 0, error: err.toString() };
    });
}

window.jsWriteQueryResultToSheet = jsWriteQueryResultToSheet;

// jsAppendQualityReportRow() was removed — its only responsibility (writing
// the minimal Table|Rows|Missing|Duplicates rollup into "Quality_Report")
// has been folded into jsWriteQualityReportWorksheet() in
// excel_quality_report_generator.js, which is now the single implementation
// used both by the automatic per-scan sync (data_screen.dart's
// _syncQualityReport(), which calls it with activate:false and only
// overview-level fields) and by the explicit "Export Full Quality Report"
// button (which supplies the complete AiReport). See that file for the
// current implementation.
