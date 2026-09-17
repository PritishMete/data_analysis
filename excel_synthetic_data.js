// Local-only hypothetical/synthetic column generation for the Excel taskpane.
// This engine never calls a remote service and never changes the source worksheet.
(function () {
  const previousExecute = window.executeSecureExcelQuery;
  function normalize(value) { return String(value ?? '').normalize('NFKC').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim().replace(/\s+/g, ' '); }
  function isSyntheticRequest(query) {
    const q = normalize(query);
    const create = /\b(?:create|add|generate|make|fill|populate)\b/.test(q);
    const synthetic = /\b(?:hypothetical|hypothesis|synthetic|simulated|simulation|fake|sample)\b/.test(q) || /\bjust\s+fill\b/.test(q);
    const numeric = /\b(?:numbers?|numeric|values?|amounts?)\b/.test(q);
    const column = /\b(?:column|field)\b/.test(q);
    const revenue = /\b(?:revenue|sales|sale|amount|price|quantity|score|rating)\b/.test(q);
    return create && (synthetic || numeric) && (column || revenue);
  }
  function requestedColumn(query) {
    const q = normalize(query);
    const explicit = q.match(/\b(?:column|field)\s+(?:called|named)\s+([a-z0-9 _-]+)/);
    if (explicit) return explicit[1].trim().replace(/[?.,]+$/, '');
    if (/\brevenue\b/.test(q)) return 'Revenue';
    if (/\bsales?\b/.test(q)) return 'Sales Amount';
    const match = q.match(/\b(?:create|add|generate|make|fill|populate)\s+(?:a\s+|an\s+|the\s+)?([a-z0-9 _-]+?)(?:\s+column|\s+field|\s+with\b|\s+numbers?\b|\s+values?\b|\s*$)/);
    return match ? match[1].trim().replace(/[?.,]+$/, '') : 'Synthetic Value';
  }
  function isRevenue(name) { return /\brevenue\b/.test(normalize(name)) || /\bsales?\s+(?:amount|revenue)\b/.test(normalize(name)); }
  function parseNumber(value, fallback) { const n = Number(String(value ?? '').trim().replace(/,/g, '')); return Number.isFinite(n) ? n : fallback; }
  function settings(revenue) {
    const minInput = window.prompt('Synthetic data setup — minimum value:', '0');
    if (minInput === null) return null;
    const maxInput = window.prompt('Synthetic data setup — maximum value:', revenue ? '100000' : '100');
    if (maxInput === null) return null;
    let min = parseNumber(minInput, 0), max = parseNumber(maxInput, revenue ? 100000 : 100);
    if (revenue) min = Math.max(0, min);
    if (max < min) [min, max] = [max, min];
    if (revenue) min = Math.max(0, min);
    const distribution = (window.prompt('Distribution: uniform, normal, or triangular:', 'uniform') || 'uniform').trim().toLowerCase();
    const normalizedDistribution = ['uniform', 'normal', 'triangular'].includes(distribution) ? distribution : 'uniform';
    const format = (window.prompt('Number format: integer or decimal:', 'decimal') || 'decimal').trim().toLowerCase() === 'integer' ? 'integer' : 'decimal';
    const seedText = window.prompt('Optional random seed (leave blank for a fresh local sequence):', '');
    if (seedText === null) return null;
    return { min, max, distribution: normalizedDistribution, format, seed: seedText.trim() === '' ? null : Math.trunc(parseNumber(seedText, 1)) };
  }
  function seeded(seed) {
    if (seed === null || !Number.isFinite(seed)) return Math.random;
    let state = (Math.trunc(seed) >>> 0) || 1;
    return function () { state = (1664525 * state + 1013904223) >>> 0; return state / 4294967296; };
  }
  function generator(config) {
    const random = seeded(config.seed), u = () => random();
    return () => {
      let value;
      if (config.distribution === 'normal') {
        const a = Math.max(u(), Number.EPSILON), b = u(), z = Math.sqrt(-2 * Math.log(a)) * Math.cos(2 * Math.PI * b);
        value = Math.min(config.max, Math.max(config.min, (config.min + config.max) / 2 + z * (config.max - config.min) / 6));
      } else if (config.distribution === 'triangular') {
        value = config.min + (config.max - config.min) * ((u() + u()) / 2);
      } else value = config.min + (config.max - config.min) * u();
      return config.format === 'integer' ? Math.round(value) : Number(value.toFixed(2));
    };
  }
  function uniqueSheetName(existing, base) {
    const clean = String(base || 'Synthetic_Data').replace(/[\\/:?*\[\]]/g, '_').slice(0, 31) || 'Synthetic_Data';
    let candidate = clean, n = 2;
    while (existing.some(x => String(x).toLowerCase() === candidate.toLowerCase())) { const suffix = `_${n++}`; candidate = clean.slice(0, Math.max(1, 31 - suffix.length)) + suffix; }
    return candidate;
  }
  async function getWorksheetNamesLocal() {
    await window.waitForOfficeReady();
    if (typeof Excel === 'undefined') return [];
    return Excel.run(async context => { const sheets = context.workbook.worksheets; sheets.load('items/name'); await context.sync(); return sheets.items.map(s => s.name); });
  }
  async function getActiveWorksheetNameLocal() {
    await window.waitForOfficeReady();
    if (typeof Excel === 'undefined') return null;
    return Excel.run(async context => { const sheet = context.workbook.worksheets.getActiveWorksheet(); sheet.load('name'); await context.sync(); return sheet.name; });
  }
  async function executeSynthetic(optionsJson) {
    let options;
    try { options = JSON.parse(optionsJson); } catch (_) { return { success: false, route: 'operation', error: 'Invalid local synthetic-data request.' }; }
    const sourceRows = Array.isArray(options.rows) ? options.rows : [], query = String(options.query || '');
    if (!isSyntheticRequest(query)) return previousExecute(optionsJson);
    if (sourceRows.length < 2 || !Array.isArray(sourceRows[0])) return { success: false, route: 'operation', error: 'The current worksheet does not contain a usable header and data range.', local_secure: true, source_mutated: false };
    await window.waitForOfficeReady();
    if (typeof Excel === 'undefined') return { success: false, route: 'operation', error: 'Office.js is unavailable; no worksheet was changed.', local_secure: true, source_mutated: false };
    const sourceSheetName = await getActiveWorksheetNameLocal();
    const headers = sourceRows[0].map(v => String(v ?? '').trim());
    const column = requestedColumn(query), revenue = isRevenue(column) || /\brevenue\b/.test(normalize(query));
    const config = settings(revenue);
    if (!config) return { success: false, route: 'operation', error: 'Synthetic data generation was cancelled before writing.', local_secure: true, source_mutated: false, cancelled: true };
    const targetHeading = `${column} (${revenue ? 'Hypothetical' : 'Synthetic'})`;
    const existingIndex = headers.findIndex(h => normalize(h) === normalize(column) || normalize(h) === normalize(targetHeading));
    if (existingIndex >= 0) {
      const overwrite = window.confirm(`The worksheet already contains a column named "${headers[existingIndex]}". Overwrite it in the synthetic output? The original worksheet will remain unchanged.`);
      if (!overwrite) return { success: false, route: 'operation', error: 'Synthetic generation cancelled; the existing column was not overwritten.', local_secure: true, source_mutated: false, cancelled: true };
    }
    const currency = revenue ? (window.prompt('Currency symbol for the hypothetical revenue column:', '₹') || '₹').trim() : '';
    const outputName = uniqueSheetName(await getWorksheetNamesLocal(), revenue ? 'Hypothetical_Revenue' : 'Synthetic_Data');
    const method = `${config.distribution} distribution, ${config.format} values`;
    const confirmation = window.confirm(
      `Create hypothetical data?\n\nGenerated values are HYPOTHETICAL, not actual business ${revenue ? 'revenue' : 'data'}.\n` +
      `Source worksheet: ${sourceSheetName || 'active worksheet'}\nOutput worksheet: ${outputName}\nColumn: ${targetHeading}\n` +
      `Range: ${config.min} to ${config.max}\nMethod: ${method}${config.seed === null ? '' : `, seed ${config.seed}`}\n` +
      `${revenue ? `Currency format: ${currency}#,##0.00\n` : ''}` +
      `Existing value overwrite: ${existingIndex >= 0 ? 'YES — only in the new synthetic sheet' : 'NO'}\n\nWrite the synthetic dataset now?`
    );
    if (!confirmation) return { success: false, route: 'operation', error: 'Synthetic data generation was cancelled before writing.', local_secure: true, source_mutated: false, cancelled: true };

    const nextValue = generator(config), outputRows = sourceRows.map(row => Array.isArray(row) ? Array.from(row) : []);
    if (existingIndex >= 0) {
      outputRows[0][existingIndex] = targetHeading;
      for (let i = 1; i < outputRows.length; i++) { while (outputRows[i].length < headers.length) outputRows[i].push(''); outputRows[i][existingIndex] = nextValue(); }
    } else {
      outputRows[0].push(targetHeading);
      for (let i = 1; i < outputRows.length; i++) outputRows[i].push(nextValue());
    }
    const written = await Excel.run(async context => {
      const workbook = context.workbook, source = workbook.worksheets.getActiveWorksheet(), sheets = workbook.worksheets;
      source.load('name'); sheets.load('items/name'); await context.sync();
      const sheetName = uniqueSheetName(sheets.items.map(s => s.name), outputName), out = workbook.worksheets.add(sheetName);
      const range = out.getRangeByIndexes(0, 0, outputRows.length, outputRows[0].length); range.values = outputRows;
      const idx = existingIndex >= 0 ? existingIndex : outputRows[0].length - 1;
      if (revenue) out.getRangeByIndexes(1, idx, Math.max(1, outputRows.length - 1), 1).numberFormat = [[`${currency}#,##0.00`]];
      out.getRangeByIndexes(0, idx, 1, 1).format.font.bold = true;
      out.activate(); await context.sync();
      return { sheetName, sourceSheetName: source.name, rowsWritten: outputRows.length - 1, column: targetHeading };
    });
    return { success: true, route: 'operation', operation: { action: 'synthetic_column', columns: [targetHeading], rows: [], hypothetical: true }, message: `${revenue ? 'HYPOTHETICAL REVENUE' : 'SYNTHETIC DATA'} CREATED: ${written.sheetName}. ${targetHeading} contains locally generated values and is not actual business data.`, sheetName: written.sheetName, sourceSheetName: written.sourceSheetName, rowsWritten: written.rowsWritten, generated_column: targetHeading, hypothetical: true, generation: config, local_secure: true, source_mutated: false };
  }
  window.executeSecureExcelQuery = function (optionsJson) {
    let options; try { options = JSON.parse(optionsJson); } catch (_) { return previousExecute(optionsJson); }
    return isSyntheticRequest(options.query || '') ? executeSynthetic(optionsJson) : previousExecute(optionsJson);
  };
  window.__insightflowSyntheticTest = { isSyntheticRequest, requestedColumn, generator };
})();
