const fs=require('fs');const path=require('path');const vm=require('vm');const assert=require('assert');

function mock(){
  const calls={pivotAdds:0,chartAdds:0,chartDeletes:0,sourceAddress:null,position:null,syncs:0,visible:[]};
  const pivotItems=['North Indian','Chinese','Indian','Biryani','South Indian','Other'];
  const pivotRange={
    address:'Pivot Analysis!A1:B6',rowCount:6,columnCount:2,rowIndex:0,columnIndex:0,
    values:[
      ['Cuisine','Sum of Cost'],
      ['North Indian',3226910],
      ['Chinese',1990023],
      ['Indian',1722723],
      ['Biryani',1470121],
      ['South Indian',1064058]
    ],
    load(){}
  };
  const chart={id:'pivot-chart-1',name:'InsightFlow_Pivot_Chart',chartType:'BarClustered',title:{text:''},setPosition(a,b){calls.position=[a,b]},load(){}};
  const chartCollection={
    items:[],
    load(){},
    add(type,source,seriesBy){calls.chartAdds++;calls.sourceAddress=source.address;calls.type=type;calls.seriesBy=seriesBy;return chart}
  };
  const pivotField={
    sortByValues(direction){calls.sortDirection=direction},
    items:{items:pivotItems.map((name)=>({name,visible:true})),load(){}}
  };
  const hierarchy={name:'Cuisine',fields:{getItem(){return pivotField}}};
  const dataHierarchy={name:'Cost',summarizeBy:null};
  const pivotTable={
    name:'Pivot_InsightFlow_Combined',
    hierarchies:{items:[hierarchy,{name:'Cost'}],getItem(name){return name==='Cuisine'?hierarchy:{name:'Cost'}}},
    rowHierarchies:{items:[],add(){},getItem(){return hierarchy}},
    columnHierarchies:{add(){}},
    dataHierarchies:{add(){calls.dataAdds++;return dataHierarchy},items:[dataHierarchy]},
    layout:{layoutType:'Compact',showRowGrandTotals:true,showColumnGrandTotals:true,getRange(){return pivotRange}}
  };
  const pivotSheet={
    name:'Pivot Analysis',
    pivotTables:{items:[pivotTable],load(){},add(){calls.pivotAdds++;return pivotTable}},
    charts:chartCollection,
    activate(){},
    getRange(){return pivotRange},
    getUsedRange(){return pivotRange}
  };
  const sourceSheet={name:'Data',getUsedRange(){return{values:[['Cuisine','Cost'],['North Indian',10]],load(){}}}};
  const context={window:{waitForOfficeReady:async()=>{}},console,Excel:{run:async fn=>fn({
    workbook:{worksheets:{getItem(n){return n==='Pivot Analysis'?pivotSheet:sourceSheet},getActiveWorksheet(){return sourceSheet}}},
    sync:async()=>{calls.syncs++}
  })}};
  vm.createContext(context);
  return{context,calls,pivotRange};
}

(async()=>{
  const {context,calls,pivotRange}=mock();
  vm.runInContext(fs.readFileSync(path.join(__dirname,'..','web','excel_native_chart.js'),'utf8'),context);

  const placement={
    sheet:'Pivot Analysis',
    pivotRangeAddress:pivotRange.address,
    chartStartCell:'D1',
    chartEndCell:'L20'
  };
  const chartResult=await context.window.createNativeExcelChart(JSON.stringify({
    sheetName:placement.sheet,
    sourceRangeAddress:placement.pivotRangeAddress,
    columns:['Cuisine','Cost'],
    rows:[{}],
    categoryColumnIndex:0,
    valueColumnIndex:1,
    chartType:'bar',
    title:'Top 5 Cuisines by Total Cost',
    chartName:'InsightFlow_Pivot_Chart',
    startCell:placement.chartStartCell,
    endCell:placement.chartEndCell
  }));
  assert.strictEqual(chartResult.success,true);
  assert.strictEqual(chartResult.stage,'chart-verified');
  assert.strictEqual(calls.sourceAddress,pivotRange.address);
  assert.strictEqual(calls.type,'BarClustered');
  assert.strictEqual(calls.seriesBy,'Columns');
  assert.deepStrictEqual(calls.position,['D1','L20']);

  // The handoff contract carries the real PivotTable output, not a second
  // aggregation. The five expected rows are exactly the chart source rows.
  assert.deepStrictEqual(pivotRange.values.slice(1).map(r=>r[0]),['North Indian','Chinese','Indian','Biryani','South Indian']);
  assert.deepStrictEqual(pivotRange.values.slice(1).map(r=>r[1]),[3226910,1990023,1722723,1470121,1064058]);

  console.log('excel_pivot_chart_integration_test: PASS');
})().catch(e=>{console.error(e);process.exit(1)});