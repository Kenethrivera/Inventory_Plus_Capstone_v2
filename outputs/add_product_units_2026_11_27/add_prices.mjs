import fs from 'node:fs/promises';
import { FileBlob, SpreadsheetFile } from '@oai/artifact-tool';

const base = 'C:/Users/WINDOWS11/Documents/GitHub/Inventory_Plus_Capstone_v3/outputs';
const sourcePath = `${base}/add_product_units_2026_11_27/Add_New_Product_Sandpaper_Variants_Units_Complete.xlsx`;
const outputDir = `${base}/add_product_prices_2026_11_27`;
const outputPath = `${outputDir}/Add_New_Product_Sandpaper_Variants_Units_and_Prices.xlsx`;
const choices = JSON.parse(await fs.readFile(`${base}/add_product_units_2026_11_27/price_choices.json`,'utf8'));
if (choices.length !== 143) throw new Error('Expected 143 product prices.');

const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(sourcePath));
const products = workbook.worksheets.getItem('Products');
for (const c of choices) {
  if (!Number.isFinite(c.price) || c.price <= 0) throw new Error(`Invalid price at row ${c.row}`);
  if (products.getRange(`G${c.row}`).values[0][0] !== null) throw new Error(`Existing price at row ${c.row}`);
  if (products.getRange(`J${c.row}`).values[0][0] !== c.unit) throw new Error(`Unit mismatch at row ${c.row}`);
  products.getRange(`G${c.row}`).values = [[c.price]];
  if (c.size) {
    if (products.getRange(`E${c.row}`).values[0][0] !== null) throw new Error(`Existing size at row ${c.row}`);
    products.getRange(`E${c.row}`).values = [[c.size]];
  }
}

workbook.recalculate();
const values = products.getRange('G6:G148').values.map(r=>r[0]);
if (values.some(v=>typeof v!=='number' || v<=0)) throw new Error('Missing price in final catalog.');
const errors=await workbook.inspect({kind:'match',searchTerm:'#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A|#NUM!|#NULL!|#SPILL!|#CALC!',options:{useRegex:true,maxResults:20},summary:'price edit formula error scan'});
console.log(errors.ndjson);
await fs.mkdir(outputDir,{recursive:true});
for (const [name,range] of [['top','B5:J20'],['middle','B63:J82'],['bottom','B136:J148']]) {
  const preview=await workbook.render({sheetName:'Products',range,scale:1.2,format:'png'});
  await fs.writeFile(`${outputDir}/after_${name}.png`,new Uint8Array(await preview.arrayBuffer()));
}
const output=await SpreadsheetFile.exportXlsx(workbook);
await output.save(outputPath);
console.log(JSON.stringify({prices:values.length,sizes:choices.filter(c=>c.size).length,outputPath}));
