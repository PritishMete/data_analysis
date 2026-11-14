// Worksheet schema bridge for the secure local query path.
// It normalizes only structural matrix shape; worksheet values remain in-page.
(function () {
    function isBlankRow(row) {
        return !Array.isArray(row) || row.every(function (value) {
            return value === null || value === undefined || String(value).trim() === "";
        });
    }

    function normalizeWorksheetMatrix(matrix) {
        if (!Array.isArray(matrix)) {
            return { matrix: [], headerIndex: -1, rows: 0, columns: 0, headerCount: 0 };
        }
        var headerIndex = matrix.findIndex(function (row) {
            return Array.isArray(row) && !isBlankRow(row);
        });
        if (headerIndex < 0) {
            return { matrix: [], headerIndex: -1, rows: matrix.length, columns: 0, headerCount: 0 };
        }

        var sourceRows = matrix.slice(headerIndex).filter(Array.isArray);
        var width = sourceRows.reduce(function (max, row) {
            return Math.max(max, row.length);
        }, 0);
        if (!width) {
            return { matrix: [], headerIndex: headerIndex, rows: matrix.length, columns: 0, headerCount: 0 };
        }

        var normalized = sourceRows.map(function (row) {
            var out = Array.from(row);
            while (out.length < width) out.push("");
            return out.slice(0, width);
        });

        // Preserve the original header names and positions. Empty/duplicate
        // headers are not silently renamed or collapsed; schema resolution
        // decides later whether a requested column is unique.
        var headers = normalized[0] || [];
        var headerCount = headers.filter(function (value) {
            return String(value ?? "").trim() !== "";
        }).length;
        return {
            matrix: normalized,
            headerIndex: headerIndex,
            rows: normalized.length,
            columns: width,
            headerCount: headerCount,
        };
    }

    window.normalizeWorksheetMatrix = normalizeWorksheetMatrix;

    function wrapReader(name) {
        var original = window[name];
        if (typeof original !== "function") return;
        window[name] = async function () {
            var result = await original.apply(this, arguments);
            if (!result) return result;
            try {
                var matrix = JSON.parse(result);
                if (matrix && matrix.__error) return result;
                var prepared = normalizeWorksheetMatrix(matrix);
                console.log("[SCHEMA]", name, {
                    inputRows: Array.isArray(matrix) ? matrix.length : 0,
                    inputColumns: Array.isArray(matrix) ? matrix.reduce(function (m, row) { return Math.max(m, Array.isArray(row) ? row.length : 0); }, 0) : 0,
                    headerIndex: prepared.headerIndex,
                    headerCount: prepared.headerCount,
                    rows: prepared.rows,
                    columns: prepared.columns,
                });
                return JSON.stringify(prepared.matrix);
            } catch (_) {
                return result;
            }
        };
    }

    wrapReader("getSelectedExcelData");
    wrapReader("getSheetData");
})();
