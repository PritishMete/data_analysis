# Cloudflare HTTPS API proxy

`insightflow-api.js` is a fixed-origin Cloudflare Worker proxy for the Oracle
VM backend. It exposes HTTPS to the Flutter site while keeping the Oracle VM
application process local and restricting browser CORS to the published
frontend origin.

The Worker origin is intentionally constant; it does not accept a
user-controlled upstream URL and therefore is not an open proxy.

The configured production Worker name is `insightflow-api`.
