import fs from 'node:fs/promises';
import { FileBlob, SpreadsheetFile } from '@oai/artifact-tool';

const base = 'C:/Users/WINDOWS11/Documents/GitHub/Inventory_Plus_Capstone_v3/outputs';
const input = `${base}/add_product_units_2026_11_27/Add_New_Product_Sandpaper_Variants_Units_Complete.xlsx`;
const output = `${base}/add_product_units_2026_11_27`;
const wb = await SpreadsheetFile.importXlsx(await FileBlob.load(input));
const summary = await wb.inspect({kind:'workbook,sheet,table', maxChars:3000, tableMaxRows:5, tableMaxCols:12});
console.log(summary.ndjson);
const preview = await wb.render({sheetName:'Products',range:'E63:J82',scale:1.3,format:'png'});
await fs.writeFile(`${output}/before_prices.png`,new Uint8Array(await preview.arrayBuffer()));
