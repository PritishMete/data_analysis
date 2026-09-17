const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

const synthetic = fs.readFileSync('web/excel_synthetic_data.js', 'utf8');
let promptValues = ['0', '1000', 'uniform', 'decimal', '42', '₹'];
let confirms = [];
const source = [['City', 'Restaurant ID'], ['Delhi', 1], ['Delhi', 2], ['Mumbai', 3]];
const original = JSON.parse(JSON.stringify(source));
const sheets = [{ name: 'Restaurants' }];
const activeSheet = { name: 'Restaurants', load() {} };
const workbook = {
  worksheets: {
    items: sheets,
    load() {},
    getActiveWorksheet() { return activeSheet; },
    add(name) {
      const out = {
        name,
        getRangeByIndexes() { return { values: null, numberFormat: null, format: { font: { bold: false } } }; },
        activate() {},
      };
      sheets.push(out);
      return out;
    },
  },
};
const context = {
  window: {
    executeSecureExcelQuery: async () => ({ success: true, delegated: true }),
    prompt: () => promptValues.shift() ?? '',
    confirm: message => { confirms.push(message); return true; },
    waitForOfficeReady: async () => {},
  },
  Excel: {
    run: async fn => fn({ workbook, sync: async () => {} }),
  },
  Math,
  Number,
  String,
  Array,
  Set,
  JSON,
  Promise,
  console,
};
vm.createContext(context);
vm.runInContext(synthetic, context);
const api = context.window.__insightflowSyntheticTest;
assert(api, 'synthetic test API should be exposed');

assert.strictEqual(api.isSyntheticRequest('ok create revenue column and just fill hypothesis numbers there'), true);
assert.strictEqual(api.isSyntheticRequest('create a hypothetical revenue column'), true);
assert.strictEqual(api.isSyntheticRequest('create a synthetic score column'), true);
assert.strictEqual(api.isSyntheticRequest('What is the average rating by city?'), false);
assert.strictEqual(api.requestedColumn('ok create revenue column and just fill hypothesis numbers there'), 'Revenue');
assert.strictEqual(api.requestedColumn('create a column named Sales Amount'), 'sales amount');

const seededConfig = { min: 0, max: 1000, distribution: 'uniform', format: 'decimal', seed: 42 };
const first = Array.from({ length: 5 }, () => api.generator(seededConfig)());
const second = Array.from({ length: 5 }, () => api.generator(seededConfig)());
assert.deepStrictEqual(first, second, 'same seed must reproduce the same sequence');
assert(first.every(v => v >= 0 && v <= 1000));
const integer = api.generator({ min: 10, max: 20, distribution: 'uniform', format: 'integer', seed: 7 });
assert(Number.isInteger(integer()));

(async () => {
  promptValues = ['0', '1000', 'uniform', 'decimal', '42', '₹'];
  confirms = [];
  const result = await context.window.executeSecureExcelQuery(JSON.stringify({ rows: source, query: 'ok create revenue column and just fill hypothesis numbers there' }));
  assert.strictEqual(result.success, true);
  assert.strictEqual(result.hypothetical, true);
  assert.strictEqual(result.source_mutated, false);
  assert.strictEqual(result.generated_column, 'Revenue (Hypothetical)');
  assert(result.sheetName.startsWith('Hypothetical_Revenue'));
  assert.strictEqual(result.generation.min, 0);
  assert.strictEqual(result.generation.max, 1000);
  assert.strictEqual(result.generation.seed, 42);
  assert(confirms.length >= 1 && /HYPOTHETICAL/.test(confirms[confirms.length - 1]));
  assert.deepStrictEqual(source, original);
  console.log('excel_synthetic_data_test.js: all assertions passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
