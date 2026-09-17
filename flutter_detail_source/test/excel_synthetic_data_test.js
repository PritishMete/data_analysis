const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

const synthetic = fs.readFileSync('web/excel_synthetic_data.js', 'utf8');
const context = {
  window: {
    executeSecureExcelQuery: async () => ({ success: true, delegated: true }),
    prompt: () => '',
    confirm: () => true,
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

console.log('excel_synthetic_data_test.js: all assertions passed');
