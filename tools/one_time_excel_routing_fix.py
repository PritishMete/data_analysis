from pathlib import Path

ROOT = Path('.')

screen = ROOT / 'flutter_detail_source/lib/features/dashboard/data_screen.dart'
text = screen.read_text(encoding='utf-8')
if 'Future<bool> _tryExecuteSecureExcelLocalQuery' not in text:
    anchor = '  Future<bool> _tryExecuteLocalNaturalFilterQuery(String query) async {'
    helper = '''  // Secure grouped-count and quality requests are claimed before the generic
  // filter planner. Grouped analytics must never be interpreted as row filters.
  Future<bool> _tryExecuteSecureExcelLocalQuery(String query) async {
    if (!secureLocalOnly || !SecureExcelLocalService.supportsQuery(query)) {
      return false;
    }
    await _executeSmartQuery(query);
    return true;
  }

'''
    if anchor not in text:
        raise SystemExit('routing anchor not found')
    text = text.replace(anchor, helper + anchor, 1)
old = '''    // Gemini is the primary natural-language planner. It receives only the
    // user query + detected column names; the workbook rows stay local. The
    // returned structured predicates are validated and executed locally.
    final bool localFilterHandled = await _tryExecuteLocalNaturalFilterQuery(
      query,
    );
'''
new = '''    // Secure worksheet analytics must win over generic filter interpretation.
    final bool localSecureHandled = await _tryExecuteSecureExcelLocalQuery(query);
    if (localSecureHandled) return;

    // Gemini is the primary natural-language planner. It receives only the
    // user query + detected column names; the workbook rows stay local. The
    // returned structured predicates are validated and executed locally.
    final bool localFilterHandled = await _tryExecuteLocalNaturalFilterQuery(
      query,
    );
'''
if old not in text:
    raise SystemExit('processChatQuery routing block not found')
text = text.replace(old, new, 1)
old_group = '''        if (action == 'group') {
          final columns = operation['columns'] is List
              ? List<dynamic>.from(operation['columns'])
              : <dynamic>[];
          final resultRows = operation['rows'] is List
              ? List<dynamic>.from(operation['rows'])
              : <dynamic>[];
          final tableText = _formatSqlResultAsText(columns, resultRows);
          setState(() {
            isSearchingChat = false;
            chatHistory.add({
              "sender": "system",
              "text": "${localResult['message'] ?? 'Here is what I found:'}\\n\\n$tableText",
            });
          });
'''
new_group = '''        if (action == 'group') {
          final columns = operation['columns'] is List
              ? List<dynamic>.from(operation['columns'])
              : <dynamic>[];
          final resultRows = operation['rows'] is List
              ? List<dynamic>.from(operation['rows'])
              : <dynamic>[];
          final tableText = _formatSqlResultAsText(columns, resultRows);
          String sheetNote = "";
          try {
            final agentName = await suggestAgenticSheetName(
              query: userText,
              operation: "query_result",
              context: {
                "result_columns": columns.map((e) => e.toString()).toList(),
              },
            );
            final sheetName = _sanitizeSheetName(
              agentName ??
                  _queryDerivedSheetName(userText, fallback: "Query_Result"),
            );
            final writeResult = await writeQueryResultToSheet(
              json.encode({
                "targetSheetName": sheetName,
                "columns": columns,
                "rows": resultRows,
              }),
            );
            if (writeResult["success"] == true) {
              sheetNote = "\\n\\n📄 Created and switched to sheet '$sheetName'.";
              await refreshWorksheetNames();
              await syncHeadersSilently();
            } else {
              sheetNote =
                  "\\n\\n⚠️ Could not write results to a sheet: ${writeResult['error'] ?? 'unknown error'}";
            }
          } catch (e) {
            sheetNote = "\\n\\n⚠️ Could not write results to a sheet: $e";
          }
          setState(() {
            isSearchingChat = false;
            chatHistory.add({
              "sender": "system",
              "text": "${localResult['message'] ?? 'Here is what I found:'}\\n\\n$tableText$sheetNote",
            });
          });
'''
if old_group not in text:
    raise SystemExit('group rendering block not found')
text = text.replace(old_group, new_group, 1)
screen.write_text(text, encoding='utf-8')

