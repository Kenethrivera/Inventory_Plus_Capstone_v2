import json
import re
from collections import Counter, defaultdict
from pathlib import Path

folder = Path(__file__).parent
lines = json.loads((folder / 'source_lines.json').read_text(encoding='utf-8'))
sales_labels = defaultdict(Counter)
for line in lines:
    if line['source'] == 'Sales' and line['category']:
        sales_labels[line['name'].strip().casefold()][line['category']] += 1

TOOLS = 'Painting Tools & Accessories'
ENAMEL = 'Enamel Paints'
LATEX = 'Latex & Masonry Paints'
WOOD = 'Automotive & Wood Finishes'
PRIMER = 'Primers & Sealers'
PUTTY = 'Putty, Skim Coat & Waterproofing'
THINNER = 'Thinners & Reducers'
ABRASIVE = 'Abrasives & Tapes'
ROOF = 'Roofing Paints'
HARDWARE = 'Tile & Construction Hardware'
TINT = 'Tinting Colors'
SPRAY = 'Spray Paints'
CLEAN = 'Cleaning & Consumables'
FASTENER = 'Fasteners & Cutting Tools'
ADHESIVE = 'Adhesives & Sealants'
ADDITIVE = 'Paint Additives & Hardeners'
EPOXY = 'Epoxy Coatings'
REVIEW = 'Needs category review'

verified = {
    'b1750': (THINNER, 'B1750 is Boysen Acrytex Reducer'),
    'b1750 (acrytex reducer)': (THINNER, 'B1750 is Boysen Acrytex Reducer'),
    'b600': (ENAMEL, 'B600 is Boysen quick drying enamel white'),
    'b2550 (roofguard) (baguio green)': (ROOF, 'B2550 is Boysen Roofgard'),
    'konstrukt': (PUTTY, 'Boysen Konstrukt K-201 is acrylic skimcoat'),
    'konstrukt (k-201)': (PUTTY, 'Boysen Konstrukt K-201 is acrylic skimcoat'),
    'titan tulle white': (LATEX, 'Tulle White is a Titan Superflex elastomeric color'),
    'tinge of gray (t-5135 titan super flex)': (LATEX, 'Titan Superflex is elastomeric wall paint'),
    'titan superflex elastomeric paint mocha blanch': (LATEX, 'Titan Superflex is elastomeric wall paint'),
    'spar varnish': (WOOD, 'Spar varnish is a wood finish'),
}
ambiguous = {
    'acrylic', 'b|s white', 'bala', 'bala ?', 'bala (s)', 'brown',
    'buildrite', 'chocolate brown', 'flat white', 'gloss chocolate brown',
    'hardener big', 'mix', 'mix ?', 'mix (power mix)?', 'maple', 'nation maple',
    'nixon paint', 'paint', 'ros 862', 'ros.530', 'sachet',
    'semi gloss b|s', 'semi gloss white', 'shepsil', 'sinclair cascara',
    'skin coat / roller 7', 'terra cotta', 'tulips (ae 121)',
}

def classify(name):
    n = re.sub(r'\s+', ' ', name.strip().casefold())
    if n in verified:
        category, note = verified[n]
        return {'category': category, 'basis': 'Product identified', 'review_note': note}
    if n in ambiguous:
        sales = sales_labels.get(n)
        if sales and n in {'terra cotta'}:
            return {'category': sales.most_common(1)[0][0], 'basis': 'Sales sheet category', 'review_note': 'Generic color name; confirm product type'}
        return {'category': REVIEW, 'basis': 'Unclear source name', 'review_note': 'Confirm the product label or brand'}
    rules = [
        (r'spray paint', SPRAY),
        (r'thinn?er|thhinner|reducer|b1750', THINNER),
        (r'primer|sanding sealer|sandy sealer|block coat|red oxide', PRIMER),
        (r'roofguard|roofgard|\brfg\b|\br[/|]s\b|\bs[/|]r\b|\bros[-.]|rain or shine', ROOF),
        (r'\bqde\b|flat wall enamel|enamel mixed|mix enamel|\bb690\b|\bb600\b|aluminum silver', ENAMEL),
        (r'latex|semi gloss|sime gloss|gloss latex|acrylic emulsiuon|acrylic emulsion|superflex|titan tulle', LATEX),
        (r'wood stain|oil wood stain|wood mahogany|spar varnish|automotive|lacquer white|clear gloss lac|dead flat lac|\bb2705\b|\bmaple\b', WOOD),
        (r'plexibond|flexibond|polituff|putty|skim coat|skin coat|konstrukt|boral', PUTTY),
        (r'epoxy non-sag|vulcaseal|sealant|stick well', ADHESIVE),
        (r'catalyst|hardener', ADDITIVE),
        (r'epoxy black', EPOXY),
        (r'brush|roller|paint tray|palita|pole extension|steel brush', TOOLS),
        (r'masking tape|gasa tape|sand.?paper|sanding paper|\bliha\b|\bs/p\b', ABRASIVE),
        (r'cutting disc|blind rivet', FASTENER),
        (r'basahan|dyaryo', CLEAN),
        (r'tile adhesive|tile grout|tile grouth|door knob|mono lock', HARDWARE),
        (r'tinting|a/c raw sienna', TINT),
        (r'gloss black|gloss chocolate', ENAMEL),
        (r'epoxy', EPOXY),
    ]
    for pattern, category in rules:
        if re.search(pattern, n):
            return {'category': category, 'basis': 'Product description', 'review_note': ''}
    sales = sales_labels.get(n)
    if sales and len(sales) == 1:
        return {'category': sales.most_common(1)[0][0], 'basis': 'Sales sheet category', 'review_note': ''}
    return {'category': REVIEW, 'basis': 'Unclear source name', 'review_note': 'Confirm the product label or brand'}

names = sorted({x['name'].strip() for x in lines if x['name'].strip()}, key=str.casefold)
mapping = {name.casefold(): classify(name) for name in names}
(folder / 'category_map.json').write_text(json.dumps(mapping, ensure_ascii=False, indent=2), encoding='utf-8')
print('names', len(names), 'categories', Counter(x['category'] for x in mapping.values()))
print('review', [(name, mapping[name.casefold()]['category']) for name in names if mapping[name.casefold()]['category'] == REVIEW])
