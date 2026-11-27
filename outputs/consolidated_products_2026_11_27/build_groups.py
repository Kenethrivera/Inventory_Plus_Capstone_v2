import json
import re
import unicodedata
from collections import defaultdict
from pathlib import Path

import openpyxl

root = Path(__file__).resolve().parents[1]
source = root / 'product_catalog_2026_11_26/Inventory_Plus_Product_Catalog.xlsx'
sheet = openpyxl.load_workbook(source, read_only=True, data_only=True)['Products']
records = []
for row in list(sheet.iter_rows(values_only=True))[5:]:
    if row[1]:
        records.append(dict(id=row[0], name=row[1].strip(), unit=(row[2] or '').strip(),
                            category=row[3], materials=row[5] or 0, sales=row[6] or 0,
                            receipts=row[7] or 0, source_review=row[14] or ''))

unit_map = {
    'pc': 'pc', 'pcs': 'pc', 'piece': 'pc', 'pieces': 'pc',
    'lt': 'L', 'ltr': 'L', 'litter': 'L', 'liter': 'L', 'litre': 'L', '1l': 'L',
    'gal': 'gal', 'gallon': 'gal', '1 gal': 'gal', '1 gallon': 'gal', 'ga': 'gal',
    'tin': 'tin', 'kilo': 'kg', 'kg': 'kg', 'kl': 'kg',
    'btl': 'bottle', 'bottle': 'bottle', 'bote': 'bottle', 'bt': 'bottle',
    '1/4 ltr': '0.25 L', '1/4 quarter liter can 250': '0.25 L',
    '1/2 ltr': '0.5 L', 'pt': 'pint', 'mtr': 'm',
    'bag': 'bag', 'set': 'set', 'pck': 'pack',
}

aliases = {
    '#1 brush': 'Paint Brush #1', 'brush #1': 'Paint Brush #1',
    'brush 1': 'Paint Brush #1', 'paint brush 1': 'Paint Brush #1',
    'paint brush #1': 'Paint Brush #1',
    'brush #2': 'Paint Brush #2', 'brush 2': 'Paint Brush #2',
    'paint br 2': 'Paint Brush #2', 'paint brush 2': 'Paint Brush #2',
    'paint brush #2': 'Paint Brush #2',
    'brush #3': 'Paint Brush #3', 'paint brush 3': 'Paint Brush #3',
    'paint brush #3': 'Paint Brush #3',
    'brush #2.5': 'Paint Brush #2.5', 'brush 2.5': 'Paint Brush #2.5',
    'brush 1 1/2': 'Paint Brush #1.5', 'paint brush 1.5': 'Paint Brush #1.5',
    'paint brush 1/2': 'Paint Brush #0.5',
    'roller #4': 'Roller 4', 'roller 4': 'Roller 4',
    'roller #7': 'Roller 7', 'roller 7': 'Roller 7', 'roller 7"': 'Roller 7',
    'refill 4': 'Roller Refill 4"',
    's/p #100': 'Sand Paper #100', 'sand paper #100': 'Sand Paper #100',
    'automotive lac. black': 'Automotive Lacquer Black',
    'automotive lacquer black': 'Automotive Lacquer Black',
    'clear gloss lac': 'Clear Gloss Lacquer',
    'clear gloss lacquer': 'Clear Gloss Lacquer',
    'paint thiner': 'Paint Thinner', 'paint thhinner': 'Paint Thinner',
    'paint thinner': 'Paint Thinner',
    'laquer thinner': 'Lacquer Thinner', 'lac. thinner': 'Lacquer Thinner',
    'lacquer thinner': 'Lacquer Thinner',
    'expoy primer': 'Epoxy Primer', 'epoxy primer': 'Epoxy Primer',
    'sandy sealer': 'Sanding Sealer', 'sanding sealer': 'Sanding Sealer',
    'qde. white': 'QDE White', 'qde white': 'QDE White',
    'qde. chocolate brown': 'QDE Chocolate Brown',
    'qde choco brown': 'QDE Chocolate Brown',
    'qde chocolate brown': 'QDE Chocolate Brown',
    'chocolate brown qde': 'QDE Chocolate Brown',
    'flat latex (white)': 'Flat Latex White',
    'flat latex white': 'Flat Latex White',
    'sime gloss': 'Semi Gloss', 'semi gloss': 'Semi Gloss',
    'tile grouth': 'Tile Grout', 'tile grout': 'Tile Grout',
    'flat wall enamel': 'Flat Wall Enamel',
    'roller': 'Roller', 'boral': 'Boral',
    'b690 (qde black)': 'QDE Black', 'qde black': 'QDE Black',
    'b1750 (acrytex reducer)': 'B1750 Acrytex Reducer',
    'b1750': 'B1750 Acrytex Reducer',
    'plexibond (b7760)': 'Plexibond', 'plexibond': 'Plexibond',
    'b2550 (roofguard) (baguio green)': 'Roofguard Baguio Green',
    'rfg baguio green': 'Roofguard Baguio Green',
}
code_review = {'B690 (QDE BLACK)', 'B1750', 'B1750 (ACRYTEX REDUCER)',
               'PLEXIBOND (B7760)', 'B2550 (ROOFGUARD) (BAGUIO GREEN)',
               'Rfg Baguio Green'}

