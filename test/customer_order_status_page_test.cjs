const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'receipt_page', 'status', 'status.js'),
  'utf8',
);
const token = 'a0000000-0000-4000-8000-000000000001';

function fakeElement() {
  return {
    textContent: '',
    className: '',
    hidden: false,
    disabled: false,
    style: {},
    attributes: {},
    listeners: {},
    append() {},
    replaceChildren() {},
    setAttribute(name, value) { this.attributes[name] = value; },
    removeAttribute(name) { delete this.attributes[name]; },
    addEventListener(name, callback) { this.listeners[name] = callback; },
  };
}

function page(search, rpc) {
  const elements = new Map();
  const get = id => {
    if (!elements.has(id)) elements.set(id, fakeElement());
    return elements.get(id);
  };
  const document = {
    hidden: false,
    getElementById: get,
    createElement: fakeElement,
    createDocumentFragment: fakeElement,
    querySelector: () => get('progress-track'),
    addEventListener() {},
  };
  const window = {
    location: { search },
    INVENTORY_PLUS_PUBLIC_CONFIG: { url: 'https://example.com', anonKey: 'test' },
    supabase: { createClient: () => ({ rpc }) },
  };
  vm.runInNewContext(source, { document, window, URLSearchParams, setInterval() {}, console });
  return get;
}

test('refreshes one order from preparing to ready with item progress', async () => {
  let status = 'pending';
  const receiptId = 'b0000000-0000-4000-8000-000000000002';
  const get = page(`?token=${token}`, async () => ({
    data: {
      orderNumber: 'ABC12345',
      status,
      receiptOrderId: status === 'completed' ? receiptId : null,
      assigned: true,
      createdAt: '2026-11-24T08:00:00Z',
      updatedAt: '2026-11-24T08:01:00Z',
      items: [
        { name: 'Paint', quantity: 1, picked: true, heavyVerified: false },
        { name: 'Brush', quantity: 2, picked: false, heavyVerified: false },
      ],
    },
    error: null,
  }));
  await new Promise(setImmediate);

  assert.equal(get('order-number').textContent, '#ABC12345');
  assert.equal(get('status-pill').textContent, 'Preparing items');
  assert.equal(get('progress-count').textContent, '1/2');
  assert.equal(get('progress-fill').style.width, '50%');
  assert.equal(get('view-receipt').hidden, true);

  status = 'prepared';
  await get('refresh').listeners.click();
  assert.equal(get('status-pill').textContent, 'Ready for checkout');
  assert.equal(get('progress-count').textContent, '2/2');
  assert.equal(get('progress-fill').style.width, '100%');
  assert.equal(get('view-receipt').hidden, true);

  status = 'completed';
  await get('refresh').listeners.click();
  assert.equal(get('view-receipt').hidden, false);
  assert.equal(get('view-receipt').href, '/?id=' + receiptId);
});

test('rejects an invalid tracking link before querying', () => {
  let calls = 0;
  const get = page('?token=not-an-order-token', async () => {
    calls += 1;
    return { data: null, error: null };
  });
  assert.equal(calls, 0);
  assert.equal(get('message').textContent, 'This tracking link is invalid.');
});
