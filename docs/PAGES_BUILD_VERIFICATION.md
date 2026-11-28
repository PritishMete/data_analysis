# Cloudflare Pages build verification

The production Flutter Pages workflow is `.github/workflows/flutter-web-pages.yml`.
Cloudflare Pages serves the application at the project root, so production builds
must use `<base href="/">`; `/data_analysis/` is not a production Pages base path.

The production backend define is pinned to the Oracle-backed Worker gateway:
`https://insightflow-api.jaiphotoshoot.workers.dev`. The workflow fails before
building if that value changes, requires the Worker origin in the generated
bundle, and scans all generated `build/web` files for Render hostnames.

Verification commands:

```powershell
pytest -q tests/test_pages_build_configuration.py
git diff --check
```

The release build requires the production Flutter and Pages environment values.
Run the workflow's build with those values supplied, then verify that
`build/web/index.html` contains `<base href="/">`, `build/web/main.dart.js`
contains the Worker origin, and no file under `build/web` contains an
`onrender.com` hostname.

This change performs no Pages deployment, `gh-pages` update, Worker deployment,
or production configuration change.
