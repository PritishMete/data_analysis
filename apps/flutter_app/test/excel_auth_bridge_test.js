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
    }
  };

  vm.runInNewContext(source, { window, URL, URLSearchParams, Promise, Error, JSON });
  return {
    window, handlers, messages, historyCalls,
    get openedUrl() { return openedUrl; },
    get closed() { return closed; },
    storage
  };
}

async function run() {
  {
    const h = createHarness('');
    h.storage.set('insightflow.excel.auth.dialog', '1');
    h.window.InsightFlowExcelAuth.restoreDialogFlag();
    assert.equal(h.historyCalls.length, 1);
    assert.match(h.historyCalls[0][2], /excelAuthDialog=1/);
  }

  {
    const h = createHarness();
    const result = h.window.InsightFlowExcelAuth.openSignInDialog();
    assert.match(h.openedUrl, /excelAuthDialog=1/);
    h.handlers.message({
      origin: 'https://pritishmete.github.io',
      message: JSON.stringify({
        type: 'insightflow.excel.auth',
        version: 1,
        refreshToken: 'r'.repeat(48)
      })
    });
    assert.equal(await result, 'r'.repeat(48));
    assert.equal(h.closed, true);
  }

  {
    const h = createHarness();
    const result = h.window.InsightFlowExcelAuth.openSignInDialog();
    h.handlers.message({
      origin: 'https://attacker.example',
      message: JSON.stringify({
        type: 'insightflow.excel.auth',
        version: 1,
        refreshToken: 'r'.repeat(48)
      })
    });
    await assert.rejects(result, /untrusted origin/);
  }

  {
    const h = createHarness();
    h.window.InsightFlowExcelAuth.completeDialog('r'.repeat(48));
    const payload = JSON.parse(h.messages[0]);
    assert.equal(payload.type, 'insightflow.excel.auth');
    assert.equal(payload.version, 1);
    assert.equal(payload.refreshToken, 'r'.repeat(48));
    assert.equal(h.storage.has('insightflow.excel.auth.dialog'), false);
  }

  console.log('Excel authentication bridge tests passed.');
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
