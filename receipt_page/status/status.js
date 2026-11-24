(() => {
  'use strict';

  const $ = id => document.getElementById(id);
  const token = new URLSearchParams(window.location.search).get('token');
  const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const validToken = uuidPattern.test(token || '');
  const config = window.INVENTORY_PLUS_PUBLIC_CONFIG;
  const client = config && window.supabase
    ? window.supabase.createClient(config.url, config.anonKey)
    : null;
  let loading = false;
  let hasOrder = false;

  function showMessage(text, error = false) {
    $('message').textContent = text;
    $('message').className = error ? 'message error' : 'message';
    $('message').hidden = false;
  }

  function node(tag, className, text) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = String(text);
    return element;
  }

  function stageFor(order) {
    const status = String(order.status || '').toLowerCase();
    if (status === 'completed') return 3;
    if (status === 'prepared') return 2;
    if (status === 'solo_picking' || order.assigned ||
        order.items.some(item => item.picked || item.heavyVerified)) return 1;
    return 0;
  }

  function render(order) {
    const items = Array.isArray(order.items) ? order.items : [];
    order.items = items;
    const status = String(order.status || '').toLowerCase();
    const cancelled = status === 'cancelled';
    const stage = stageFor(order);
    const labels = ['Order received', 'Preparing items', 'Ready for checkout', 'Completed'];
    const statusText = cancelled ? 'Cancelled' : labels[stage];

    $('order-number').textContent = '#' + String(order.orderNumber || '');
    $('status-pill').textContent = statusText;
    $('status-pill').className = 'pill ' + (cancelled ? 'cancelled' : stage === 3 ? 'completed' : stage === 2 ? 'ready' : '');
    const receiptLink = $('view-receipt');
    const receiptAvailable = status === 'completed' && uuidPattern.test(order.receiptOrderId || '');
    receiptLink.hidden = !receiptAvailable;
    if (receiptAvailable) receiptLink.href = '/?id=' + encodeURIComponent(order.receiptOrderId);
    else receiptLink.removeAttribute('href');

    const stages = document.createDocumentFragment();
    labels.forEach((label, index) => {
      const row = node('li', 'stage' + (!cancelled && index < stage ? ' done' : !cancelled && index === stage ? ' active' : ''));
      const dot = node('span', 'stage-dot', !cancelled && index < stage ? '✓' : String(index + 1));
      dot.setAttribute('aria-hidden', 'true');
      row.append(dot, node('span', '', label));
      stages.append(row);
    });
    $('stages').replaceChildren(stages);

    const completed = status === 'completed' || status === 'prepared'
      ? items.length
      : items.filter(item => item.picked || item.heavyVerified).length;
    const percent = items.length ? Math.round(100 * completed / items.length) : 0;
    $('progress-count').textContent = `${completed}/${items.length}`;
    $('progress-fill').style.width = percent + '%';
    document.querySelector('.progress-track').setAttribute('aria-valuenow', String(percent));

    const itemRows = document.createDocumentFragment();
    items.forEach(item => {
      const done = status === 'completed' || status === 'prepared' || item.picked || item.heavyVerified;
      const row = node('div', 'item');
      const name = node('span', 'item-name', item.name || 'Item');
      const quantity = Number(item.quantity);
      name.append(node('span', 'muted', ` · Qty ${Number.isFinite(quantity) ? quantity : 0}`));
      row.append(name, node('span', 'item-state' + (done ? ' done' : ''), done ? 'Prepared' : 'Waiting'));
      itemRows.append(row);
    });
    $('items').replaceChildren(itemRows);

    const updated = new Date(order.updatedAt || order.createdAt);
    $('last-updated').textContent = Number.isNaN(updated.getTime())
      ? 'Updates automatically every 5 seconds'
      : 'Last updated ' + updated.toLocaleString();
    $('order').hidden = false;
    $('message').hidden = true;
    hasOrder = true;
    if (cancelled) showMessage('This order was cancelled. Please contact the store if you need help.', true);
  }

  async function refresh() {
    if (loading || !validToken || !client) return;
    loading = true;
    $('refresh').disabled = true;
    try {
      const { data, error } = await client.rpc('customer_order_status_v1', { p_token: token });
      if (error) throw error;
      if (!data) {
        $('order').hidden = true;
        hasOrder = false;
        showMessage('This tracking link is unavailable or has expired.', true);
      } else {
        render(data);
      }
    } catch (error) {
      showMessage(hasOrder
        ? 'Could not refresh right now. Showing the last known status.'
        : 'Could not load this order. Check your connection and try again.', true);
      console.error('Order status refresh failed', error);
    } finally {
      loading = false;
      $('refresh').disabled = false;
    }
  }

  $('refresh').addEventListener('click', refresh);
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) refresh();
  });
  if (!validToken) showMessage('This tracking link is invalid.', true);
  else if (!client) showMessage('Order tracking is temporarily unavailable.', true);
  else {
    refresh();
    setInterval(() => { if (!document.hidden) refresh(); }, 5000);
  }
})();
