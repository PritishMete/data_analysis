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
  function seeded(seed) {
    if (seed === null || !Number.isFinite(seed)) return Math.random;
    let state = (Math.trunc(seed) >>> 0) || 1;
    return function () {
      state = (1664525 * state + 1013904223) >>> 0;
      return state / 4294967296;
    };
  }

  function generator(config) {
    const random = seeded(config.seed);
    return () => {
      const value = config.min + (config.max - config.min) * random();
      return config.format === 'integer' ? Math.round(value) : Number(value.toFixed(2));
    };
  }

  function uniqueSheetName(existing, base) {
    const clean = String(base || 'Synthetic_Data').replace(/[\\/:?*\\[\\]]/g, '_').slice(0, 31) || 'Synthetic_Data';
    let candidate = clean;
    let n = 2;
    while (existing.some(x => String(x).toLowerCase() === candidate.toLowerCase())) {
      const suffix = '_' + n++;
      candidate = clean.slice(0, Math.max(1, 31 - suffix.length)) + suffix;
    }
    return candidate;
  }

  function uniqueColumnHeading(headers, requested) {
    const base = String(requested || 'Synthetic Value').trim() || 'Synthetic Value';
    const lower = new Set(headers.map(h => normalize(h)));
    const preferred = isRevenue(base) ? base + ' (Hypothetical)' : base + ' (Synthetic)';
    if (!lower.has(normalize(preferred))) return preferred;
    let n = 2;
    while (lower.has(normalize(preferred + ' ' + n))) n++;
    return preferred + ' ' + n;
  }

  async function executeSyntheticData(optionsJson) {
    let options;
    try { options = JSON.parse(optionsJson); } catch (_) {
      return { success: false, route: 'operation', error: 'Invalid local synthetic-data request.' };
    }
    const sourceRows = Array.isArray(options.rows) ? options.rows : [];
    if (sourceRows.length < 2 || !Array.isArray(sourceRows[0])) {
      return { success: false, route: 'operation', error: 'The current worksheet does not contain a usable header and data range.', local_secure: true, source_mutated: false };
    }
    await window.waitForOfficeReady();
    if (typeof Excel === 'undefined') {
      return { success: false, route: 'operation', error: 'Office.js is unavailable; no worksheet was changed.', local_secure: true, source_mutated: false };
    }

    const sourceSheetName = String(options.sourceSheetName || '').trim();
    const requested = String(options.columnName || requestedColumn(options.query || '')).trim();
    const revenue = options.revenue === true || isRevenue(requested);
    const min = parseNumber(options.min, 0);
    const max = parseNumber(options.max, revenue ? 100000 : 100);
    const format = options.format === 'integer' ? 'integer' : 'decimal';
    const seed = options.seed === null || options.seed === undefined || options.seed === ''
      ? null
      : Math.trunc(parseNumber(options.seed, 1));
    if (!Number.isFinite(min) || !Number.isFinite(max) || max < min) {
      return { success: false, route: 'operation', error: 'Invalid synthetic-data range.', local_secure: true, source_mutated: false };
    }

    const headers = sourceRows[0].map(v => String(v ?? '').trim());
    const targetHeading = uniqueColumnHeading(headers, requested);
    const outputBase = String(options.outputSheetName || (revenue ? 'Hypothetical_Revenue' : 'Synthetic_Data')).trim();
    const outputRows = sourceRows.map(row => Array.isArray(row) ? Array.from(row) : []);
    outputRows[0].push(targetHeading);
    const nextValue = generator({ min, max, format, seed });
    for (let i = 1; i < outputRows.length; i++) outputRows[i].push(nextValue());

    try {
      const written = await Excel.run(async context => {
        const workbook = context.workbook;
        const source = sourceSheetName
          ? workbook.worksheets.getItem(sourceSheetName)
          : workbook.worksheets.getActiveWorksheet();
        source.load('name');
        const sheets = workbook.worksheets;
        sheets.load('items/name');
        await context.sync();

        const existingNames = sheets.items.map(s => s.name);
        const existingOutputName = existingNames.find(name => String(name).toLowerCase() === outputBase.toLowerCase());
        if (existingOutputName) {
          const existingOut = workbook.worksheets.getItem(existingOutputName);
          const existingRange = existingOut.getUsedRange(true);
          existingRange.load('values');
          await context.sync();
          const existingHeaders = Array.isArray(existingRange.values) && Array.isArray(existingRange.values[0])
            ? existingRange.values[0].map(v => String(v ?? '').trim())
            : [];
          if (existingHeaders.some(h => h.toLowerCase() === targetHeading.toLowerCase())) {
            existingOut.activate();
            return {
              sheetName: existingOutputName,
              sourceSheetName: source.name,
              rowsWritten: Math.max(0, existingRange.values.length - 1),
              column: targetHeading,
              created: false,
              already_exists: true,
            };
          }
          return {
            conflict: true,
            sheetName: existingOutputName,
            error: `Output worksheet "${existingOutputName}" already exists but does not contain the requested generated column. No values were overwritten and no replacement sheet was created.`,
          };
        }

        const sheetName = uniqueSheetName(existingNames, outputBase);
        const out = workbook.worksheets.add(sheetName);
        const range = out.getRangeByIndexes(0, 0, outputRows.length, outputRows[0].length);
        range.values = outputRows;

        const idx = outputRows[0].length - 1;
        out.getRangeByIndexes(0, idx, outputRows.length, 1).format.autofitColumns();
        out.getRangeByIndexes(1, idx, Math.max(1, outputRows.length - 1), 1).numberFormat = [[format === 'integer' ? '#,##0' : '#,##0.00']];
        out.getRangeByIndexes(0, idx, 1, 1).format.font.bold = true;
        out.getRangeByIndexes(0, 0, 1, outputRows[0].length).format.font.bold = true;
        out.activate();
        await context.sync();
        return { sheetName, sourceSheetName: source.name, rowsWritten: outputRows.length - 1, column: targetHeading, created: true, already_exists: false };
      });

      if (written.conflict) {
        return {
          success: false,
          route: 'operation',
          operation: { action: 'synthetic_column', hypothetical: revenue, synthetic: !revenue },
          error: written.error,
          sheetName: written.sheetName,
          local_secure: true,
          source_mutated: false,
          overwrite: false,
          output_sheet_conflict: true
        };
      }
      const reused = written.already_exists === true;
      return {
        success: true,
        route: 'operation',
        operation: { action: 'synthetic_column', columns: [targetHeading], rows: [], hypothetical: revenue, synthetic: !revenue, created: !reused, already_exists: reused },
        message: (revenue ? 'HYPOTHETICAL REVENUE' : 'SYNTHETIC DATA') + (reused ? ' ALREADY EXISTS: ' : ' CREATED: ') + written.sheetName + '. ' + targetHeading + ' contains locally generated values and is not actual business data.',
        sheetName: written.sheetName,
        sourceSheetName: written.sourceSheetName,
        rowsWritten: written.rowsWritten,
        generated_column: targetHeading,
        hypothetical: revenue,
        synthetic: !revenue,
        generation: { min, max, format, seed, distribution: 'uniform' },
        local_secure: true,
        source_mutated: false,
        overwrite: false,
        created: !reused,
        already_exists: reused
      };
    } catch (error) {
      return { success: false, route: 'operation', error: String(error), local_secure: true, source_mutated: false };
    }
  }

  window.executeSyntheticData = executeSyntheticData;
  window.executeSecureExcelQuery = function (optionsJson) {
    let options;
    try { options = JSON.parse(optionsJson); } catch (_) { return previousExecute(optionsJson); }
    return isSyntheticRequest(options.query || '') ? executeSyntheticData(optionsJson) : previousExecute(optionsJson);
  };
  window.__insightflowSyntheticTest = { isSyntheticRequest, requestedColumn, generator };
})();
