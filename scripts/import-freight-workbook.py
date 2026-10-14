"""Extract source data using Python's standard library; no Excel dependency required."""
import sys, zipfile, xml.etree.ElementTree as ET, json, hashlib
from pathlib import Path
source=Path(sys.argv[1]); z=zipfile.ZipFile(source)
ns={'s':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
strings=[''.join(x.itertext()) for x in ET.fromstring(z.read('xl/sharedStrings.xml'))]
def sheet(i):
 result=[]
 for row in ET.fromstring(z.read(f'xl/worksheets/sheet{i}.xml')).findall('s:sheetData/s:row',ns):
  cells={}
  for c in row:
   v=c.find('s:v',ns); value=v.text if v is not None else ''
   cells[c.get('r')]='' if not value else strings[int(value)] if c.get('t')=='s' else value
  result.append(cells)
 return result
def col(row,c):
 return next((v for k,v in row.items() if k.rstrip('0123456789')==c),'')
calc=sheet(1); summary=sheet(2); details=sheet(3)
rates=[{'name':col(r,'AD'),'zone':col(r,'AE'),'type':col(r,'AF'),'rate':float(col(r,'AG'))} for r in calc if col(r,'AG') and col(r,'AG')!='Rate']
pins={}; oda={}; city_zones={}
# Preserve first-match VLOOKUP behavior and the precise sheets referenced by formulas.
for r in sheet(5)[1:]:
 pin=col(r,'B'); oda.setdefault(pin,col(r,'H'))
for r in sheet(4)[1:]:
 pin=col(r,'B')
 city_zones.setdefault(col(r,'F').casefold(),col(r,'J'))
 if pin.isdigit() and len(pin)==6:
  pins.setdefault(pin,{'city':col(r,'F'),'state':col(r,'G'),'zone':col(r,'J'),'location_type':oda.get(pin),'source_row':next(iter(r)).lstrip('ABCDEFGHIJKLMNOPQRSTUVWXYZ')})
formulas={}
for i in [1,2,3]:
 for c in ET.fromstring(z.read(f'xl/worksheets/sheet{i}.xml')).findall('.//s:c',ns):
  f=c.find('s:f',ns)
  if f is not None and f.text: formulas[f'{i}!{c.get("r")}']=f.text
# Values extracted from formula constants, with assertions to fail on changed workbook rules.
expected={'2!B7':'+IF($B$6<20,20,ROUND(($B$6),0))','2!B14':'+ROUND(($B$10*15%),0)','2!B15':'+ROUND(($B$5*0.2%),0)','2!B19':'+ROUND(($B$18*18%),0)','3!H3':'+C3*D3*E3*6/1728'}
for cell,formula in expected.items():
 if formulas.get(cell)!=formula: raise ValueError(f'Workbook logic changed at {cell}: review importer')
config={'source':source.name,'sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'partner':'Delhivery','rates':rates,'rules':{'kg_per_cubic_foot':6,'minimum_weight':20,'fuel_percent':15,'insurance_percent':0.2,'minimum_insurance':100,'oda_per_kg':3,'minimum_oda':500,'eway_charge':float(col(summary[12],'B')),'minimum_taxable':600,'gst_percent':18},'formulas':formulas,'reference':{'destination':'360024','weight':1000,'shipment_value':150000,'base_freight':12000,'taxable':14250,'gst':2565,'total':16815},'pins':pins,'city_zones':city_zones}
out=Path('lib/dispatch/freight-workbook.json');out.write_text(json.dumps(config,separators=(',',':'))+'\n');print(f'Imported {len(pins)} PIN codes and {len(rates)} rate rows into {out}')
