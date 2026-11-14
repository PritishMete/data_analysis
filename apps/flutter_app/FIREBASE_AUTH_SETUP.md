# InsightFlow Firebase Web Authentication Setup

Firebase project: `insightflow-5a23d`

## 1. Register the existing Flutter Web app

In Firebase Console:

1. Open Project settings for `insightflow-5a23d`.
2. Under **Your apps**, register/select the existing **Web** app for InsightFlow.
3. Copy the Web SDK configuration values. These are public application identifiers; **do not provide or commit a service-account private key**.

Required values for the current build:
- `apiKey`
- `appId`
- `messagingSenderId`
- `projectId` — must be `insightflow-5a23d`
- `authDomain`

The Flutter build also needs the workspace context configured as a non-secret build define:

`INSIGHTFLOW_WORKSPACE_ID=<workspace-id>`

The backend verifies that this workspace belongs to the signed-in Firebase UID. Do not use a user-supplied UID as an identity claim.

The project already has Realtime Database at:
`https://insightflow-5a23d-default-rtdb.asia-southeast1.firebasedatabase.app/`

The Flutter client does not initialize or write to that database. Authorization metadata is read/written by the trusted Python backend.

## 2. Preferred FlutterFire CLI path

From `flutter_detail_source/`:

```bash
firebase login
dart pub global activate flutterfire_cli
flutterfire configure --project=insightflow-5a23d --platforms=web
```

This generates `lib/firebase_options.dart`. If you use the generated file, replace the repository's environment-driven configuration with the generated `DefaultFirebaseOptions` values, preserving the same `projectId`.

## 3. Current repository build-define path

The repository currently keeps the Web identifiers out of source control and reads them with `--dart-define`:

```bash
flutter build web --release \
  --dart-define=INSIGHTFLOW_FIREBASE_WEB_API_KEY="<API_KEY>" \
  --dart-define=INSIGHTFLOW_FIREBASE_WEB_APP_ID="<APP_ID>" \
  --dart-define=INSIGHTFLOW_FIREBASE_WEB_MESSAGING_SENDER_ID="<SENDER_ID>" \
  --dart-define=INSIGHTFLOW_FIREBASE_WEB_PROJECT_ID="insightflow-5a23d" \
  --dart-define=INSIGHTFLOW_FIREBASE_WEB_AUTH_DOMAIN="<AUTH_DOMAIN>" \\
  --dart-define=INSIGHTFLOW_WORKSPACE_ID="<WORKSPACE_ID>"
```

These values are not service-account credentials.

## 4. Enable Email/Password

Firebase Console → **Authentication → Sign-in method** → enable **Email/Password**.

Do not enable anonymous sign-in for InsightFlow authorization.

## 5. Authorized domains

Add the exact browser hostnames used by the add-in/web build under **Authentication → Settings → Authorized domains**.

Development:
- `localhost` (if the local browser taskpane is served from localhost)

Production:
- Add the actual hostname serving the deployed InsightFlow Web taskpane. The repository history indicates GitHub Pages/gh-pages has been used, but the current GitHub repository metadata does not expose the configured Pages hostname, so it must be confirmed from **Repository Settings → Pages** before adding it.

Do not add arbitrary domains or the backend API hostname as an Auth authorized domain unless that hostname actually serves the Firebase-authenticated web client.

## 6. Backend environment

Production/backend runtime must explicitly set:

```text
FIREBASE_PROJECT_ID=insightflow-5a23d
FIREBASE_DATABASE_URL=https://insightflow-5a23d-default-rtdb.asia-southeast1.firebasedatabase.app
GOOGLE_APPLICATION_CREDENTIALS=<path to trusted backend service-account JSON>
INSIGHTFLOW_BOOTSTRAP_SECRET=<separate bootstrap secret>
```

Never put the service-account JSON, private key, or bootstrap secret in Flutter source, Web config, Git, browser storage, or client requests.

## 7. Privacy boundary

Firebase Authentication stores identity/session information. Realtime Database stores authorization metadata only. Workbook rows, filenames, sheet names, column names, and analysis results must remain in the local Excel/Flutter execution path and must not be written to Firebase.
