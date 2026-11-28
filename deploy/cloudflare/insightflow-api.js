const FRONTEND_ORIGIN = "https://insightflow-3e8.pages.dev";
const UPSTREAM_ORIGIN = "http://127.0.0.1:8000";

const ALLOWED_METHODS = "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS";
const ALLOWED_HEADERS = [
  "Authorization",
  "Content-Type",
  "X-InsightFlow-Workspace-ID",
  "X-InsightFlow-Resource-ID",
  "X-InsightFlow-Location-ID",
  "X-InsightFlow-Dataset-ID",
  "X-InsightFlow-Version",
  "X-InsightFlow-Branch-ID",
  "X-Requested-With",
].join(", ");

function corsHeaders(origin) {
  const headers = new Headers({
    "Access-Control-Allow-Methods": ALLOWED_METHODS,
    "Access-Control-Allow-Headers": ALLOWED_HEADERS,
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  });

  if (origin === FRONTEND_ORIGIN) {
    headers.set("Access-Control-Allow-Origin", FRONTEND_ORIGIN);
  }

  return headers;
}

function mergeVary(headers, value) {
  const existing = headers.get("Vary");
  const values = new Set((existing || "").split(",").map((part) => part.trim()).filter(Boolean));
  values.add(value);
  headers.set("Vary", [...values].join(", "));
}

export default {
  async fetch(request, env) {
    const incoming = new URL(request.url);
    const origin = request.headers.get("Origin");

    // Browser origins are restricted to the existing production Pages site.
    // Non-browser clients without an Origin header remain supported.
    if (origin && origin !== FRONTEND_ORIGIN) {
      return new Response("Origin not allowed", { status: 403 });
    }

    if (request.method === "OPTIONS") {
      const headers = corsHeaders(origin);
      if (origin !== FRONTEND_ORIGIN) {
        return new Response(null, { status: 403, headers });
      }
      return new Response(null, { status: 204, headers });
    }

    const target = new URL(incoming.pathname + incoming.search, UPSTREAM_ORIGIN);
    const requestHeaders = new Headers(request.headers);
    requestHeaders.delete("host");
    requestHeaders.set("X-Forwarded-Host", incoming.host);
    requestHeaders.set("X-Forwarded-Proto", "https");

    const init = {
      method: request.method,
      headers: requestHeaders,
      redirect: "manual",
    };

    if (request.method !== "GET" && request.method !== "HEAD") {
      init.body = request.body;
    }

    try {
      const upstreamRequest = new Request(target, init);
      const upstreamResponse = await env.ORACLE_VPC.fetch(upstreamRequest);
      const responseHeaders = new Headers(upstreamResponse.headers);

      if (origin === FRONTEND_ORIGIN) {
        for (const [name, value] of corsHeaders(origin)) {
          if (name.toLowerCase() !== "vary") responseHeaders.set(name, value);
        }
        mergeVary(responseHeaders, "Origin");
      }

      return new Response(upstreamResponse.body, {
        status: upstreamResponse.status,
        statusText: upstreamResponse.statusText,
        headers: responseHeaders,
      });
    } catch {
      // Do not expose tunnel, network, or internal origin details to clients.
      return new Response("InsightFlow API gateway unavailable", {
        status: 502,
        headers: origin === FRONTEND_ORIGIN ? corsHeaders(origin) : undefined,
      });
    }
  },
};
