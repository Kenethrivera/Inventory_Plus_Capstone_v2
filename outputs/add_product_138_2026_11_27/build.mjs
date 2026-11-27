import fs from 'node:fs/promises';
import { createRequire } from 'node:module';

const require = createRequire('C:/Program Files/WindowsApps/OpenAI.CodexPrimaryRuntime.v26-1123-915-0_26.1123.915.0_x64__3k8sg7r9htsxt/dependencies/node/node_modules/entry.js');
const { Workbook, SpreadsheetFile } = require('@oai/artifact-tool');
const outDir = new URL('.', import.meta.url);
const rows = JSON.parse(await fs.readFile(new URL('source_data.json', outDir), 'utf8'));
if (rows.length !== 138 || rows.some((r, i) => r.id !== i + 1)) throw new Error('Expected source products 1–138');

const brands = {
  33:'Titan', 37:'Davies', 38:'Boysen', 43:'Boysen', 45:'Nixon', 46:'Titan', 47:'Titan',
  52:'Sinclair', 60:'Nation', 80:'Davies', 92:'Boysen', 98:'Buildrite', 133:'Bosny'
};
const models = {39:'601',44:'AE-121',47:'T-5135',75:'B-2550',80:'SR-411',81:'ROS-530',82:'ROS-862',88:'K-201',105:'B-1254',114:'B-1750',115:'B-1250',123:'B-2705'};
const sizes = {5:'2 in',6:'1 1/2 in',8:'1 in',9:'4 in',11:'7 in',12:'4 in',15:'3 in',17:'4 in',19:'4 in',20:'7 in',21:'2 1/2 in',22:'1/2 in'};
const colors = {
  30:'White',33:'Tulle White',34:'Off-white',36:'Milk Tea',37:'White',38:'White',39:'Smoke Gray',
  40:'Dark Semi Gray',41:'Dark Seal Gray',46:'Mocha Blanch',47:'Tinge of Gray',48:'Wind Whisper',
  49:'White',51:'Black',52:'Cascara',53:'Sunny Days',54:'White',55:'Black',56:'Chocolate Brown',
  57:'Medium / Modern Gray',60:'Maple',61:'Black',62:'Sky Blue',63:'Lemon Yellow',64:'Aluminum Silver',
  65:'Caramel Brown',67:'Black',68:'Gray',69:'Yellow',70:'Blue',71:'Green',73:'Gray / Smoke Gray',
  74:'Terra Cotta',75:'Baguio Green',76:'Chocolate Brown',77:'Pacific Blue',78:'Pacific Blue',
  79:'Tulle White',80:'Cream Surprise',83:'White',101:'Gray',102:'White',103:'Red Oxide',109:'Black',
  117:'White',118:'Black',119:'Mahogany',120:'Raw Sienna',123:'Maple',124:'Oak',125:'Walnut',
  134:'Gray',135:'Gold',137:'Blue',138:'Raw Sienna'
};
function unit(breakdown) {
  const parts = String(breakdown).split(',');
  if (parts.length !== 1) return null;
  const b = parts[0].trim();
  const fractional = b.match(/^\d+(?:\.\d+)? \((1\/4|1\/2) ltr\)$/);
  if (fractional) return `${fractional[1]} ltr`;
  const plain = b.match(/^\d+(?:\.\d+)? (pcs|kilo|ltr|gal|tin|btl|bag|pack|pint|mtr|set)$/);
  return plain ? plain[1] : null;
}

const wb = Workbook.create();
const products = wb.worksheets.add('Products');
const evidence = wb.worksheets.add('Source evidence');
products.showGridLines = false;
evidence.showGridLines = false;
products.tabColor = '#C94108';
evidence.tabColor = '#A7A09C';

products.getRange('A2').values = [['Products for Add New Product']];
products.getRange('A3').values = [['143 catalog rows from 138 source groups. Sandpaper grits are separate. Tin items require truck loading; other blank loading fields need review.']];
products.getRange('A5:L5').values = [[
  'Source ID','Product Name','Brand / Manufacturer','Model #','Size','Color','Price (₱)','Category',
  'Initial Stock','Unit of Measure','Heavy / truck loading required','Detailed Description'
]];
const sandpaper = [
  ['1-100','Sandpaper (Liha) #100','Grit #100',null],
  ['1-120','Sandpaper (Liha) #120','Grit #120',null],
  ['1-150','Sandpaper (Liha) #150','Grit #150',null],
  ['1-156','Sandpaper (Liha) #156','Grit #156','Source lists S/P #156; verify this grit before entry.'],
  ['1-240','Sandpaper (Liha) #240','Grit #240',null],
  ['1-other','Sandpaper (Liha) — Unspecified grit',null,'Source also contains generic Sand Paper and LIHA #? entries.']
].map(([id,name,size,description]) => [
  id,name,null,null,size,null,null,rows[0].category,null,null,null,description
]);
const remainingProducts = rows.slice(1).map(r => [
  r.id,r.name,brands[r.id] || null,models[r.id] || null,sizes[r.id] || null,colors[r.id] || null,
  null,r.category,null,unit(r.unit_breakdown),unit(r.unit_breakdown)==='tin' ? 'Yes' : null,null
]);
const productValues = [...sandpaper,...remainingProducts];
const productEnd = 5 + productValues.length;
if (productValues.length !== 143) throw new Error('Expected 143 catalog rows after splitting sandpaper');
products.getRange(`A6:L${productEnd}`).values = productValues;

