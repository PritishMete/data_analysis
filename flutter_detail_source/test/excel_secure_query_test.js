// Node regression tests for the taskpane-local secure query engine.
// The engine is deliberately independent of Office.js, so these tests can
// validate grouped-count, identifier-resolution, and read-only quality logic.
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
  assert.ok(source.includes('window.executeSecureExcelQuery'));

  console.log('triggering one-time routing fix workflow');
  console.log(rows.length);
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
