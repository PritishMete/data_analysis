// Deterministic secure Excel operations. The only input is the worksheet
// matrix already read by the taskpane. There is no fetch/XHR/network path.
function _secureNormalize(value) {
    return String(value ?? "").normalize("NFKC").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().replace(/\s+/g, " ");
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
    const aliases = { city: ["city", "town", "municipality", "locality"], country: ["country", "country name", "nation"], restaurant: ["restaurant name", "restaurant"] };
    for (const alias of Object.keys(aliases)) {
        if (wanted === alias || aliases[alias].includes(wanted)) {
            hit = names.filter(x => aliases[alias].includes(x.n));
            if (hit.length === 1) return hit[0].i;
        }
    }
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
    if (!match) return -1;
    return _secureResolveColumn(headers, match[1].trim().replace(/^(the|a|an)\s+/, ""));
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
        const wanted = _secureNormalize(requested).replace(/\bids\b/g, "id");
        const candidates = names.filter(x => x.n.replace(/\bids\b/g, "id") === wanted);
        return { index: candidates.length === 1 ? candidates[0].i : -1, requested, candidates };
    }
    const candidates = names.filter(x => /(^| )(restaurant )?(id|identifier)( |$)/.test(x.n));
    return { index: candidates.length === 1 ? candidates[0].i : -1, requested: null, candidates };
}
function _secureGroup(rows, headers, query) {
    const index = _secureInferGroupColumn(headers, query);
    if (index < 0) return { success: false, route: "operation", operation: { action: "group" }, error: "Could not resolve a unique grouping column from the current worksheet." };
    const groups = new Map();
    for (const row of rows) {
        const key = _secureMissing(row[index]) ? null : row[index];
        const mapKey = key === null ? "__NULL__" : `${typeof key}:${String(key)}`;
        if (!groups.has(mapKey)) groups.set(mapKey, { [headers[index]]: key, count: 0 });
        groups.get(mapKey).count += 1;
    }
    const resultRows = Array.from(groups.values());
    return { success: true, route: "operation", operation: { action: "group", group_by: [headers[index]], columns: [headers[index], "count"], rows: resultRows, row_count: resultRows.length, source_mutated: false }, message: `Counted records by ${headers[index]} locally (${resultRows.length} groups).`, local_secure: true, source_mutated: false };
}
function _secureQuality(rows, headers, query) {
    const missingByColumn = {};
    for (let i = 0; i < headers.length; i++) { let count = 0; for (const row of rows) if (_secureMissing(row[i])) count++; if (count) missingByColumn[String(headers[i])] = count; }
    const resolution = _secureIdentifierResolution(headers, query);
    let duplicateIdentifier = { status: "identifier_not_selected", message: "No unique identifier column was found for duplicate-ID analysis.", requested_column: resolution.requested, candidates: resolution.candidates.map(x => x.name), column: null, duplicate_value_count: 0, duplicate_row_count: 0, values: [] };
    if (resolution.index < 0) {
        if (resolution.requested) { duplicateIdentifier.status = resolution.candidates.length > 1 ? "ambiguous_identifier" : "identifier_not_found"; duplicateIdentifier.message = resolution.candidates.length > 1 ? `Requested identifier "${resolution.requested}" is ambiguous; candidates: ${resolution.candidates.map(x => x.name).join(", ")}.` : `Could not resolve requested identifier column "${resolution.requested}" from the current worksheet.`; }
        else if (resolution.candidates.length > 1) { duplicateIdentifier.status = "ambiguous_identifier"; duplicateIdentifier.message = `Multiple identifier candidates found: ${resolution.candidates.map(x => x.name).join(", ")}.`; }
    } else {
        const counts = new Map();
        for (const row of rows) { const value = row[resolution.index]; if (_secureMissing(value)) continue; const key = `${typeof value}:${String(value).trim()}`; const existing = counts.get(key); if (existing) existing.count++; else counts.set(key, { value: typeof value === "string" ? value.trim() : value, count: 1 }); }
        const duplicates = Array.from(counts.values()).filter(x => x.count > 1);
        duplicateIdentifier = { status: "ok", requested_column: resolution.requested, candidates: resolution.candidates.map(x => x.name), column: String(headers[resolution.index]), duplicate_value_count: duplicates.length, duplicate_row_count: duplicates.reduce((sum, x) => sum + x.count, 0), values: duplicates.map(x => x.value) };
    }
    const seenRows = new Map();
    for (const row of rows) { const key = JSON.stringify(row.map(v => v === undefined ? null : v)); seenRows.set(key, (seenRows.get(key) || 0) + 1); }
    let duplicateRows = 0; for (const count of seenRows.values()) if (count > 1) duplicateRows += count;
    return { success: true, route: "operation", operation: { action: "quality_check", row_count: rows.length, column_count: headers.length, missing_by_column: missingByColumn, duplicate_rows: duplicateRows, duplicate_identifier: duplicateIdentifier, source_mutated: false }, message: "Completed the read-only data quality check locally in the Excel taskpane.", local_secure: true, source_mutated: false };
}
async function executeSecureExcelQuery(optionsJson) {
    try {
        const options = typeof optionsJson === "string" ? JSON.parse(optionsJson) : optionsJson;
        const matrix = options && Array.isArray(options.rows) ? options.rows : [];
        const query = String(options && options.query || "").trim();
        if (matrix.length < 2 || !Array.isArray(matrix[0]) || matrix[0].length === 0) return JSON.stringify({ success: false, route: "operation", error: "Dataset is empty or has no header row." });
        const headers = matrix[0].map(x => String(x ?? "").trim()), rows = matrix.slice(1).filter(Array.isArray);
        if (_secureLooksLikeQuality(query)) return JSON.stringify(_secureQuality(rows, headers, query));
        if (_secureLooksLikeGroup(query)) return JSON.stringify(_secureGroup(rows, headers, query));
        return JSON.stringify({ success: false, route: "operation", error: "This secure local engine only handles grouped counts and read-only quality checks." });
    } catch (error) { return JSON.stringify({ success: false, route: "operation", error: `Local Excel operation failed: ${error}` }); }
}
window.executeSecureExcelQuery = executeSecureExcelQuery;
