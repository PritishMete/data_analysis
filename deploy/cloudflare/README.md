# InsightFlow Cloudflare API Gateway

The Worker exposes the existing FastAPI backend through the existing Cloudflare Tunnel using a Workers VPC Network binding.

- Public API: `https://insightflow-api.jaiphotoshoot.workers.dev`
- Frontend origin: `https://insightflow-3e.pages.dev`
- Private upstream: `http://127.0.0.1:8000`
- Tunnel: `data-analysis-oracle`
- Binding: `ORACLE_VPC`

## Security and compatibility

- The Worker only accepts browser requests from the production Pages origin.
- Requests without an Origin header remain available for native/mobile clients; FastAPI/Supabase remain responsible for authentication and authorization.
- The Worker forwards bearer tokens and InsightFlow workspace/resource/location/dataset/version/branch headers without storing credentials.
- OPTIONS requests are answered at the edge with the explicit Pages origin and the required headers.
- Methods, path, query string, request body stream, upstream status, response headers, and response body stream are preserved.
- The Worker never connects to the Oracle public IP.

## Deployment

Use the existing Cloudflare Worker `insightflow-api` and deploy this source with the VPC Network binding in `wrangler.toml`. The deploying Cloudflare identity must have Connectivity Directory Admin because the binding references a tunnel UUID directly.

Do not change the Flutter API URL or retire Render until the Oracle backend commit, database schema, health, build identity, authentication, authorization, CORS, upload, and streaming checks all pass.

## Rollback

Cloudflare Worker versions/deployments retain prior versions. If the new gateway fails, restore the previously active Worker version/deployment. Do not delete the tunnel or modify Oracle networking as part of Worker rollback.
