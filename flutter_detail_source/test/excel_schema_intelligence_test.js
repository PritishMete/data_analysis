const fs=require('fs');const path=require('path');const vm=require('vm');const assert=require('assert');const context={window:{},console};vm.createContext(context);vm.runInContext(fs.readFileSync(path.join(__dirname,'..','web','excel_schema_intelligence.js'),'utf8'),context);const s=context.window.InsightFlowSchemaIntelligence;assert.strictEqual(s.resolveDimension(['cuisine','cost'],'cuisines').index,0);assert.strictEqual(s.resolveDimension(['city','cost'],'cities').index,0);const amb=s.resolveDimension(['City Center','City Name','cost'],'city');assert.strictEqual(amb.index,-1);assert.strictEqual(amb.candidates.length,2);assert.strictEqual(s.resolveMeasure(['cost'],'total cost').index,0);
const priceSchema=['Brand','marked_price','discounted_price'];
assert.strictEqual(s.resolveMeasure(priceSchema,'marked price').index,1);
assert.strictEqual(s.resolveMeasure(priceSchema,'discounted price').index,2);
assert.strictEqual(s.resolveDimension(['cuisine','cost'],'cuisines').index,0);
assert.strictEqual(s.resolveMeasure(['sale price','unit price'],'price').index,-1);
assert.strictEqual(s.resolveMeasure(['Revenue','Revenue Amount'],'revenue').index,-1);
console.log('excel_schema_intelligence_test: PASS');