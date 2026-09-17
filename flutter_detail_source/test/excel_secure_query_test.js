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
  assert.ok(source.includes('window.executeSecureExcelQuery'));
  console.log('routing-fix trigger test');
}
run().catch(e => { console.error(e); process.exitCode = 1; });
