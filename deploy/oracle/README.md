# Oracle VM deployment

These files are deployment templates, not a substitute for a verified production rollout.

## Before deployment

1. Use Ubuntu 22.04/24.04 with a supported Python version.
2. Create a dedicated `insightflow` service account and `/opt/data_analysis` deployment directory.
3. Clone the private repository using the read-only GitHub deploy key.
4. Create `/etc/insightflow/insightflow.env` with production values. Do not commit this file.
5. Create the virtual environment and install `requirements.txt`.
6. Copy `insightflow.service.example` to `/etc/systemd/system/insightflow.service`, then enable it.
7. Place Nginx or Caddy in front of Uvicorn and issue an HTTPS certificate for the API hostname.
8. Permit only SSH from a trusted source and HTTPS from the Internet. Do not expose port 8000.

## Required environment values

Use the repository's `.env.example` as the variable inventory. At minimum, configure the Supabase/database values, production environment mode, and `INSIGHTFLOW_CORS_ORIGINS` with the exact GitHub Pages origin. Keep secrets server-side.

## Verification gate

Before changing the GitHub Pages repository variable, verify:

```bash
curl --fail --silent --show-error https://api.example.com/health
```

Then test authenticated organization membership, tenant authorization, dataset upload limits, and an ordinary analysis request over HTTPS. Set `INSIGHTFLOW_BACKEND_URL` to the verified HTTPS origin only after those checks pass.

The Oracle VM is not marked Always Free in the current account view; confirm billing before leaving it running.
