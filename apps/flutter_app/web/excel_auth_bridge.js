(function (global) {
  "use strict";

  var TYPE = "insightflow.excel.auth.handoff";
  var VERSION = 2;
  var DIALOG_FLAG = "excelAuthDialog";
  var DIALOG_KEY = "insightflow.excel.auth.dialog";
  var STATE_PARAM = "excelAuthState";
  var STATE_KEY = "insightflow.excel.auth.state";
  var CORRELATION_KEY = "insightflow.excel.auth.correlation";
  var DIAGNOSTIC_KEY = "insightflow.excel.auth.diagnostics";
  var DIAGNOSTIC_TTL = 15 * 60 * 1000;
  var events = [];
  var correlation = null;
  var handoffContext = null;
  var contextPromise = null;
  var contextResolve = null;
  var contextReject = null;
  var completionPromise = null;
  var handoffReadyToNotify = false;

  function diagnostic(event, fields) {
    if (!global.__INSIGHTFLOW_EXCEL_AUTH_DIAGNOSTICS__) return;
    var item = Object.assign({ event: event, timestamp: new Date().toISOString(), correlation_id: correlation }, fields || {});
    events.push(item);
    if (events.length > 100) events.shift();
    if (global.console && typeof global.console.debug === "function") {
      global.console.debug("[excel-auth-bridge-diagnostic]", item);
    }
  }

  function setDiagnosticsEnabled(enabled) {
    var active = false;
    try {
      var params = new URLSearchParams(global.location.search || "");
      correlation = params.get("excelAuthCorrelation") || correlation;
      if (enabled === true && params.get("excelAuthDiagnostics") === "1") {
        global.sessionStorage.setItem(DIAGNOSTIC_KEY, String(Date.now() + DIAGNOSTIC_TTL));
      }
      var expiry = Number(global.sessionStorage.getItem(DIAGNOSTIC_KEY) || 0);
      active = enabled === true && expiry > Date.now();
      if (!active && expiry) global.sessionStorage.removeItem(DIAGNOSTIC_KEY);
    } catch (_) {}
    global.__INSIGHTFLOW_EXCEL_AUTH_DIAGNOSTICS__ = active;
    return active;
  }

  function exportDiagnostics() { return JSON.stringify(events); }
  function resetDiagnostics() {
    events = [];
    try { global.sessionStorage.removeItem(DIAGNOSTIC_KEY); } catch (_) {}
    global.__INSIGHTFLOW_EXCEL_AUTH_DIAGNOSTICS__ = false;
  }

  function randomHex(size) {
    if (!global.crypto || typeof global.crypto.getRandomValues !== "function") {
      throw new Error("secure_random_unavailable");
    }
    var bytes = new Uint8Array(size);
    global.crypto.getRandomValues(bytes);
    return Array.prototype.map.call(bytes, function (value) {
      return value.toString(16).padStart(2, "0");
    }).join("");
  }

  function createUuid() {
    var bytes = new Uint8Array(16);
    global.crypto.getRandomValues(bytes);
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    var hex = Array.prototype.map.call(bytes, function (value) {
      return value.toString(16).padStart(2, "0");
    }).join("");
    return hex.slice(0, 8) + "-" + hex.slice(8, 12) + "-" +
      hex.slice(12, 16) + "-" + hex.slice(16, 20) + "-" + hex.slice(20);
  }

  function apiOrigin(value) {
    var url;
    try { url = new URL(value); } catch (_) { throw new Error("handoff_api_unavailable"); }
    var local = url.hostname === "localhost" || url.hostname === "127.0.0.1";
    if ((!local && url.protocol !== "https:") ||
        (local && url.protocol !== "http:" && url.protocol !== "https:") ||
        url.username || url.password || url.pathname !== "/" || url.search || url.hash) {
      throw new Error("handoff_api_unavailable");
    }
    return url.origin;
  }

  function post(origin, route, body) {
    return global.fetch(origin + route, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      cache: "no-store",
      credentials: "omit",
      redirect: "error"
    }).then(function (response) {
      if (route === "/v1/excel-auth/handoff/claim" && response.status === 404) return null;
      if (!response || !response.ok) throw new Error("handoff_request_failed");
      if (response.status === 204) return {};
      return response.json().catch(function () { throw new Error("handoff_response_invalid"); });
    });
  }

  function dialogState() {
    var state = null;
    try {
      var params = new URLSearchParams(global.location.search || "");
      state = params.get(STATE_PARAM) || global.sessionStorage.getItem(STATE_KEY);
    } catch (_) {}
    return typeof state === "string" && /^[a-f0-9]{48}$/.test(state) ? state : null;
  }

  function restoreDialogFlag() {
    try {
      var params = new URLSearchParams(global.location.search || "");
      if (params.get(DIALOG_FLAG) === "1") {
        global.__isInsightFlowExcelAuthDialog = true;
        global.sessionStorage.setItem(DIALOG_KEY, "1");
        var state = params.get(STATE_PARAM);
        var id = params.get("excelAuthCorrelation");
        if (id) {
          correlation = id;
          global.__insightFlowExcelAuthCorrelation = id;
          global.sessionStorage.setItem(CORRELATION_KEY, id);
        }
        if (state && /^[a-f0-9]{48}$/.test(state)) global.sessionStorage.setItem(STATE_KEY, state);
        return;
      }
      if (global.sessionStorage.getItem(DIALOG_KEY) === "1") {
        global.__isInsightFlowExcelAuthDialog = true;
        params.set(DIALOG_FLAG, "1");
        var saved = global.sessionStorage.getItem(STATE_KEY);
        if (saved) params.set(STATE_PARAM, saved);
        var savedCorrelation = global.sessionStorage.getItem(CORRELATION_KEY);
        if (savedCorrelation) {
          correlation = savedCorrelation;
          global.__insightFlowExcelAuthCorrelation = savedCorrelation;
          params.set("excelAuthCorrelation", savedCorrelation);
        }
        var query = params.toString();
        global.history.replaceState(global.history.state, "", global.location.pathname +
          (query ? "?" + query : "") + (global.location.hash || ""));
      }
    } catch (_) {}
  }

  function validCapability(value) {
    return typeof value === "string" && value.length >= 43 && value.length <= 128 &&
      /^[A-Za-z0-9_-]+$/.test(value);
  }

  function validTransaction(value) {
    return typeof value === "string" &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
  }

  function waitForHandoffContext() {
    if (!global.__isInsightFlowExcelAuthDialog) {
      return Promise.reject(new Error("excel_dialog_required"));
    }
    if (handoffContext) return Promise.resolve(JSON.stringify(handoffContext));
    if (contextPromise) return contextPromise;
    var state = dialogState();
    var ui = global.Office && global.Office.context && global.Office.context.ui;
    if (!state || !ui || typeof ui.addHandlerAsync !== "function" ||
        typeof ui.messageParent !== "function") {
      return Promise.reject(new Error("excel_dialog_channel_unavailable"));
    }

    contextPromise = new Promise(function (resolve, reject) {
      contextResolve = resolve;
      contextReject = reject;
      var contextTimer = global.setTimeout(function () {
        if (contextReject) contextReject(new Error("excel_dialog_channel_timeout"));
        contextResolve = null;
        contextReject = null;
      }, 60000);
      ui.addHandlerAsync(global.Office.EventType.DialogParentMessageReceived, function (args) {
        if (!args || args.origin !== global.location.origin ||
            typeof args.message !== "string" || args.message.length > 4096) {
          diagnostic("parent_context_rejected", { error_code: "invalid_origin_or_message" });
          return;
        }
        var message;
        try { message = JSON.parse(args.message); } catch (_) { return; }
        if (message.type !== TYPE || message.version !== VERSION ||
            message.action !== "context" || message.state !== state ||
            !validTransaction(message.transaction_id) ||
            !validCapability(message.completion_capability)) {
          diagnostic("parent_context_rejected", { error_code: "invalid_context" });
          return;
        }
        handoffContext = {
          transaction_id: message.transaction_id,
          completion_capability: message.completion_capability,
          state: state
        };
        diagnostic("parent_context_received", { result: "validated" });
        global.clearTimeout(contextTimer);
        if (contextResolve) contextResolve(JSON.stringify(handoffContext));
        contextResolve = null;
        contextReject = null;
      }, function (result) {
        if (result && result.status &&
            result.status !== global.Office.AsyncResultStatus.Succeeded) {
          global.clearTimeout(contextTimer);
          if (contextReject) contextReject(new Error("excel_dialog_channel_unavailable"));
          contextResolve = null;
          contextReject = null;
          return;
        }
        try {
          ui.messageParent(JSON.stringify({
            type: TYPE, version: VERSION, action: "ready", state: state
          }), { targetOrigin: global.location.origin });
          diagnostic("dialog_ready_sent", { result: "sent" });
        } catch (_) {
          global.clearTimeout(contextTimer);
          if (contextReject) contextReject(new Error("excel_dialog_channel_unavailable"));
          contextResolve = null;
          contextReject = null;
        }
      });
    }).catch(function (error) {
      contextPromise = null;
      throw error;
    });
    return contextPromise;
  }

  function cancel(origin, transactionId, claimCapability) {
    return post(origin, "/v1/excel-auth/handoff/cancel", {
      transaction_id: transactionId, claim_capability: claimCapability
    }).catch(function () {});
  }

  function openSignInDialog(correlationId, backendOrigin) {
    if (typeof correlationId === "string" && correlationId.length <= 80) {
      correlation = correlationId;
    }
    diagnostic("dialog_open_started");
    var requirements = global.Office && global.Office.context &&
      global.Office.context.requirements;
    if (!requirements || typeof requirements.isSetSupported !== "function" ||
        !requirements.isSetSupported("DialogApi", "1.2") ||
        !requirements.isSetSupported("DialogOrigin", "1.1")) {
      // DialogApi 1.2 supplies parent-to-dialog messaging; DialogOrigin 1.1
      // supplies the origin metadata and targetOrigin pinning used to protect
      // the capability exchange. Fail closed if either contract is missing.
      return Promise.reject(new Error("excel_dialog_api_unsupported"));
    }
    var origin, transactionId, claimCapability, completionCapability, state;
    try {
      origin = apiOrigin(backendOrigin);
      transactionId = createUuid();
      claimCapability = randomHex(32);
      completionCapability = randomHex(32);
      state = randomHex(24);
    } catch (_) {
      return Promise.reject(new Error("excel_handoff_unavailable"));
    }

    return post(origin, "/v1/excel-auth/handoff/create", {
      transaction_id: transactionId,
      claim_capability: claimCapability,
      completion_capability: completionCapability
    }).then(function (created) {
      if (!created || created.transaction_id !== transactionId) throw new Error("handoff_create_failed");
      return new Promise(function (resolve, reject) {
        var ui = global.Office && global.Office.context && global.Office.context.ui;
        if (!ui || typeof ui.displayDialogAsync !== "function") {
          cancel(origin, transactionId, claimCapability);
          reject(new Error("excel_dialog_unavailable"));
          return;
        }

        var url;
        try {
          url = new URL(global.location.href);
          url.searchParams.set(DIALOG_FLAG, "1");
          url.searchParams.set(STATE_PARAM, state);
          if (typeof correlationId === "string" && correlationId.length <= 80) {
            url.searchParams.set("excelAuthCorrelation", correlationId);
          }
          if (global.__INSIGHTFLOW_EXCEL_AUTH_DIAGNOSTICS__) {
            url.searchParams.set("excelAuthDiagnostics", "1");
          }
          url.hash = "";
        } catch (_) {
          cancel(origin, transactionId, claimCapability);
          reject(new Error("excel_dialog_unavailable"));
          return;
        }

        var dialog = null;
        var settled = false;
        var completionReceived = false;
        var claimRunning = false;

        function finish(error, token) {
          if (settled) return;
          settled = true;
          if (error) {
            cancel(origin, transactionId, claimCapability);
            reject(error);
          } else {
            try { if (dialog) dialog.close(); } catch (_) {}
            resolve(token);
          }
        }

        function claimWithRetries(remaining, delay) {
          if (claimRunning || settled) return;
          claimRunning = true;
          function attempt(left, waitMs) {
            post(origin, "/v1/excel-auth/handoff/claim", {
              transaction_id: transactionId, claim_capability: claimCapability
            }).then(function (result) {
              if (result && typeof result.refresh_token === "string" &&
                  result.refresh_token.length >= 20) {
                diagnostic("handoff_claimed", { result: "succeeded" });
                finish(null, result.refresh_token);
                return;
              }
              if (left <= 0) {
                claimRunning = false;
                finish(new Error("excel_handoff_unavailable"));
                return;
              }
              var nextWait = Math.min(waitMs * 2, 4000);
              global.setTimeout(function () { attempt(left - 1, nextWait); }, waitMs);
            }).catch(function () {
              claimRunning = false;
              finish(new Error("excel_handoff_unavailable"));
            });
          }
          attempt(remaining, delay);
        }

        function onMessage(args) {
          if (!args || args.origin !== global.location.origin ||
              typeof args.message !== "string" || args.message.length > 2048) {
            diagnostic("dialog_message_rejected", { error_code: "invalid_origin_or_message" });
            return;
          }
          var message;
          try { message = JSON.parse(args.message); } catch (_) { return; }
          if (message.type !== TYPE || message.version !== VERSION || message.state !== state) return;

          if (message.action === "ready") {
            try {
              // The Office dialog document reloads during Google OAuth. Re-send
              // the one-time context to each new same-origin document.
              dialog.messageChild(JSON.stringify({
                type: TYPE, version: VERSION, action: "context", state: state,
                transaction_id: transactionId,
                completion_capability: completionCapability
              }), { targetOrigin: global.location.origin });
              diagnostic("dialog_context_sent", { result: "sent" });
            } catch (_) {
              diagnostic("dialog_context_sent", { result: "failed", error_code: "office_message_failed" });
              finish(new Error("excel_dialog_channel_unavailable"));
            }
            return;
          }
          if (message.action === "completed" && message.transaction_id === transactionId) {
            completionReceived = true;
            diagnostic("dialog_completion_received", { result: "validated" });
            claimWithRetries(5, 250);
          }
        }

        ui.displayDialogAsync(url.toString(), { height: 80, width: 60, displayInIframe: false }, function (result) {
          if (!result || result.status !== global.Office.AsyncResultStatus.Succeeded || !result.value) {
            cancel(origin, transactionId, claimCapability);
            reject(new Error("excel_dialog_unavailable"));
            return;
          }
          dialog = result.value;
          if (typeof dialog.messageChild !== "function") {
            cancel(origin, transactionId, claimCapability);
            reject(new Error("excel_dialog_unavailable"));
            return;
          }
          diagnostic("dialog_open_succeeded");
          dialog.addEventHandler(global.Office.EventType.DialogMessageReceived, onMessage);
          dialog.addEventHandler(global.Office.EventType.DialogEventReceived, function () {
            if (settled) return;
            diagnostic("dialog_closed", { result: "received" });
            // A completed backend handoff can still be claimed if the child
            // closes just as its Office message is delayed or lost.
            // Dialog close can race an in-flight /complete request. Poll the
            // one-time claim until it commits or the backend's transaction
            // expires; never fail early while the backend may still be rotating.
            claimWithRetries(8, 250);
          });
        });
      });
    }).catch(function () { throw new Error("excel_handoff_unavailable"); });
  }

  function completeDialog(accessToken, refreshToken, backendOrigin) {
    if (completionPromise) return completionPromise;
    if (!handoffContext || typeof accessToken !== "string" || accessToken.length < 20 ||
        typeof refreshToken !== "string" || refreshToken.length < 20) {
      return Promise.reject(new Error("excel_handoff_unavailable"));
    }
    var origin;
    try { origin = apiOrigin(backendOrigin); } catch (_) {
      return Promise.reject(new Error("excel_handoff_unavailable"));
    }
    completionPromise = post(origin, "/v1/excel-auth/handoff/complete", {
      transaction_id: handoffContext.transaction_id,
      completion_capability: handoffContext.completion_capability,
      access_token: accessToken,
      refresh_token: refreshToken
    }).then(function () {
      // Backend has rotated and stored a different refresh token. Flutter marks
      // its UI complete before explicitly notifying the parent dialog.
      global.__INSIGHTFLOW_EXCEL_AUTH_HANDOFF_COMPLETED__ = true;
      handoffReadyToNotify = true;
      diagnostic("handoff_complete", { result: "succeeded" });
      return true;
    }).catch(function () {
      completionPromise = null;
      diagnostic("handoff_complete", { result: "failed", error_code: "handoff_request_failed" });
      throw new Error("excel_handoff_unavailable");
    });
    return completionPromise;
  }

  function notifyDialogComplete() {
    if (!handoffReadyToNotify || !handoffContext) return false;
    try {
      var ui = global.Office && global.Office.context && global.Office.context.ui;
      if (!ui || typeof ui.messageParent !== "function") throw new Error("channel_unavailable");
      ui.messageParent(JSON.stringify({
        type: TYPE, version: VERSION, action: "completed",
        state: handoffContext.state,
        transaction_id: handoffContext.transaction_id
      }), { targetOrigin: global.location.origin });
      diagnostic("completion_notice_sent", { result: "sent" });
      handoffReadyToNotify = false;
      return true;
    } catch (_) {
      // Parent makes a final one-time claim attempt when the dialog closes.
      diagnostic("completion_notice_sent", { result: "failed", error_code: "office_message_failed" });
      return false;
    }
  }

  global.InsightFlowExcelAuth = {
    openSignInDialog: openSignInDialog,
    waitForHandoffContext: waitForHandoffContext,
    completeDialog: completeDialog,
    notifyDialogComplete: notifyDialogComplete,
    setDiagnosticsEnabled: setDiagnosticsEnabled,
    exportDiagnostics: exportDiagnostics,
    resetDiagnostics: resetDiagnostics,
    restoreDialogFlag: restoreDialogFlag
  };
  restoreDialogFlag();
})(window);
