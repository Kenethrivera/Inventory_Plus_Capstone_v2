import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const directory = dirname(fileURLToPath(import.meta.url));
const localEnvPath = resolve(directory, '../lib/.env');
let local = {};

try {
  const source = await readFile(localEnvPath, 'utf8');
  for (const line of source.split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (match) local[match[1]] = match[2].replace(/^['"]|['"]$/g, '');
  }
} catch { /* Netlify uses its environment variables. */ }

const url = (process.env.SUPABASE_URL || local.SUPABASE_URL || '').trim().replace(/\/$/, '');
const anonKey = (process.env.SUPABASE_ANON_KEY || local.SUPABASE_ANON_KEY || '').trim();
if (!/^https:\/\/[^/]+$/.test(url) || !anonKey) {
  throw new Error('Set SUPABASE_URL and SUPABASE_ANON_KEY in Netlify environment variables, or provide lib/.env for a local build.');
}

if (anonKey.startsWith('eyJ')) {
  const payload = JSON.parse(Buffer.from(anonKey.split('.')[1], 'base64url').toString('utf8'));
  if (payload.role !== 'anon') throw new Error('SUPABASE_ANON_KEY must have the anon role. Never publish a service role key.');
} else if (!anonKey.startsWith('sb_publishable_')) {
  throw new Error('SUPABASE_ANON_KEY must be a Supabase anon or publishable key.');
}

await writeFile(resolve(directory, 'config.js'),
  'window.ORDER_QUEUE_CONFIG = ' + JSON.stringify({ url, anonKey }) + ';\n',
  'utf8');
console.log('Order queue configuration generated.');
