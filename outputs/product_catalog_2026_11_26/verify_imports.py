import json
import re
from collections import Counter
from pathlib import Path

root = Path(__file__).resolve().parents[2]
history = (root / 'database/import_historical_sales.sql').read_text(encoding='utf-8')
inventory = (root / 'database/import_product_catalog.sql').read_text(encoding='utf-8')
combined_query = (root / 'database/import_client_sales_one_query.sql').read_text(encoding='utf-8')
sales = json.loads(history.split('$ch_source$', 2)[1])
catalog = json.loads(inventory.split('$ci_source$', 2)[1])

assert len(sales) == 427
assert Counter(row['source'] for row in sales) == {
    'Materials': 148, 'Receipts': 126, 'Sales': 153,
}
assert len({(row['source'], row['sheet'], row['group_number']) for row in sales}) == 158
assert sum(row['amount'] for row in sales) == 255110
assert len(catalog) == 295
assert all(row['requires_loading'] for row in catalog if row['unit'].strip().lower() == 'tin')
assert sum(not row['name'] for row in sales) == 18
assert sum(bool(row['variance']) for row in sales) == 7

combined = history + inventory + combined_query
assert not re.search(r'\b(?:alter\s+table|create\s+trigger|create\s+(?:or\s+replace\s+)?function)\b',
                     combined, re.I)
assert not re.search(r'\bupdate\s+public\.products\b[^;]*\bproduct_quantity\s*=',
                     combined, re.I | re.S)
assert not re.search(r'\b(?:Abdul|Allen|Yves|Keneth)\b', combined, re.I)
assert not re.search(r'\bdemo\b', combined, re.I)
assert not re.search(r'\bcapstone\b|HIST-CAP', combined, re.I)
assert 'product_quantity,\n   max_quantity' in inventory
assert 'c.reference_price, 0,' in inventory
assert "lower(trim(coalesce(p.unit,''))) = 'tin'" in inventory
assert "'requires_loading',m.product_requires_loading" in history
assert 'create temp table _ch_mapped (' in history
assert 'insert into _ch_mapped\nselect l.*' in history
assert len(re.findall(r'^begin;$', combined_query, re.M)) == 1
assert len(re.findall(r'^commit;$', combined_query, re.M)) == 1
assert combined_query.count('$ch_source$') == 2
assert combined_query.count('$ci_source$') == 2
assert combined_query.count('null::uuid') == 1
print('Verified 158 orders, 427 lines, PHP 255,110, 295 catalog entries; no schema changes or staff attribution.')
