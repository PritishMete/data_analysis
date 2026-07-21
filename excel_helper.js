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

async function getSheetData(sheetName) {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") return null;
    try {
        return await Excel.run(async function (context) {
            const sheet = context.workbook.worksheets.getItem(sheetName);
            const range = sheet.getUsedRange();
            range.load("values");
            await context.sync();
            console.log("[DEBUG getSheetData] values:", JSON.stringify(range.values));
            return JSON.stringify(range.values);
        });
    } catch (err) {
        console.error("getSheetData error:", err);
        return null;
    }
}

async function getSelectedExcelData() {
    await window.waitForOfficeReady();
    if (typeof Excel === "undefined") return null;
    try {
        return await Excel.run(async function (context) {
            const range = context.workbook.getSelectedRange();
            range.load("values");
            await context.sync();

            if (!range.values || range.values.length === 0 || (range.values.length === 1 && range.values[0][0] === "")) {
                const sheet = context.workbook.worksheets.getActiveWorksheet();
                const usedRange = sheet.getUsedRange();
                usedRange.load("values");
                await context.sync();
                console.log("[DEBUG getSelectedExcelData] usedRange.values:", JSON.stringify(usedRange.values));
                return JSON.stringify(usedRange.values);
            }
            console.log("[DEBUG getSelectedExcelData] range.values:", JSON.stringify(range.values));
            return JSON.stringify(range.values);
        });
    } catch (err) {
        console.error("getSelectedExcelData error:", err);
        return null;
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

            // Clear existing formatting safely using clearAll()
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

        // Two flavors share this one action: the original group-aggregate
        // classification (partitionBy + windowFunction), and a row-wise
        // arithmetic comparison/computation (rightExpression present) — e.g.
        // checking TotalPrice against UnitPrice * Quantity. Auto-detected so
        // no separate action/interop entry is needed for the arithmetic case.
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
                // Both mutation functions return the SAME reference back when
                // their config couldn't be resolved against this sheet's
                // headers — treat that as a failure, not a no-op.
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

            // Upgrade the new column's data cells from static computed
            // values to LIVE Excel formulas (e.g. "=(B2*C2)" or
            // '=IF(D2=B2*C2,"Match","Mismatch")') referencing the actual
            // source cells, so edits elsewhere in the sheet keep this
            // column correct instead of it going stale. Only applies to
            // formula mode — aggregate/window-function columns still write
            // a one-time computed label, same as before.
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
                            // 1-based Excel row number for this data row.
                            const excelRow = usedRange.rowIndex + r + 1;
                            formulaRows.push([buildExcelFormulaForRow(config, headerToLetter, excelRow)]);
                        }
                        const newColOffset = headers.length; // 0-based index of the new column
                        const formulaRange = sheet.getRangeByIndexes(
                            usedRange.rowIndex + 1,     // first DATA row (skip header)
                            usedRange.columnIndex + newColOffset,
                            dataRowCount,
                            1
                        );
                        formulaRange.formulas = formulaRows;
                        await context.sync();
                    }
                } catch (err) {
                    // Non-fatal: the static computed values above are already
                    // written and correct as of right now — a failure here
                    // just means the column won't auto-recalculate on future
                    // edits, not that the operation itself failed.
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

// ── Orchestrator Pipeline ───────────────────────────────────────────────────

function _getColumnLabel(colIndex) {
    let label = "";
    let temp = colIndex;
    while (temp >= 0) {
        label = String.fromCharCode((temp % 26) + 65) + label;
        temp = Math.floor(temp / 26) - 1;
    }
    return label;
}

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
            const fIdx = headerRow.indexOf(fCol);
            if (fIdx !== -1) {
                const fType = opts.filter.type;
                if (fType === "top_n" || fType === "bottom_n") {
                    const n = parseInt(opts.filter.value, 10) || 10;
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

        if (opts.targetSheetName === null && opts.pivotConfig) {
        } else {
            const sheetsList = workbook.worksheets;
            sheetsList.load("items/name");
            await context.sync();
            for (let i = 0; i < sheetsList.items.length; i++) {
                if (sheetsList.items[i].name === sheetName) {
                    sheetsList.items[i].delete();
                    break;
                }
            }
            await context.sync();
        }

        let targetSheet;
        if (opts.targetSheetName === null && opts.pivotConfig) {
            targetSheet = workbook.worksheets.add("Temp_Source_Buffer_" + Math.floor(Math.random() * 1000));
        } else {
            targetSheet = workbook.worksheets.add(sheetName);
        }

        const finalRange = targetSheet.getRangeByIndexes(0, 0, runningData.length, runningData[0].length);
        finalRange.values = runningData;

        if (opts.freezeHeaderRow) {
            targetSheet.freezePanes.freezeRows(1);
        }
        if (opts.enableAutoFilter) {
            targetSheet.autoFilter.apply(finalRange);
        }
        targetSheet.getUsedRange().format.autofitColumns();

        if (opts.pivotConfig) {
            const pc = opts.pivotConfig;
            const pivotSheetName = (pc.sheetName || ("Pivot_" + (sheetName || "Data"))).substring(0, 31);

            const currentSheets = workbook.worksheets;
            currentSheets.load("items/name");
            await context.sync();

            let pivotSheet = currentSheets.items.find(s => s.name === pivotSheetName);
            let destinationCell = "A1";

            if (!pc.appendMode || !pivotSheet) {
                for (let i = 0; i < currentSheets.items.length; i++) {
                    if (currentSheets.items[i].name === pivotSheetName) {
                        currentSheets.items[i].delete();
                        break;
                    }
                }
                await context.sync();
                pivotSheet = workbook.worksheets.add(pivotSheetName);
            } else {
                const usedRange = pivotSheet.getUsedRange(true);
                await context.sync();
                if (usedRange && !usedRange.isNullObject) {
                    usedRange.load(["columnCount", "columnIndex"]);
                    await context.sync();
                    const nextFreeColumnIndex = usedRange.columnIndex + usedRange.columnCount + 2;
                    destinationCell = _getColumnLabel(nextFreeColumnIndex) + "1";
                }
            }

            const pivotSourceSheet = workbook.worksheets.getItem(resolvedSourceName);
            const pivotSourceRange = pivotSourceSheet.getUsedRange();
            pivotSourceRange.load(["rowCount", "columnCount"]);
            await context.sync();

            const destinationRange = pivotSheet.getRange(destinationCell);
            const pivotTable = pivotSheet.pivotTables.add(
                pc.tableName || "AI_Generated_PivotTable",
                pivotSourceRange,
                destinationRange
            );

            const hierarchies = pivotTable.hierarchies;
            hierarchies.load("items/name");
            await context.sync();

            const hierMap = {};
            for (const h of hierarchies.items) {
                hierMap[h.name.trim().toLowerCase()] = h;
            }

            function findHier(fieldName) {
                if (!fieldName) return null;
                const key = String(fieldName).trim().toLowerCase();
                if (hierMap[key]) return hierMap[key];
                for (const [k, v] of Object.entries(hierMap)) {
                    if (k.includes(key) || key.includes(k)) return v;
                }
                return null;
            }

            const rowFields = Array.isArray(pc.rowFields) ? pc.rowFields : (pc.rowField ? [pc.rowField] : []);
            let appliedRows = 0;
            for (const rf of rowFields) {
                const rHier = findHier(rf);
                if (rHier) {
                    pivotTable.rowHierarchies.add(rHier);
                    appliedRows++;
                }
            }
            if (appliedRows === 0 && hierarchies.items.length > 0) {
                pivotTable.rowHierarchies.add(hierarchies.items[0]);
            }

            const columnFields = Array.isArray(pc.columnFields) ? pc.columnFields : (pc.columnField ? [pc.columnField] : []);
            for (const cf of columnFields) {
                const cHier = findHier(cf);
                if (cHier) pivotTable.columnHierarchies.add(cHier);
            }

            function opToAggFunction(opStr) {
                const op = (opStr || "sum").toLowerCase();
                if (op === "count" || op === "counta")  return Excel.AggregationFunction.count;
                if (op === "average")                    return Excel.AggregationFunction.average;
                if (op === "max")                        return Excel.AggregationFunction.max;
                if (op === "min")                        return Excel.AggregationFunction.min;
                if (op === "product")                    return Excel.AggregationFunction.product;
                if (op === "stdev")                      return Excel.AggregationFunction.standardDeviation;
                return Excel.AggregationFunction.sum;
            }

            let lastAddedDataHier = null;
            if (Array.isArray(pc.valueFields) && pc.valueFields.length > 0) {
                for (const vf of pc.valueFields) {
                    if (!vf || !vf.field) continue;
                    const valHier = findHier(vf.field);
                    if (valHier) {
                        const dataHierarchy = pivotTable.dataHierarchies.add(valHier);
                        dataHierarchy.summarizeBy = opToAggFunction(vf.op);
                        lastAddedDataHier = dataHierarchy;
                    }
                }
            } else if (pc.valueField) {
                const valTarget = findHier(pc.valueField);
                if (valTarget) {
                    const dataHierarchy = pivotTable.dataHierarchies.add(valTarget);
                    dataHierarchy.summarizeBy = opToAggFunction(pc.valueOperation || "sum");
                    lastAddedDataHier = dataHierarchy;
                }
            }

            try {
                targetSheet.delete();
            } catch(e) { console.warn(" Staging layer clear bypassed."); }

            await context.sync();
            pivotSheet.activate();
            await context.sync();
            return { success: true, processedRows: runningData.length, error: null };
        }

        await context.sync();
        targetSheet.activate();
        await context.sync();
        return { success: true, processedRows: runningData.length, error: null };

    }).catch(function (err) {
        return { success: false, processedRows: 0, error: err.toString() };
    });
}

