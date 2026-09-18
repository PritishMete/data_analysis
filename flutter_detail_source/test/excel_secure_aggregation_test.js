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
function clone(rows) { return JSON.parse(JSON.stringify(rows)); }

async function run() {
  const source = [
    ['Restaurant ID', 'City', 'Aggregate rating', 'Region', 'Category', 'Price'],
    [1, 'Delhi', 4.5, 'North', 'A', '10'], [2, 'Delhi', 3.5, 'North', 'A', 20],
    [3, 'Mumbai', 4.0, 'West', 'B', 30], [4, 'Mumbai', '', 'West', 'B', 40],
    [5, '', 5.0, 'East', 'A', 50], [6, null, '5', 'East', 'C', 60], [7, 'Kolkata', 4.5, 'East', 'C', '70'],
  ];
  const original = clone(source);

  const highest = await execute(source, 'Which city has the highest average restaurant rating?');
  assert.strictEqual(highest.success, true); assert.deepStrictEqual(clone(highest.operation.rows), [{ City: 'Kolkata', average: 4.5 }]);
  assert.strictEqual(highest.operation.measure, 'Aggregate rating');
  const average = await execute(source, 'What is the average rating by city?');
  assert.deepStrictEqual(clone(average.operation.rows), [{ City: null, average: 5 }, { City: 'Kolkata', average: 4.5 }, { City: 'Delhi', average: 4 }, { City: 'Mumbai', average: 4 }]);
  const top = await execute(source, 'Show the top 5 cities by average rating.');
  assert.deepStrictEqual(clone(top.operation.rows), [{ City: 'Kolkata', average: 4.5 }, { City: 'Delhi', average: 4 }, { City: 'Mumbai', average: 4 }]);
  const lowest = await execute(source, 'Which city has the lowest average rating?');
  assert.deepStrictEqual(clone(lowest.operation.rows), [{ City: 'Delhi', average: 4 }, { City: 'Mumbai', average: 4 }]);

  const count = await execute(source, 'Show the number of restaurants in each city');
  assert.strictEqual(count.success, true); assert.strictEqual(count.operation.action, 'group');
  const quality = await execute(source, 'Check for missing values and duplicate restaurant IDs');
  assert.strictEqual(quality.success, true); assert.strictEqual(quality.operation.action, 'quality_check');

  const productSource = [
    ['Product', 'Revenue', 'City'],
    ['Pizza', 1200, 'Delhi'], ['Burger', 800, 'Mumbai'], ['Pizza', 300, 'Kolkata'],
    ['Pasta', 1500, 'Delhi'], ['Burger', 200, 'Kolkata'],
  ];
  const productRevenue = await execute(productSource, 'Which products contribute the most to total revenue?');
  assert.strictEqual(productRevenue.success, true);
  assert.deepStrictEqual(clone(productRevenue.operation.rows), [
    { Product: 'Pizza', sum: 1500 },
    { Product: 'Pasta', sum: 1500 },
    { Product: 'Burger', sum: 1000 },
  ]);
  assert.strictEqual(productRevenue.operation.group_by[0], 'Product');
  assert.strictEqual(productRevenue.operation.measure, 'Revenue');
  assert.strictEqual(productRevenue.operation.aggregation, 'sum');
  assert.strictEqual(productRevenue.operation.sort, 'desc');
  assert.strictEqual(productRevenue.operation.hypothetical, false);

  const hypotheticalProductSource = [
    ['Product', 'Revenue (Hypothetical)'],
    ['Pizza', 1200], ['Burger', 800], ['Pizza', 300], ['Pasta', 1500],
  ];
  const hypotheticalProductRevenue = await execute(hypotheticalProductSource, 'Which products contribute the most to total revenue?');
  assert.strictEqual(hypotheticalProductRevenue.success, true);
  assert.strictEqual(hypotheticalProductRevenue.operation.hypothetical, true);
  assert.match(hypotheticalProductRevenue.message, /HYPOTHETICAL REVENUE/i);

  const noProduct = [['City', 'Revenue'], ['Delhi', 100], ['Mumbai', 200]];
  const noProductResult = await execute(noProduct, 'Which products contribute the most to total revenue?');
  assert.strictEqual(noProductResult.success, false);
  assert.match(noProductResult.error, /Could not resolve grouping column "products"/i);
  assert(!/requested field/i.test(noProductResult.error));

  const ambiguousProduct = [['Product', 'Product Name', 'Revenue'], ['Pizza', 'Pizza Classic', 100], ['Burger', 'Burger Deluxe', 200]];
  const ambiguousProductResult = await execute(ambiguousProduct, 'Which products contribute the most to total revenue?');
  assert.strictEqual(ambiguousProductResult.success, false);
  assert.match(ambiguousProductResult.error, /ambiguous/i);
  assert.match(ambiguousProductResult.error, /Product/);

  const revenueSource = [
    ['City', 'Revenue', 'Aggregate rating', 'Votes'],
    ['Delhi', 100, 4.5, 20], ['Delhi', '200', 4.0, 10], ['Mumbai', '1,250', 3.9, 30], ['Kolkata', '', 4.2, 5],
  ];
  const revenueOriginal = clone(revenueSource);
  const revenue = await execute(revenueSource, 'What is the total revenue generated by each city?');
  assert.strictEqual(revenue.success, true);
  assert.deepStrictEqual(clone(revenue.operation.rows), [{ City: 'Mumbai', sum: 1250 }, { City: 'Delhi', sum: 300 }]);
  assert.strictEqual(revenue.operation.measure, 'Revenue');
  assert.deepStrictEqual(revenueSource, revenueOriginal);

  const salesSource = [['City', 'Sales Amount'], ['Delhi', '100'], ['Delhi', 250], ['Mumbai', '1,000']];
  const sales = await execute(salesSource, 'What is the total sales amount by city?');
  assert.strictEqual(sales.success, true);
  assert.deepStrictEqual(clone(sales.operation.rows), [{ City: 'Mumbai', sum: 1000 }, { City: 'Delhi', sum: 350 }]);
  const revenueFromSalesAmount = await execute(salesSource, 'What is the total revenue generated by each city?');
  assert.strictEqual(revenueFromSalesAmount.success, true);
  assert.deepStrictEqual(clone(revenueFromSalesAmount.operation.rows), [{ City: 'Mumbai', sum: 1000 }, { City: 'Delhi', sum: 350 }]);

  const derivedSource = [
    ['City', 'Quantity', 'Unit Price'],
    ['Delhi', 2, 100], ['Delhi', '3', '50'], ['Mumbai', 4, '25'], ['Mumbai', '', 90],
  ];
  const derivedOriginal = clone(derivedSource);
  const derived = await execute(derivedSource, 'What is the total revenue generated by each city?');
  assert.strictEqual(derived.success, true);
  assert.deepStrictEqual(clone(derived.operation.rows), [{ City: 'Delhi', sum: 350 }, { City: 'Mumbai', sum: 100 }]);
  assert.strictEqual(derived.operation.derived_measure, 'quantity * unit price');
  assert.deepStrictEqual(derivedSource, derivedOriginal);

  const priceOnly = [['City', 'Price Range', 'Aggregate rating', 'Votes'], ['Delhi', '100-200', 4.5, 20], ['Mumbai', '200-300', 4.1, 40]];
  const unavailable = await execute(priceOnly, 'What is the total revenue generated by each city?');
  assert.strictEqual(unavailable.success, false);
  assert.match(unavailable.error, /Revenue cannot be calculated from this worksheet/i);
  assert.strictEqual(unavailable.diagnostics.derived_revenue, false);
  assert.deepStrictEqual(priceOnly, [['City', 'Price Range', 'Aggregate rating', 'Votes'], ['Delhi', '100-200', 4.5, 20], ['Mumbai', '200-300', 4.1, 40]]);

  const ambiguous = [['City', 'Revenue', 'Revenue Amount'], ['Delhi', 100, 90], ['Mumbai', 200, 180]];
  const ambiguousResult = await execute(ambiguous, 'What is the total revenue generated by each city?');
  assert.strictEqual(ambiguousResult.success, false);
  assert.match(ambiguousResult.error, /ambiguous/i);
  assert.deepStrictEqual(ambiguous, [['City', 'Revenue', 'Revenue Amount'], ['Delhi', 100, 90], ['Mumbai', 200, 180]]);

  const salesAmbiguous = [['Region', 'Sales', 'Sales Amount'], ['North', 100, 90], ['South', 200, 180]];
  const salesAmbiguousResult = await execute(salesAmbiguous, 'What is the total sales by region?');
  assert.strictEqual(salesAmbiguousResult.success, false);
  assert.match(salesAmbiguousResult.error, /ambiguous/i);

  const missingNumeric = [['City', 'Revenue'], ['Delhi', 100], ['Delhi', 'not available'], ['Mumbai', ''], ['Mumbai', '50']];
  const missingResult = await execute(missingNumeric, 'What is the total revenue generated by each city?');
  assert.strictEqual(missingResult.success, true);
  assert.deepStrictEqual(clone(missingResult.operation.rows), [{ City: 'Delhi', sum: 100 }, { City: 'Mumbai', sum: 50 }]);

  assert.ok(!aggregation.includes('fetch('));
  assert.ok(!aggregation.includes('XMLHttpRequest'));
  assert.deepStrictEqual(source, original);
  console.log('excel_secure_aggregation_test.js: all assertions passed');
}
run().catch(error => { console.error(error); process.exitCode = 1; });
