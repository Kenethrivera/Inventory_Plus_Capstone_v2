import fs from 'node:fs/promises';
import { FileBlob, SpreadsheetFile } from '@oai/artifact-tool';

const base = 'C:/Users/WINDOWS11/Documents/GitHub/Inventory_Plus_Capstone_v3/outputs';
const sourcePath = `${base}/add_product_138_2026_11_27/Add_New_Product_Sandpaper_Variants.xlsx`;
const outputDir = `${base}/add_product_units_2026_11_27`;
const outputPath = `${outputDir}/Add_New_Product_Sandpaper_Variants_Units_Complete.xlsx`;
const workbook = await SpreadsheetFile.importXlsx(await FileBlob.load(sourcePath));
const products = workbook.worksheets.getItem('Products');

const updates = new Map([
  [6,'pcs'],[7,'pcs'],[8,'pcs'],[9,'pcs'],[10,'pcs'],[11,'pcs'],
  [17,'pcs'],[24,'kilo'],[26,'pcs'],[28,'pcs'],
  [38,'gal'],[39,'gal'],[40,'gal'],[41,'gal'],[42,'tin'],
  [64,'ltr'],[65,'ltr'],[66,'ltr'],[67,'gal'],[68,'ltr'],[70,'ltr'],
  [77,'ltr'],[78,'ltr'],[79,'ltr'],[80,'ltr'],[81,'ltr'],[82,'ltr'],
  [83,'gal'],[84,'gal'],[94,'kilo'],[95,'gal'],[100,'gal'],[101,'gal'],
  [111,'gal'],[121,'btl'],[122,'btl'],[123,'gal'],[139,'pcs'],[140,'kilo'],
  [146,'ltr'],[147,'ltr'],[148,'ltr'],
]);

for (const [row, unit] of updates) {
  products.getRange(`J${row}`).values = [[unit]];
}

workbook.recalculate();
const units = products.getRange('J6:J148').values.map(r => r[0]);
if (units.some(v => typeof v !== 'string' || !/^[A-Za-z]+$/.test(v))) {
  throw new Error('A unit is blank or contains a non-letter character.');
}
console.log(JSON.stringify({productRows:units.length,changed:updates.size,distinctUnits:[...new Set(units)].sort()}));
const errors = await workbook.inspect({kind:'match',searchTerm:'#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A|#NUM!|#NULL!|#SPILL!|#CALC!',options:{useRegex:true,maxResults:20},summary:'unit edit formula error scan'});
console.log(errors.ndjson);
for (const [name,range] of [['top','H5:K18'],['middle','H63:K82'],['bottom','H136:K148']]) {
  const preview = await workbook.render({sheetName:'Products',range,scale:1.3,format:'png'});
  await fs.writeFile(`${outputDir}/after_${name}.png`,new Uint8Array(await preview.arrayBuffer()));
}
const output = await SpreadsheetFile.exportXlsx(workbook);
await output.save(outputPath);
console.log(outputPath);