// ── Write arbitrary SQL/query result rows to a sheet ──────────────────────
// Used by the /smart_query "sql" route: the backend returns
// { columns: [...], rows: [{...}, ...] } (a list of records), and this
// writes that straight into a new sheet as a plain table (headers + data),
// bolding the header row and autofitting columns — same visual treatment
// as the other "write results to a new sheet" paths above, but for
// arbitrary externally-computed rows rather than a transform of existing
// sheet data.
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

    // Writing every row in a single Range.values assignment works fine for
    // small results, but large datasets (tens of thousands of rows — e.g. a
    // full customer_shopping_behavior.csv with 70k+ rows) build a JSON
    // payload big enough to exceed Excel's per-request size limit
    // (particularly on Excel Online / Excel for the web), or simply take
    // long enough that the request stalls. Either way the write can fail
    // with nothing visible happening in the UI. Writing in bounded-size
    // chunks and syncing after each one keeps every individual request
    // small, regardless of total row count.
    const CHUNK_ROWS = 2000;

    function rowToArray(row) {
        return columns.map(function (c) {
            const v = row ? row[c] : undefined;
            return (v === null || v === undefined) ? "" : v;
        });
    }

    return await Excel.run(async function (context) {
        const workbook = context.workbook;
        const sheetName = String(opts.targetSheetName || "Query_Result").substring(0, 31);

        // ── Capture the user's current sheet + selection BEFORE touching
        // anything, so we can restore it afterward. Without this, activating
        // the new results sheet below would silently change what "Active
        // Selection" mode reads on the NEXT query — effectively making it
        // look like the selection was "forgotten".
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

        // Header row on its own — always small, always safe to write in one go.
        const headerRange = outSheet.getRangeByIndexes(0, 0, 1, columns.length);
        headerRange.values = [columns];
        headerRange.format.font.bold = true;
        await context.sync();

        // Data rows in bounded chunks, syncing after each one so no single
        // request has to carry the whole dataset at once. Row 0 is the
        // header, so chunk i's data starts at sheet row (1 + start).
        let written = 0;
        for (let start = 0; start < rows.length; start += CHUNK_ROWS) {
            const chunk = rows.slice(start, start + CHUNK_ROWS);
            const matrix = chunk.map(rowToArray);
            const dataRange = outSheet.getRangeByIndexes(1 + start, 0, matrix.length, columns.length);
            dataRange.values = matrix;
            written += matrix.length;
            await context.sync();
        }

        outSheet.getUsedRange().format.autofitColumns();
        await context.sync();

        // ── Restore focus to wherever the user actually was, so their
        // active-selection workflow continues uninterrupted. The new sheet
        // still exists and can be opened manually — it's just not forced
        // into view, and (more importantly) it's not left as the active
        // sheet for the next query to accidentally read from.
        try {
            const sheetToRestore = workbook.worksheets.getItem(previousSheetName);
            sheetToRestore.activate();
            if (previousSelectionAddress) {
                sheetToRestore.getRange(previousSelectionAddress).select();
            }
            await context.sync();
        } catch (_) {
            // If restoring fails for any reason (e.g. the address was on a
            // sheet that no longer exists), don't fail the whole write —
            // the results sheet was already created successfully.
        }

        return { success: true, processedRows: written, error: null };
    }).catch(function (err) {
        return { success: false, processedRows: 0, error: err.toString() };
    });
}

