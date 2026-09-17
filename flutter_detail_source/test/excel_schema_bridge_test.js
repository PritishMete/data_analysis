const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

const source = fs.readFileSync(
  require('path').join(__dirname, '..', 'web', 'excel_schema_bridge.js'),
  'utf8',
);
const context = { window: {}, console };
vm.createContext(context);
vm.runInContext(source, context);

async function run() {
  const normalize = context.window.normalizeWorksheetMatrix;
  assert.strictEqual(typeof normalize, 'function');

  const ordinaryRange = [
    ['', '', '', ''],
    ['', '', '', ''],
    ['Restaurant ID', 'Restaurant Name', 'City', 'Aggregate rating'],
    [101, 'A', 'Delhi', 4.5],
    [102, 'B', 'Mumbai', 3.2],
  ];
  const ordinary = normalize(ordinaryRange);
  assert.strictEqual(ordinary.headerIndex, 2);
  assert.strictEqual(ordinary.columns, 4);
  assert.strictEqual(ordinary.headerCount, 4);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(ordinary.matrix[0])), ordinaryRange[2]);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(ordinary.matrix[1])), ordinaryRange[3]);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(ordinary.matrix[2])), ordinaryRange[4]);

  // Excel tables arrive already bounded to their table range. The bridge must
  // preserve the table header spelling and row/column positions exactly.
  const tableRange = [
    ['restaurant_id', 'city', 'Aggregate rating'],
    [101, 'Delhi', 4.5],
    [101, 'Mumbai', 3.2],
  ];
  const table = normalize(tableRange);
  assert.strictEqual(table.headerIndex, 0);
  assert.strictEqual(table.rows, 3);
  assert.strictEqual(table.columns, 3);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(table.matrix)), tableRange);

  // Empty and duplicate headers are preserved; schema resolution, not the
  // reader, decides whether a requested field is ambiguous.
  const duplicateHeaders = [
    ['', 'Restaurant ID', 'restaurant_id', 'City'],
    ['x', 1, 1, 'Delhi'],
  ];
  const duplicate = normalize(duplicateHeaders);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(duplicate.matrix[0])), duplicateHeaders[0]);
  assert.strictEqual(duplicate.columns, 4);
  assert.strictEqual(duplicate.headerCount, 3);

  console.log('excel_schema_bridge_test.js: all assertions passed');
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
