const config = globalThis.INSIGHTFLOW_ADMIN_CONFIG || {};
const api = config.apiOrigin || '';
const supabaseUrl = config.supabaseUrl || '';
const supabaseAnonKey = config.supabaseAnonKey || '';
const SESSION_KEY = 'insightflow.admin.session.v1';
const state = { token: '', q: '', page: 1, pageSize: 25, principal: '', companyPrincipal: '' };
function readSession() { try { return JSON.parse(localStorage.getItem(SESSION_KEY) || 'null'); } catch { return null; } }
function clearSession() { state.token = ''; localStorage.removeItem(SESSION_KEY); }
function saveSession(session) {
  if (!session?.access_token || !session?.refresh_token) throw Error('The authentication session was incomplete.');
  const saved = { access_token: session.access_token, refresh_token: session.refresh_token, token_type: session.token_type || 'bearer', expires_at: Date.now() + Number(session.expires_in || 3600) * 1000 };
  localStorage.setItem(SESSION_KEY, JSON.stringify(saved)); state.token = saved.access_token;
}
let refreshInFlight = null;
async function refreshSession() {
  if (refreshInFlight) return refreshInFlight;
  refreshInFlight = (async () => {
    const saved = readSession();
    if (!saved?.refresh_token || !supabaseUrl || !supabaseAnonKey) { clearSession(); return false; }
    try {
      const response = await fetch(`${supabaseUrl}/auth/v1/token?grant_type=refresh_token`, { method: 'POST', headers: { apikey: supabaseAnonKey, 'content-type': 'application/json' }, body: JSON.stringify({ refresh_token: saved.refresh_token }) });
      if (!response.ok) { clearSession(); return false; }
      saveSession(await response.json()); return true;
    } catch { state.token = saved.access_token || ''; return false; }
  })();
  try { return await refreshInFlight; } finally { refreshInFlight = null; }
}
async function restoreSession() {
  const saved = readSession();
  if (!saved?.access_token || !saved?.refresh_token) { clearSession(); login(); return; }
  if (Number(saved.expires_at || 0) <= Date.now() + 60_000) {
    if (!await refreshSession()) { login(); return; }
  } else state.token = saved.access_token;
  dashboard();
}
async function signOut() {
  const token = state.token || readSession()?.access_token || '';
  clearSession();
  try { if (token && supabaseUrl && supabaseAnonKey) await fetch(`${supabaseUrl}/auth/v1/logout`, { method: 'POST', headers: { apikey: supabaseAnonKey, Authorization: `Bearer ${token}` } }); } catch { /* Local sign-out still completes offline. */ }
  login();
}
const app = document.querySelector('#app');
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

