from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
inventory = (root / 'database/import_product_catalog.sql').read_text(encoding='utf-8')
history = (root / 'database/import_historical_sales.sql').read_text(encoding='utf-8')

def body(sql):
    _, rest = sql.split('\nbegin;\n', 1)
    content, after = rest.rsplit('\ncommit;', 1)
    assert not after.strip()
    return content.strip()

inventory_body = body(inventory)
history_body = body(history)
for config_name, content in (('_ci_config', inventory_body), ('_ch_config', history_body)):
    pattern = rf'create temp table {config_name} on commit drop as\nselect id as location_id.*?end\);'
    replacement = f'create temp table {config_name} on commit drop as\nselect location_id from _import_location;'
    changed, count = re.subn(pattern, replacement, content, count=1, flags=re.S)
    assert count == 1
    if config_name == '_ci_config':
        inventory_body = changed
    else:
        history_body = changed

combined = (
    '-- Import the documented product catalog and customer sales in one transaction.\n'
    '-- Paste this entire file into Supabase SQL Editor and run once.\n'
    '-- One store must exist, or set its UUID once in _import_location below.\n'
    '-- No permanent columns or triggers are created. No staff identities or\n'
    '-- current stock quantities are invented. An error rolls back everything.\n'
    '-- Products with unit TIN receive requires_loading = true.\n'
    'begin;\n\n'
    'create temp table _import_location on commit drop as\n'
    'select id as location_id from public.locations\n'
    'where id = coalesce(null::uuid, -- Set store UUID here if multiple stores exist.\n'
    '  case when (select count(*) from public.locations) = 1 then id end);\n\n'
    + inventory_body + '\n\n'
    + history_body + '\ncommit;\n'
)
destination = root / 'database/import_client_sales_one_query.sql'
destination.write_text(combined, encoding='utf-8')
print(destination, len(combined), 'characters')
