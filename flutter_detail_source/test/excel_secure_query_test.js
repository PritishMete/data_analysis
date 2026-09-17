const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

const source = fs.readFileSync(require('path').join(__dirname, '..', 'web', 'excel_secure_query.js'), 'utf8');
const context = { window: {}, console };
vm.createContext(context);
vm.runInContext(source, context);

async function execute(rows, query) {
  return JSON.parse(await context.window.executeSecureExcelQuery(
    JSON.stringify({ rows, query }),
  ));
}

async function run() {
  const rows = [
    ['Restaurant ID', 'Restaurant Name', 'City', 'Aggregate rating'],
    [101, 'A', 'Delhi', 4.5],
    [102, 'B', 'Mumbai', 3.2],
    [102, 'C', 'Delhi', 4.1],
    [103, 'D', '', 4.8],
    [104, 'E', null, 2.9],
  ];
  const original = JSON.parse(JSON.stringify(rows));

  // Grouped-count routing regression: neither wording may be interpreted as
  // a filter_rows plan or require a nonexistent `name` column.
  for (const query of [
    'Show the number of restaurants in each city',
    'Count restaurants by city',
  ]) {
    const result = await execute(rows, query);
    assert.strictEqual(result.success, true, query);
    assert.strictEqual(result.operation.action, 'group', query);
    assert.deepStrictEqual(result.operation.columns, ['City', 'count']);
    assert.deepStrictEqual(result.operation.rows, [
      { City: 'Delhi', count: 2 },
      { City: 'Mumbai', count: 1 },
      { City: null, count: 2 },
    ]);
    assert.strictEqual(result.diagnostics.group_resolution, 'resolved');
    assert.strictEqual(result.diagnostics.resolved_group_column, 'City');
    assert.strictEqual(result.source_mutated, false);
    assert.ok(!JSON.stringify(result).includes('filter_rows'));
    assert.ok(!JSON.stringify(result).includes('Could not resolve filter column'));
  }

  // Header normalization: blank leading worksheet rows are not headers.
  const leadingBlankRows = [
    ['', '', '', ''],
    ['', '', '', ''],
    ...rows,
  ];
  const leadingBlankResult = await execute(
    leadingBlankRows,
    'Show the number of restaurants in each city',
  );
  assert.strictEqual(leadingBlankResult.success, true);
  assert.strictEqual(leadingBlankResult.diagnostics.header_index, 2);
  assert.strictEqual(leadingBlankResult.diagnostics.header_count, 4);
  assert.strictEqual(leadingBlankResult.operation.group_by[0], 'City');
  assert.strictEqual(leadingBlankResult.source_mutated, false);

  // Equivalent grouping headers are resolved without changing the original
  // header spelling used in the result.
  for (const header of ['City', 'city', 'City_Name', 'city name']) {
    const matrix = rows.map((row, index) =>
      index === 0 ? [row[0], row[1], header, row[3]] : row.slice(),
    );
    const result = await execute(matrix, 'Count restaurants by city');
    assert.strictEqual(result.success, true, header);
    assert.strictEqual(result.operation.group_by[0], header, header);
    assert.strictEqual(result.operation.columns[0], header, header);
  }

  // Requested identifier resolution across realistic worksheet header forms.
  for (const header of [
    'Restaurant ID',
    'RestaurantID',
    'restaurant_id',
    'restaurant id',
  ]) {
    const matrix = rows.map((row, index) =>
      index === 0 ? [header, row[1], row[2], row[3]] : row.slice(),
    );
    const result = await execute(
      matrix,
      'Check for missing values and duplicate restaurant IDs',
    );
    assert.strictEqual(result.success, true, header);
    assert.strictEqual(result.operation.action, 'quality_check', header);
    assert.strictEqual(result.operation.duplicate_identifier.status, 'ok', header);
    assert.strictEqual(result.operation.duplicate_identifier.column, header, header);
    assert.deepStrictEqual(result.operation.duplicate_identifier.values, [102], header);
    assert.strictEqual(result.operation.duplicate_identifier.duplicate_row_count, 2, header);
    assert.strictEqual(result.diagnostics.identifier_resolution, 'resolved', header);
  }

  // Explicit compact identifier wording.
  const variation = await execute(rows, 'Find duplicate RestaurantID values');
  assert.strictEqual(variation.operation.duplicate_identifier.status, 'ok');
  assert.strictEqual(variation.operation.duplicate_identifier.column, 'Restaurant ID');
  assert.deepStrictEqual(variation.operation.duplicate_identifier.values, [102]);

  // Genuine ambiguity must be reported rather than silently selecting one.
  const ambiguous = await execute(
    [
      ['Restaurant ID', 'restaurant_id', 'City'],
      [1, 2, 'Delhi'],
      [1, 2, 'Mumbai'],
    ],
    'Check missing values and duplicate identifiers',
  );
  assert.strictEqual(
    ambiguous.operation.duplicate_identifier.status,
    'ambiguous_identifier',
  );
  assert.deepStrictEqual(
    ambiguous.operation.duplicate_identifier.candidates,
    ['Restaurant ID', 'restaurant_id'],
  );
  assert.strictEqual(ambiguous.diagnostics.identifier_resolution, 'ambiguous');

  // Explicit requested identifier missing from the schema must be explained.
  const notFound = await execute(
    [
      ['Restaurant Name', 'City'],
      ['A', 'Delhi'],
    ],
    'Check for missing values and duplicate restaurant IDs',
  );
  assert.strictEqual(
    notFound.operation.duplicate_identifier.status,
    'identifier_not_found',
  );
  assert.ok(
    notFound.operation.duplicate_identifier.message.includes('restaurant id'),
  );
  assert.strictEqual(notFound.diagnostics.identifier_resolution, 'not_found');

  // Read-only guarantee: input worksheet matrix is unchanged.
  assert.deepStrictEqual(rows, original);
  assert.ok(!source.includes('fetch('));
  assert.ok(!source.includes('XMLHttpRequest'));

  console.log('excel_secure_query_test.js: all assertions passed');
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
