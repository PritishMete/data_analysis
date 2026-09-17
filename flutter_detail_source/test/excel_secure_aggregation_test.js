const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const context = { window: {}, console };
vm.createContext(context);
const base = fs.readFileSync(path.join(__dirname, '..', 'web', 'excel_secure_query.js'), 'utf8');
const aggregation = fs.readFileSync(path.join(__dirname, '..', 'web', 'excel_secure_aggregation.js'), 'utf8');
vm.runInContext(base, context);
vm.runInContext(aggregation, context);

async function execute(rows, query) {
  return JSON.parse(await context.window.executeSecureExcelQuery(JSON.stringify({ rows, query })));
}
function normalizeRows(rows) { return JSON.parse(JSON.stringify(rows)); }

async function run() {
  const source = [
    ['Restaurant ID', 'City', 'Aggregate rating', 'Sales Amount', 'Region', 'Category', 'Price'],
    [1, 'Delhi', 4.5, '100', 'North', 'A', '10'],
    [2, 'Delhi', 3.5, 200, 'North', 'A', 20],
    [3, 'Mumbai', 4.0, '300', 'West', 'B', 30],
    [4, 'Mumbai', '', 100, 'West', 'B', 40],
    [5, '', 5.0, '400', 'East', 'A', 50],
    [6, null, '5', 'bad', 'East', 'C', 60],
    [7, 'Kolkata', 4.5, 50, 'East', 'C', '70'],
  ];
  const original = normalizeRows(source);

  const highest = await execute(source, 'Which city has the highest average restaurant rating?');
  assert.strictEqual(highest.success, true);
  assert.strictEqual(highest.operation.action, 'aggregate');
  assert.deepStrictEqual(normalizeRows(highest.operation.rows), [{ City: 'Kolkata', average: 4.5 }]);
  assert.strictEqual(highest.operation.measure, 'Aggregate rating');
  assert.strictEqual(highest.operation.sort, 'desc');

  const average = await execute(source, 'What is the average rating by city?');
  assert.deepStrictEqual(normalizeRows(average.operation.rows), [
    { City: '', average: 5 }, { City: 'Kolkata', average: 4.5 },
    { City: 'Delhi', average: 4 }, { City: 'Mumbai', average: 4 },
  ]);

  const top = await execute(source, 'Show the top 5 cities by average rating.');
  assert.deepStrictEqual(normalizeRows(top.operation.rows), [
    { City: 'Kolkata', average: 4.5 }, { City: 'Delhi', average: 4 }, { City: 'Mumbai', average: 4 },
  ]);

  const lowest = await execute(source, 'Which city has the lowest average rating?');
  assert.deepStrictEqual(normalizeRows(lowest.operation.rows), [
    { City: 'Delhi', average: 4 }, { City: 'Mumbai', average: 4 },
  ]);

  const sales = await execute(source, 'What is the total sales amount by region?');
  assert.deepStrictEqual(normalizeRows(sales.operation.rows), [
    { Region: 'East', sum: 450 }, { Region: 'West', sum: 400 }, { Region: 'North', sum: 300 },
  ]);
  assert.strictEqual(sales.diagnostics.resolved_measure_column, 'Sales Amount');

  const price = await execute(source, 'Show the highest average price by category.');
  assert.deepStrictEqual(normalizeRows(price.operation.rows), [
    { Category: 'C', average: 65 }, { Category: 'B', average: 35 }, { Category: 'A', average: 26.6666666667 },
  ]);

  const variant = source.map((row, i) => i === 0
    ? ['Restaurant ID', 'city_name', 'aggregate_rating', 'Sales_Amount', 'Region', 'Category', 'Price']
    : row.slice());
  const variantResult = await execute(variant, 'What is the average rating by cities?');
  assert.strictEqual(variantResult.success, true);
  assert.strictEqual(variantResult.operation.group_by[0], 'city_name');
  assert.strictEqual(variantResult.operation.measure, 'aggregate_rating');

  const ambiguous = await execute([
    ['City', 'Rating', 'Average Rating'], ['Delhi', 4, 4], ['Mumbai', 5, 5],
  ], 'What is the average rating by city?');
  assert.strictEqual(ambiguous.success, false);
  assert.match(ambiguous.error, /ambiguous/i);
  assert.strictEqual(ambiguous.diagnostics.measure_resolution, 'ambiguous');

  const ambiguousGroup = await execute([
    ['City', 'city', 'Rating'], ['Delhi', 'D', 4], ['Mumbai', 'M', 5],
  ], 'What is the average rating by city?');
  assert.strictEqual(ambiguousGroup.success, false);
  assert.match(ambiguousGroup.error, /ambiguous/i);

  const leadingBlank = [['', '', '', '', '', '', ''], ...source];
  const leadingResult = await execute(leadingBlank, 'What is the average rating by city?');
  assert.strictEqual(leadingResult.success, true);
  assert.strictEqual(leadingResult.diagnostics.header_index, 1);

  const tie = await execute([
    ['Region', 'Sales Amount'], ['North', 100], ['South', 100], ['West', 80],
  ], 'Which region has the highest average sales amount?');
  assert.deepStrictEqual(normalizeRows(tie.operation.rows), [
    { Region: 'North', average: 100 }, { Region: 'South', average: 100 },
  ]);

  const count = await execute(source, 'Show the number of restaurants in each city');
  assert.strictEqual(count.success, true);
  assert.strictEqual(count.operation.action, 'group');
  const quality = await execute(source, 'Check for missing values and duplicate restaurant IDs');
  assert.strictEqual(quality.success, true);
  assert.strictEqual(quality.operation.action, 'quality_check');

  assert.deepStrictEqual(source, original);
  assert.ok(!aggregation.includes('fetch('));
  assert.ok(!aggregation.includes('XMLHttpRequest'));
  console.log('excel_secure_aggregation_test.js: all assertions passed');
}
run().catch(error => { console.error(error); process.exitCode = 1; });
