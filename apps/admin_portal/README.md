# InsightFlow Admin Portal

Independent Cloudflare Pages frontend for administrator diagnostics. The intended Pages project is `insightflow-admin`, with this directory as its root, `npm run build` as its build command, `dist` as output, and `main` as the production branch. No production deployment is performed by this repository.

Set `INSIGHTFLOW_ADMIN_API` at build/runtime integration time to the existing FastAPI origin. Authentication must use the existing Supabase Auth project; the API remains the authorization boundary.
