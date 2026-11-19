(function (global) {
  "use strict";

  var API_SUFFIX = "/v2/excel-auth/handoff";
  var EXCEL_KEY = "insightflow.excel.v2.transaction";
  var BROWSER_KEY = "insightflow.excel.v2.browser";
  var VERIFIER_KEY = "insightflow.excel.v2.pkce.verifier";
  var initialParams = new URLSearchParams(global.location.search || "");
  var pendingOAuthCode = initialParams.get("code");
  var callbackError = initialParams.get("error_description") || initialParams.get("error") || "";
  global.__isInsightFlowExcelAuthDialog = initialParams.get("excelAuthDialog") === "1";

  if (pendingOAuthCode || callbackError) {
    // The authorization code is removed before Flutter/Supabase bootstrap.
    var clean = new URLSearchParams();
    if (initialParams.get("excelHandoff")) clean.set("excelHandoff", initialParams.get("excelHandoff"));
    if (initialParams.get("excelAuthDialog") === "1") clean.set("excelAuthDialog", "1");
    global.history.replaceState(global.history.state, "", global.location.pathname +
      (clean.toString() ? "?" + clean.toString() : "") + (global.location.hash || ""));
  }

  function randomToken(bytes) {
    if (!global.crypto || !global.crypto.getRandomValues) throw new Error("Secure browser authentication is unavailable.");
    var data = new Uint8Array(bytes);
    global.crypto.getRandomValues(data);
    var binary = "";
    for (var i = 0; i < data.length; i++) binary += String.fromCharCode(data[i]);
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
  }

  function uuid() {
    if (global.crypto && global.crypto.randomUUID) return global.crypto.randomUUID();
    var bytes = new Uint8Array(16);
    global.crypto.getRandomValues(bytes);
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    var hex = Array.prototype.map.call(bytes, function (b) { return b.toString(16).padStart(2, "0"); }).join("");
    return hex.slice(0,8)+"-"+hex.slice(8,12)+"-"+hex.slice(12,16)+"-"+hex.slice(16,20)+"-"+hex.slice(20);
  }

  function apiUrl(config, path) { return config.apiBase.replace(/\/$/, "") + API_SUFFIX + path; }

  async function post(config, path, body) {
    var response = await fetch(apiUrl(config, path), {
      method: "POST", credentials: "omit", cache: "no-store",
      headers: { "Content-Type": "application/json" }, body: JSON.stringify(body)
    });
    var payload = {};
    try { payload = await response.json(); } catch (_) {}
    if (!response.ok) throw new Error(payload.detail || "Excel sign-in request failed.");
    return payload;
  }

  function loadBrowser() {
    try { return JSON.parse(global.sessionStorage.getItem(BROWSER_KEY) || "null"); }
    catch (_) { return null; }
  }

  function getTransactionId() {
    return new URLSearchParams(global.location.search || "").get("excelHandoff") || "";
  }

  function isDialog() { return global.__isInsightFlowExcelAuthDialog === true; }

  function browserFromConfig(raw) {
    var config = typeof raw === "string" ? JSON.parse(raw) : raw;
    if (!config || !config.transactionId || !config.pairingCode ||
        !config.supabaseUrl || !config.publishableKey || !config.apiBase ||
        config.transactionId !== getTransactionId()) {
      throw new Error("The Excel sign-in request is incomplete or does not match this browser tab.");
    }
    var value = {
      transactionId: config.transactionId,
      pairingCode: config.pairingCode.toUpperCase(),
      generation: Number(config.generation || 1),
      supabaseUrl: config.supabaseUrl.replace(/\/$/, ""),
      publishableKey: config.publishableKey,
      apiBase: config.apiBase.replace(/\/$/, ""),
      browserCapability: randomToken(32)
    };
    global.sessionStorage.setItem(BROWSER_KEY, JSON.stringify(value));
    return value;
  }

  async function copyText(value) {
    if (global.navigator.clipboard && global.navigator.clipboard.writeText) {
      await global.navigator.clipboard.writeText(value);
      return true;
    }
    var field = document.createElement("textarea");
    field.value = value;
    field.style.position = "fixed";
    field.style.opacity = "0";
    document.body.appendChild(field);
    field.select();
    var copied = document.execCommand("copy");
    field.remove();
    if (!copied) throw new Error("Copy is unavailable in this browser.");
    return true;
  }

  async function sha256Base64Url(value) {
    var hash = await global.crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
    var data = new Uint8Array(hash);
    var binary = "";
    data.forEach(function (b) { binary += String.fromCharCode(b); });
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
  }

  async function startGoogle() {
    var browser = loadBrowser();
    if (!browser) throw new Error("Enter the Excel pairing code first.");
    var verifier = randomToken(32);
    global.sessionStorage.setItem(VERIFIER_KEY, verifier);
    var challenge = await sha256Base64Url(verifier);
    var redirect = global.location.origin + global.location.pathname +
      "?excelHandoff=" + encodeURIComponent(browser.transactionId) +
      (isDialog() ? "&excelAuthDialog=1" : "");
    var authorize = new URL(browser.supabaseUrl + "/auth/v1/authorize");
    authorize.searchParams.set("provider", "google");
    authorize.searchParams.set("redirect_to", redirect);
    authorize.searchParams.set("code_challenge", challenge);
    authorize.searchParams.set("code_challenge_method", "s256");
    global.location.assign(authorize.toString());
  }

  async function exchangeOAuthCode() {
    var code = pendingOAuthCode;
    pendingOAuthCode = null;
    if (!code) {
      if (callbackError) throw new Error("Google sign-in was cancelled or could not be completed.");
      return false;
    }
    var browser = loadBrowser();
    var verifier = global.sessionStorage.getItem(VERIFIER_KEY);
    global.sessionStorage.removeItem(VERIFIER_KEY);
    if (!browser || !verifier || !getTransactionId() || getTransactionId() !== browser.transactionId) {
      throw new Error("The browser sign-in could not be matched to its Excel request. Start again.");
    }
    var response = await fetch(browser.supabaseUrl + "/auth/v1/token?grant_type=pkce", {
      method: "POST", credentials: "omit", cache: "no-store",
      headers: { "apikey": browser.publishableKey, "Content-Type": "application/json" },
      body: JSON.stringify({ auth_code: code, code_verifier: verifier })
    });
    var session = await response.json();
    if (!response.ok || !session.access_token || !session.refresh_token) {
      throw new Error("Google sign-in could not be exchanged. Start a new sign-in.");
    }
    await submitCandidate(browser, session);
    return true;
  }

  async function passwordSignIn(raw) {
    var input = typeof raw === "string" ? JSON.parse(raw) : raw;
    var browser = loadBrowser() || browserFromConfig(input);
    var response = await fetch(browser.supabaseUrl + "/auth/v1/token?grant_type=password", {
      method: "POST", credentials: "omit", cache: "no-store",
      headers: { "apikey": browser.publishableKey, "Content-Type": "application/json" },
      body: JSON.stringify({ email: input.email, password: input.password })
    });
    var session = await response.json();
    if (!response.ok || !session.access_token || !session.refresh_token) {
      throw new Error("Email or password could not be verified.");
    }
    await submitCandidate(browser, session);
    return "completed";
  }

  async function submitCandidate(browser, session) {
    var bound = await post(browser, "/browser/bind", {
      transaction_id: browser.transactionId,
      pairing_code: browser.pairingCode,
      browser_capability: browser.browserCapability,
      request_id: uuid()
    });
    browser.generation = bound.generation;
    browser.pairingCode = "";
    global.sessionStorage.setItem(BROWSER_KEY, JSON.stringify(browser));
    await post(browser, "/browser/candidate", {
      transaction_id: browser.transactionId,
      browser_capability: browser.browserCapability,
      generation: browser.generation,
      request_id: uuid(),
      access_token: session.access_token
    });
    // Access and refresh tokens live only in this async call's memory.
    await waitForExcelApproval(browser, session);
  }

  async function waitForExcelApproval(browser, session) {
    var deadline = Date.now() + 8 * 60 * 1000;
    while (Date.now() < deadline) {
      await new Promise(function (resolve) { setTimeout(resolve, 2000); });
      var state = await post(browser, "/browser/status", {
        transaction_id: browser.transactionId,
        browser_capability: browser.browserCapability
      });
      if (state.generation !== browser.generation) throw new Error("This browser sign-in attempt is stale.");
      if (["rejected", "cancelled", "expired", "failed"].indexOf(state.state) >= 0) {
        throw new Error("The Excel sign-in request was rejected or expired.");
      }
      if (state.state === "approved") {
        if (!state.approved_uid || state.approved_uid !== state.candidate_uid ||
            state.approved_generation !== browser.generation) {
          throw new Error("Excel approval does not match this signed-in account.");
        }
        await post(browser, "/browser/complete", {
          transaction_id: browser.transactionId,
          browser_capability: browser.browserCapability,
          generation: browser.generation,
          request_id: uuid(),
          access_token: session.access_token,
          refresh_token: session.refresh_token
        });
        global.sessionStorage.removeItem(BROWSER_KEY);
        global.sessionStorage.removeItem(VERIFIER_KEY);
        if (isDialog() && global.Office && global.Office.context &&
            global.Office.context.ui && typeof global.Office.context.ui.messageParent === "function") {
          global.Office.context.ui.messageParent(JSON.stringify({
            type: "insightflow.excel.auth.v2", version: 2,
            transactionId: browser.transactionId, state: "completed"
          }));
        }
        return "completed";
      }
    }
    throw new Error("Excel approval timed out. Start a new sign-in.");
  }

  function openOfficeDialog(url) {
    return new Promise(function (resolve, reject) {
      if (!global.Office || !global.Office.context || !global.Office.context.ui ||
          typeof global.Office.context.ui.displayDialogAsync !== "function") {
        reject(new Error("Office sign-in dialog is unavailable in this host."));
        return;
      }
      var dialog;
      var settled = false;
      function finish(error, value) {
        if (settled) return;
        settled = true;
        if (error) reject(error); else resolve(value);
      }
      global.Office.context.ui.displayDialogAsync(url, {
        height: 80, width: 60, displayInIframe: false
      }, function (result) {
        if (!result || result.status !== global.Office.AsyncResultStatus.Succeeded || !result.value) {
          finish(new Error("Excel could not open the sign-in dialog."));
          return;
        }
        dialog = result.value;
        dialog.addEventHandler(global.Office.EventType.DialogMessageReceived, function (event) {
          try {
            if (event.origin !== global.location.origin) throw new Error("Untrusted dialog origin.");
            var message = JSON.parse(event.message || "{}");
            if (message.type !== "insightflow.excel.auth.v2" ||
                message.version !== 2 || message.state !== "completed") {
              throw new Error("Invalid sign-in dialog response.");
            }
            finish(null, message.state);
            dialog.close();
          } catch (error) { finish(error); dialog.close(); }
        });
        dialog.addEventHandler(global.Office.EventType.DialogEventReceived, function () {
          finish(new Error("The sign-in dialog was closed."));
        });
      });
    });
  }

  global.InsightFlowExcelAuth = {
    getTransactionId: getTransactionId,
    isDialog: isDialog,
    saveExcelTransaction: function (value) { global.sessionStorage.setItem(EXCEL_KEY, value); },
    loadExcelTransaction: function () { return global.sessionStorage.getItem(EXCEL_KEY) || ""; },
    clearExcelTransaction: function () { global.sessionStorage.removeItem(EXCEL_KEY); },
    copyText: copyText,
    prepareBrowser: browserFromConfig,
    startGoogle: startGoogle,
    passwordSignIn: passwordSignIn,
    resumeOAuth: exchangeOAuthCode,
    openOfficeDialog: openOfficeDialog
  };
})(window);
