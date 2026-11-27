import openpyxl, re, json, collections

root = r'C:\Users\WINDOWS11\Documents\GitHub\Inventory_Plus_Capstone_v3'
catalog = openpyxl.load_workbook(root+r'\outputs\add_product_units_2026_11_27\Add_New_Product_Sandpaper_Variants_Units_Complete.xlsx',read_only=True,data_only=True)
receipt = openpyxl.load_workbook(r'C:\Users\WINDOWS11\Downloads\Sales_Categorized_Fixed_v3 (1).xlsx',read_only=True,data_only=True)
out = root+r'\outputs\add_product_units_2026_11_27\price_choices.json'

def norm(s):
    return re.sub(r'[^a-z0-9]+',' ',str(s or '').lower()).strip()

def package(s):
    s=norm(s)
    if '1 4' in s or 'quarter' in s: return 'ltr','1/4 ltr'
    if '1 2' in s: return 'ltr','1/2 ltr'
    if s in ('gal','ga','gallon','1 gallon','1 gal'): return 'gal',''
    if s in ('ltr','lt','l','1l','1 l','litter','liter'): return 'ltr',''
    if s in ('pc','pcs','piece','pieces'): return 'pcs',''
    if s in ('btl','bottle','bottles','bote','bt'): return 'btl',''
    if s in ('kg','kl','kilo','kilogram'): return 'kilo',''
    if s in ('tin','tins'): return 'tin',''
    if s in ('bag','bags'): return 'bag',''
    if s in ('pack','packs','pck'): return 'pack',''
    if s in ('set','sets'): return 'set',''
    return s or 'unspec',''

sales=[]
for sh in list(receipt)[:4]:
    for rowno,r in enumerate(sh.values,1):
        if rowno==1 or not isinstance(r[2],(int,float)) or r[2]<=0 or not r[4]: continue
        qty,listed,total=r[2],r[6],r[7]
        if not isinstance(listed,(int,float)) and not isinstance(total,(int,float)): continue
        receipt_price=round(total/qty,2) if isinstance(total,(int,float)) else None
        if isinstance(listed,(int,float)) and listed>0:
            price=round(listed,2)
        else:
            price=receipt_price
        if r[8] and 'lump-sum' in str(r[8]).lower(): price=receipt_price
        u,size=package(r[3])
        sales.append(dict(article=str(r[4]),key=norm(r[4]),unit=u,size=size,price=price,receipt_price=receipt_price,listed=listed,qty=qty,date=str(r[1])[:10],sheet=sh.title,row=rowno))

evidence={r[0]:r for r in list(catalog['Source evidence'].values)[5:]}
choices=[]
overrides={
    33:490.0,  # One-piece receipt total is 490; its Price cell says 390.
    51:3400.0, # One-tin receipt total is 3400; its Price cell says 300.
    67:980.0,  # Modern Gray gallon receipt at 290 resembles a liter price; earlier gallon receipt is 980.
    82:200.0,  # Unit absent in receipt; 150 / 0.75 quantity is the only available price basis.
    100:1390.0,# One-gallon receipt total is 1390; its Price cell says 930.
    138:0.75,  # Receipt amount 75 / 100 pcs, despite inconsistent Price cell of 7.50.
}
for rowno,p in enumerate(list(catalog['Products'].values)[5:],6):
    source_id=p[0]
    group=1 if isinstance(source_id,str) and source_id.startswith('1-') else source_id
    variants={norm(v) for v in str(evidence[group][8]).split(',')}
    variants.add(norm(p[1]))
    if group==1:
        if source_id=='1-other': variants={v for v in variants if not re.search(r'\b(100|120|150|156|240)\b',v)}
        else:
            grit=source_id.split('-')[1]
            variants={v for v in variants if re.search(r'\b'+grit+r'\b',v)}
    matches=[s for s in sales if s['key'] in variants]
    wanted_size='1/2 ltr' if rowno==78 else ('1/4 ltr' if rowno in (77,79,80,81,146,147,148) else '')
    eligible=[s for s in matches if s['unit']==p[9] and s['size']==wanted_size]
    if rowno==82: eligible=matches
    if not eligible: raise ValueError(f'No unit/size matched receipt for row {rowno}: {p[1]}')
    counts=collections.Counter(s['price'] for s in eligible)
    max_count=max(counts.values())
    top={price for price,n in counts.items() if n==max_count}
    latest=max((s for s in eligible if s['price'] in top),key=lambda s:(s['date'],s['sheet'],s['row']))
    chosen=overrides.get(rowno,latest['price'])
    support=[s for s in eligible if s['price']==chosen]
    if not support: support=eligible
    last=max(support,key=lambda s:(s['date'],s['sheet'],s['row']))
    choices.append(dict(row=rowno,source_id=source_id,product=p[1],unit=p[9],size=wanted_size,price=chosen,receipt_sheet=last['sheet'],receipt_row=last['row'],receipt_article=last['article'],receipt_date=last['date'],matching_sales=len(eligible),price_options=dict(sorted(counts.items()))))

with open(out,'w',encoding='utf-8') as f: json.dump(choices,f,ensure_ascii=False,indent=2)
for x in choices:
    print(f"{x['row']:3} {x['price']:>7} {x['unit']:<4} {x['size']:<8} {x['product'][:38]:<38} {x['receipt_date']} {x['receipt_sheet']}:{x['receipt_row']}")
print('TOTAL',len(choices),'FILE',out)
