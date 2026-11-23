(() => {
  'use strict';

  const config = window.ORDER_QUEUE_CONFIG;
  const storageKey = 'inventory-plus-order-queue-session';
  const pollMs = 5000;
  const clockSvg = '<svg viewBox="0 0 24 24" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9"></circle><path d="M12 7v5l3 2"></path></svg>';
  const $ = id => document.getElementById(id);
  let session = null;
  let timer = null;
  let refreshing = false;
  let lastSessionCheck = 0;
  let lastSnapshot = null;

  function node(tag, className, value) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (value !== undefined) element.textContent = String(value);
    return element;
  }

  function setConnection(message, state = '') {
    const element = $('connection-text');
    element.textContent = message;
    element.className = 'connection-text' + (state ? ' ' + state : '');
  }

  function storedToken() {
    try { return sessionStorage.getItem(storageKey); } catch { return null; }
  }

  function saveToken(token) {
    try { sessionStorage.setItem(storageKey, token); } catch { /* A private browser can still use the in-memory session. */ }
  }

  function clearToken() {
    try { sessionStorage.removeItem(storageKey); } catch { /* No stored token to clear. */ }
  }

  async function request(path, { method = 'GET', query, body } = {}) {
    const url = new URL(config.url.replace(/\/$/, '') + '/rest/v1/' + path);
    if (query) Object.entries(query).forEach(([key, value]) => url.searchParams.set(key, value));
    const response = await fetch(url, {
      method,
      headers: {
        apikey: config.anonKey,
        Authorization: 'Bearer ' + config.anonKey,
        Accept: 'application/json',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
      cache: 'no-store',
    });
    if (!response.ok) {
      const detail = await response.json().catch(() => null);
      throw new Error(detail?.message || `Request failed (${response.status})`);
    }
    return response.status === 204 ? null : response.json();
  }

  const rpc = (name, body) => request('rpc/' + name, { method: 'POST', body });
  const table = (name, query) => request(name, { query });

  async function loadOpenOrders(locationFilter) {
    const all = [];
    for (let offset = 0; ; offset += 1000) {
      const page = await table('orders', {
        select: 'id,status,items,created_at,created_by_name,assigned_helper_id,assigned_helper_name,assigned_bodegero_id,assigned_bodegero_name,loading_verified_at',
        location_id: locationFilter,
        status: 'in.(pending,prepared,solo_picking)',
        order: 'created_at.asc,id.asc',
        limit: '1000',
        offset: String(offset),
      });
      all.push(...page);
      if (page.length < 1000) return all;
    }
  }

  function showSignIn(message = '') {
    clearInterval(timer);
    timer = null;
    session = null;
    lastSnapshot = null;
    clearToken();
    $('dashboard').hidden = true;
    $('auth-panel').hidden = false;
    $('logout-button').hidden = true;
    $('login-error').textContent = message;
    setConnection('Sign in required');
  }

  async function acceptSession(payload, token) {
    const profile = payload?.profile;
    if (!profile || !profile.location_id || !token) throw new Error('This account has no store access.');
    if (String(profile.role).toLowerCase() !== 'admin') throw new Error('An admin account is required.');
    if (profile.must_change_password) throw new Error('Change your password in Inventory Plus first.');
    session = { token, locationId: String(profile.location_id) };
    saveToken(token);
    lastSessionCheck = Date.now();
    $('auth-panel').hidden = true;
    $('dashboard').hidden = false;
    $('logout-button').hidden = false;
    setConnection('Loading live orders');
    await refreshQueue();
    clearInterval(timer);
    timer = setInterval(refreshQueue, pollMs);
  }

  async function validateSession() {
    if (!session || Date.now() - lastSessionCheck < 60000) return;
    const payload = await rpc('profile_restore_session_v1', { p_session_token: session.token });
    if (!payload || String(payload.profile?.role).toLowerCase() !== 'admin' ||
        String(payload.profile?.location_id) !== session.locationId) {
      showSignIn('Your session expired. Sign in again.');
      throw new Error('Session expired');
    }
    lastSessionCheck = Date.now();
  }

  function initials(name) {
    return String(name || '?').trim().split(/\s+/).slice(0, 2).map(part => part[0] || '').join('').toUpperCase();
  }

  function avatar(name) {
    const element = node('span', 'avatar', initials(name));
    element.setAttribute('aria-hidden', 'true');
    return element;
  }

  function isOnline(person) {
    const seen = new Date(person?.last_seen_at || 0).getTime();
    return person?.is_online === true && Date.now() - seen < 120000 && Date.now() >= seen;
  }

  function ageLabel(date) {
    const age = Math.max(0, Date.now() - new Date(date).getTime());
    if (!Number.isFinite(age) || age < 60000) return 'now';
    if (age < 3600000) return Math.floor(age / 60000) + 'm';
    if (age < 86400000) return Math.floor(age / 3600000) + 'h';
    return Math.floor(age / 86400000) + 'd';
  }

  function stage(order, activeOrderIds) {
    const status = String(order.status || '').toLowerCase();
    if (status === 'prepared') return 'ready';
    if (status !== 'pending' && status !== 'solo_picking') return null;
    const items = Array.isArray(order.items) ? order.items : [];
    const needsHelper = status === 'pending' && items.some(item => item?.requires_loading !== true);
    const needsBodegero = items.some(item => item?.requires_loading === true);
    if ((needsHelper && !order.assigned_helper_id) ||
        (needsBodegero && !order.assigned_bodegero_id)) return 'waiting';
    if (activeOrderIds.has(String(order.id)) || status === 'solo_picking' || order.loading_verified_at ||
        items.some(item => item?.picked === true || item?.heavy_verified === true)) return 'preparing';
    return 'assigned';
  }

  function orderCard(order, group, onlineStaff) {
    const card = node('article', group === 'ready' ? 'order compact' : 'order');
    const id = String(order.id || '').slice(0, 8).toUpperCase();
    card.setAttribute('aria-label', `Order ${id}, ${group.replace('_', ' ')}`);
    const top = node('div', 'order-top');
    top.append(node('span', 'order-id', '#' + id));
    const age = node('span', 'age');
    age.innerHTML = clockSvg;
    age.append(document.createTextNode(ageLabel(order.created_at)));
    top.append(age);
    card.append(top);
    const items = Array.isArray(order.items) ? order.items : [];
    const lightItems = items.filter(item => item?.requires_loading !== true);
    const heavyItems = items.filter(item => item?.requires_loading === true);
    const solo = String(order.status || '').toLowerCase() === 'solo_picking';
    const itemLabel = `${items.length} ${items.length === 1 ? 'item' : 'items'}`;
    const creator = String(order.created_by_name || '').trim();
    card.append(node('p', 'order-meta', `${itemLabel}${creator ? ' · Created by ' + creator : ''}`));
    if (group === 'waiting') {
      const missing = [];
      if (lightItems.length && !solo && !order.assigned_helper_id) missing.push('Helper');
      if (heavyItems.length && !order.assigned_bodegero_id) missing.push('Bodegero');
      card.append(node('p', 'waiting-detail', 'Waiting for ' + missing.join(' and ')));
    }
    if (group === 'assigned' || group === 'preparing') {
      const addProgress = (label, done, total) => {
        const heading = node('div', 'progress-heading');
        heading.append(node('span', '', label), node('span', '', `${done}/${total}`));
        const track = node('div', 'progress-track');
        const fill = node('div', 'progress-fill');
        fill.style.width = (total ? done / total * 100 : 0) + '%';
        track.append(fill);
        card.append(heading, track);
      };
      if (lightItems.length) addProgress('Light items picked', lightItems.filter(item => item?.picked === true).length, lightItems.length);
      if (heavyItems.length) {
        addProgress('Heavy items scanned', heavyItems.filter(item => item?.heavy_verified === true).length, heavyItems.length);
        card.append(node('p', 'loading-state', order.loading_verified_at ? 'Loading verified' : 'Truck loading pending'));
      }
    } else if (group === 'ready' && heavyItems.length) {
      card.append(node('p', 'loading-state verified', 'Truck loading verified · proof ready for cashier review'));
    }
    const footer = node('div', 'order-footer');
    const assignees = node('div', 'order-assignees');
    const addAssignee = (role, name, personId) => {
      const assigned = personId != null && String(personId).trim() !== '';
      const online = assigned && onlineStaff.has(String(personId));
      const row = node('div', assigned ? `assignee ${online ? 'online' : 'offline'}` : 'assignee');
      if (assigned) {
        row.append(avatar(name || role));
        row.title = `${role}: ${online ? 'online' : 'offline'}`;
      }
      row.append(node('span', 'assignee-role', role));
      row.append(node('span', 'assignee-name', name || (assigned ? 'Assigned' : 'Unassigned')));
      assignees.append(row);
    };
    if (lightItems.length) {
      addAssignee(solo ? 'Cashier' : 'Helper',
        solo ? creator : String(order.assigned_helper_name || '').trim(),
        solo ? null : order.assigned_helper_id);
    }
    if (heavyItems.length) {
      addAssignee('Bodegero', String(order.assigned_bodegero_name || '').trim(), order.assigned_bodegero_id);
    }
    footer.append(assignees);
    card.append(footer);
    return card;
  }

  function renderOrders(orders, presence) {
    const activePresence = presence.filter(isOnline);
    const onlineStaff = new Set(activePresence.map(person => String(person.user_id)));
    const activeOrderIds = new Set(activePresence.map(person => {
      const module = String(person.current_module || '');
      const marker = module.startsWith('Loading order:') ? 'Loading order:' :
        module.startsWith('Preparing order:') ? 'Preparing order:' : '';
      return marker ? module.slice(marker.length) : '';
    }).filter(Boolean));
    const groups = { waiting: [], assigned: [], preparing: [], ready: [] };
    for (const order of orders) {
      const key = stage(order, activeOrderIds);
      if (key) groups[key].push(order);
    }
    for (const [key, list] of Object.entries(groups)) {
      $(key + '-count').textContent = list.length;
      const fragment = document.createDocumentFragment();
      if (!list.length) fragment.append(node('p', 'empty', 'Nothing here'));
      else for (const order of list) fragment.append(orderCard(order, key, onlineStaff));
      $(key + '-orders').replaceChildren(fragment);
    }
  }

  async function refreshQueue() {
    if (!session || refreshing) return;
    refreshing = true;
    try {
      await validateSession();
      if (!session) return;
      const filter = 'eq.' + session.locationId;
      const [orders, presence] = await Promise.all([
        loadOpenOrders(filter),
        table('staff_presence', { select: 'user_id,is_online,last_seen_at,current_module', location_id: filter, user_role: 'in.(helper,bodegero)' }),
      ]);
      if (!session) return;
      lastSnapshot = { orders, presence };
      renderOrders(orders, presence);
      setConnection('Live · updated ' + new Date().toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }), 'live');
    } catch (error) {
      if (session) {
        if (lastSnapshot) {
          renderOrders(lastSnapshot.orders, lastSnapshot.presence);
        }
        setConnection(lastSnapshot ? 'Retrying live updates' : 'Could not load orders', 'error');
        console.error('Order queue refresh failed:', error);
      }
    } finally {
      refreshing = false;
    }
  }

  $('login-form').addEventListener('submit', async event => {
    event.preventDefault();
    const button = $('login-button');
    button.disabled = true;
    $('login-error').textContent = '';
    try {
      const payload = await rpc('profile_login_v1', {
        p_username: $('username').value.trim(),
        p_password: $('password').value.trim(),
      });
      if (payload?.rate_limited || payload?.status === 'rate_limited') {
        const seconds = Number(payload.retry_after_seconds);
        throw new Error(seconds > 0 ? `Too many attempts. Try again in ${seconds} seconds.` : 'Too many attempts. Try again later.');
      }
      if (!payload?.session_token) throw new Error('Invalid username or password.');
      try {
        await acceptSession(payload, payload.session_token);
      } catch (error) {
        await rpc('profile_logout_v1', { p_session_token: payload.session_token }).catch(() => {});
        throw error;
      }
      $('password').value = '';
    } catch (error) {
      showSignIn(error.message || 'Could not sign in.');
    } finally {
      button.disabled = false;
    }
  });

  $('logout-button').addEventListener('click', async () => {
    const token = session?.token;
    showSignIn();
    if (token) await rpc('profile_logout_v1', { p_session_token: token }).catch(() => {});
  });
  document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshQueue(); });

  async function start() {
    if (!config?.url?.startsWith('https://') || !config?.anonKey) {
      $('auth-panel').hidden = false;
      $('auth-title').textContent = 'Connection not configured';
      $('auth-panel').querySelector('p').textContent = 'Build the page with your Supabase URL and publishable key before deploying it.';
      $('login-form').hidden = true;
      setConnection('Setup required', 'error');
      return;
    }
    const token = storedToken();
    if (token) {
      try {
        const payload = await rpc('profile_restore_session_v1', { p_session_token: token });
        await acceptSession(payload, token);
        return;
      } catch { clearToken(); }
    }
    showSignIn();
  }

  start();
})();
