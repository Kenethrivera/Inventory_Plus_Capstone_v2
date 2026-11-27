import openpyxl, re, collections, statistics, json

base = r'C:\Users\WINDOWS11\Documents\GitHub\Inventory_Plus_Capstone_v3'
catalog = openpyxl.load_workbook(base+r'\outputs\add_product_units_2026_11_27\Add_New_Product_Sandpaper_Variants_Units_Complete.xlsx',read_only=True,data_only=True)
receipt = openpyxl.load_workbook(r'C:\Users\WINDOWS11\Downloads\Sales_Categorized_Fixed_v3 (1).xlsx',read_only=True,data_only=True)

def norm(s):
    return re.sub(r'[^a-z0-9]+',' ',str(s or '').lower()).strip()

def unit(s):
    s=norm(s)
    if '1 4' in s or '1 2' in s: return 'ltr'
    if s in ('gal','ga','gallon','1 gallon'): return 'gal'
    if s in ('ltr','lt','l','1l','litter','liter'): return 'ltr'
    if s in ('pc','pcs','piece','pieces'): return 'pcs'
    if s in ('btl','bottle','bottles'): return 'btl'
    if s in ('kg','kl','kilo','kilogram'): return 'kilo'
    if s in ('tin','tins'): return 'tin'
    if s in ('bag','bags'): return 'bag'
    if s in ('pack','packs','pck'): return 'pack'
    if s in ('set','sets'): return 'set'
    return s or 'unspec'

rows=[]
for sheet in list(receipt)[:4]:
    for i,r in enumerate(sheet.values,1):
        if i==1 or not isinstance(r[2],(int,float)) or not r[4]: continue
        qty,price,amount=r[2],r[6],r[7]
        if qty<=0: continue
        if isinstance(amount,(int,float)):
            calc=round(amount/qty,2)
        elif isinstance(price,(int,float)):
            calc=round(price,2)
        else: continue
        rows.append({'sheet':sheet.title,'row':i,'date':str(r[1])[:10],'article':str(r[4]),'norm':norm(r[4]),'unit':unit(r[3]),'rawunit':str(r[3]),'qty':qty,'price':price,'amount':amount,'calc':calc,'note':r[8]})

evidence={r[0]:r for r in list(catalog['Source evidence'].values)[5:]}
products=list(catalog['Products'].values)[5:]
all_matches=set()
for ix,p in enumerate(products,6):
    id=p[0]; group=1 if isinstance(id,str) and id.startswith('1-') else id
    raw=evidence[group][8]
    variants={norm(s) for s in str(raw).split(',')}
    variants.add(norm(p[1]))
    if group==1:
        if id=='1-other':
            variants={v for v in variants if not re.search(r'\b(100|120|150|156|240)\b',v)}
        else:
            grit=id.split('-')[1]
            variants={v for v in variants if re.search(r'\b'+grit+r'\b',v)}
    candidates=[r for r in rows if r['norm'] in variants]
    for r in candidates: all_matches.add((r['sheet'],r['row']))
    byunit=collections.defaultdict(list)
    for r in candidates: byunit[r['unit']].append(r['calc'])
    chosen=byunit.get(p[9],[])
    print(f"{ix:3} {str(id):>7} {str(p[9]):<5} {str(p[1])[:43]:<43} matches={len(candidates):2} same={len(chosen):2} prices={dict(byunit)}")
    if ix in list(range(6,12))+[12,24,37,38,39,40,41,42,64,65,66,67,69,73,77,78,79,80,81,82,94,97,103,121,122,123,138,146,147,148]:
        print('   DETAIL',[(r['date'],r['article'],r['rawunit'],r['qty'],r['price'],r['amount'],r['calc']) for r in candidates])
print('total receipt rows',len(rows),'matched',len(all_matches))
print('unmatched receipt articles',sorted({r['article'] for r in rows if (r['sheet'],r['row']) not in all_matches}))
