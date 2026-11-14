# InsightFlow repository structure

This repository uses three intentionally different branches:

## `main`

The Python/FastAPI backend source and its backend tests. This is the backend
development branch used by Render.

## `insightflow`

The canonical application source branch. Open this branch in Android Studio or
VS Code. It contains the complete repository source, including:

```text
flutter_detail_source/
├── android/       # Android Studio project
├── ios/           # iOS host project
├── macos/         # macOS host project, when supported
├── windows/       # Windows host project, when supported
├── web/            # Flutter Web bootstrap and host assets
├── lib/            # InsightFlow application code
├── test/           # Flutter tests
└── pubspec.yaml   # Flutter dependencies and scripts

backend source     # FastAPI/Python services at repository root
docs/              # Developer and architecture documentation
.github/           # CI and GitHub Pages workflows
```

Do not edit generated files on `gh-pages`. Make source changes here and let the
workflow publish the web build.

## `gh-pages`

Generated Flutter Web deployment output only. It is maintained by
`.github/workflows/flutter-web-pages.yml` and is not an Android Studio source
branch.

## Development rules

1. Create feature branches from `insightflow` for application changes.
2. Keep backend-only changes targeted to `main` or an approved backend branch.
3. Merge verified application changes into `insightflow` before publishing.
4. Never commit secrets, local environment files, or generated build output to
   `insightflow`.