evidence.getRange('A2').values = [['Source sales evidence']];
evidence.getRange('A3').values = [['Source: Consolidated_Sales_Product_Summary.xlsx, Merged Product Count, rows 5–142. Sandpaper sales remain combined because quantities by grit are unavailable.']];
evidence.getRange('A5:I5').values = [[
  'Source ID','Source row','Merged product name','Category','Line items','Sales quantity',
  'Unit breakdown','Sales total (₱)','Raw variants merged'
]];
evidence.getRange('A6:I143').values = rows.map(r => [
  r.id,r.source_row,r.name,r.category,r.line_items,r.sales_qty,r.unit_breakdown,r.sales_php,r.variants
]);

for (const sheet of [products,evidence]) {
  const last = sheet === products ? 'L' : 'I';
  const end = sheet === products ? productEnd : 143;
  sheet.getRange(`A2:${last}${end}`).format.font = { name:'Arial', size:10, color:'#302D2C' };
  sheet.getRange('A2').format.font = { name:'Arial', size:15, bold:true, color:'#2D2927' };
  sheet.getRange('A2').format.rowHeight = 30;
  sheet.getRange('A3').format.font = { name:'Arial', size:10, italic:true, color:'#736B67' };
  sheet.getRange('A3').format.rowHeight = 23;
  sheet.getRange(`A5:${last}5`).format = {
    fill:'#C94108',font:{ name:'Arial', size:10, bold:true, color:'#FFFFFF' },
    rowHeight:32, verticalAlignment:'center', horizontalAlignment:'center', wrapText:true
  };
  sheet.getRange(`A5:${last}5`).format.borders = { bottom:{style:'medium',color:'#A53106'} };
  sheet.getRange(`A6:${last}${end}`).format.rowHeight = 22;
  sheet.getRange(`A6:${last}${end}`).format.verticalAlignment = 'center';
  sheet.freezePanes.freezeRows(5);
}

const pWidths = {A:10,B:46,C:22,D:14,E:16,F:24,G:15,H:30,I:15,J:18,K:25,L:42};
for (const [c,w] of Object.entries(pWidths)) products.getRange(`${c}:${c}`).format.columnWidth = w;
const eWidths = {A:10,B:12,C:47,D:31,E:14,F:17,G:25,H:20,I:75};
for (const [c,w] of Object.entries(eWidths)) evidence.getRange(`${c}:${c}`).format.columnWidth = w;
products.getRange(`G6:G${productEnd}`).setNumberFormat('"₱"#,##0.00');
products.getRange(`I6:I${productEnd}`).setNumberFormat('#,##0.##');
evidence.getRange('A6:B143').setNumberFormat('0');
evidence.getRange('E6:E143').setNumberFormat('#,##0');
evidence.getRange('H6:H143').setNumberFormat('"₱"#,##0.00');
for (const c of ['C','D','E','F','G','I','J','K','L']) {
  products.getRange(`${c}6:${c}${productEnd}`).format.fill = '#FFF9EF';
}
products.getRange(`K6:K${productEnd}`).dataValidation = { rule:{type:'list',values:['Yes','No']} };
products.getRange(`A5:L${productEnd}`).format.borders = { insideHorizontal:{style:'thin',color:'#EEE8E3'} };
evidence.getRange('A5:I143').format.borders = { insideHorizontal:{style:'thin',color:'#EEE8E3'} };
products.tables.add(`A5:L${productEnd}`,true,'ProductsTable');
evidence.tables.add('A5:I143',true,'SourceEvidenceTable');

wb.recalculate();
const check = await wb.inspect({kind:'table',range:'Products!A5:L9',include:'values,formulas',tableMaxRows:5,tableMaxCols:12,maxChars:3500});
console.log(check.ndjson);
const errors = await wb.inspect({kind:'match',searchTerm:'#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A|#NUM!|#NULL!|#SPILL!|#CALC!',options:{useRegex:true,maxResults:20},maxChars:1000});
console.log('Formula errors:',errors.ndjson);
const preview = await wb.render({sheetName:'Products',range:'A2:L10',scale:1,format:'png'});
await fs.writeFile(new URL('preview.png',outDir),new Uint8Array(await preview.arrayBuffer()));
const sourcePreview = await wb.render({sheetName:'Source evidence',range:'A2:I10',scale:1,format:'png'});
await fs.writeFile(new URL('source_preview.png',outDir),new Uint8Array(await sourcePreview.arrayBuffer()));
const xlsx = await SpreadsheetFile.exportXlsx(wb);
await xlsx.save(new URL('Add_New_Product_Sandpaper_Variants.xlsx',outDir).pathname.replace(/^\/(?:([A-Za-z]:))/, '$1'));
console.log('Saved',productValues.length,'catalog rows from',rows.length,'source groups');
