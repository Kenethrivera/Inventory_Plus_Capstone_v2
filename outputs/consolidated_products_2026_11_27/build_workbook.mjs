import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire('C:/Program Files/WindowsApps/OpenAI.CodexPrimaryRuntime.v26-1123-915-0_26.1123.915.0_x64__3k8sg7r9htsxt/dependencies/node/node_modules/runtime-loader.js');
const { Workbook, SpreadsheetFile } = require('@oai/artifact-tool');
const dir = path.dirname(fileURLToPath(import.meta.url));
const data = JSON.parse(await fs.readFile(path.join(dir, 'consolidated_products.json'), 'utf8'));
const products = data.products.map((p, i) => ({...p, id:`P${String(i+1).padStart(4,'0')}`}));
const idByOldId = new Map(products.flatMap(p => p.members.map(id => [id, p.id])));
const workbook = Workbook.create();
const main = workbook.worksheets.add('Products');
const mapping = workbook.worksheets.add('Source mapping');
main.showGridLines = false;
mapping.showGridLines = false;

main.getRange('A2').values = [['Consolidated product list']];
main.getRange('A3').values = [['Names and equivalent units are combined. Different sizes and colors stay separate. Review flagged entries before using them in inventory.']];
main.getRange('A5:H5').values = [[
  'Product ID','Product name','Unit','Category','Requires loading',
  'Original entries','Source lines','Review'
]];
const rows = products.map(p => [p.id,p.name,p.unit,p.category,p.unit.toLowerCase()==='tin',
  p.original_entries,p.materials+p.sales+p.receipts,p.review]);
main.getRangeByIndexes(5,0,rows.length,8).values = rows;
main.getRange(`D6:D${rows.length+5}`).conditionalFormats.add('containsText', {
  text:'Needs category review',format:{fill:'#FFF1CC',font:{color:'#8A4A00',bold:true}}
});
main.getRange(`H6:H${rows.length+5}`).conditionalFormats.add('notContainsBlanks', {
  format:{fill:'#FFF1CC',font:{color:'#8A4A00'}}
});

mapping.getRange('A2').values = [['Original names to consolidated products']];
mapping.getRange('A3').values = [['Every catalog entry is mapped to one product above. Original names and units remain visible for review.']];
mapping.getRange('A5:G5').values = [[
  'Original ID','Original product name','Original unit','Product ID',
  'Consolidated product','Consolidated unit','Category'
]];
const mapped = data.mapping.map(m => [m.old_id,m.old_name,m.old_unit || '(missing)',
  idByOldId.get(m.old_id),m.new_name,m.new_unit,m.category]);
mapping.getRangeByIndexes(5,0,mapped.length,7).values = mapped;

for (const [sheet,lastCol,count] of [[main,'H',rows.length],[mapping,'G',mapped.length]]) {
  sheet.getRange(`A2:${lastCol}${count+5}`).format.font = {name:'Arial',size:10,color:'#243040'};
  sheet.getRange('A2').format.font = {name:'Arial',size:15,bold:true,color:'#172B4D'};
  sheet.getRange('A3').format.font = {name:'Arial',size:10,italic:true,color:'#637084'};
  sheet.getRange(`A5:${lastCol}5`).format = {
    fill:'#193B5B',font:{name:'Arial',size:10,bold:true,color:'#FFFFFF'},
    rowHeight:31,verticalAlignment:'center',wrapText:true
  };
  sheet.getRange(`A6:${lastCol}${count+5}`).format.rowHeight = 22;
  sheet.freezePanes.freezeRows(5);
}
for (const [col,width] of Object.entries({A:15,B:49,C:17,D:34,E:18,F:19,G:16,H:43}))
  main.getRange(`${col}:${col}`).format.columnWidth = width;
for (const [col,width] of Object.entries({A:16,B:52,C:18,D:16,E:52,F:19,G:34}))
  mapping.getRange(`${col}:${col}`).format.columnWidth = width;
main.tabColor = '#193B5B';
mapping.tabColor = '#74899E';

workbook.recalculate();
for (const [sheetName,range,label] of [
  ['Products','A2:H13','products'],['Source mapping','A2:G12','mapping']
]) {
  const check = await workbook.inspect({kind:'table',range:`'${sheetName}'!${range}`,
    include:'values',tableMaxRows:12,tableMaxCols:8,maxChars:2600});
  console.log(label,check.ndjson);
  const preview = await workbook.render({sheetName,range,scale:1,format:'png'});
  await fs.writeFile(path.join(dir,`${label}_preview.png`),
    new Uint8Array(await preview.arrayBuffer()));
}
const output = await SpreadsheetFile.exportXlsx(workbook);
const destination = path.join(dir,'Consolidated_Products.xlsx');
await output.save(destination);
console.log(JSON.stringify({file:destination,products:rows.length,mapped:mapped.length,
  review:products.filter(p=>p.review).length}));
