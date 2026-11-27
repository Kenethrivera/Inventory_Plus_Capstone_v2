import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire('C:/Program Files/WindowsApps/OpenAI.CodexPrimaryRuntime.v26-1123-915-0_26.1123.915.0_x64__3k8sg7r9htsxt/dependencies/node/node_modules/runtime-loader.js');
const { Workbook, SpreadsheetFile } = require('@oai/artifact-tool');

const dir = path.dirname(new URL(import.meta.url).pathname).replace(/^\/(?:[A-Za-z]:)/, m => m.slice(1));
const lines = JSON.parse(await fs.readFile(path.join(dir, 'source_lines.json'), 'utf8'));
const categoryMap = JSON.parse(await fs.readFile(path.join(dir, 'category_map.json'), 'utf8'));
const categoryFor = name => categoryMap[name.trim().toLocaleLowerCase()] || {category:'Needs category review',basis:'Unclear source name',review_note:'Confirm the product label or brand'};
const keyOf = x => `${x.name.trim().replace(/\s+/g, ' ').toLocaleLowerCase()}\u0000${x.unit.trim().replace(/\s+/g, ' ').toLocaleLowerCase()}`;
const groups = new Map();
for (const line of lines.filter(x => x.name)) {
  const key = keyOf(line);
  if (!groups.has(key)) groups.set(key, []);
  groups.get(key).push(line);
}
const products = [...groups.values()].sort((a,b) => a[0].name.localeCompare(b[0].name) || a[0].unit.localeCompare(b[0].unit));
const productIds = new Map(products.map((g,i) => [keyOf(g[0]), `P${String(i+1).padStart(4,'0')}`]));
const asDate = s => s ? new Date(`${s}T00:00:00Z`) : null;
const workbook = Workbook.create();
const catalog = workbook.worksheets.add('Products');
const source = workbook.worksheets.add('Source Lines');
catalog.showGridLines = false;
source.showGridLines = false;

catalog.getRange('A2').values = [['Product catalog']];
catalog.getRange('A3').values = [['Categories use product descriptions, sales labels and verified product names. Unclear names remain for review. Prices are historical; receipt dates follow the Nov 2–9 filename.']];
catalog.getRange('A5:P5').values = [[
  'Product ID','Product name','Unit as written','Product category','Category basis','Materials lines','Sales lines','Receipt lines',
  'Lowest unit price (PHP)','Highest unit price (PHP)','First seen','Last seen','Sources',
  'Name variants','Review','Notes from source'
]];
const rows = products.map(g => {
  const sales = g.filter(x => x.source === 'Sales');
  const materials = g.filter(x => x.source === 'Materials');
  const receipts = g.filter(x => x.source === 'Receipts');
  const preferred = sales[0] || receipts[0] || g[0];
  const prices = g.map(x => x.unit_price).filter(x => typeof x === 'number');
  const dates = g.map(x => x.date).filter(Boolean).sort();
  const names = [...new Set(g.map(x => x.name))];
  const categories = [...new Set(sales.map(x => x.category).filter(Boolean))];
  const notes = [...new Set(g.map(x => x.notes).filter(Boolean))];
  const classified = categoryFor(preferred.name);
  const review = [];
  if (!preferred.unit) review.push('Unit missing');
  if (g.some(x => x.variance && Math.abs(x.variance) > 0.001)) review.push('Amount discrepancy');
  if (g.some(x => /\?|verify|unclear|possibly|implied/i.test(x.notes || '') || /\?/.test(x.name))) review.push('Check source wording');
  if (categories.length > 1) review.push('Category differs');
  if (categories.some(x => x !== classified.category)) review.push('Sales category needs review');
  if (classified.category === 'Needs category review') review.push(classified.review_note);
  else if (classified.review_note && classified.basis !== 'Product identified') review.push(classified.review_note);
  return [productIds.get(keyOf(g[0])), preferred.name, preferred.unit, classified.category, classified.basis,
    materials.length, sales.length, receipts.length, prices.length ? Math.min(...prices) : null,
    prices.length ? Math.max(...prices) : null, asDate(dates[0]), asDate(dates.at(-1)),
    [materials.length ? 'Materials' : null, sales.length ? 'Sales' : null, receipts.length ? 'Receipts' : null].filter(Boolean).join(', '),
    names.length > 1 ? names.join('; ') : '', review.join('; '), notes.join('; ')];
});
catalog.getRangeByIndexes(5,0,rows.length,16).values = rows;
catalog.getRange(`I6:J${rows.length+5}`).setNumberFormat('"₱"#,##0.00');
catalog.getRange(`K6:L${rows.length+5}`).setNumberFormat('yyyy-mm-dd');
catalog.getRange(`F6:H${rows.length+5}`).setNumberFormat('#,##0');
catalog.getRange(`D6:D${rows.length+5}`).conditionalFormats.add('containsText', {text:'Needs category review',format:{fill:'#FFF1CC',font:{color:'#8A4A00',bold:true}}});

