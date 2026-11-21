(function (global) {
  "use strict";

  var MESSAGE_TYPE = "insightflow.excel.auth";
  var MESSAGE_VERSION = 1;
  var DIALOG_FLAG = "excelAuthDialog";
  var DIALOG_SESSION_KEY = "insightflow.excel.auth.dialog";
  var DIALOG_STATE_PARAM = "excelAuthState";
  var DIALOG_STATE_SESSION_KEY = "insightflow.excel.auth.state";
  var CORRELATION_SESSION_KEY = "insightflow.excel.auth.correlation";
  var DIAGNOSTIC_EVENTS_KEY = "insightflow.excel.auth.events";
  var MAX_DIAGNOSTIC_EVENTS = 64;

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

  function createCorrelationId() {
    var bytes = new Uint8Array(16);
    global.crypto.getRandomValues(bytes);
    return "auth-" + Array.prototype.map.call(bytes, function (value) {
      return value.toString(16).padStart(2, "0");
    }).join("");
  }

  function diagnostic(operation, success, category) {
    var correlationId = "auth-unknown";
    try {
      correlationId = global.sessionStorage.getItem(CORRELATION_SESSION_KEY) || correlationId;
    } catch (_) {}
    var fields = {
      correlation_id: correlationId,
      operation: operation,
      timestamp: new Date().toISOString(),
      success: success
    };
    if (category) fields.category = category;
    try {
      var events = JSON.parse(global.sessionStorage.getItem(DIAGNOSTIC_EVENTS_KEY) || "[]");
      if (!Array.isArray(events)) events = [];
      events.push(fields);
      global.sessionStorage.setItem(
        DIAGNOSTIC_EVENTS_KEY,
        JSON.stringify(events.slice(-MAX_DIAGNOSTIC_EVENTS))
      );
    } catch (_) {}
    global.console.info("[auth-diagnostic]", JSON.stringify(fields));
  }

  function setCorrelationId(correlationId) {
    if (typeof correlationId !== "string" || !/^auth-[0-9a-f]{32}$/.test(correlationId)) {
      throw new Error("The authentication diagnostic ID is invalid.");
    }
    global.sessionStorage.setItem(CORRELATION_SESSION_KEY, correlationId);
  }

  function currentCorrelationId() {
    try {
      return global.sessionStorage.getItem(CORRELATION_SESSION_KEY);
    } catch (_) {
      return null;
    }
  }

  function restoreDialogFlag() {
    try {
      var params = new URLSearchParams(global.location.search || "");
      if (params.get(DIALOG_FLAG) === "1") {
        global.__isInsightFlowExcelAuthDialog = true;
        global.sessionStorage.setItem(DIALOG_SESSION_KEY, "1");
        var incomingState = params.get(DIALOG_STATE_PARAM);
        if (incomingState) {
          global.sessionStorage.setItem(DIALOG_STATE_SESSION_KEY, incomingState);
        }
        var incomingCorrelationId = params.get("excelAuthCorrelationId");
        if (incomingCorrelationId && /^auth-[0-9a-f]{32}$/.test(incomingCorrelationId)) {
          global.sessionStorage.setItem(CORRELATION_SESSION_KEY, incomingCorrelationId);
        }
        return;
      }
      if (global.sessionStorage.getItem(DIALOG_SESSION_KEY) === "1") {
        global.__isInsightFlowExcelAuthDialog = true;
        params.set(DIALOG_FLAG, "1");
        var savedState = global.sessionStorage.getItem(DIALOG_STATE_SESSION_KEY);
        if (savedState) params.set(DIALOG_STATE_PARAM, savedState);
        var savedCorrelationId = currentCorrelationId();
        if (savedCorrelationId) params.set("excelAuthCorrelationId", savedCorrelationId);
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

  function openSignInDialog() {
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
      try {
        if (!currentCorrelationId()) setCorrelationId(createCorrelationId());
      } catch (_) {}
      diagnostic("excel_dialog_open", true);
      url.searchParams.set(DIALOG_FLAG, "1");
      url.searchParams.set(DIALOG_STATE_PARAM, expectedState);
      url.searchParams.set("excelAuthCorrelationId", currentCorrelationId() || "");
      url.hash = "";

      var dialog = null;
      var settled = false;
      function finish(error, refreshToken, correlationId) {
        if (settled) return;
        settled = true;
        if (error) {
          reject(error);
        } else {
          resolve(JSON.stringify({
            refreshToken: refreshToken,
            correlationId: correlationId
          }));
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
          dialog.addEventHandler(
            global.Office.EventType.DialogMessageReceived,
            function (eventArgs) {
              try {
                if (eventArgs.origin !== global.location.origin) {
                  diagnostic("excel_dialog_message_validation", false, "origin_mismatch");
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
                    message.refreshToken.length > 4096 ||
                    typeof message.correlationId !== "string" ||
                    !/^auth-[0-9a-f]{32}$/.test(message.correlationId)) {
                  diagnostic("excel_dialog_message_validation", false, "state_or_shape_mismatch");
                  throw new Error("The sign-in response was invalid.");
                }
                diagnostic("excel_dialog_message_validation", true);
                finish(null, message.refreshToken, message.correlationId);
                if (dialog) dialog.close();
              } catch (error) {
                finish(error instanceof Error ? error : new Error("Invalid sign-in response."));
                if (dialog) dialog.close();
              }
            }
          );

          dialog.addEventHandler(
            global.Office.EventType.DialogEventReceived,
            function (eventArgs) {
              if (!settled) {
                diagnostic("excel_dialog_closed", false, "dialog_closed");
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
    var correlationId = params.get("excelAuthCorrelationId") || currentCorrelationId();
    if (!correlationId || !/^auth-[0-9a-f]{32}$/.test(correlationId)) {
      throw new Error("The Excel authentication diagnostic ID is invalid.");
    }
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
        refreshToken: refreshToken,
        correlationId: correlationId
      }));
      diagnostic("excel_dialog_message_parent", true);
    } catch (error) {
      diagnostic(
        "excel_dialog_message_parent",
        false,
        error && error.name ? error.name : "message_parent_failure"
      );
      throw error;
    }

    try {
      global.sessionStorage.removeItem(DIALOG_SESSION_KEY);
      global.sessionStorage.removeItem(DIALOG_STATE_SESSION_KEY);
      global.sessionStorage.removeItem(CORRELATION_SESSION_KEY);
      global.sessionStorage.removeItem(DIAGNOSTIC_EVENTS_KEY);
    } catch (_) {}
  }

  global.InsightFlowExcelAuth = {
    openSignInDialog: openSignInDialog,
    completeDialog: completeDialog,
    restoreDialogFlag: restoreDialogFlag,
    setCorrelationId: setCorrelationId,
    currentCorrelationId: currentCorrelationId
  };

  restoreDialogFlag();
})(window);