service = ROOT / 'flutter_detail_source/lib/core/services/secure_excel_local_service_web.dart'
service_text = service.read_text(encoding='utf-8')
old_support = """    final hasDuplicate = RegExp(r'\\b(?:duplicate|duplicates|duplicated)\\b').hasMatch(lower);\n    if (hasCheckVerb && hasMissing && hasDuplicate) return true;"""
new_support = """    final hasDuplicate = RegExp(r'\\b(?:duplicate|duplicates|duplicated)\\b').hasMatch(lower);\n    final hasIdentifierReference = RegExp(r'\\b(?:restaurant\\s*ids?|restaurant[_ ]?identifier|duplicates?\\s+[a-z0-9_]+\\s+(?:values?|ids?))\\b').hasMatch(lower);\n    if (hasCheckVerb && (hasMissing || hasDuplicate) && (hasMissing || hasIdentifierReference)) return true;"""
if old_support not in service_text:
    raise SystemExit('secure service support block not found')
service.write_text(service_text.replace(old_support, new_support, 1), encoding='utf-8')

js = ROOT / 'flutter_detail_source/web/excel_secure_query.js'
js.write_text(r'''// Deterministic secure Excel operations. The only input is the worksheet
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
''', encoding='utf-8')

test = ROOT / 'flutter_detail_source/test/excel_secure_query_test.js'
test.write_text(r'''const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const source = fs.readFileSync(require('path').join(__dirname, '..', 'web', 'excel_secure_query.js'), 'utf8');
const context = { window: {}, console };
vm.createContext(context);
vm.runInContext(source, context);
async function execute(rows, query) { return JSON.parse(await context.window.executeSecureExcelQuery(JSON.stringify({ rows, query }))); }
async function run() {
  const rows = [
    ['Restaurant ID', 'Restaurant Name', 'City', 'Aggregate rating'],
    [101, 'A', 'Delhi', 4.5], [102, 'B', 'Mumbai', 3.2], [102, 'C', 'Delhi', 4.1], [103, 'D', '', 4.8], [104, 'E', null, 2.9],
  ];
  const original = JSON.parse(JSON.stringify(rows));
  for (const query of ['Show the number of restaurants in each city', 'Count restaurants by city']) {
    const r = await execute(rows, query); assert.strictEqual(r.success, true); assert.strictEqual(r.operation.action, 'group'); assert.deepStrictEqual(r.operation.columns, ['City', 'count']); assert.deepStrictEqual(r.operation.rows, [{ City: 'Delhi', count: 2 }, { City: 'Mumbai', count: 1 }, { City: null, count: 2 }]); assert.strictEqual(r.source_mutated, false); assert.ok(!JSON.stringify(r).includes('filter_rows'));
  }
  for (const header of ['Restaurant ID', 'RestaurantID', 'restaurant_id', 'restaurant id']) {
    const matrix = rows.map((r, i) => i === 0 ? [header, r[1], r[2], r[3]] : r.slice());
    const r = await execute(matrix, 'Check for missing values and duplicate restaurant IDs'); assert.strictEqual(r.operation.duplicate_identifier.status, 'ok'); assert.strictEqual(r.operation.duplicate_identifier.column, header); assert.deepStrictEqual(r.operation.duplicate_identifier.values, [102]); assert.strictEqual(r.operation.duplicate_identifier.duplicate_row_count, 2);
  }
  const variation = await execute(rows, 'Find duplicate RestaurantID values'); assert.strictEqual(variation.operation.duplicate_identifier.column, 'Restaurant ID'); assert.deepStrictEqual(variation.operation.duplicate_identifier.values, [102]);
  const ambiguous = await execute([['Restaurant ID', 'restaurant_id', 'City'], [1, 2, 'Delhi'], [1, 2, 'Mumbai']], 'Check missing values and duplicate identifiers'); assert.strictEqual(ambiguous.operation.duplicate_identifier.status, 'ambiguous_identifier');
  const notFound = await execute([['Restaurant Name', 'City'], ['A', 'Delhi']], 'Check for missing values and duplicate restaurant IDs'); assert.strictEqual(notFound.operation.duplicate_identifier.status, 'identifier_not_found');
  assert.deepStrictEqual(rows, original);
  console.log('excel_secure_query_test.js: all assertions passed');
}
run().catch(e => { console.error(e); process.exitCode = 1; });
''', encoding='utf-8')

# Remove the temporary patcher files after this run. They are intentionally
# not part of the final product tree.
for path in [ROOT / '.github/workflows/excel-routing-fix.yml', ROOT / 'tools/one_time_excel_routing_fix.py']:
    if path.exists(): path.unlink()