source.getRange('A2').values = [['Source lines']];
source.getRange('A3').values = [['Original line details. Receipt dates follow the Nov 2–9 filename; source date cells display Feb 11–Sep 11.']];
source.getRange('A5:P5').values = [[
  'Product ID','Source','Sheet','Source row','Group / order','Date','Product name as written',
  'Unit as written','Quantity','Unit price (PHP)','Price basis','Written amount (PHP)',
  'Calculated amount (PHP)','Variance (PHP)','Reviewed category','Source notes'
]];
const details = lines.map(x => [x.name ? productIds.get(keyOf(x)) : '', x.source, x.sheet, x.row, x.group,
  asDate(x.date), x.name, x.unit, x.qty, x.unit_price, x.price_basis, x.amount,
  x.calculated_amount, x.variance, categoryFor(x.name).category, x.notes]);
source.getRangeByIndexes(5,0,details.length,16).values = details;
source.getRange(`F6:F${details.length+5}`).setNumberFormat('yyyy-mm-dd');
source.getRange(`I6:I${details.length+5}`).setNumberFormat('#,##0.##');
source.getRange(`J6:J${details.length+5}`).setNumberFormat('"₱"#,##0.00');
source.getRange(`L6:N${details.length+5}`).setNumberFormat('"₱"#,##0.00');

for (const [sheet, lastCol, count] of [[catalog,'P',rows.length],[source,'P',details.length]]) {
  sheet.getRange(`A2:${lastCol}${count+5}`).format.font = {name:'Arial',size:10,color:'#243040'};
  sheet.getRange('A2').format.font = {name:'Arial',size:15,bold:true,color:'#172B4D'};
  sheet.getRange('A3').format.font = {name:'Arial',size:10,italic:true,color:'#637084'};
  sheet.getRange(`A5:${lastCol}5`).format = {fill:'#193B5B',font:{name:'Arial',size:10,bold:true,color:'#FFFFFF'},rowHeight:32,verticalAlignment:'center',wrapText:true};
  sheet.getRange(`A6:${lastCol}${count+5}`).format.rowHeight = 22;
  sheet.freezePanes.freezeRows(5);
}
for (const [col,width] of Object.entries({A:16,B:55,C:18,D:30,E:26,F:15,G:13,H:15,I:22,J:22,K:17,L:17,M:22,N:55,O:38,P:53})) catalog.getRange(`${col}:${col}`).format.columnWidth = width;
for (const [col,width] of Object.entries({A:15,B:14,C:17,D:13,E:16,F:14,G:38,H:18,I:13,J:19,K:20,L:23,M:24,N:20,O:30,P:53})) source.getRange(`${col}:${col}`).format.columnWidth = width;
catalog.tabColor = '#193B5B';
source.tabColor = '#74899E';
workbook.recalculate();
for (const [sheetName,range,previewName] of [['Products','A2:P14','products_preview.png'],['Source Lines','A2:P12','source_preview.png']]) {
  const check = await workbook.inspect({kind:'table',range:`'${sheetName}'!${range}`,include:'values',tableMaxRows:12,tableMaxCols:16,maxChars:3200});
  console.log(sheetName, check.ndjson);
  const preview = await workbook.render({sheetName,range,scale:1,format:'png'});
  await fs.writeFile(path.join(dir,previewName),new Uint8Array(await preview.arrayBuffer()));
}
const output = await SpreadsheetFile.exportXlsx(workbook);
const dest = path.join(dir,'Inventory_Plus_Product_Catalog.xlsx');
await output.save(dest);
console.log(JSON.stringify({file:dest, products:rows.length, sourceLines:details.length}));