function login() {
  app.innerHTML = `<main class="auth"><section class="panel"><p class="eyebrow">INSIGHTFLOW / ADMIN</p><h1>Administrator sign in</h1><p>Supabase authenticates you; the API independently verifies diagnostic authorization.</p><form id="login"><label>Email<input required type="email" autocomplete="username" name="email"></label><label>Password<input required type="password" autocomplete="current-password" name="password"></label><button>Sign in securely</button><p id="error" role="alert"></p></form></section></main>`;
  document.querySelector('#login').onsubmit = async event => {
    event.preventDefault(); const error = document.querySelector('#error');
    if (!supabaseUrl || !supabaseAnonKey) { error.textContent = 'Supabase configuration is unavailable.'; return; }
    try { const form = new FormData(event.target); const response = await fetch(`${supabaseUrl}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: supabaseAnonKey, 'content-type': 'application/json' }, body: JSON.stringify({ email: form.get('email'), password: form.get('password') }) }); const body = await response.json(); if (!response.ok) throw Error(body.error_description || 'Sign in failed'); saveSession(body); dashboard(); } catch (err) { error.textContent = err.message; }
  };
}
async function load(path) {
  let response = await fetch(api + path, { headers: { Authorization: `Bearer ${state.token}` } });
  if (response.status === 401 && await refreshSession()) response = await fetch(api + path, { headers: { Authorization: `Bearer ${state.token}` } });
  if (response.status === 401) { clearSession(); login(); throw Error('expired'); }
  if (!response.ok) throw Error(await response.text()); return response.json();
}
async function download(path, filename, type) {
  let response = await fetch(api + path, { headers: { Authorization: `Bearer ${state.token}` } });
  if (response.status === 401 && await refreshSession()) response = await fetch(api + path, { headers: { Authorization: `Bearer ${state.token}` } });
  if (response.status === 401) { clearSession(); login(); throw Error('expired'); }
  if (!response.ok) throw Error(await response.text());
  const blob = new Blob([await response.blob()], { type }); const url = URL.createObjectURL(blob); const link = document.createElement('a'); link.href = url; link.download = filename; link.click(); URL.revokeObjectURL(url);
}
function table(headers, rows) { if (!rows.length) return '<p class="muted" role="status">No records in this authorized scope.</p>'; const cell = value => value && typeof value === 'object' && value.action ? `<td data-action-principal="${esc(value.action)}"></td>` : `<td>${esc(value)}</td>`; return `<div class="table-wrap"><table><thead><tr>${headers.map(h => `<th>${esc(h)}</th>`).join('')}</tr></thead><tbody>${rows.map(row => `<tr>${row.map(cell).join('')}</tr>`).join('')}</tbody></table></div>`; }
async function renderPanel(name) {
  const panel = document.querySelector('#panel'); panel.innerHTML = '<p role="status">Loading authorized data…</p>';
  try {
    if (name === 'overview') { const data = await load('/v1/admin/overview'); panel.innerHTML = `<h2>Diagnostic overview</h2><div class="cards"><article><span>Events</span><strong>${data.total_events}</strong></article><article><span>Users with history</span><strong>${data.users}</strong></article><article><span>Scope</span><strong>Server-authorized</strong></article></div>`; }
    else if (name === 'users') { const data = await load(`/v1/admin/users?q=${encodeURIComponent(state.q)}&page=${state.page}&page_size=${state.pageSize}`); panel.innerHTML = `<h2>User directory</h2><form id="search"><label class="sr-only" for="q">Search users</label><input id="q" placeholder="Search user ID or email" value="${esc(state.q)}"><button>Search</button></form>${table(['User ID','Email','Branch','Action'], data.users.map(user => [user.user_id, user.email, user.branch_id || 'Organization', { action: user.principal_id }]))}<div class="pager"><button id="prev" ${state.page === 1 ? 'disabled' : ''}>Previous</button><span>Page ${state.page}</span><button id="next" ${data.users.length < state.pageSize ? 'disabled' : ''}>Next</button></div>`; document.querySelector('#search').onsubmit = event => { event.preventDefault(); state.q = document.querySelector('#q').value; state.page = 1; renderPanel('users'); }; document.querySelectorAll('[data-action-principal]').forEach(cell => { const button = document.createElement('button'); button.type = 'button'; button.textContent = 'Timeline'; button.addEventListener('click', () => { state.principal = cell.dataset.actionPrincipal; state.page = 1; renderPanel('timeline'); }); cell.append(button); }); document.querySelector('#prev').onclick = () => { state.page--; renderPanel('users'); }; document.querySelector('#next').onclick = () => { state.page++; renderPanel('users'); }; }
    else if (name === 'timeline') { const data = state.principal ? await load(`/v1/admin/users/${encodeURIComponent(state.principal)}/timeline?page=${state.page}&page_size=${state.pageSize}`) : { events: [] }; panel.innerHTML = `<h2>User diagnostic timeline</h2>${state.principal ? table(['Timestamp','Correlation','Category','Status','Sanitized error'], data.events.map(event => [event.event_at, event.correlation_id, event.category, event.status, event.sanitized_error])) : '<p class="muted">Select a user from the directory first.</p>'}`; }
    else if (name === 'support') { panel.innerHTML = `<h2>Support-reference search</h2><form id="support"><label for="reference">Session reference, correlation ID, or category</label><input id="reference" minlength="2" required><button>Search</button></form><div id="support-results"></div>`; document.querySelector('#support').onsubmit = async event => { event.preventDefault(); const result = await load(`/v1/admin/support/search?q=${encodeURIComponent(document.querySelector('#reference').value)}`); document.querySelector('#support-results').innerHTML = table(['Timestamp','Session reference','Correlation','Category','Status'], result.references.map(item => [item.event_at, item.session_id, item.correlation_id, item.category, item.status])); }; }
    else if (name === 'export') { panel.innerHTML = '<h2>Export reports</h2><p class="muted">Exports are organization/branch scoped and audited by the API.</p><p><a href="#" id="json-export">Download JSON</a> · <a href="#" id="csv-export">Download CSV</a></p>'; document.querySelector('#json-export').onclick = async event => { event.preventDefault(); const data = await load('/v1/admin/export?format=json'); const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' }); const url = URL.createObjectURL(blob); const link = document.createElement('a'); link.href = url; link.download = 'diagnostics.json'; link.click(); URL.revokeObjectURL(url); }; document.querySelector('#csv-export').onclick = async event => { event.preventDefault(); await download('/v1/admin/export?format=csv', 'diagnostics.csv', 'text/csv'); }; }
    else if (name === 'company-overview') { const data = await load('/v1/company-admin/overview'); panel.innerHTML = `<h2>InsightFlow company-wide diagnostics</h2><div class="cards"><article><span>Customer events</span><strong>${data.total_events}</strong></article><article><span>Backend requests</span><strong>${data.backend_requests}</strong></article><article><span>Backend errors</span><strong>${data.backend_errors}</strong></article><article><span>Customer users</span><strong>${data.users}</strong></article><article><span>Active users</span><strong>${data.active_users}</strong></article><article><span>Companies</span><strong>${data.organizations}</strong></article><article><span>Active companies</span><strong>${data.active_organizations}</strong></article><article><span>Customer failures</span><strong>${data.failures}</strong></article></div><p class="muted">Global support scope is granted only by the separate company-admin role.</p>`; }
    else if (name === 'companies') { const data = await load('/v1/company-admin/companies'); panel.innerHTML = `<h2>All registered companies</h2>${table(['Company','Organization ID','Status','Registered','Members','Active users','Events','Failures','Last activity'], data.companies.map(item => [item.name, item.organization_id, item.status, item.created_at, item.members, item.active_users, item.events, item.failures, item.last_activity]))}`; }
    else if (name === 'company-users') { const data = await load(`/v1/company-admin/users?q=${encodeURIComponent(state.q)}&page=${state.page}&page_size=${state.pageSize}`); panel.innerHTML = `<h2>All customer users</h2><form id="company-search"><label class="sr-only" for="company-q">Search users</label><input id="company-q" placeholder="Search user ID or email" value="${esc(state.q)}"><button>Search</button></form>${table(['User ID','Email','Organizations','Organization names','Roles','Membership status','Events','Failures','Last seen','Action'], data.users.map(user => [user.user_id, user.email, user.organization_count, user.organizations, user.roles, user.membership_statuses, user.event_count, user.failures, user.last_seen, { action: user.principal_id }]))}`; document.querySelector('#company-search').onsubmit = event => { event.preventDefault(); state.q = document.querySelector('#company-q').value; state.page = 1; renderPanel('company-users'); }; document.querySelectorAll('[data-action-principal]').forEach(cell => { const button = document.createElement('button'); button.type = 'button'; button.textContent = 'Timeline'; button.addEventListener('click', () => { state.companyPrincipal = cell.dataset.actionPrincipal; renderPanel('company-timeline'); }); cell.append(button); }); }
    else if (name === 'company-timeline') { const data = state.companyPrincipal ? await load(`/v1/company-admin/users/${encodeURIComponent(state.companyPrincipal)}/timeline?page=${state.page}&page_size=${state.pageSize}`) : { events: [] }; panel.innerHTML = `<h2>Company-wide user timeline</h2>${table(['Timestamp','Organization','Branch','Correlation','Category','Status','Safe error','Details'], data.events.map(event => [event.event_at, event.organization_id, event.branch_id, event.correlation_id, event.category, event.status, event.sanitized_error, JSON.stringify(event.payload)]))}`; }
    else if (name === 'company-events') { panel.innerHTML = `<h2>Search all customer diagnostics</h2><form id="company-event-search"><label for="company-event-q">Email, correlation ID, session reference, error or category</label><input id="company-event-q" minlength="2" required><button>Search</button></form><div id="company-event-results"></div>`; document.querySelector('#company-event-search').onsubmit = async event => { event.preventDefault(); const result = await load(`/v1/company-admin/events/search?q=${encodeURIComponent(document.querySelector('#company-event-q').value)}`); document.querySelector('#company-event-results').innerHTML = table(['Timestamp','Organization','User','Email','Branch','Correlation','Category','Status','Safe error'], result.events.map(item => [item.event_at, item.organization_id, item.user_principal_id, item.email, item.branch_id, item.correlation_id, item.category, item.status, item.sanitized_error])); }; }
    else if (name === 'backend-requests') { panel.innerHTML = `<h2>Backend request and error logs</h2><form id="backend-log-search"><label for="backend-log-q">Search route, request ID, user email, or error</label><input id="backend-log-q" minlength="0" placeholder="Search backend logs"><label><input id="backend-log-failed" type="checkbox"> Failed requests only</label><button>Search</button></form><div id="backend-log-results"></div>`; const runSearch = async () => { const params = new URLSearchParams({ q: document.querySelector('#backend-log-q').value, failed_only: document.querySelector('#backend-log-failed').checked ? 'true' : 'false' }); const result = await load(`/v1/company-admin/backend-requests?${params}`); document.querySelector('#backend-log-results').innerHTML = table(['Timestamp','Method','Route','HTTP','Duration ms','Request ID','User','Error type','Error detail','Stack frames','Fingerprint'], result.requests.map(item => [item.created_at, item.method, item.route, item.status_code, item.duration_ms, item.request_id, item.email || item.principal_id, item.error_type, item.error_message, item.error_stack, item.error_fingerprint])); }; document.querySelector('#backend-log-search').onsubmit = async event => { event.preventDefault(); await runSearch(); }; await runSearch(); }
    else if (name === 'company-audit') { const data = await load('/v1/company-admin/audit'); panel.innerHTML = `<h2>Company administrator audit</h2>${table(['Timestamp','Action','Metadata'], data.audit.map(item => [item.created_at, item.action, JSON.stringify(item.metadata)]))}`; }
    else if (name === 'audit') { const data = await load('/v1/admin/audit'); panel.innerHTML = `<h2>Administrator audit history</h2>${table(['Timestamp','Action','Outcome','Metadata'], data.audit.map(item => [item.created_at, item.action, item.outcome, JSON.stringify(item.metadata)]))}`; }
  } catch (error) { if (error.message !== 'expired') panel.innerHTML = `<div class="error" role="alert"><strong>Request failed</strong><pre>${esc(error.message)}</pre></div>`; }
}
function dashboard() {
  app.innerHTML = `<div class="shell" id="admin-shell">
    <header class="mobile-topbar">
      <button type="button" id="menu-toggle" class="menu-toggle" aria-label="Open navigation menu" aria-controls="admin-sidebar" aria-expanded="false"><span aria-hidden="true">☰</span></button>
      <div class="mobile-brand">InsightFlow <span>ADMIN</span></div>
    </header>
    <button type="button" id="sidebar-backdrop" class="sidebar-backdrop" aria-label="Close navigation menu" tabindex="-1"></button>
    <aside id="admin-sidebar" aria-label="Main navigation"><div class="sidebar-heading"><div class="brand">InsightFlow<span>ADMIN</span></div><button type="button" id="sidebar-close" class="sidebar-close" aria-label="Close navigation menu"><span aria-hidden="true">×</span></button></div><nav>${['company-overview:Company-wide overview','companies:All companies','company-users:All customer users','backend-requests:Backend request logs','company-events:Search all diagnostics','company-audit:Company admin audit','overview:Organization diagnostic overview','users:Organization user directory','timeline:Organization user timeline','support:Support-reference search','export:Organization exports','audit:Organization admin audit'].map(item => { const [id,label] = item.split(':'); return `<button class="nav-link" data-view="${id}">${label}</button>`; }).join('')}</nav><button id="signout" class="ghost">Sign out</button></aside>
    <main class="content"><header><p class="eyebrow">SECURE OPERATIONS</p><h1>Administrator diagnostics</h1><p class="muted">Company-wide views require a separate InsightFlow company-admin authorization. Tenant support views remain organization-scoped.</p></header><section id="panel" class="panel"></section></main>
  </div>`;
  const shell = document.querySelector('#admin-shell');
  const toggle = document.querySelector('#menu-toggle');
  const closeButton = document.querySelector('#sidebar-close');
  const backdrop = document.querySelector('#sidebar-backdrop');
  const sidebar = document.querySelector('#admin-sidebar');
  const focusableInSidebar = () => [...sidebar.querySelectorAll('button:not([disabled]), a[href], input:not([disabled]), [tabindex]:not([tabindex="-1"])')];
  const closeMenu = ({ restoreFocus = true } = {}) => {
    shell.classList.remove('nav-open');
    toggle.setAttribute('aria-expanded', 'false');
    toggle.setAttribute('aria-label', 'Open navigation menu');
    if (restoreFocus) toggle.focus();
  };
  const openMenu = () => {
    shell.classList.add('nav-open');
    toggle.setAttribute('aria-expanded', 'true');
    toggle.setAttribute('aria-label', 'Close navigation menu');
    focusableInSidebar()[0]?.focus();
  };
  toggle.onclick = () => shell.classList.contains('nav-open') ? closeMenu() : openMenu();
  closeButton.onclick = () => closeMenu();
  backdrop.addEventListener('pointerdown', event => event.preventDefault());
  backdrop.onclick = event => { event.preventDefault(); closeMenu({ restoreFocus: false }); backdrop.blur(); };
  document.onkeydown = event => {
    if (!shell.classList.contains('nav-open')) return;
    if (event.key === 'Escape') { event.preventDefault(); closeMenu(); return; }
    if (event.key !== 'Tab') return;
    const focusable = focusableInSidebar();
    if (!focusable.length) { event.preventDefault(); return; }
    const first = focusable[0], last = focusable[focusable.length - 1];
    if (event.shiftKey && (document.activeElement === first || !sidebar.contains(document.activeElement))) {
      event.preventDefault(); last.focus();
    } else if (!event.shiftKey && (document.activeElement === last || !sidebar.contains(document.activeElement))) {
      event.preventDefault(); first.focus();
    }
  };
  document.querySelectorAll('[data-view]').forEach(button => { button.onclick = () => { closeMenu({ restoreFocus: false }); renderPanel(button.dataset.view); }; });
  document.querySelector('#signout').onclick = signOut;
  renderPanel('company-overview');
}
restoreSession();
