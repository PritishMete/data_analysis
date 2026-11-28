# InsightFlow Cloudflare API Gateway

The `insightflow-api` Worker forwards the existing FastAPI backend through the
Cloudflare Tunnel using the Workers VPC binding declared in `wrangler.toml`.

Cloudflare build settings copy both `insightflow-api.js` and `wrangler.toml`
into the build root before running Wrangler. Build watch paths are restricted
to `deploy/cloudflare/**`, so FastAPI-only changes do not trigger Worker
previews. Preview builds use `wrangler preview` with the explicit `previews`
configuration in `wrangler.toml`; this is separate from production deployment.
The preview build command must copy `wrangler.toml` before invoking Wrangler.

The production branch should be set to `main` only after this gateway source
is available on `main`. The existing production Worker, VPC binding, tunnel,
and public URL must remain unchanged until an independently approved Worker
deployment.
