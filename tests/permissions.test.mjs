import test from'node:test';import assert from'node:assert/strict';import{normalizeGrant,moduleVisible,firstVisiblePurchaseHref,purchaseTabs}from'../lib/security/permissions.ts';
test('Edit automatically includes View',()=>assert.deepEqual(normalizeGrant(false,true),{canView:true,canEdit:true}));
test('removing View also removes Edit when UI supplies both disabled',()=>assert.deepEqual(normalizeGrant(false,false),{canView:false,canEdit:false}));
test('Purchase module is hidden without any section View grant',()=>assert.equal(moduleVisible({'purchase.orders':{canView:false,canEdit:false}},'purchase'),false));
test('Purchase module is visible with one section View grant',()=>assert.equal(moduleVisible({'purchase.orders':{canView:true,canEdit:false}},'purchase'),true));
test('Purchase landing selects the first visible authorized section',()=>assert.equal(firstVisiblePurchaseHref({'purchase.overview':{canView:false,canEdit:false},'purchase.indents':{canView:false,canEdit:false},'purchase.suppliers':{canView:false,canEdit:false},'purchase.orders':{canView:true,canEdit:false},'purchase.material_receipts':{canView:false,canEdit:false}}),'/purchase/orders'));

test('Management Approval follows Purchase Orders and reuses its permission grant',()=>{
 const index=purchaseTabs.findIndex(x=>x.label==='Management Approval');
 assert.equal(purchaseTabs[index-1].label,'Purchase Orders');
 assert.equal(purchaseTabs[index+1].label,'Material Receipts');
 assert.equal(purchaseTabs[index].key,'purchase.orders');
});