window.jsWriteQueryResultToSheet = jsWriteQueryResultToSheet;

// ── Quality Report Aggregator ────────────────────────────────────────────────
//
// Every time a tab/upload is analyzed, this appends one summary row
// (Table | Rows | Missing | Duplicates) into a running "Quality_Report"
// sheet. If the same table was already scanned before, its row is
// overwritten in place rather than duplicated — so the sheet stays a clean
// one-row-per-table rollup no matter how many times a given tab is
// re-scanned, giving an overall view as each tab gets analyzed one by one.
async function jsAppendQualityReportRow(optionsJson) {
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

    const targetSheetName = String(opts.targetSheetName || "Quality_Report").substring(0, 31);
    const HEADERS = ["Table", "Rows", "Missing", "Duplicates"];

    return await Excel.run(async function (context) {
        const workbook = context.workbook;

        // ── Capture the user's current sheet + selection BEFORE touching
        // anything, so we can restore it afterward — same pattern as
        // jsWriteQueryResultToSheet, so this rollup never "steals" focus.
        const previousSheet = workbook.worksheets.getActiveWorksheet();
        previousSheet.load("name");
        let previousSelection = null;
        try {
            previousSelection = workbook.getSelectedRange();
            previousSelection.load("address");
        } catch (_) {
            previousSelection = null;
        }

        // ── Resolve the label for this row: either an explicit tableName
        // (used for uploaded files, which have no worksheet of their own),
        // or the sheet that was actually analyzed (named source, else
        // whatever is currently active).
        let tableLabel = opts.tableName || null;
        let resolvedSheet = null;
        if (!tableLabel) {
            resolvedSheet = opts.sourceSheetName
                ? workbook.worksheets.getItem(opts.sourceSheetName)
                : workbook.worksheets.getActiveWorksheet();
            resolvedSheet.load("name");
        }
        await context.sync();
        if (!tableLabel) tableLabel = resolvedSheet.name;

        const previousSheetName = previousSheet.name;
        const previousSelectionAddress = previousSelection ? previousSelection.address : null;

        // ── Find or create the Quality_Report sheet.
        const sheets = workbook.worksheets;
        sheets.load("items/name");
        await context.sync();

        let reportSheet = null;
        for (let i = 0; i < sheets.items.length; i++) {
            if (sheets.items[i].name === targetSheetName) {
                reportSheet = sheets.items[i];
                break;
            }
        }

        let existingRows = [];
        if (!reportSheet) {
            reportSheet = workbook.worksheets.add(targetSheetName);
            const headerRange = reportSheet.getRangeByIndexes(0, 0, 1, HEADERS.length);
            headerRange.values = [HEADERS];
            headerRange.format.font.bold = true;
            await context.sync();
        } else {
            const usedRange = reportSheet.getUsedRange();
            usedRange.load("values");
            await context.sync();
            existingRows = usedRange.values || [];
        }

        // ── Overwrite this table's existing row if it was scanned before,
        // otherwise append a new one at the end.
        let rowIndex = -1;
        for (let i = 1; i < existingRows.length; i++) {
            if (String(existingRows[i][0]) === String(tableLabel)) {
                rowIndex = i;
                break;
            }
        }
        if (rowIndex === -1) rowIndex = Math.max(existingRows.length, 1);

        const rowValues = [[
            tableLabel,
            Number(opts.rows) || 0,
            Number(opts.missing) || 0,
            Number(opts.duplicates) || 0,
        ]];
        const dataRange = reportSheet.getRangeByIndexes(rowIndex, 0, 1, HEADERS.length);
        dataRange.values = rowValues;
        await context.sync();

        reportSheet.getUsedRange().format.autofitColumns();
        await context.sync();

        // ── Restore focus to wherever the user actually was.
        try {
            const sheetToRestore = workbook.worksheets.getItem(previousSheetName);
            sheetToRestore.activate();
            if (previousSelectionAddress) {
                sheetToRestore.getRange(previousSelectionAddress).select();
            }
            await context.sync();
        } catch (_) {
            // Non-fatal — the report row was already written successfully.
        }

        return { success: true, processedRows: 1, error: null };
    }).catch(function (err) {
        return { success: false, processedRows: 0, error: err.toString() };
    });
}

window.jsAppendQualityReportRow = jsAppendQualityReportRow;