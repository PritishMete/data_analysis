(function (global) {
  "use strict";

  var MESSAGE_TYPE = "insightflow.excel.auth";
  var MESSAGE_VERSION = 1;
  var DIALOG_FLAG = "excelAuthDialog";
  var DIALOG_SESSION_KEY = "insightflow.excel.auth.dialog";
  var DIALOG_STATE_PARAM = "excelAuthState";
  var DIALOG_STATE_SESSION_KEY = "insightflow.excel.auth.state";
  var DIAGNOSTIC_SESSION_KEY = "insightflow.excel.auth.diagnostics";
  var DIAGNOSTIC_EXPIRY_MS = 15 * 60 * 1000;
  var bridgeEvents = [];
  var bridgeCorrelation = null;

  function diagnostic(event, fields) {
    if (!global.__INSIGHTFLOW_EXCEL_AUTH_DIAGNOSTICS__) return;
    var payload = Object.assign({
      event: event,
      timestamp: new Date().toISOString(),
      correlation_id: bridgeCorrelation
    }, fields || {});
    bridgeEvents.push(payload);
    if (bridgeEvents.length > 100) bridgeEvents.shift();
    // Never include message bodies, tokens, state, nonce, cookies or URLs.
    if (global.console && typeof global.console.debug === "function") {
      global.console.debug("[excel-auth-bridge-diagnostic]", payload);
    }
  }

  function setDiagnosticsEnabled(enabled) {
    var active = false;
    try {
      var params = new URLSearchParams(global.location.search || "");
      bridgeCorrelation = params.get("excelAuthCorrelation") || bridgeCorrelation;
      if (enabled === true && params.get("excelAuthDiagnostics") === "1") {
        global.sessionStorage.setItem(DIAGNOSTIC_SESSION_KEY, String(Date.now() + DIAGNOSTIC_EXPIRY_MS));
      }
      var expiry = Number(global.sessionStorage.getItem(DIAGNOSTIC_SESSION_KEY) || 0);
      active = enabled === true && expiry > Date.now();
      if (!active && expiry) global.sessionStorage.removeItem(DIAGNOSTIC_SESSION_KEY);
    } catch (_) {}
    global.__INSIGHTFLOW_EXCEL_AUTH_DIAGNOSTICS__ = active;
    return active;
  }

  function exportDiagnostics() { return JSON.stringify(bridgeEvents); }
  function resetDiagnostics() {
    bridgeEvents = [];
    try { global.sessionStorage.removeItem(DIAGNOSTIC_SESSION_KEY); } catch (_) {}
    global.__INSIGHTFLOW_EXCEL_AUTH_DIAGNOSTICS__ = false;
  }

  function createState() {
    if (!global.crypto || typeof global.crypto.getRandomValues !== "function") {
      throw new Error("Secure sign-in state generation is unavailable.");
    }
    var bytes = new Uint8Array(24);
    global.crypto.getRandomValues(bytes);
    return Array.prototype.map.call(bytes, function (value) {
      return value.toString(16).padStart(2, "0");
    }).join("");
  }

  function restoreDialogFlag() {
    try {
      var params = new URLSearchParams(global.location.search || "");
      if (params.has("code") || params.has("error")) {
        diagnostic("oauth_callback_detected");
      }
      if (params.get(DIALOG_FLAG) === "1") {
        global.__isInsightFlowExcelAuthDialog = true;
        global.sessionStorage.setItem(DIALOG_SESSION_KEY, "1");
        var incomingState = params.get(DIALOG_STATE_PARAM);
        var incomingCorrelation = params.get("excelAuthCorrelation");
        if (incomingCorrelation) {
          bridgeCorrelation = incomingCorrelation;
          global.__insightFlowExcelAuthCorrelation = incomingCorrelation;
        }
        if (incomingState) {
          global.sessionStorage.setItem(DIALOG_STATE_SESSION_KEY, incomingState);
        }
        return;
      }
      if (global.sessionStorage.getItem(DIALOG_SESSION_KEY) === "1") {
        global.__isInsightFlowExcelAuthDialog = true;
        params.set(DIALOG_FLAG, "1");
        var savedState = global.sessionStorage.getItem(DIALOG_STATE_SESSION_KEY);
        if (savedState) params.set(DIALOG_STATE_PARAM, savedState);
        if (global.__insightFlowExcelAuthCorrelation) {
          params.set("excelAuthCorrelation", global.__insightFlowExcelAuthCorrelation);
        }
        var query = params.toString();
        var nextUrl = global.location.pathname +
          (query ? "?" + query : "") + (global.location.hash || "");
        global.history.replaceState(global.history.state, "", nextUrl);
      }
    } catch (_) {
      // Storage can be unavailable in locked-down Office webviews. The initial
      // dialog URL still carries the flag for password-based authentication.
    }
  }

  function openSignInDialog(correlationId) {
    diagnostic("dialog_open_started");
    return new Promise(function (resolve, reject) {
      if (!global.Office ||
          !global.Office.context ||
          !global.Office.context.ui ||
          typeof global.Office.context.ui.displayDialogAsync !== "function") {
        reject(new Error("Excel sign-in dialog is unavailable in this Office host."));
        return;
      }

      var url = new URL(global.location.href);
      var expectedState;
      try {
        expectedState = createState();
      } catch (error) {
        reject(error);
        return;
      }
      url.searchParams.set(DIALOG_FLAG, "1");
      url.searchParams.set(DIALOG_STATE_PARAM, expectedState);
      if (typeof correlationId === "string" && correlationId.length <= 80) {
        url.searchParams.set("excelAuthCorrelation", correlationId);
      }
      if (global.__INSIGHTFLOW_EXCEL_AUTH_DIAGNOSTICS__) {
        url.searchParams.set("excelAuthDiagnostics", "1");
      }
      url.hash = "";

      var dialog = null;
      var settled = false;
      function finish(error, refreshToken) {
        if (settled) return;
        settled = true;
        if (error) {
          reject(error);
        } else {
          resolve(refreshToken);
        }
      }

      global.Office.context.ui.displayDialogAsync(
        url.toString(),
        { height: 80, width: 60, displayInIframe: false },
        function (result) {
          if (!result ||
              result.status !== global.Office.AsyncResultStatus.Succeeded ||
              !result.value) {
            var message = result && result.error && result.error.message
              ? result.error.message
              : "Excel could not open the InsightFlow sign-in window.";
            finish(new Error(message));
            return;
          }

          dialog = result.value;
          diagnostic("dialog_open_succeeded");
          dialog.addEventHandler(
            global.Office.EventType.DialogMessageReceived,
            function (eventArgs) {
              diagnostic("dialog_message_received", { origin: eventArgs && eventArgs.origin === global.location.origin ? "same_origin" : "other_origin" });
              try {
                if (eventArgs.origin !== global.location.origin) {
                  throw new Error("The sign-in response came from an untrusted origin.");
                }
                if (typeof eventArgs.message !== "string" ||
                    eventArgs.message.length > 8192) {
                  throw new Error("The sign-in response was invalid.");
                }
                var message = JSON.parse(eventArgs.message);
                if (message.type !== MESSAGE_TYPE ||
                    message.version !== MESSAGE_VERSION ||
                    message.state !== expectedState ||
                    typeof message.refreshToken !== "string" ||
                    message.refreshToken.length < 20 ||
                    message.refreshToken.length > 4096) {
                  throw new Error("The sign-in response was invalid.");
                }
                finish(null, message.refreshToken);
                diagnostic("message_validated", { result: "succeeded" });
                if (dialog) dialog.close();
              } catch (error) {
                diagnostic("message_validation", { result: "failed", error_code: "invalid_message" });
                finish(error instanceof Error ? error : new Error("Invalid sign-in response."));
                if (dialog) dialog.close();
              }
            }
          );

          dialog.addEventHandler(
            global.Office.EventType.DialogEventReceived,
            function (eventArgs) {
              diagnostic("dialog_event_received", { event_code: eventArgs && eventArgs.error === 12006 ? "user_closed" : "dialog_error" });
              if (!settled) {
                finish(new Error(
                  eventArgs && eventArgs.error === 12006
                    ? "The sign-in window was closed before authentication finished."
                    : "The InsightFlow sign-in window was closed."
                ));
              }
            }
          );
        }
      );
    });
  }

  function completeDialog(refreshToken) {
    diagnostic("message_parent_started");
    if (typeof refreshToken !== "string" ||
        refreshToken.length < 20 ||
        refreshToken.length > 4096) {
      throw new Error("A valid InsightFlow session is required.");
    }
    if (!global.Office ||
        !global.Office.context ||
        !global.Office.context.ui ||
        typeof global.Office.context.ui.messageParent !== "function") {
      throw new Error("This page is not running inside an Excel sign-in dialog.");
    }

    var params = new URLSearchParams(global.location.search || "");
    var state = params.get(DIALOG_STATE_PARAM);
    if (!state) {
      try {
        state = global.sessionStorage.getItem(DIALOG_STATE_SESSION_KEY);
      } catch (_) {}
    }
    if (!state || state.length > 128) {
      throw new Error("The Excel sign-in request could not be verified.");
    }

    try {
      global.Office.context.ui.messageParent(JSON.stringify({
        type: MESSAGE_TYPE,
        version: MESSAGE_VERSION,
        state: state,
        refreshToken: refreshToken
      }));
      diagnostic("message_parent_returned", { result: "synchronous_return" });
    } catch (error) {
      diagnostic("message_parent_exception", { result: "threw", error_code: "message_parent_error" });
      throw error;
    }

    try {
      global.sessionStorage.removeItem(DIALOG_SESSION_KEY);
      global.sessionStorage.removeItem(DIALOG_STATE_SESSION_KEY);
    } catch (_) {}
  }

  global.InsightFlowExcelAuth = {
    openSignInDialog: openSignInDialog,
    completeDialog: completeDialog,
    setDiagnosticsEnabled: setDiagnosticsEnabled,
    exportDiagnostics: exportDiagnostics,
    resetDiagnostics: resetDiagnostics,
    restoreDialogFlag: restoreDialogFlag
  };

  restoreDialogFlag();
})(window);
