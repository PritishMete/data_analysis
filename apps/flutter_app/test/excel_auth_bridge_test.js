const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'web', 'excel_auth_bridge.js'),
  'utf8'
);

function createHarness(options = {}) {
  const parentHandlers = {};
  const childHandlers = {};
  const storage = new Map();
  const messages = [];
  const requests = [];
  const historyCalls = [];
  let openedUrl = '';
  let closed = false;
  let completed = false;
  let claimed = false;
  let readyMessagesToDrop = options.dropReadyMessages || 0;

  const dialog = {
    addEventHandler: (name, handler) => { parentHandlers[name] = handler; },
    messageChild: (message, messageOptions) => {
      const parsed = JSON.parse(message);
      assert.equal(messageOptions.targetOrigin, window.location.origin);
      if (childHandlers['parent-message']) {
        childHandlers['parent-message']({
          origin: window.location.origin,
          message
        });
      }
      return parsed;
    },
    close: () => { closed = true; }
  };

  function response(status, body) {
    return {
      status,
      ok: status >= 200 && status < 300,
      json: async () => body
    };
  }

  const window = {
    location: {
      href: 'https://insightflow-3e.pages.dev/?excelAuthDiagnostics=1',
      origin: 'https://insightflow-3e.pages.dev',
      pathname: '/',
      search: '?excelAuthDiagnostics=1',
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
        DialogEventReceived: 'event',
        DialogParentMessageReceived: 'parent-message'
      },
      context: {
        requirements: {
          isSetSupported: (name, version) =>
            (name === 'DialogApi' && version === '1.2' && options.supportDialogApi !== false) ||
            (name === 'DialogOrigin' && version === '1.1' && options.supportDialogOrigin !== false)
        },
        ui: {
          displayDialogAsync: (url, dialogOptions, callback) => {
            openedUrl = url;
            assert.equal(dialogOptions.displayInIframe, false);
            callback({ status: 'succeeded', value: dialog });
          },
          addHandlerAsync: (name, handler, callback) => {
            childHandlers[name] = handler;
            callback({ status: 'succeeded' });
          },
          messageParent: (message, messageOptions) => {
            assert.equal(messageOptions.targetOrigin, window.location.origin);
            messages.push(message);
            const parsed = JSON.parse(message);
            if (parsed.action === 'completed' && options.dropCompletionMessage) {
              throw new Error('simulated late Office message');
            }
            if (parsed.action === 'ready' && readyMessagesToDrop > 0) {
              readyMessagesToDrop--;
              return;
            }
            if (parentHandlers.message) {
              parentHandlers.message({
                origin: window.location.origin,
                message
              });
            }
          }
        }
      }
    },
    fetch: async (url, request) => {
      const route = new URL(url).pathname;
      const body = JSON.parse(request.body);
      requests.push({ route, body });
      if (route.endsWith('/create')) {
        return response(201, { transaction_id: body.transaction_id, expires_in: 180 });
      }
      if (route.endsWith('/complete')) {
        if (options.completeDelayMs) {
          await new Promise((resolve) => setTimeout(resolve, options.completeDelayMs));
        }
        completed = true;
        return response(204, {});
      }
      if (route.endsWith('/claim')) {
        if (!completed || claimed) return response(404, {});
        claimed = true;
        return response(200, { refresh_token: 'rotated-refresh-token-from-server' });
      }
      if (route.endsWith('/cancel')) return response(204, {});
      return response(404, {});
    },
    crypto: {
      getRandomValues: (bytes) => {
        for (let i = 0; i < bytes.length; i++) bytes[i] = (i * 17 + 11) & 255;
        return bytes;
      }
    },
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    console: { debug: () => {} }
  };

  vm.runInNewContext(source, {
    window, URL, URLSearchParams, Promise, Error, JSON, Uint8Array, Array, Date
  });

  return {
    window, parentHandlers, childHandlers, messages, requests, historyCalls, storage,
    get openedUrl() { return openedUrl; },
    get closed() { return closed; },
    get completed() { return completed; },
    get claimed() { return claimed; },
    setDialogUrl(url) {
      const parsed = new URL(url);
      window.location.href = parsed.href;
      window.location.search = parsed.search;
      window.location.pathname = parsed.pathname;
      window.InsightFlowExcelAuth.restoreDialogFlag();
    },
    simulateDialogClose() {
      if (parentHandlers.event) parentHandlers.event({ error: 12006 });
    }
  };
}

