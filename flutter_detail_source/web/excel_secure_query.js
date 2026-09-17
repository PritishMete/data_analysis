// Deterministic secure Excel operations. The only input is the worksheet
// matrix already read by the taskpane. There is no fetch/XHR/network path.
function _secureNormalize(value) {
    return String(value ?? "").normalize("NFKC").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().replace(/\s+/g, " ");
}
function _secureIsBlankRow(row) {
    return !Array.isArray(row) || row.every(v => v === null || v === undefined || String(v).trim() === "");
}
function _securePrepareMatrix(matrix) {
    if (!Array.isArray(matrix)) return { headers: [], rows: [], headerIndex: -1, originalRows: 0, originalColumns: 0 };
    const originalRows = matrix.length;
    const originalColumns = matrix.reduce((m, row) => Math.max(m, Array.isArray(row) ? row.length : 0), 0);
    const firstDataBearingRow = matrix.findIndex(row => Array.isArray(row) && !_secureIsBlankRow(row));
    if (firstDataBearingRow < 0) return { headers: [], rows: [], headerIndex: -1, originalRows, originalColumns };
    const width = Math.max(0, ...matrix.slice(firstDataBearingRow).filter(Array.isArray).map(row => row.length));
    const normaliseRow = row => {
        const out = Array.isArray(row) ? Array.from(row) : [];
        while (out.length < width) out.push("");
        return out.slice(0, width);
    };
    const normalised = matrix.slice(firstDataBearingRow).filter(Array.isArray).map(normaliseRow);
    if (normalised.length < 2 || width === 0) return { headers: [], rows: [], headerIndex: -1, originalRows, originalColumns };
    const headers = normalised[0].map(x => String(x ?? "").trim());
    const rows = normalised.slice(1).filter(row => !_secureIsBlankRow(row));
    return { headers, rows, headerIndex: firstDataBearingRow, originalRows, originalColumns };
}
function _secureColumnInfo(headers) {
    return headers.map((h, i) => ({ i, name: String(h ?? "").trim(), n: _secureNormalize(h) })).filter(x => x.name);
}
function _secureResolveColumn(headers, requested) {
    const wanted = _secureNormalize(requested);
    if (!wanted) return -1;
    const names = _secureColumnInfo(headers);
    let hit = names.filter(x => x.n === wanted);
    if (hit.length === 1) return hit[0].i;
    const aliases = { city: ["city", "city name", "city_name", "town", "municipality", "locality"], country: ["country", "country name", "nation"], restaurant: ["restaurant name", "restaurant"] };
    for (const alias of Object.keys(aliases)) {
        if (wanted === alias || aliases[alias].includes(wanted)) {
            hit = names.filter(x => aliases[alias].includes(x.n));
            if (hit.length === 1) return hit[0].i;
            if (hit.length > 1) return -1;
        }
    }
    const compactWanted = wanted.replace(/\s+/g, "");
    hit = names.filter(x => x.n.replace(/\s+/g, "") === compactWanted);
    if (hit.length === 1) return hit[0].i;
    if (hit.length > 1) return -1;
    const tokens = wanted.split(" ").filter(x => x.length >= 2);
    const scored = names.map(x => ({ ...x, score: tokens.filter(t => x.n.split(" ").includes(t)).length })).filter(x => x.score > 0).sort((a, b) => b.score - a.score);
    if (scored.length === 1 || (scored.length > 1 && scored[0].score > scored[1].score)) return scored[0].i;
    return -1;
}
function _secureLooksLikeQuality(query) {
    const q = _secureNormalize(query);
    const verb = /\b(check|inspect|find|show|report|identify)\b/.test(q);
    const missing = /\b(missing|null|blank|empty)\b/.test(q);
    const duplicate = /\b(duplicate|duplicates|duplicated)\b/.test(q);
    const restaurantId = /\brestaurant\s+ids?\b/.test(q) || /\brestaurantid\b/.test(q) || /\brestaurant\s+identifier\b/.test(q);
    const explicitNamed = /\bduplicates?\s+(?:the\s+)?[a-z0-9_]+(?:\s+[a-z0-9_]+)?\s+(?:values?|ids?)\b/.test(q);
    return verb && (missing || duplicate) && (missing || restaurantId || explicitNamed);
}
function _secureLooksLikeGroup(query) {
    const q = _secureNormalize(query);
    return /\b(count|how many|number of)\b/.test(q) && /\b(each|per|by|group(?:ed)? by)\b/.test(q);
}
function _secureMissing(value) { return value === null || value === undefined || String(value).trim() === ""; }
function _secureInferGroupColumn(headers, query) {
    const q = _secureNormalize(query);
    const match = q.match(/\b(?:each|per|by|group(?:ed)? by)\s+(.+?)(?:\?|$)/);
    if (!match) return { index: -1, requested: null, candidates: [] };
    const requested = match[1].trim().replace(/^(the|a|an)\s+/, "");
    const exactCandidates = _secureColumnInfo(headers).filter(x => x.n === _secureNormalize(requested));
    if (exactCandidates.length === 1) return { index: exactCandidates[0].i, requested, candidates: exactCandidates };
    const index = _secureResolveColumn(headers, requested);
    const candidates = _secureColumnInfo(headers).filter(x => {
        const normalized = _secureNormalize(x.name);
        return normalized === _secureNormalize(requested) || normalized.replace(/\s+/g, "") === _secureNormalize(requested).replace(/\s+/g, "");
    });
    return { index, requested, candidates };
}
function _secureIdentifierResolution(headers, query) {
    const q = _secureNormalize(query), names = _secureColumnInfo(headers);
    let requested = null;
    if (/\brestaurant\s+ids?\b/.test(q)) requested = "restaurant id";
    else if (/\brestaurantid\b/.test(q)) requested = "restaurantid";
    else if (/\brestaurant\s+identifier\b/.test(q)) requested = "restaurant identifier";
    else {
        const named = q.match(/\bduplicates?\s+(?:the\s+)?([a-z0-9_]+(?:\s+[a-z0-9_]+)?)\s+(?:values?|ids?)\b/);
        if (named) requested = named[1].trim();
    }
    if (requested) {
        const compact = value => _secureNormalize(value).replace(/\s+/g, "").replace(/ids$/, "id");
        const wanted = compact(requested);
        const candidates = names.filter(x => compact(x.n) === wanted);
        return { index: candidates.length === 1 ? candidates[0].i : -1, requested, candidates };
    }
    const candidates = names.filter(x => /(^| )(restaurant )?(id|identifier)( |$)/.test(x.n));
    return { index: candidates.length === 1 ? candidates[0].i : -1, requested: null, candidates };
}
function _secureGroup(rows, headers, query, diagnostics) {
    const resolution = _secureInferGroupColumn(headers, query);
    diagnostics.group_resolution = resolution.index >= 0 ? "resolved" : (resolution.candidates.length > 1 ? "ambiguous" : "not_found");
    diagnostics.group_requested = resolution.requested || null;
    if (resolution.index < 0) {
        if (resolution.candidates.length > 1) {
            return { success: false, route: "operation", operation: { action: "group", candidates: resolution.candidates.map(x => x.name) }, error: `Grouping column "${resolution.requested}" is ambiguous; candidates: ${resolution.candidates.map(x => x.name).join(", ")}.`, local_secure: true, diagnostics, source_mutated: false };
        }
        return { success: false, route: "operation", operation: { action: "group" }, error: `Could not resolve grouping column "${resolution.requested || "requested field"}" from the current worksheet schema.`, local_secure: true, diagnostics, source_mutated: false };
    }
    const groups = new Map();
    for (const row of rows) {
        const key = _secureMissing(row[resolution.index]) ? null : row[resolution.index];
        const mapKey = key === null ? "__NULL__" : `${typeof key}:${String(key)}`;
        if (!groups.has(mapKey)) groups.set(mapKey, { [headers[resolution.index]]: key, count: 0 });
        groups.get(mapKey).count += 1;
    }
    const resultRows = Array.from(groups.values());
    diagnostics.resolved_group_column = String(headers[resolution.index]);
    return { success: true, route: "operation", operation: { action: "group", group_by: [headers[resolution.index]], columns: [headers[resolution.index], "count"], rows: resultRows, row_count: resultRows.length, source_mutated: false }, message: `Counted records by ${headers[resolution.index]} locally (${resultRows.length} groups).`, local_secure: true, diagnostics, source_mutated: false };
}
function _secureQuality(rows, headers, query, diagnostics) {
    const missingByColumn = {};
    for (let i = 0; i < headers.length; i++) { let count = 0; for (const row of rows) if (_secureMissing(row[i])) count++; if (count) missingByColumn[String(headers[i])] = count; }
    const resolution = _secureIdentifierResolution(headers, query);
    diagnostics.identifier_resolution = resolution.index >= 0 ? "resolved" : (resolution.candidates.length > 1 ? "ambiguous" : (resolution.requested ? "not_found" : "not_selected"));
    let duplicateIdentifier = { status: "identifier_not_selected", message: "No unique identifier column was found for duplicate-ID analysis.", requested_column: resolution.requested, candidates: resolution.candidates.map(x => x.name), column: null, duplicate_value_count: 0, duplicate_row_count: 0, values: [] };
    if (resolution.index < 0) {
        if (resolution.requested) { duplicateIdentifier.status = resolution.candidates.length > 1 ? "ambiguous_identifier" : "identifier_not_found"; duplicateIdentifier.message = resolution.candidates.length > 1 ? `Requested identifier "${resolution.requested}" is ambiguous; candidates: ${resolution.candidates.map(x => x.name).join(", ")}.` : `Could not resolve requested identifier column "${resolution.requested}" from the current worksheet schema.`; }
        else if (resolution.candidates.length > 1) { duplicateIdentifier.status = "ambiguous_identifier"; duplicateIdentifier.message = `Multiple identifier candidates found: ${resolution.candidates.map(x => x.name).join(", ")}.`; }
    } else {
        const counts = new Map();
        for (const row of rows) { const value = row[resolution.index]; if (_secureMissing(value)) continue; const key = `${typeof value}:${String(value).trim()}`; const existing = counts.get(key); if (existing) existing.count++; else counts.set(key, { value: typeof value === "string" ? value.trim() : value, count: 1 }); }
        const duplicates = Array.from(counts.values()).filter(x => x.count > 1);
        duplicateIdentifier = { status: "ok", requested_column: resolution.requested, candidates: resolution.candidates.map(x => x.name), column: String(headers[resolution.index]), duplicate_value_count: duplicates.length, duplicate_row_count: duplicates.reduce((sum, x) => sum + x.count, 0), values: duplicates.map(x => x.value) };
        diagnostics.resolved_identifier_column = String(headers[resolution.index]);
    }
    const seenRows = new Map();
    for (const row of rows) { const key = JSON.stringify(row.map(v => v === undefined ? null : v)); seenRows.set(key, (seenRows.get(key) || 0) + 1); }
    let duplicateRows = 0; for (const count of seenRows.values()) if (count > 1) duplicateRows += count;
    return { success: true, route: "operation", operation: { action: "quality_check", row_count: rows.length, column_count: headers.length, missing_by_column: missingByColumn, duplicate_rows: duplicateRows, duplicate_identifier: duplicateIdentifier, source_mutated: false }, message: "Completed the read-only data quality check locally in the Excel taskpane.", local_secure: true, diagnostics, source_mutated: false };
}
async function executeSecureExcelQuery(optionsJson) {
    try {
        const options = typeof optionsJson === "string" ? JSON.parse(optionsJson) : optionsJson;
        const matrix = options && Array.isArray(options.rows) ? options.rows : [];
        const query = String(options && options.query || "").trim();
        const prepared = _securePrepareMatrix(matrix);
        const diagnostics = { input_rows: prepared.originalRows, input_columns: prepared.originalColumns, header_index: prepared.headerIndex, header_count: prepared.headers.filter(Boolean).length, data_rows: prepared.rows.length };
        if (prepared.headers.length === 0 || prepared.rows.length === 0) return JSON.stringify({ success: false, route: "operation", error: "Dataset is empty or no worksheet header/data row could be resolved.", local_secure: true, diagnostics, source_mutated: false });
        if (_secureLooksLikeQuality(query)) return JSON.stringify(_secureQuality(prepared.rows, prepared.headers, query, diagnostics));
        if (_secureLooksLikeGroup(query)) return JSON.stringify(_secureGroup(prepared.rows, prepared.headers, query, diagnostics));
        return JSON.stringify({ success: false, route: "operation", error: "This secure local engine only handles grouped counts and read-only quality checks.", local_secure: true, diagnostics, source_mutated: false });
    } catch (error) { return JSON.stringify({ success: false, route: "operation", error: `Local Excel operation failed: ${error}` }); }
}
window.executeSecureExcelQuery = executeSecureExcelQuery;
