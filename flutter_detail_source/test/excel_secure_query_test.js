const fs = require('fs');
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