async function openDialog(harness) {
  const pending = harness.window.InsightFlowExcelAuth.openSignInDialog(
    'excel-test-correlation',
    'https://api.insightflow.test'
  );
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.ok(harness.openedUrl, 'Office dialog should open after handoff creation');
  const url = new URL(harness.openedUrl);
  assert.equal(url.searchParams.get('excelAuthDialog'), '1');
  assert.ok(/^[a-f0-9]{48}$/.test(url.searchParams.get('excelAuthState')));
  assert.equal(url.searchParams.has('claim_capability'), false);
  assert.equal(url.searchParams.has('completion_capability'), false);
  assert.equal(url.searchParams.has('refresh_token'), false);
  return { pending, url };
}

async function prepareDialog(harness, url) {
  harness.setDialogUrl(url.href);
  const contextPromise = harness.window.InsightFlowExcelAuth.waitForHandoffContext();
  const context = JSON.parse(await contextPromise);
  assert.ok(context.transaction_id);
  assert.ok(context.completion_capability);
  assert.equal(Object.prototype.hasOwnProperty.call(context, 'claim_capability'), false);
  return context;
}

async function run() {
  {
    const h = createHarness({ dropReadyMessages: 2 });
    const { pending, url } = await openDialog(h);
    const context = await prepareDialog(h, url);

    // Simulate a Google OAuth redirect/reload: the dialog keeps its state nonce,
    // and the parent resends the in-memory transaction context to the new page.
    h.window.Office.context.ui.messageParent(JSON.stringify({
      type: 'insightflow.excel.auth.handoff',
      version: 2,
      action: 'ready',
      state: url.searchParams.get('excelAuthState')
    }), { targetOrigin: h.window.location.origin });
    assert.equal(typeof h.parentHandlers.message, 'function');

    const completed = await h.window.InsightFlowExcelAuth.completeDialog(
      'access-token-for-test-only-123456',
      'original-dialog-refresh-token',
      'https://api.insightflow.test'
    );
    assert.equal(completed, true);
    assert.equal(h.completed, true);
    assert.equal(h.messages.map(JSON.parse).some((item) => item.action === 'completed'), false,
      'parent notification must wait until Flutter marks its dialog UI complete');
    assert.equal(h.window.InsightFlowExcelAuth.notifyDialogComplete(), true);
    const taskPaneToken = await pending;
    assert.equal(taskPaneToken, 'rotated-refresh-token-from-server');
    assert.notEqual(taskPaneToken, 'original-dialog-refresh-token');
    assert.equal(h.completed, true);
    assert.equal(h.claimed, true);
    assert.equal(h.closed, true);

    const completeRequest = h.requests.find((item) => item.route.endsWith('/complete'));
    assert.equal(completeRequest.body.transaction_id, context.transaction_id);
    assert.equal(completeRequest.body.completion_capability, context.completion_capability);
    const completedMessage = h.messages.map(JSON.parse).find((item) => item.action === 'completed');
    assert.equal(completedMessage.state, url.searchParams.get('excelAuthState'));
    assert.equal(completedMessage.transaction_id, context.transaction_id);
    assert.equal(Object.prototype.hasOwnProperty.call(completedMessage, 'refreshToken'), false);
    assert.equal(JSON.stringify(h.messages).includes('original-dialog-refresh-token'), false);
    assert.equal(JSON.stringify(h.messages).includes('rotated-refresh-token-from-server'), false);
  }

  {
    const h = createHarness();
    const { pending, url } = await openDialog(h);
    await prepareDialog(h, url);
    const first = h.window.InsightFlowExcelAuth.completeDialog(
      'access-token-for-test-only-123456',
      'original-refresh-token-for-rotation',
      'https://api.insightflow.test'
    );
    const second = h.window.InsightFlowExcelAuth.completeDialog(
      'access-token-for-test-only-123456',
      'original-refresh-token-for-rotation',
      'https://api.insightflow.test'
    );
    assert.equal(first, second, 'duplicate callbacks must share one completion request');
    await Promise.all([first, second]);
    assert.equal(h.requests.filter((item) => item.route.endsWith('/complete')).length, 1);
    assert.equal(h.window.InsightFlowExcelAuth.notifyDialogComplete(), true);
    assert.equal(await pending, 'rotated-refresh-token-from-server');
  }

  {
    const h = createHarness({ dropCompletionMessage: true, completeDelayMs: 650 });
    const { pending, url } = await openDialog(h);
    await prepareDialog(h, url);
    const completing = h.window.InsightFlowExcelAuth.completeDialog(
      'access-token-for-test-only-123456',
      'original-refresh-token-late-close',
      'https://api.insightflow.test'
    );
    // Office closes while the backend is still rotating and persisting the
    // replacement token. Parent keeps polling the one-time claim.
    await new Promise((resolve) => setTimeout(resolve, 25));
    h.simulateDialogClose();
    await completing;
    assert.equal(h.window.InsightFlowExcelAuth.notifyDialogComplete(), false);
    assert.equal(await pending, 'rotated-refresh-token-from-server');
    assert.equal(h.claimed, true);
  }

  {
    const h = createHarness({ supportDialogApi: false });
    await assert.rejects(
      h.window.InsightFlowExcelAuth.openSignInDialog(
        'excel-test-correlation',
        'https://api.insightflow.test'
      ),
      /excel_dialog_api_unsupported/
    );
    assert.equal(h.requests.length, 0,
      'unsupported Office hosts must not create a stranded handoff transaction');
  }

  {
    const h = createHarness({ supportDialogOrigin: false });
    await assert.rejects(
      h.window.InsightFlowExcelAuth.openSignInDialog(
        'excel-test-correlation',
        'https://api.insightflow.test'
      ),
      /excel_dialog_api_unsupported/
    );
    assert.equal(h.requests.length, 0,
      'hosts without origin metadata must not receive handoff capabilities');
  }

  {
    const h = createHarness('?excelAuthDialog=1&excelAuthDiagnostics=1');
    assert.equal(h.window.InsightFlowExcelAuth.setDiagnosticsEnabled(true), true);
    assert.equal(h.window.__INSIGHTFLOW_EXCEL_AUTH_DIAGNOSTICS__, true);
    h.window.InsightFlowExcelAuth.resetDiagnostics();
    assert.equal(h.window.__INSIGHTFLOW_EXCEL_AUTH_DIAGNOSTICS__, false);
  }

  {
    const h = createHarness('');
    h.storage.set('insightflow.excel.auth.dialog', '1');
    h.storage.set('insightflow.excel.auth.state', 'a'.repeat(48));
    h.storage.set('insightflow.excel.auth.correlation', 'excel-correlation-after-oauth');
    h.window.InsightFlowExcelAuth.restoreDialogFlag();
    assert.equal(h.historyCalls.length, 1);
    assert.match(h.historyCalls[0][2], /excelAuthDialog=1/);
    assert.match(h.historyCalls[0][2], /excelAuthState=/);
    assert.match(h.historyCalls[0][2], /excelAuthCorrelation=excel-correlation-after-oauth/);
    assert.equal(h.window.__insightFlowExcelAuthCorrelation, 'excel-correlation-after-oauth');
  }

  {
    const h = createHarness();
    const { pending, url } = await openDialog(h);
    await prepareDialog(h, url);
    h.parentHandlers.message({
      origin: 'https://attacker.example',
      message: JSON.stringify({
        type: 'insightflow.excel.auth.handoff',
        version: 2,
        action: 'completed',
        state: url.searchParams.get('excelAuthState'),
        transaction_id: '11111111-1111-4111-8111-111111111111'
      })
    });
    assert.equal(h.claimed, false);
    assert.equal(
      h.requests.filter((item) => item.route.endsWith('/claim')).length,
      0,
      'an untrusted origin must not trigger a one-time claim'
    );
  }

  console.log('Excel authentication one-time handoff tests passed.');
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
