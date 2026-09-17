// Node regression tests for the taskpane-local secure query engine.
// The engine is deliberately independent of Office.js, so these tests can
// validate the actual grouped-count and quality logic without an Excel host.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

const source = fs.readFileSync(require('path').join(__dirname, '..', 'web', 'excel_secure_query.js'), 'utf8');
const context = { window: {}, console };
vm.createContext(context);
vm.runInContext(source, context);

async function run() {
  const rows = [
    ['Restaurant ID', 'Restaurant Name', 'City', 'Aggregate rating'],
    [101, 'A', 'Delhi', 4.5],
    [102, 'B', 'Mumbai', 3.2],
    [102, 'C', 'Delhi', 4.1],
    [103, 'D', '', 4.8],
    [104, 'E', null, 2.9],
  ];

  const group = JSON.parse(await context.window.executeSecureExcelQuery(JSON.stringify({
    rows,
    query: 'Show the number of restaurants in each city',
  })));
  assert.strictEqual(group.success, true);
  assert.strictEqual(group.operation.action, 'group');
  assert.deepStrictEqual(group.operation.rows, [
    { City: 'Delhi', count: 2 },
    { City: 'Mumbai', count: 1 },
    { City: null, count: 2 },
  ]);
  assert.strictEqual(group.source_mutated, false);

  const quality = JSON.parse(await context.window.executeSecureExcelQuery(JSON.stringify({
    rows,
    query: 'Check for missing values and duplicate restaurant IDs',
  })));
  assert.strictEqual(quality.success, true);
  assert.strictEqual(quality.operation.action, 'quality_check');
  assert.strictEqual(quality.operation.missing_by_column.City, 2);
  assert.strictEqual(quality.operation.duplicate_identifier.column, 'Restaurant ID');
  assert.deepStrictEqual(quality.operation.duplicate_identifier.values, [102]);
  assert.strictEqual(quality.operation.duplicate_identifier.duplicate_row_count, 2);
  assert.strictEqual(quality.operation.source_mutated, false);
  assert.strictEqual(quality.source_mutated, false);
  assert.deepStrictEqual(rows, [
    ['Restaurant ID', 'Restaurant Name', 'City', 'Aggregate rating'],
    [101, 'A', 'Delhi', 4.5],
    [102, 'B', 'Mumbai', 3.2],
    [102, 'C', 'Delhi', 4.1],
    [103, 'D', '', 4.8],
    [104, 'E', null, 2.9],
  ]);

  console.log('excel_secure_query_test.js: all assertions passed');
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
