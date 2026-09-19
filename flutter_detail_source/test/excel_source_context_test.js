const fs=require('fs');const vm=require('vm');const assert=require('assert');
const source=fs.readFileSync(require('path').join(__dirname,'..','web','excel_helper.js'),'utf8');
const state={active:'Quality_Report',settings:{}};
const sourceSheet={name:'Restaurants',isNullObject:false};
const reportSheet={name:'Quality_Report',isNullObject:false};
const settings={
  getItemOrNullObject(key){return {key,value:state.settings[key],isNullObject:state.settings[key]===undefined,load(){}};},
  add(key,value){state.settings[key]=value;}
};
const workbook={
  settings,
  worksheets:{
    getActiveWorksheet(){return state.active==='Quality_Report'?reportSheet:sourceSheet;},
    getItemOrNullObject(name){return name==='Restaurants'?sourceSheet:(name==='Quality_Report'?reportSheet:{name,isNullObject:true});},
    getItem(name){return name==='Restaurants'?sourceSheet:reportSheet;}
  }
};
const context={console,window:{waitForOfficeReady:async()=>{}},Excel:{run:async fn=>fn({workbook,sync:async()=>{}})}};
vm.createContext(context);vm.runInContext(source,context);

(async()=>{
  state.settings['InsightFlow.SourceWorksheet']='Restaurants';
  const restored=await context.window.getInsightFlowSourceWorksheetName();
  assert.strictEqual(restored,'Restaurants');

  state.settings={};
  state.active='Quality_Report';
  assert.strictEqual(await context.window.getInsightFlowSourceWorksheetName(),null);

  state.active='Restaurants';
  assert.strictEqual(await context.window.setInsightFlowSourceWorksheetName('Restaurants'),true);
  assert.strictEqual(state.settings['InsightFlow.SourceWorksheet'],'Restaurants');

  assert.strictEqual(await context.window.setInsightFlowSourceWorksheetName('Quality_Report'),false);
  console.log('excel_source_context_test: PASS');
})().catch(e=>{console.error(e);process.exit(1)});