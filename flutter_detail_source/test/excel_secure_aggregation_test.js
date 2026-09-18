const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const context = { window: {}, console };
vm.createContext(context);
const base = fs.readFileSync(path.join(__dirname, '..', 'web', 'excel_secure_query.js'), 'utf8');
const schema = fs.readFileSync(path.join(__dirname, '..', 'web', 'excel_schema_intelligence.js'), 'utf8');
const aggregation = fs.readFileSync(path.join(__dirname, '..', 'web', 'excel_secure_aggregation.js'), 'utf8');
vm.runInContext(base, context);
vm.runInContext(schema, context);
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

  const cuisineSource = [['cuisine','cost'],['North Indian',3226910],['Chinese',1990023],['Indian',1722723],['Biryani',1470121],['South Indian',1064058],['Italian',900000]];
  const cuisineResult = await execute(cuisineSource, 'Create a bar chart of the top 5 cuisines by cost.');
  assert.strictEqual(cuisineResult.success, true);
  assert.deepStrictEqual(clone(cuisineResult.operation.rows), [
    { cuisine: 'North Indian', 'Total cost': 3226910 }, { cuisine: 'Chinese', 'Total cost': 1990023 },
    { cuisine: 'Indian', 'Total cost': 1722723 }, { cuisine: 'Biryani', 'Total cost': 1470121 },
    { cuisine: 'South Indian', 'Total cost': 1064058 },
  ]);
  assert.strictEqual(cuisineResult.operation.chart.chartType, 'bar');
  assert.strictEqual(cuisineResult.operation.chart.categoryColumn, 'cuisine');
  assert.strictEqual(cuisineResult.operation.chart.valueColumn, 'Total cost');
  assert.strictEqual(cuisineResult.operation.chart.title, 'Top 5 Cuisines by Total Cost');
  const ambiguousCuisine = await execute([['City Center','City Name','Cost'],['Delhi','Delhi',10]], 'Show total cost by city.');
  assert.strictEqual(ambiguousCuisine.success, false);
  assert.match(ambiguousCuisine.error, /ambiguous/i);

  const highest = await execute(source, 'Which city has the highest average restaurant rating?');
  assert.strictEqual(highest.success, true); assert.strictEqual(highest.operation.action, 'rank_selection');
  assert.strictEqual(highest.operation.sort, 'desc');
  const highestOne = await execute(source, 'Which city has the highest average restaurant rating? top 1');
  assert.deepStrictEqual(clone(highestOne.operation.rows), [{ City: 'Kolkata', 'Average Aggregate rating': 4.5 }]);
  assert.strictEqual(highestOne.operation.measure, 'Aggregate rating');
  const average = await execute(source, 'What is the average rating by city?');
  assert.deepStrictEqual(clone(average.operation.rows), [{ City: null, 'Average Aggregate rating': 5 }, { City: 'Kolkata', 'Average Aggregate rating': 4.5 }, { City: 'Delhi', 'Average Aggregate rating': 4 }, { City: 'Mumbai', 'Average Aggregate rating': 4 }]);
  const top = await execute(source, 'Show the top 5 cities by average rating.');
  assert.deepStrictEqual(clone(top.operation.rows), [{ City: 'Kolkata', 'Average Aggregate rating': 4.5 }, { City: 'Delhi', 'Average Aggregate rating': 4 }, { City: 'Mumbai', 'Average Aggregate rating': 4 }]);
  const lowest = await execute(source, 'Which city has the lowest average rating?');
  assert.strictEqual(lowest.success, true); assert.strictEqual(lowest.operation.action, 'rank_selection');
  assert.strictEqual(lowest.operation.sort, 'asc');
  const lowestTwo = await execute(source, 'Which city has the lowest average rating? bottom 2');
  assert.deepStrictEqual(clone(lowestTwo.operation.rows), [{ City: 'Delhi', 'Average Aggregate rating': 4 }, { City: 'Mumbai', 'Average Aggregate rating': 4 }]);

  const count = await execute(source, 'Show the number of restaurants in each city');
  assert.strictEqual(count.success, true); assert.strictEqual(count.operation.action, 'group');
  const quality = await execute(source, 'Check for missing values and duplicate restaurant IDs');
  assert.strictEqual(quality.success, true); assert.strictEqual(quality.operation.action, 'quality_check');

  const productSource = [
    ['Product', 'Revenue', 'City'],
    ['Pizza', 1200, 'Delhi'], ['Burger', 800, 'Mumbai'], ['Pizza', 300, 'Kolkata'],
    ['Pasta', 1500, 'Delhi'], ['Burger', 200, 'Kolkata'],
  ];
  const productSelection = await execute(productSource, 'Which products contribute the most to total revenue?');
  assert.strictEqual(productSelection.success, true);
  assert.strictEqual(productSelection.operation.action, 'rank_selection');
  assert.strictEqual(productSelection.operation.sort, 'desc');
  assert.strictEqual(productSelection.operation.available_count, 3);
  const productRevenue = await execute(productSource, 'Which products contribute the most to total revenue? top 2');
  assert.strictEqual(productRevenue.success, true);
  assert.deepStrictEqual(clone(productRevenue.operation.rows), [
    { Product: 'Pasta', 'Total Revenue': 1500 },
    { Product: 'Pizza', 'Total Revenue': 1500 },
  ]);
  assert.strictEqual(productRevenue.operation.group_by[0], 'Product');
  assert.strictEqual(productRevenue.operation.measure, 'Revenue');
  assert.strictEqual(productRevenue.operation.aggregation, 'sum');
  assert.strictEqual(productRevenue.operation.sort, 'desc');
  assert.strictEqual(productRevenue.operation.hypothetical, false);

  const bottomSelection = await execute(productSource, 'Which products contribute the least to total revenue?');
  assert.strictEqual(bottomSelection.success, true);
  assert.strictEqual(bottomSelection.operation.action, 'rank_selection');
  assert.strictEqual(bottomSelection.operation.sort, 'asc');

  const bottom10 = await execute(productSource, 'Show the bottom 10 products by revenue.');
  assert.strictEqual(bottom10.success, true);
  assert.strictEqual(bottom10.operation.limit, 10);
  assert.deepStrictEqual(clone(bottom10.operation.rows), [
    { Product: 'Burger', 'Total Revenue': 1000 },
    { Product: 'Pasta', 'Total Revenue': 1500 },
    { Product: 'Pizza', 'Total Revenue': 1500 },
  ]);

  const topFive = await execute(productSource, 'Show the top five products by revenue.');
  assert.strictEqual(topFive.success, true);
  assert.strictEqual(topFive.operation.limit, 5);

  const custom20 = await execute(productSource, 'Show the top 20 products by revenue.');
  assert.strictEqual(custom20.success, true);
  assert.strictEqual(custom20.operation.rows.length, 3);

  const allResults = await execute(productSource, 'Show the top all products by revenue.');
  assert.strictEqual(allResults.success, true);
  assert.strictEqual(allResults.operation.rows.length, 3);

  const ties = [['Cuisine', 'Revenue'], ['Indian', 100], ['Chinese', 100], ['Italian', 50]];
  const tiedTop = await execute(ties, 'Show the top 1 cuisines by revenue.');
  assert.deepStrictEqual(clone(tiedTop.operation.rows), [{ Cuisine: 'Chinese', 'Total Revenue': 100 }]);
  assert.match(tiedTop.diagnostics.tie_policy, /deterministically/i);
  assert.deepStrictEqual(ties, [['Cuisine', 'Revenue'], ['Indian', 100], ['Chinese', 100], ['Italian', 50]]);

  const hypotheticalProductSource = [
    ['Product', 'Revenue (Hypothetical)'],
    ['Pizza', 1200], ['Burger', 800], ['Pizza', 300], ['Pasta', 1500],
  ];
  const hypotheticalProductRevenue = await execute(hypotheticalProductSource, 'Which products contribute the most to total revenue? top 5');
  assert.strictEqual(hypotheticalProductRevenue.success, true);
  assert.strictEqual(hypotheticalProductRevenue.operation.hypothetical, true);
  assert.match(hypotheticalProductRevenue.message, /HYPOTHETICAL REVENUE/i);

  const restaurantHypotheticalSource = [
    ['Restaurant Name', 'City', 'Revenue (Hypothetical)'],
    ['Cafe A', 'Delhi', 900], ['Cafe B', 'Mumbai', 1400], ['Cafe A', 'Kolkata', 600],
  ];
  const restaurantHypothetical = await execute(restaurantHypotheticalSource, 'Which restaurants contribute the most to hypothetical revenue? top 5');
  assert.strictEqual(restaurantHypothetical.success, true);
  assert.deepStrictEqual(clone(restaurantHypothetical.operation.rows), [
    { 'Restaurant Name': 'Cafe A', 'Total Hypothetical Revenue': 1500 },
    { 'Restaurant Name': 'Cafe B', 'Total Hypothetical Revenue': 1400 },
  ]);
  assert.strictEqual(restaurantHypothetical.operation.group_by[0], 'Restaurant Name');
  assert.strictEqual(restaurantHypothetical.operation.measure, 'Revenue (Hypothetical)');
  assert.strictEqual(restaurantHypothetical.operation.hypothetical, true);
  assert.match(restaurantHypothetical.message, /HYPOTHETICAL REVENUE/i);

  const restaurantIdHypothetical = [
    ['Restaurant ID', 'Revenue (Hypothetical)'],
    [101, 500], [202, 800], [101, 200],
  ];
  const restaurantIdResult = await execute(restaurantIdHypothetical, 'Which restaurants contribute the most to hypothetical revenue? top 5');
  assert.strictEqual(restaurantIdResult.success, true);
  assert.deepStrictEqual(clone(restaurantIdResult.operation.rows), [
    { 'Restaurant ID': 202, 'Total Hypothetical Revenue': 800 },
    { 'Restaurant ID': 101, 'Total Hypothetical Revenue': 700 },
  ]);
  assert.strictEqual(restaurantIdResult.operation.group_by[0], 'Restaurant ID');
  assert.strictEqual(restaurantIdResult.operation.hypothetical, true);

  const noProduct = [['City', 'Revenue'], ['Delhi', 100], ['Mumbai', 200]];
  const noProductResult = await execute(noProduct, 'Which products contribute the most to total revenue?');
  assert.strictEqual(noProductResult.success, false);
  assert.match(noProductResult.error, /does not contain product information/i);
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
  assert.deepStrictEqual(clone(revenue.operation.rows), [{ City: 'Mumbai', 'Total Revenue': 1250 }, { City: 'Delhi', 'Total Revenue': 300 }]);
  assert.strictEqual(revenue.operation.measure, 'Revenue');
  assert.deepStrictEqual(revenueSource, revenueOriginal);

  const salesSource = [['City', 'Sales Amount'], ['Delhi', '100'], ['Delhi', 250], ['Mumbai', '1,000']];
  const sales = await execute(salesSource, 'What is the total sales amount by city?');
  assert.strictEqual(sales.success, true);
  assert.deepStrictEqual(clone(sales.operation.rows), [{ City: 'Mumbai', 'Total Sales Amount': 1000 }, { City: 'Delhi', 'Total Sales Amount': 350 }]);
  const revenueFromSalesAmount = await execute(salesSource, 'What is the total revenue generated by each city?');
  assert.strictEqual(revenueFromSalesAmount.success, true);
  assert.deepStrictEqual(clone(revenueFromSalesAmount.operation.rows), [{ City: 'Mumbai', 'Total Sales Amount': 1000 }, { City: 'Delhi', 'Total Sales Amount': 350 }]);

  const derivedSource = [
    ['City', 'Quantity', 'Unit Price'],
    ['Delhi', 2, 100], ['Delhi', '3', '50'], ['Mumbai', 4, '25'], ['Mumbai', '', 90],
  ];
  const derivedOriginal = clone(derivedSource);
  const derived = await execute(derivedSource, 'What is the total revenue generated by each city?');
  assert.strictEqual(derived.success, true);
  assert.deepStrictEqual(clone(derived.operation.rows), [{ City: 'Delhi', 'Total Revenue': 350 }, { City: 'Mumbai', 'Total Revenue': 100 }]);
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
  assert.deepStrictEqual(clone(missingResult.operation.rows), [{ City: 'Delhi', 'Total Revenue': 100 }, { City: 'Mumbai', 'Total Revenue': 50 }]);

  assert.ok(!aggregation.includes('fetch('));
  assert.ok(!aggregation.includes('XMLHttpRequest'));
  assert.deepStrictEqual(source, original);
  console.log('excel_secure_aggregation_test.js: all assertions passed');
}
run().catch(error => { console.error(error); process.exitCode = 1; });
