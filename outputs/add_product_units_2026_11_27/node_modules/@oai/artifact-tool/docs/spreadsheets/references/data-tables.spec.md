## Data tables (`worksheet.dataTables`)

Use data tables to project a formula across a row/column grid. Include the top-left formula cell and input headers in the table range.

### Two-variable data table

```ts
const sheet = workbook.worksheets.add("TwoVariable");

sheet.getRange("B3").values = [[0.095]];  // rate
sheet.getRange("B4").values = [[360]];    // periods
sheet.getRange("B5").values = [[80000]];  // principal

sheet.getRange("C2").formulas = [[`=PMT(B3/12,B4,-B5)`]];
sheet.getRange("C3:C5").values = [[0.09], [0.0925], [0.095]];
sheet.getRange("D2:E2").values = [[180, 360]];

sheet.dataTables.add("C2:E5", {
  rowInput: "B4",
  columnInput: "B3",
});

workbook.recalculate();
```

### Single-variable (row input only)

For one-variable sensitivity tables in Excel workbooks, use explicit formulas.
This example tests a one-variable table in Artifact Tool.

```ts
const rowSheet = workbook.worksheets.add("OneVariable");
rowSheet.getRange("B4").values = [[5]];
rowSheet.getRange("C2").formulas = [["=B4*2"]];
rowSheet.getRange("D2:E2").values = [[10, 20]];
rowSheet.dataTables.add("C2:E3", { rowInput: "B4" });
workbook.recalculate();
```
