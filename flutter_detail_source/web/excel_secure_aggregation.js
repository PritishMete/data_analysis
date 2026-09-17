// Extension of the existing secure Excel taskpane engine for generic analytical
// aggregations. It runs after excel_secure_query.js and delegates all existing
// grouped-count/quality requests to that engine; only aggregation requests are
// handled here. No network or workbook mutation is performed.
(function () {
  const previousExecute = window.executeSecureExcelQuery;
  function normalize(value) { return String(value ?? '').normalize('NFKC').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim().replace(/\s+/g, ' '); }
  function compact(value) { return normalize(value).replace(/\s+/g, ''); }
  function blank(value) { return value === null || value === undefined || String(value).trim() === ''; }
  function prepare(matrix) {
    if (!Array.isArray(matrix)) return { headers: [], rows: [], headerIndex: -1 };
    const first = matrix.findIndex(r => Array.isArray(r) && r.some(v => !blank(v)));
    if (first < 0) return { headers: [], rows: [], headerIndex: -1 };
    const width = Math.max(0, ...matrix.slice(first).filter(Array.isArray).map(r => r.length));
    const rows = matrix.slice(first).filter(Array.isArray).map(r => { const out = Array.from(r); while (out.length < width) out.push(''); return out.slice(0, width); });
    if (rows.length < 2 || width === 0) return { headers: [], rows: [], headerIndex: -1 };
    return { headers: rows[0].map(v => String(v ?? '').trim()), rows: rows.slice(1).filter(r => !r.every(blank)), headerIndex: first };
  }
  function infos(headers) { return headers.map((name, i) => ({ i, name, n: normalize(name), c: compact(name) })).filter(x => x.name); }

  function resolve(headers, requested) {
    const wanted = normalize(requested);
    if (!wanted) return { index: -1, requested: '', candidates: [] };
    const list = infos(headers);
    let hits = list.filter(x => x.n === wanted);
    if (hits.length === 1) return { index: hits[0].i, requested, candidates: hits };
    if (hits.length > 1) return { index: -1, requested, candidates: hits };
    const wantedCompact = compact(wanted);
    hits = list.filter(x => x.c === wantedCompact);
    if (hits.length === 1) return { index: hits[0].i, requested, candidates: hits };
    if (hits.length > 1) return { index: -1, requested, candidates: hits };
    const variants = new Set([wanted]);
    if (wanted.endsWith('ies')) variants.add(wanted.slice(0, -3) + 'y');
    if (wanted.endsWith('s')) variants.add(wanted.slice(0, -1));
    hits = list.filter(x => variants.has(x.n));
    if (hits.length === 1) return { index: hits[0].i, requested, candidates: hits };
    if (hits.length > 1) return { index: -1, requested, candidates: hits };

    const aliases = {
      city: ['city', 'city name', 'city_name', 'town', 'municipality', 'locality'],
      region: ['region', 'region name', 'state', 'state name', 'province', 'area'],
      country: ['country', 'country name', 'nation'],
      category: ['category', 'category name', 'type', 'class', 'classification'],
      price: ['price', 'unit price', 'sale price', 'selling price', 'amount'],
      amount: ['amount', 'sales amount', 'sale amount', 'total amount', 'value', 'revenue', 'sales'],
      rating: ['rating', 'average rating', 'aggregate rating', 'score', 'rating score'],
    };
    for (const key of Object.keys(aliases)) {
      if (variants.has(key) || aliases[key].some(alias => variants.has(alias))) {
        hits = list.filter(x => aliases[key].includes(x.n));
        if (hits.length === 1) return { index: hits[0].i, requested, candidates: hits };
        if (hits.length > 1) return { index: -1, requested, candidates: hits };
      }
    }

    const stop = new Set(['the','a','an','of','by','per','each','has','have','with','for','restaurant','restaurants','value','values','column','field']);
    const tokens = wanted.split(' ').filter(t => t.length >= 2 && !stop.has(t));
    const scored = list.map(x => { const xt = new Set(x.n.split(' ')); let score = 0; for (const t of tokens) if (xt.has(t)) score += 3; for (const t of tokens) if (x.n.includes(t)) score += 1; return { ...x, score }; }).filter(x => x.score > 0).sort((a,b) => b.score - a.score);
    if (scored.length && (scored.length === 1 || scored[0].score > scored[1].score)) return { index: scored[0].i, requested, candidates: [scored[0]] };
    if (scored.length) return { index: -1, requested, candidates: scored.filter(x => x.score === scored[0].score) };
    return { index: -1, requested, candidates: [] };
  }

  function looksLikeAggregation(query) {
    const q = normalize(query);
    return /\b(?:average|avg|mean|sum|total|count|minimum|min|maximum|max|highest|lowest|top|bottom)\b/.test(q) && /\b(?:by|per|each|group(?:ed)?\s+by|which|what)\b/.test(q);
  }
  function parse(query) {
    const q = normalize(query);
    let mode = 'average';
    if (/\b(?:sum|total)\b/.test(q)) mode = 'sum';
    else if (/\bcount\b|\bhow many\b/.test(q)) mode = 'count';
    else if (/\b(?:average|avg|mean)\b/.test(q)) mode = 'average';
    else if (/\b(?:minimum|min|lowest)\b/.test(q)) mode = 'min';
    else if (/\b(?:maximum|max|highest)\b/.test(q)) mode = 'max';
    const explicitN = q.match(/\b(?:top|bottom)\s+(\d+)\b");
    const direction = /\b(?:bottom|lowest|min|minimum)\b/.test(q) ? 'asc' : 'desc';
    const limit = explicitN ? Number(explicitN[1]) : null;
    let groupText = '';
    const ranked = q.match(/\b(?:top|bottom)\s+\d+\s+(.+?)\s+by\s+(.+?)(?:\?|$)/);
    const by = q.match(/\b(?:by|per|each|group(?:ed)?\s+by)\s+(.+?)(?:\?|$)/);
    if (ranked) groupText = ranked[1].trim(); else if (by) groupText = by[1].trim();
    if (!groupText) { const which = q.match(/\bwhich\s+(.+?)\s+(?:has|have|with)\b/); if (which) groupText = which[1].trim(); }
    if (!groupText) { const what = q.match(/\bwhat\s+(.+?)\s+(?:has|have|with)\b/); if (what) groupText = what[1].trim(); }
    groupText = groupText.replace(/^(the|a|an)\s+/, '').trim();
    let measureText = '';
    if (ranked) measureText = ranked[2].trim().replace(/\b(?:highest|lowest|maximum|minimum)\s+/, '').replace(/\b(?:average|avg|mean|sum|total|count)\b\s*/, '').trim();
    else if (by) { const beforeBy = q.slice(0, by.index).trim(); measureText = beforeBy.replace(/^which\s+.+?\s+(?:has|have)\s+/, '').replace(/^what\s+is\s+/, '').replace(/^(show|calculate|give|find|report)\s+/, '').replace(/\b(?:top|bottom)\s+\d+\s+/, '').replace(/\b(?:highest|lowest|maximum|minimum)\s+/, '').replace(/\b(?:average|avg|mean|sum|total|count)\b\s*/, '').trim(); }
    else { const has = q.match(/\b(?:has|have|with)\s+(.+?)(?:\?|$)/); if (has) measureText = has[1].replace(/^(the|a|an)\s+/, '').trim(); }
    return { mode, direction, limit, groupText, measureText };
  }
  function numeric(value) { if (typeof value === 'number' && Number.isFinite(value)) return value; if (typeof value !== 'string') return null; const cleaned = value.trim().replace(/,/g, ''); if (!cleaned) return null; const n = Number(cleaned); return Number.isFinite(n) ? n : null; }

  function aggregate(matrix, query) {
    const prepared = prepare(matrix);
    const diagnostics = { input_rows: Array.isArray(matrix) ? matrix.length : 0, input_columns: Array.isArray(matrix) ? Math.max(0, ...matrix.filter(Array.isArray).map(r => r.length)) : 0, header_index: prepared.headerIndex, header_count: prepared.headers.filter(Boolean).length, data_rows: prepared.rows.length, aggregation_resolution: 'pending', source_mutated: false };
    if (!prepared.headers.length || !prepared.rows.length) return { success:false, route:'operation', error:'Dataset is empty or no worksheet header/data row could be resolved.', local_secure:true, diagnostics, source_mutated:false };
    const spec = parse(query);
    const group = resolve(prepared.headers, spec.groupText);
    diagnostics.group_requested = spec.groupText;
    diagnostics.group_resolution = group.index >= 0 ? 'resolved' : (group.candidates.length > 1 ? 'ambiguous' : 'not_found');
    if (group.index < 0) { const detail = group.candidates.length > 1 ? `Grouping column "${spec.groupText}" is ambiguous; candidates: ${group.candidates.map(x=>x.name).join(', ')}.` : `Could not resolve grouping column "${spec.groupText || 'requested field'}" from the current worksheet schema.`; return { success:false, route:'operation', operation:{action:'aggregate', candidates:group.candidates.map(x=>x.name)}, error:detail, local_secure:true, diagnostics, source_mutated:false }; }
    diagnostics.resolved_group_column = prepared.headers[group.index];
    let measure = { index: -1, requested: spec.measureText, candidates: [] };
    if (spec.mode !== 'count') {
      measure = resolve(prepared.headers, spec.measureText);
      diagnostics.measure_resolution = measure.index >= 0 ? 'resolved' : (measure.candidates.length > 1 ? 'ambiguous' : 'not_found');
      diagnostics.measure_requested = spec.measureText;
      if (measure.index < 0) { const detail = measure.candidates.length > 1 ? `Measurement column "${spec.measureText}" is ambiguous; candidates: ${measure.candidates.map(x=>x.name).join(', ')}.` : `Could not resolve measurement column "${spec.measureText || 'requested field'}" from the current worksheet schema.`; return { success:false, route:'operation', operation:{action:'aggregate', candidates:measure.candidates.map(x=>x.name)}, error:detail, local_secure:true, diagnostics, source_mutated:false }; }
      diagnostics.resolved_measure_column = prepared.headers[measure.index];
    } else diagnostics.measure_resolution = 'not_required';
    const groups = new Map();
    for (const row of prepared.rows) { const key = blank(row[group.index]) ? null : row[group.index]; const mapKey = key === null ? '__NULL__' : `${typeof key}:${String(key)}`; if (!groups.has(mapKey)) groups.set(mapKey, { key, values: [], count: 0 }); const bucket = groups.get(mapKey); bucket.count++; if (measure.index >= 0) { const n = numeric(row[measure.index]); if (n !== null) bucket.values.push(n); } }
    const output = [];
    for (const bucket of groups.values()) { let value = bucket.count; if (spec.mode !== 'count') { if (!bucket.values.length) continue; if (spec.mode === 'sum') value = bucket.values.reduce((a,b)=>a+b,0); else if (spec.mode === 'min') value = Math.min(...bucket.values); else if (spec.mode === 'max') value = Math.max(...bucket.values); else value = bucket.values.reduce((a,b)=>a+b,0) / bucket.values.length; } output.push({ key: bucket.key, value, count: bucket.count, valid_measurements: bucket.values.length }); }
    output.sort((a,b) => spec.direction === 'asc' ? a.value - b.value : b.value - a.value);
    const namedOutput = output.filter(x => x.key !== null);
    let selected = output;
    if (spec.limit !== null) selected = namedOutput.slice(0, spec.limit);
    else if (/\b(?:highest|lowest|max(?:imum)?|min(?:imum)?)\b/.test(normalize(query))) { if (namedOutput.length) { const best = namedOutput[0].value; selected = namedOutput.filter(x => x.value === best); } }
    const aggregateLabel = spec.mode === 'average' ? 'average' : spec.mode;
    const valueColumn = aggregateLabel;
    const rows = selected.map(x => ({ [prepared.headers[group.index]]: x.key, [valueColumn]: Number.isInteger(x.value) ? x.value : Number(x.value.toFixed(10)) }));
    const columns = [prepared.headers[group.index], valueColumn];
    diagnostics.aggregation_resolution = 'resolved'; diagnostics.group_count = output.length; diagnostics.named_group_count = namedOutput.length; diagnostics.returned_group_count = rows.length; diagnostics.operation = `${spec.mode}_by_group`;
    return { success:true, route:'operation', operation:{ action:'aggregate', group_by:[prepared.headers[group.index]], measure:measure.index >= 0 ? prepared.headers[measure.index] : null, aggregation:spec.mode, sort:spec.direction, limit:spec.limit, columns, rows, row_count:rows.length, source_mutated:false }, message:`Calculated ${aggregateLabel} by ${prepared.headers[group.index]} locally (${rows.length} result groups).`, local_secure:true, diagnostics, source_mutated:false };
  }

  window.executeSecureExcelQuery = async function (optionsJson) {
    try {
      const options = typeof optionsJson === 'string' ? JSON.parse(optionsJson) : optionsJson;
      const query = String(options && options.query || '').trim();
      const normalized = normalize(query);
      const existingGroupedCount = /\b(?:count|how many|number of)\b/.test(normalized) && /\b(?:each|per|by|group(?:ed)?\s+by)\b/.test(normalized);
      if (existingGroupedCount) return previousExecute(optionsJson);
      if (looksLikeAggregation(query)) return JSON.stringify(aggregate(options && Array.isArray(options.rows) ? options.rows : [], query));
      return previousExecute(optionsJson);
    } catch (error) { return JSON.stringify({ success:false, route:'operation', error:`Local Excel operation failed: ${error}`, local_secure:true, source_mutated:false }); }
  };
})();
