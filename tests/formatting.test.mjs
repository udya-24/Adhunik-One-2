import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import ts from "typescript";

function moduleAt(path, dependencies = {}) {
  const source = fs.readFileSync(path, "utf8");
  const js = ts.transpileModule(source, {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
  const mod = {exports:{}};
  new Function("exports","module","require",js)(mod.exports, mod, name => {
    assert.ok(name in dependencies, `Missing dependency ${name}`);
    return dependencies[name];
  });
  return mod.exports;
}
const dates = moduleAt("lib/formatting/date.ts");
const text = moduleAt("lib/formatting/text.ts");
const addresses = moduleAt("lib/crm/order-address.ts", {"@/lib/formatting/text":text});

test("India formatting is identical regardless of process timezone", () => {
  const original = process.env.TZ;
  try {
    for (const zone of ["UTC", "America/Los_Angeles", "Asia/Tokyo"]) {
      process.env.TZ = zone;
      assert.equal(dates.formatDateTime("2026-10-09T00:54:23Z"), "09-Oct-2026 06:24 AM");
      assert.equal(dates.formatDateTime("2026-10-08T20:30:00Z"), "09-Oct-2026 02:00 AM");
      assert.equal(dates.formatDate("2026-10-09"), "09-Oct-2026");
      assert.equal(dates.formatTime("2026-10-09T06:30:00Z"), "12:00 PM");
      assert.equal(dates.formatTime("2026-10-08T18:30:00Z"), "12:00 AM");
      assert.equal(dates.indiaDateInput("2026-10-08T20:30:00Z"), "2026-10-09");
      assert.equal(dates.indiaDateTimeInput("2026-10-09T00:54:23Z"), "2026-10-09T06:24");
      assert.equal(dates.indiaDateTimeToIso("2026-10-09T06:24"), "2026-10-09T00:54:00.000Z");
    }
  } finally { if (original === undefined) delete process.env.TZ; else process.env.TZ = original; }
});

test("missing dates and India day ranges stay deterministic", () => {
  for (const value of [null,undefined,"","invalid"]) assert.equal(dates.formatDateTime(value), "—");
  assert.equal(dates.formatDate(null,""), "");
  const {start,end} = dates.indiaDayRange("2026-10-08T20:30:00Z");
  assert.equal(start.toISOString(), "2026-10-08T18:30:00.000Z");
  assert.equal(end.toISOString(), "2026-10-09T18:30:00.000Z");
  assert.equal(dates.formatMonth(2026,10,true), "October 2026");
});

test("single and repeated UTF-8 corruption repairs without damaging multilingual text", () => {
  const corrupt=value=>new TextDecoder("windows-1252").decode(new TextEncoder().encode(value));
  const once=corrupt("—"),twice=corrupt(once),thrice=corrupt(twice);
  for (const value of [once,twice,thrice]) assert.equal(text.cleanText(value), "—");
  assert.equal(text.cleanText("\u00e2\u20ac\u2122"), "’");
  assert.equal(text.cleanText("—"+corrupt("’")), "—’");
  assert.equal(text.cleanText(corrupt("मराठी हिंदी")), "मराठी हिंदी");
  assert.equal(text.cleanText("\u00c2\u00b7"), "·");
  assert.equal(text.cleanText("\u00c3\u00a9"), "é");
  for (const value of ["₹ 1,000", "मराठी हिंदी", "Café", "São Paulo", "— × mm³"]) assert.equal(text.cleanText(value), value);
  assert.deepEqual(text.cleanJson({notes:"\u00e2\u20ac\u2122",items:["\u00c2\u00b7"],empty:null,amount:10}), {notes:"’",items:["·"],empty:null,amount:10});
  for (const value of [null,undefined,""," ","\ufffd"]) assert.equal(text.displayText(value), "—");
});

test("address overrides are order-local copies and legacy forms can omit them", () => {
  const master={address_line_1:"A-25 Industrial Area Delhi",city:"Delhi",country:"India"};
  const snapshot=addresses.addressSnapshot(master);
  snapshot.address_line_1="Warehouse 2, Plot 15";snapshot.city="Lucknow";
  assert.equal(master.address_line_1,"A-25 Industrial Area Delhi");
  assert.equal(master.city,"Delhi");
  const form=new FormData();for(const [key,value] of Object.entries(snapshot)) form.set(`shipping_${key}`, value);
  assert.deepEqual(addresses.readAddressSnapshot(form,"shipping"),snapshot);
  assert.equal(addresses.readAddressSnapshot(form,"billing"),undefined);
});

test("database fetch repairs JSON reads/writes and preserves file upload bytes", async () => {
  const {utf8Fetch}=moduleAt("lib/supabase/utf8-fetch.ts",{"@/lib/formatting/text":text});
  const original=globalThis.fetch;
  try {
    let sent;
    globalThis.fetch=async (_,options)=>{sent=options.body;return new Response(JSON.stringify({description:"\u00e2\u20ac\u2122"}),{headers:{"content-type":"application/json","content-length":"999"}})};
    const result=await utf8Fetch("https://local.test",{body:JSON.stringify({notes:"\u00c2\u00b7"})});
    assert.equal(JSON.parse(sent).notes,"·");assert.deepEqual(await result.json(),{description:"’"});
    assert.equal(result.headers.get("content-type"),"application/json; charset=utf-8");assert.equal(result.headers.get("content-length"),null);
    const binary=new Uint8Array([0,1,255]);globalThis.fetch=async (_,options)=>{sent=options.body;return new Response(binary,{headers:{"content-type":"application/pdf"}})};
    const file=await utf8Fetch("https://local.test",{body:binary});assert.equal(sent,binary);assert.deepEqual(new Uint8Array(await file.arrayBuffer()),binary);
  } finally { globalThis.fetch=original; }
});
