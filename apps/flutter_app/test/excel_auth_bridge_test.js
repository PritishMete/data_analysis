const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname, '..', 'web', 'excel_auth_bridge.js'), 'utf8');

function harness(search, initialStorage = {}) {
  const values = new Map(Object.entries(initialStorage));
  const historyCalls = [];
  let assigned = '';
  let parentMessage = '';
  let issuedSession = null;
  const location = {
    href: 'https://pritishmete.github.io/data_analysis/' + search,
    origin: 'https://pritishmete.github.io',
    pathname: '/data_analysis/',
    search,
    hash: '',
    assign: (url) => { assigned = url; }
  };
  const window = {
    location,
    history: { state: null, replaceState: (...args) => historyCalls.push(args) },
    sessionStorage: {
      setItem: (key, value) => values.set(key, value),
      getItem: (key) => values.has(key) ? values.get(key) : null,
      removeItem: (key) => values.delete(key)
    },
    crypto: {
      getRandomValues: (bytes) => { bytes.fill(7); return bytes; },
      randomUUID: () => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      subtle: { digest: async () => new Uint8Array(32).buffer }
    },
    navigator: {},
    Office: {
      AsyncResultStatus: { Succeeded: 'succeeded' },
      EventType: { DialogMessageReceived: 'message', DialogEventReceived: 'event' },
      context: { ui: { messageParent: (message) => { parentMessage = message; } } }
    }
  };
  const context = {
    window, URL, URLSearchParams, Promise, Error, JSON, Uint8Array,
    TextEncoder, Date, Math, setTimeout: (fn) => { fn(); return 1; },
    fetch: async (url, options) => {
      if (String(url).includes('/auth/v1/token?grant_type=pkce') ||
          String(url).includes('/auth/v1/token?grant_type=password')) {
        issuedSession = { access_token: 'a'.repeat(40), refresh_token: 'r'.repeat(40) };
        return { ok: true, json: async () => issuedSession };
      }
      if (String(url).includes('/browser/bind')) return { ok: true, json: async () => ({ generation: 1 }) };
      if (String(url).includes('/browser/candidate')) return { ok: true, json: async () => ({ state: 'candidate_pending_approval' }) };
      if (String(url).includes('/browser/status')) return { ok: true, json: async () => ({
        state: 'approved', generation: 1,
        candidate_uid: 'user-1', approved_uid: 'user-1', approved_generation: 1
      }) };
      if (String(url).includes('/browser/complete')) return { ok: true, json: async () => ({ state: 'completed' }) };
      throw new Error('Unexpected fetch ' + url);
    },
    btoa: (value) => Buffer.from(value, 'binary').toString('base64'),
    atob: (value) => Buffer.from(value, 'base64').toString('binary')
  };
  vm.runInNewContext(source, context);
  return {
    window, values, historyCalls,
    get assigned() { return assigned; },
    get parentMessage() { return parentMessage; },
    get issuedSession() { return issuedSession; }
  };
}

async function run() {
  {
    const h = harness('?excelHandoff=tx-1&code=single-use-oauth-code&state=provider-state');
    assert.equal(h.window.InsightFlowExcelAuth.getTransactionId(), 'tx-1');
    assert.equal(h.historyCalls.length, 1);
    assert.equal(h.historyCalls[0][2].includes('single-use-oauth-code'), false);
    assert.equal(h.historyCalls[0][2].includes('state='), false);
  }

  {
    const h = harness('?excelHandoff=tx-2');
    h.window.InsightFlowExcelAuth.prepareBrowser(JSON.stringify({
      transactionId: 'tx-2',
      pairingCode: '0123-4567-89AB-CDEF',
      generation: 1,
      supabaseUrl: 'https://project.supabase.co',
      publishableKey: 'public-key',
      apiBase: 'https://api.example'
    }));
    const browser = JSON.parse(h.values.get('insightflow.excel.v2.browser'));
    assert.equal(browser.pairingCode, '0123-4567-89AB-CDEF');
    assert.equal(browser.browserCapability.length >= 40, true);
    assert.ok(browser.bindRequestId);
    assert.ok(browser.candidateRequestId);
    assert.ok(browser.completionRequestId);
    const sameBrowser = h.window.InsightFlowExcelAuth.prepareBrowser(JSON.stringify({
      transactionId: 'tx-2', pairingCode: '0123-4567-89AB-CDEF',
      generation: 1, supabaseUrl: 'https://project.supabase.co',
      publishableKey: 'public-key', apiBase: 'https://api.example'
    }));
    assert.equal(JSON.parse(h.values.get('insightflow.excel.v2.browser')).browserCapability, browser.browserCapability);
    assert.equal(JSON.stringify(browser).includes('refresh_token'), false);
    await h.window.InsightFlowExcelAuth.startGoogle();
    assert.match(h.assigned, /code_challenge_method=s256/);
    assert.equal(h.values.has('insightflow.excel.v2.pkce.verifier'), true);
  }

  {
    const stored = {
      transactionId: 'tx-3', pairingCode: '0123-4567-89AB-CDEF',
      generation: 1, supabaseUrl: 'https://project.supabase.co',
      publishableKey: 'public-key', apiBase: 'https://api.example',
      browserCapability: 'browser-capability-value',
      bindRequestId: 'bind-request-uuid',
      candidateRequestId: 'candidate-request-uuid',
      completionRequestId: 'completion-request-uuid'
    };
    const h = harness('?excelHandoff=tx-3&code=callback-code', {
      'insightflow.excel.v2.browser': JSON.stringify(stored),
      'insightflow.excel.v2.pkce.verifier': 'pkce-verifier'
    });
    assert.equal(await h.window.InsightFlowExcelAuth.resumeOAuth(), true);
    assert.equal(h.values.has('insightflow.excel.v2.browser'), false);
    assert.equal(h.values.has('insightflow.excel.v2.pkce.verifier'), false);
    assert.equal(h.values.get('insightflow.excel.v2.browser'), undefined);
    const messages = h.parentMessage ? JSON.parse(h.parentMessage) : null;
    if (messages) {
      assert.deepEqual(Object.keys(messages).sort(), ['state', 'transactionId', 'type', 'version']);
    }
  }

  {
    const h = harness('?excelHandoff=tx-4');
    const config = {
      transactionId: 'tx-4', pairingCode: '0123-4567-89AB-CDEF',
      generation: 1, supabaseUrl: 'https://project.supabase.co',
      publishableKey: 'public-key', apiBase: 'https://api.example'
    };
    h.window.InsightFlowExcelAuth.prepareBrowser(JSON.stringify(config));
    const result = await h.window.InsightFlowExcelAuth.passwordSignIn(JSON.stringify({
      ...config, email: 'person@example.com', password: 'not-a-real-password'
    }));
    assert.equal(result, 'completed');
    assert.equal(h.values.has('insightflow.excel.v2.browser'), false);
    assert.equal(h.issuedSession.access_token, '');
    assert.equal(h.issuedSession.refresh_token, '');
  }
  console.log('Excel v2 authentication bridge tests passed.');
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
