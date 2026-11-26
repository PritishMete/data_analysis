// Oracle origin is served through the VM's temporary Cloudflare Quick Tunnel.
const ORIGIN = "https://rebel-distance-pursuant-valium.trycloudflare.com";
const FRONTEND_ORIGIN = "https://insightflow-3e8.pages.dev";

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": FRONTEND_ORIGIN,
    "Access-Control-Allow-Methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
    "Access-Control-Allow-Headers": "Authorization,Content-Type,X-Requested-With",
    "Access-Control-Allow-Credentials": "true",
    Vary: "Origin",
  };
}

export default {
  async fetch(request) {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }
    const incoming = new URL(request.url);
    const target = new URL(incoming.pathname + incoming.search, ORIGIN);
    const headers = new Headers(request.headers);
    headers.set("X-Forwarded-Host", incoming.host);
    headers.set("X-Forwarded-Proto", "https");
    const init = { method: request.method, headers, redirect: "manual" };
    if (request.method !== "GET" && request.method !== "HEAD") init.body = request.body;
    const upstream = await fetch(new Request(target, init));
    const response = new Response(upstream.body, upstream);
    for (const [key, value] of Object.entries(corsHeaders())) response.headers.set(key, value);
    return response;
  },
};
