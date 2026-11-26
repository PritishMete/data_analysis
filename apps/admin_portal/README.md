# InsightFlow Admin Portal

Independent Cloudflare Pages frontend for administrator diagnostics. The intended Pages project is `insightflow-admin`, with this directory as its root, `npm run build` as its build command, `dist` as output, and `main` as the production branch. No production deployment is performed by this repository.

The build writes a non-secret `dist/config.js` bootstrap file from environment variables; it never embeds a service-role key or database credential. Production builds must set:

```text
ADMIN_PORTAL_ENV=production
INSIGHTFLOW_ADMIN_API=https://<existing-fastapi-origin>
INSIGHTFLOW_SUPABASE_URL=https://<project>.supabase.co
INSIGHTFLOW_SUPABASE_ANON_KEY=<public-anon-key>
```

Missing production values fail the build. For local development, omit `ADMIN_PORTAL_ENV` and optionally set the same variables; otherwise the API defaults to `http://localhost:8000` and Supabase login remains unavailable until configured. Run `npm run build` then `npm run dev`.

Authentication uses the existing Supabase Auth project; the API remains the authorization boundary. `dist/config.js` is deployment configuration, not a secret store.
