const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

function createRange(values, address = 'Data!A1:D4') {
  return {
    values,
    formulas: values,
    numberFormat: values.map((row) => row.map(() => 'General')),
    rowCount: values.length,
    columnCount: values[0].length,
    rowIndex: 0,
    columnIndex: 0,
    address,
    format: { autofitColumns() {} },
    load() {},
  };
}

function mockWorkbook() {
  const calls = {
    rowAdds: [],
    columnAdds: [],
    filterAdds: [],
    dataAdds: [],
    summarizations: [],
    pivotAdds: 0,
    addedSheets: [],
    deletedSheets: [],
    activated: [],
  };
  const sourceValues = [
    ['brand_name', 'marked_price'],
    ['Brand A', 100],
    ['Brand A', 250],
    ['Brand B', 150],
    ['Brand B', 300],
  ];
  const sourceRange = createRange(sourceValues);
  const pivotRange = createRange(
    [
      ['brand_name', 'Max of marked_price'],
      ['Brand A', 250],
      ['Brand B', 300],
      ['Grand Total', 300],
    ],
    'Pivot_Output!A1:B4',
  );
  const hierarchies = ['brand_name', 'marked_price']
    .map((name) => ({ name, fields: { getItem: () => ({ sortByValues() {}, items: { items: [], load() {} } }) } }));
  const hierarchyCollection = {
    items: hierarchies,
    load() {},
    getItem(name) {
      const found = hierarchies.find((h) => h.name === name);
      if (!found) throw new Error(`missing hierarchy ${name}`);
      return found;
    },
  };
  const pivotTable = {
    hierarchies: hierarchyCollection,
    rowHierarchies: { add(h) { calls.rowAdds.push(h.name); } },
    columnHierarchies: { add(h) { calls.columnAdds.push(h.name); } },
    filterHierarchies: { add(h) { calls.filterAdds.push(h.name); } },
    dataHierarchies: {
      add(h) {
        calls.dataAdds.push(h.name);
        const dataHierarchy = {};
        Object.defineProperty(dataHierarchy, 'summarizeBy', {
          set(value) { calls.summarizations.push(value); },
        });
        return dataHierarchy;
      },
    },
    layout: {
      set layoutType(_) {},
      set subtotalLocation(_) {},
      set showFieldHeaders(_) {},
      set showRowGrandTotals(_) {},
      set showColumnGrandTotals(_) {},
      set preserveFormatting(_) {},
      set autoFormat(_) {},
      getRange() { return pivotRange; },
    },
  };
  const sheets = new Map();
  const sourceSheet = {
    name: 'Products',
    getUsedRange() { return sourceRange; },
    activate() { calls.activated.push('Products'); },
    load() {},
  };
  sheets.set('Products', sourceSheet);
  const workbook = {
    worksheets: {
      getActiveWorksheet() { return sourceSheet; },
      getItem(name) {
        if (!sheets.has(name)) throw new Error(`missing sheet ${name}`);
        return sheets.get(name);
      },
      add(name) {
        calls.addedSheets.push(name);
        const sheet = {
          name,
          pivotTables: {
            items: [],
            load() {},
            add(tableName, range, destination) {
              calls.pivotAdds += 1;
              calls.tableName = tableName;
              calls.sourceAddress = range.address;
              calls.destination = destination.address || 'A1';
              this.items.push(pivotTable);
              return pivotTable;
            },
          },
          freezePanes: { freezeRows() {} },
          autoFilter: { apply() {} },
          getRange(cell) { return { address: cell, load() {} }; },
          getRangeByIndexes() { return createRange([['temp']]); },
          getUsedRange() { return createRange([['temp']]); },
          activate() { calls.activated.push(name); },
          delete() { calls.deletedSheets.push(name); sheets.delete(name); },
          load() {},
        };
        sheets.set(name, sheet);
        return sheet;
      },
      get items() { return Array.from(sheets.values()); },
      load() {},
    },
  };
  const context = {
    window: { waitForOfficeReady: async () => {} },
    console,
    Excel: {
      AggregationFunction: {
        sum: 'SUM',
        average: 'AVERAGE',
        count: 'COUNT',
        max: 'MAX',
        min: 'MIN',
        product: 'PRODUCT',
        standardDeviation: 'STDEV',
      },
      PivotLayoutType: { compact: 'Compact' },
      SubtotalLocationType: { atTop: 'AtTop' },
      run: async (fn) => fn({ workbook, sync: async () => {} }),
    },
  };
  vm.createContext(context);
  return { context, calls };
}

async function main() {
  const { context, calls } = mockWorkbook();
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'web', 'excel_helper.js'), 'utf8'), context);
  context.window._onOfficeReady();

  const result = await context.processExcelPipeline(JSON.stringify({
    sourceSheetName: 'Products',
    targetSheetName: null,
    createNewSheet: false,
    freezeHeaderRow: false,
    enableAutoFilter: false,
    generateSummarySheet: false,
    removeDuplicates: false,
    pivotConfig: {
      sheetName: 'Pivot_Output',
      tableName: 'Pivot_Test',
      rowFields: ['brand_name'],
      columnFields: [],
      filterFields: [],
      valueFields: [
        { field: 'marked_price', op: 'max' },
      ],
      appendMode: false,
    },
  }));

  assert.strictEqual(result.success, true, result.error);
  assert.strictEqual(calls.pivotAdds, 1);
  assert.deepStrictEqual(calls.rowAdds, ['brand_name']);
  assert.deepStrictEqual(calls.columnAdds, []);
  assert.deepStrictEqual(calls.filterAdds, []);
  assert.deepStrictEqual(calls.dataAdds, ['marked_price']);
  assert.deepStrictEqual(calls.summarizations, ['MAX']);
  assert.deepStrictEqual(calls.addedSheets, ['Pivot_Output']);
  assert.deepStrictEqual(calls.deletedSheets, []);
  assert.deepStrictEqual(calls.activated, ['Pivot_Output']);
  const placement = JSON.parse(result.pivotPlacement);
  assert.strictEqual(placement.nativePivotVerified, true);
  assert.strictEqual(placement.pivotRangeAddress, 'Pivot_Output!A1:B4');

  const failed = await context.processExcelPipeline(JSON.stringify({
    sourceSheetName: 'Products',
    targetSheetName: null,
    pivotConfig: {
      sheetName: 'Pivot_Bad',
      rowFields: ['missing_field'],
      valueFields: [{ field: 'marked_price', op: 'max' }],
    },
  }));
  assert.strictEqual(failed.success, false);
  assert.match(failed.error, /Could not resolve PivotTable row field/);

  const nonNumeric = await context.processExcelPipeline(JSON.stringify({
    sourceSheetName: 'Products',
    targetSheetName: null,
    pivotConfig: {
      sheetName: 'Pivot_Bad_Max',
      rowFields: ['brand_name'],
      valueFields: [{ field: 'brand_name', op: 'max' }],
    },
  }));
  assert.strictEqual(nonNumeric.success, false);
  assert.match(nonNumeric.error, /MAX requires a numeric value field/);

  console.log('excel_native_pivot_test: PASS');
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
