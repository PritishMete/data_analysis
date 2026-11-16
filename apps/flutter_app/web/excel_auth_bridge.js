(function (global) {
  "use strict";

  var MESSAGE_TYPE = "insightflow.excel.auth";
  var MESSAGE_VERSION = 1;
  var DIALOG_FLAG = "excelAuthDialog";
  var DIALOG_SESSION_KEY = "insightflow.excel.auth.dialog";

  function restoreDialogFlag() {
    try {
      var params = new URLSearchParams(global.location.search || "");
      if (params.get(DIALOG_FLAG) === "1") {
        global.sessionStorage.setItem(DIALOG_SESSION_KEY, "1");
        return;
      }
      if (global.sessionStorage.getItem(DIALOG_SESSION_KEY) === "1") {
        params.set(DIALOG_FLAG, "1");
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
      url.searchParams.set(DIALOG_FLAG, "1");
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
          dialog.addEventHandler(
            global.Office.EventType.DialogMessageReceived,
            function (eventArgs) {
              try {
                if (eventArgs.origin &&
                    eventArgs.origin !== global.location.origin) {
                  throw new Error("The sign-in response came from an untrusted origin.");
                }
                var message = JSON.parse(eventArgs.message || "{}");
                if (message.type !== MESSAGE_TYPE ||
                    message.version !== MESSAGE_VERSION ||
                    typeof message.refreshToken !== "string" ||
                    message.refreshToken.length < 20 ||
                    message.refreshToken.length > 4096) {
                  throw new Error("The sign-in response was invalid.");
                }
                finish(null, message.refreshToken);
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

    global.Office.context.ui.messageParent(JSON.stringify({
      type: MESSAGE_TYPE,
      version: MESSAGE_VERSION,
      refreshToken: refreshToken
    }));

    try {
      global.sessionStorage.removeItem(DIALOG_SESSION_KEY);
    } catch (_) {}
  }

  global.InsightFlowExcelAuth = {
    openSignInDialog: openSignInDialog,
    completeDialog: completeDialog,
    restoreDialogFlag: restoreDialogFlag
  };

  restoreDialogFlag();
})(window);
