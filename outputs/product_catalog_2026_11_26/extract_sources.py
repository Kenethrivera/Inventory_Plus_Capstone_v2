import json
from collections import Counter
from datetime import datetime, date
from pathlib import Path
import openpyxl

base = Path(r'C:\Users\WINDOWS11\Downloads')
files = [base / 'Paint_and_Hardware_Materials_Transcription-v2.xlsx', base / 'Sales  (1).xlsx', base / 'Receipt_List_Nov2-Nov9.xlsx']
sql_text = Path('database/import_sales_categorized_fixed.sql').read_text(encoding='utf-8')
sql_rows = json.loads(sql_text.split('$scf$')[1])
sales_categories = {(x['sheet'], x['row_number']): x['category'] for x in sql_rows}
sales_sql = {(x['sheet'], x['row_number']): x for x in sql_rows}
lines = []

def clean(value):
    return str(value).strip() if value is not None else ''

def money(value):
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        value = value.replace('₱', '').replace(',', '').strip()
        try:
            return float(value)
        except ValueError:
            pass
    return None

def date_text(value):
    if isinstance(value, (datetime, date)):
        return value.strftime('%Y-%m-%d')
    return ''

materials = openpyxl.load_workbook(files[0], read_only=True, data_only=True)
for rownum, row in enumerate(materials['All Items'].iter_rows(min_row=5, values_only=True), 5):
    sheet, group, day, qty, unit, name, price, calc, written, variance, notes = (list(row) + [None] * 11)[:11]
    if not clean(name) or not isinstance(qty, (int, float)):
        continue
    lines.append(dict(source='Materials', sheet=clean(sheet), row=rownum, group=clean(group), date=date_text(day),
                      name=clean(name), unit=clean(unit), qty=qty, unit_price=price if isinstance(price, (int,float)) else None,
                      price_basis='Written unit price', amount=written if isinstance(written,(int,float)) else None,
                      calculated_amount=calc if isinstance(calc,(int,float)) else None, category='',
                      notes=clean(notes), variance=variance if isinstance(variance,(int,float)) else None))

sales = openpyxl.load_workbook(files[1], read_only=True, data_only=True)
for ws in sales:
    group = 0
    in_group = False
    for rownum, row in enumerate(ws.iter_rows(min_row=2, values_only=True), 2):
        day, qty, unit, name, price, amount = (list(row) + [None] * 6)[:6]
        if isinstance(qty, datetime) and (ws.title, rownum) in {('Sheet2', 14), ('Sheet2', 20), ('Sheet2', 77)}:
            qty = 0.5
        sql_line = sales_sql.get((ws.title, rownum))
        if isinstance(unit, datetime) and sql_line:
            unit = sql_line['unit']
        name = clean(name)
        if not name or name.upper().startswith('TOTAL'):
            in_group = False
            continue
        amount = money(amount)
        price = money(price)
        if not isinstance(qty, (int,float)) or amount is None:
            continue
        if not in_group:
            group += 1
            in_group = True
        actual_price = price if price is not None else amount / qty if qty else None
        date_value = date_text(day)
        source_note = ''
        if not date_value and sql_line:
            date_value = openpyxl.utils.datetime.from_excel(sql_line['date_serial']).strftime('%Y-%m-%d')
            source_note = 'Date filled from order group'
        lines.append(dict(source='Sales', sheet=ws.title, row=rownum, group=str(group), date=date_value,
                          name=name, unit=clean(unit), qty=qty, unit_price=actual_price,
                          price_basis='Written unit price' if price is not None else 'Amount / quantity',
                          amount=amount, calculated_amount=qty*actual_price if actual_price is not None else None,
                          category=sales_categories.get((ws.title, rownum), ''), notes=source_note, variance=None))

receipts = openpyxl.load_workbook(files[2], read_only=True, data_only=True)
receipt_date = ''
receipt_group = 0
receipt_lines = []
for rownum, row in enumerate(receipts.active.iter_rows(values_only=True), 1):
    qty, unit, name, price, amount, _, receipt_no = (list(row) + [None] * 7)[:7]
    if isinstance(qty, datetime):
        receipt_date = f'2026-11-{qty.month:02d}'
        continue
    if clean(qty).upper() == 'QTY':
        receipt_group += 1
        continue
    if not isinstance(qty, (int, float)) or not isinstance(amount, (int, float)):
        continue
    calculated = qty * price if isinstance(price, (int, float)) else None
    note = 'Product name missing' if not clean(name) else ''
    receipt_lines.append(dict(source='Receipts', sheet='Sheet1', row=rownum, group=str(receipt_group),
                              date=receipt_date, name=clean(name), unit=clean(unit), qty=qty,
                              unit_price=price if isinstance(price, (int, float)) else amount / qty if qty else None,
                              price_basis='Written unit price' if isinstance(price, (int, float)) else 'Amount / quantity',
                              amount=amount, calculated_amount=calculated, category='', notes=note,
                              variance=calculated - amount if calculated is not None else None,
                              receipt_no=clean(receipt_no)))
for group in {x['group'] for x in receipt_lines}:
    number = next((x['receipt_no'] for x in receipt_lines if x['group'] == group and x['receipt_no']), '')
    for x in receipt_lines:
        if x['group'] == group:
            x['notes'] = '; '.join(filter(None, [number, x['notes']]))
            del x['receipt_no']
lines.extend(receipt_lines)

out = Path(__file__).with_name('source_lines.json')
out.write_text(json.dumps(lines, ensure_ascii=False, indent=2), encoding='utf-8')
print('source rows', Counter(x['source'] for x in lines))
print('distinct product+unit', len({(x['name'].casefold(), x['unit'].casefold()) for x in lines if x['name']}))
print('sales amount', sum(x['amount'] or 0 for x in lines if x['source']=='Sales'))
print('materials written amount', sum(x['amount'] or 0 for x in lines if x['source']=='Materials'))
print('receipt amount', sum(x['amount'] or 0 for x in lines if x['source']=='Receipts'))
print('dates', sorted({x['date'] for x in lines}))
extracted = {(x['sheet'], x['row']) for x in lines if x['source'] == 'Sales'}
print('sales rows in existing SQL but not extraction', [(x['sheet'], x['row_number'], x['article'], x['amount']) for x in sql_rows if (x['sheet'], x['row_number']) not in extracted])
