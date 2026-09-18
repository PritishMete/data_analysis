const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

const synthetic = fs.readFileSync('web/excel_synthetic_data.js', 'utf8');
const source = [['City', 'Restaurant ID'], ['Delhi', 1], ['Delhi', 2], ['Mumbai', 3]];
const workbookSource = [['Product', 'City', 'Restaurant ID'], ['Pizza', 'Delhi', 1], ['Burger', 'Delhi', 2], ['Pasta', 'Mumbai', 3]];
const original = JSON.parse(JSON.stringify(source));
const createdWrites = [];
const activeSheet = { name: 'Restaurants', load() {}, getUsedRange() { return { values: workbookSource, load() {} }; } };
const sheets = [activeSheet];
const workbook = {
  worksheets: {
    items: sheets, load() {},
    getActiveWorksheet() { return activeSheet; },
    getItem(name) { const found = sheets.find(s => s.name === name); if (found) return found; throw new Error('missing worksheet'); },
    add(name) {
      const out = { name, getUsedRange() { return { values: this.__values || [], load() {} }; }, getRangeByIndexes() {
        const range = {
          numberFormat: null,
          format: { font: { bold: false }, autofitColumns() {} },
          getColumn() { return { format: { autofitColumns() {} } }; }
        };
        Object.defineProperty(range, 'values', {
          get() { return out.__values; },
          set(value) { out.__values = value; },
          configurable: true
        });
        return range;
      }, activate() {}, __values: null };
      sheets.push(out); createdWrites.push(name); return out;
    },
  },
};
const context = {
  window: { executeSecureExcelQuery: async () => ({ success: true, delegated: true }), waitForOfficeReady: async () => {} },
  Excel: { run: async fn => fn({ workbook, sync: async () => {} }) },
  Math, Number, String, Array, Set, JSON, Promise, console,
};
vm.createContext(context);
vm.runInContext(synthetic, context);
const api = context.window.__insightflowSyntheticTest;
assert(api);
assert.strictEqual(api.isSyntheticRequest('ok create revenue column and just fill hypothesis numbers there'), true);
assert.strictEqual(api.isSyntheticRequest('create a hypothetical revenue column'), true);
assert.strictEqual(api.isSyntheticRequest('create a synthetic score column'), true);
assert.strictEqual(api.isSyntheticRequest('What is the average rating by city?'), false);
assert.strictEqual(api.requestedColumn('ok create revenue column and just fill hypothesis numbers there'), 'Revenue');
assert.strictEqual(api.requestedColumn('create a column named Sales Amount'), 'sales amount');

const first = Array.from({length: 5}, () => api.generator({min: 0, max: 1000, format: 'decimal', seed: 42})());
const second = Array.from({length: 5}, () => api.generator({min: 0, max: 1000, format: 'decimal', seed: 42})());
assert.deepStrictEqual(first, second);
assert(first.every(v => v >= 0 && v <= 1000));
assert(Number.isInteger(api.generator({min: 10, max: 20, format: 'integer', seed: 7})()));
assert(!/window\.(?:prompt|confirm|alert)\s*\(/.test(synthetic));
assert(!/\b(?:prompt|confirm|alert)\s*\(/.test(synthetic));

(async () => {
  const result = await context.window.executeSyntheticData(JSON.stringify({
    rows: source, query: 'ok create revenue column and just fill hypothesis numbers there',
    sourceSheetName: 'Restaurants', columnName: 'Revenue', min: 0, max: 1000,
    format: 'decimal', seed: 42, outputSheetName: 'Hypothetical_Revenue', revenue: true
  }));
  assert.strictEqual(result.success, true);
  assert.strictEqual(result.hypothetical, true);
  assert.strictEqual(result.source_mutated, false);
  assert.strictEqual(result.generated_column, 'Revenue (Hypothetical)');
  assert(result.sheetName.startsWith('Hypothetical_Revenue'));
  assert.strictEqual(result.generation.min, 0);
  assert.strictEqual(result.generation.max, 1000);
  assert.strictEqual(result.generation.seed, 42);
  assert.strictEqual(result.overwrite, false);
  assert.strictEqual(result.created, true);
  assert.strictEqual(result.already_exists, false);
  assert.deepStrictEqual(source, original);
  assert.deepStrictEqual(sheets.find(s => s.name === 'Hypothetical_Revenue').__values[0], ['Product', 'City', 'Restaurant ID', 'Revenue (Hypothetical)']);
  assert.deepStrictEqual(createdWrites, ['Hypothetical_Revenue']);
  assert(sheets.some(s => String(s.name).startsWith('Hypothetical_Revenue')));

  const existing = sheets.find(s => s.name === 'Hypothetical_Revenue');
  existing.__values = [['City', 'Revenue (Hypothetical)'], ['Delhi', 100]];
  const retry = await context.window.executeSyntheticData(JSON.stringify({
    rows: source, query: 'ok create revenue column and just fill hypothesis numbers there',
    sourceSheetName: 'Restaurants', columnName: 'Revenue', min: 0, max: 1000,
    format: 'decimal', seed: 42, outputSheetName: 'Hypothetical_Revenue', revenue: true
  }));
  assert.strictEqual(retry.success, true);
  assert.strictEqual(retry.already_exists, true);
  assert.strictEqual(retry.created, false);
  assert.strictEqual(retry.sheetName, 'Hypothetical_Revenue');
  assert.deepStrictEqual(createdWrites, ['Hypothetical_Revenue']);

  existing.__values = [['Unrelated', 'Data'], ['x', 1]];
  const conflict = await context.window.executeSyntheticData(JSON.stringify({
    rows: source, query: 'ok create revenue column and just fill hypothesis numbers there',
    sourceSheetName: 'Restaurants', columnName: 'Revenue', min: 0, max: 1000,
    format: 'decimal', seed: 42, outputSheetName: 'Hypothetical_Revenue', revenue: true
  }));
  assert.strictEqual(conflict.success, false);
  assert.strictEqual(conflict.output_sheet_conflict, true);
  assert.strictEqual(conflict.sheetName, 'Hypothetical_Revenue');
  assert.deepStrictEqual(createdWrites, ['Hypothetical_Revenue']);
  console.log('excel_synthetic_data_test.js: all assertions passed');
})().catch(error => { console.error(error); process.exitCode = 1; });