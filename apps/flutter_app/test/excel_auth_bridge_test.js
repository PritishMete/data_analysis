const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'web', 'excel_auth_bridge.js'),
  'utf8'
);

function createHarness(search = '?excelAuthDialog=1') {
  const handlers = {};
  const storage = new Map();
  const messages = [];
  const historyCalls = [];
  let openedUrl = '';
  let closed = false;

  const dialog = {
    addEventHandler: (name, handler) => { handlers[name] = handler; },
    close: () => { closed = true; }
  };
  const window = {
    location: {
      href: 'https://pritishmete.github.io/data_analysis/' + search,
      origin: 'https://pritishmete.github.io',
      pathname: '/data_analysis/',
      search,
      hash: ''
    },
    sessionStorage: {
      setItem: (key, value) => storage.set(key, value),
      getItem: (key) => storage.has(key) ? storage.get(key) : null,
      removeItem: (key) => storage.delete(key)
    },
    history: {
      state: null,
      replaceState: (...args) => historyCalls.push(args)
    },
    Office: {
      AsyncResultStatus: { Succeeded: 'succeeded' },
      EventType: {
        DialogMessageReceived: 'message',
        DialogEventReceived: 'event'
      },
      context: {
        ui: {
          displayDialogAsync: (url, options, callback) => {
            openedUrl = url;
            assert.equal(options.displayInIframe, false);
            callback({ status: 'succeeded', value: dialog });
          },
          messageParent: (message) => messages.push(message)
        }
      }
    },
    console: { debug: () => {} }
  };

  window.crypto = { getRandomValues: (bytes) => { bytes.fill(7); return bytes; } };
  vm.runInNewContext(source, { window, URL, URLSearchParams, Promise, Error, JSON, Uint8Array, Array });
  return {
    window, handlers, messages, historyCalls,
    get openedUrl() { return openedUrl; },
    get closed() { return closed; },
    storage
  };
}

async function run() {
  {
    const h = createHarness('?excelAuthDialog=1&excelAuthDiagnostics=1&code=test-code');
    assert.equal(h.window.InsightFlowExcelAuth.setDiagnosticsEnabled(true), true);
    assert.equal(h.window.__INSIGHTFLOW_EXCEL_AUTH_DIAGNOSTICS__, true);
    h.window.InsightFlowExcelAuth.restoreDialogFlag();
    assert.match(h.window.InsightFlowExcelAuth.exportDiagnostics(), /oauth_callback_detected/);
    h.window.InsightFlowExcelAuth.resetDiagnostics();
    assert.equal(h.window.__INSIGHTFLOW_EXCEL_AUTH_DIAGNOSTICS__, false);
  }

  {
    const h = createHarness('?excelAuthDialog=1&excelAuthDiagnostics=1&code=test-code');
    assert.equal(h.window.InsightFlowExcelAuth.setDiagnosticsEnabled(true), true);
    const diagnostics = h.window.InsightFlowExcelAuth.exportDiagnostics();
    assert.match(diagnostics, /oauth_callback_detected/);
    assert.doesNotMatch(diagnostics, /test-code/);
  }

  {
    const h = createHarness('');
    h.storage.set('insightflow.excel.auth.dialog', '1');
    h.storage.set('insightflow.excel.auth.state', 'test-state');
    h.window.InsightFlowExcelAuth.restoreDialogFlag();
    assert.equal(h.historyCalls.length, 1);
    assert.match(h.historyCalls[0][2], /excelAuthDialog=1/);
    assert.match(h.historyCalls[0][2], /excelAuthState=test-state/);
  }

  {
    const h = createHarness();
    const result = h.window.InsightFlowExcelAuth.openSignInDialog();
    assert.match(h.openedUrl, /excelAuthDialog=1/);
    const state = new URL(h.openedUrl).searchParams.get('excelAuthState');
    assert.ok(state);
    h.handlers.message({
      origin: 'https://pritishmete.github.io',
      message: JSON.stringify({
        type: 'insightflow.excel.auth',
        version: 1,
        state,
        refreshToken: 'r'.repeat(48)
      })
    });
    assert.equal(await result, 'r'.repeat(48));
    assert.equal(h.closed, true);
  }

  {
    const h = createHarness();
    const result = h.window.InsightFlowExcelAuth.openSignInDialog();
    const state = new URL(h.openedUrl).searchParams.get('excelAuthState');
    h.handlers.message({
      origin: 'https://attacker.example',
      message: JSON.stringify({
        type: 'insightflow.excel.auth',
        version: 1,
        state,
        refreshToken: 'r'.repeat(48)
      })
    });
    await assert.rejects(result, /untrusted origin/);
  }

  {
    const h = createHarness('?excelAuthDialog=1&excelAuthState=test-state');
    h.window.InsightFlowExcelAuth.completeDialog('r'.repeat(48));
    const payload = JSON.parse(h.messages[0]);
    assert.equal(payload.type, 'insightflow.excel.auth');
    assert.equal(payload.version, 1);
    assert.equal(payload.state, 'test-state');
    assert.equal(payload.refreshToken, 'r'.repeat(48));
    assert.equal(h.storage.has('insightflow.excel.auth.dialog'), false);
    assert.equal(h.storage.has('insightflow.excel.auth.state'), false);
  }

  console.log('Excel authentication bridge tests passed.');
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