def norm_name(value):
    return re.sub(r'\s+', ' ', unicodedata.normalize('NFKC', value.replace('½', '.5')).strip()).casefold()

groups = defaultdict(list)
for record in records:
    raw = norm_name(record['name'])
    canonical = aliases.get(raw, record['name'].title() if record['name'].islower() else record['name'])
    unit = unit_map.get(norm_name(record['unit']), record['unit'] or 'Unspecified')
    record['standard_name'] = canonical
    record['standard_unit'] = unit
    record['key'] = (norm_name(canonical), unit.casefold(), record['category'])
    groups[record['key']].append(record)

products = []
mapping = []
for group in groups.values():
    group.sort(key=lambda r: (-(r['sales'] + r['receipts']), r['name'].casefold(), r['id']))
    first = group[0]
    names = list(dict.fromkeys(r['name'] for r in group))
    units = list(dict.fromkeys(r['unit'] or '(missing)' for r in group))
    reviews = []
    if first['category'] == 'Needs category review':
        reviews.append('Category needs review')
    if first['standard_unit'] == 'Unspecified' or any('?' in u or u.upper() in ('KL', 'ML') for u in units):
        reviews.append('Unit needs review')
    if any(r['name'] in code_review for r in group) and len(group) > 1:
        reviews.append('Confirm item code match')
    if any('?' in r['name'] for r in group):
        reviews.append('Name needs review')
    products.append(dict(name=first['standard_name'], unit=first['standard_unit'],
                         category=first['category'], original_entries=len(group),
                         original_names='; '.join(names), original_units='; '.join(units),
                         materials=sum(r['materials'] for r in group),
                         sales=sum(r['sales'] for r in group),
                         receipts=sum(r['receipts'] for r in group),
                         review='; '.join(reviews), members=[r['id'] for r in group]))
    for record in group:
        mapping.append(dict(old_id=record['id'], old_name=record['name'], old_unit=record['unit'],
                            new_name=first['standard_name'], new_unit=first['standard_unit'],
                            category=record['category']))

products.sort(key=lambda p: (p['category'], p['name'].casefold(), p['unit'].casefold()))
mapping.sort(key=lambda m: m['old_id'])
assert len(records) == len(mapping) == 295
assert sum(p['original_entries'] for p in products) == 295
assert sum(p['materials'] + p['sales'] + p['receipts'] for p in products) == 409

result = {'products': products, 'mapping': mapping,
          'source_file': source.name, 'source_entries': len(records)}
destination = Path(__file__).with_name('consolidated_products.json')
destination.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
print('products', len(products), 'merged_entries', 295 - len(products),
      'reviews', sum(bool(p['review']) for p in products), 'output', destination)
