# InsightFlow repository structure

This repository uses two intentionally different permanent branches:

## `main`

The single source-of-truth branch. Open this branch in Android Studio or
VS Code. It contains the complete repository source, including:

```text
apps/flutter_app/
├── android/       # Android Studio project
├── ios/           # iOS host project
├── macos/         # macOS host project, when supported
├── windows/       # Windows host project, when supported
├── web/            # Flutter Web bootstrap and host assets
├── lib/            # InsightFlow application code
├── test/           # Flutter tests
└── pubspec.yaml   # Flutter dependencies and scripts

backend source     # FastAPI/Python services at repository root (kept here
                   # temporarily because Render and Python imports use root paths)
docs/              # Developer and architecture documentation
.github/           # CI and GitHub Pages workflows
```

Do not edit generated files on `gh-pages`. Make source changes on `main` (or a
short-lived feature branch from `main`) and let the
workflow publish the web build.

## `gh-pages`

Generated Flutter Web deployment output only. It is maintained by
`.github/workflows/flutter-web-pages.yml` and is not an Android Studio source
branch.

## Development rules

1. Create short-lived feature branches from `main` for application changes.
2. Merge verified changes into `main` before publishing.
3. Never commit secrets, local environment files, or generated build output to
   `main`.
