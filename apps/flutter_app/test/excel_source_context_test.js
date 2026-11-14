const fs=require('fs');const vm=require('vm');const assert=require('assert');
const source=fs.readFileSync(require('path').join(__dirname,'..','web','excel_helper.js'),'utf8');
const state={active:'Quality_Report',settings:{},sourceMatrix:[['Product','marked_price'],['A',100]]};
const sourceSheet={name:'Restaurants',id:'sheet-source-1',isNullObject:false};
const reportSheet={name:'Quality_Report',id:'sheet-report-1',isNullObject:false};
const settings={
  getItemOrNullObject(key){return {key,value:state.settings[key],isNullObject:state.settings[key]===undefined,load(){}};},
  add(key,value){state.settings[key]=value;}
};
const workbook={
  getSelectedRange(){return {address:'Restaurants!A1:B2',rowCount:2,columnCount:2,load(){},getCurrentRegion(){return {address:'Restaurants!A1:B2',rowCount:2,columnCount:2,load(){}};}};},
  settings,
  worksheets:{
    getActiveWorksheet(){return state.active==='Quality_Report'?reportSheet:sourceSheet;},
    getItemOrNullObject(name){return name==='Restaurants'||name==='sheet-source-1'?sourceSheet:(name==='Quality_Report'||name==='sheet-report-1'?reportSheet:{name,isNullObject:true});},
    getItem(name){return name==='Restaurants'?sourceSheet:reportSheet;}
  }
};
const context={console,window:{waitForOfficeReady:async()=>{},insightflowRequireMutationAuthorization:async()=>true},Excel:{run:async fn=>fn({workbook,sync:async()=>{}})}};
vm.createContext(context);vm.runInContext(source,context);

(async()=>{
  state.settings['InsightFlow.SourceWorksheet']=JSON.stringify({id:'sheet-source-1',name:'Restaurants'});
  const restored=await context.window.getInsightFlowSourceWorksheetName();
  assert.strictEqual(restored,'Restaurants');

  state.settings={};
  state.active='Restaurants';
  assert.strictEqual(await context.window.establishInsightFlowSourceFromActiveWorksheet(),'Restaurants');
  const storedRange=JSON.parse(state.settings['InsightFlow.SourceWorksheet']);
  assert.strictEqual(storedRange.rangeAddress,'Restaurants!A1:B2');
  state.active='Quality_Report';
  assert.strictEqual(await context.window.getInsightFlowSourceWorksheetName(),null);

  state.active='Restaurants';
  assert.strictEqual(await context.window.establishInsightFlowSourceFromActiveWorksheet(),'Restaurants');
  const stored=JSON.parse(state.settings['InsightFlow.SourceWorksheet']);
  assert.strictEqual(stored.id,'sheet-source-1');
  assert.strictEqual(stored.name,'Restaurants');

  state.active='Quality_Report';
  assert.strictEqual(await context.window.getInsightFlowSourceWorksheetName(),'Restaurants');

  sourceSheet.name='Products';
  assert.strictEqual(await context.window.getInsightFlowSourceWorksheetName(),'Products');

  assert.strictEqual(await context.window.setInsightFlowSourceWorksheetName('Quality_Report'),false);
  console.log('excel_source_context_test: PASS');
})().catch(e=>{console.error(e);process.exit(1)});