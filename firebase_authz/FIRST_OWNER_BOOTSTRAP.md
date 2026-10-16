# First-Owner Bootstrap: Secure Setup

This procedure initializes one workspace Owner. It does not automatically make every Firebase signup an Owner.

## Preconditions

Configure the trusted Python backend with:

    FIREBASE_PROJECT_ID=insightflow-5a23d
    FIREBASE_DATABASE_URL=https://insightflow-5a23d-default-rtdb.asia-southeast1.firebasedatabase.app/
    GOOGLE_APPLICATION_CREDENTIALS=<trusted backend credential path>
    INSIGHTFLOW_BOOTSTRAP_SECRET=<random high-entropy secret>

Do not commit the service-account JSON or bootstrap secret. Do not paste either secret into ChatGPT, GitHub issues, pull requests, source files, or browser JavaScript.

## Bootstrap identity

The person who becomes Owner must first authenticate with Firebase Email/Password and obtain a normal Firebase ID token.

The bootstrap request requires the authenticated user's Firebase ID token, workspace ID, that same user's Firebase UID as expected_uid, and the backend-only bootstrap secret.

The backend independently verifies the ID token and requires:
1. token is valid and not revoked;
2. token UID equals expected_uid;
3. bootstrap secret matches the backend secret;
4. workspace ID passes strict validation.

Authentication alone never grants Owner.

## First initialization

Call the trusted backend's POST /v1/authz/bootstrap-owner.

The backend uses an RTDB transaction on workspaces/{workspace_id}. The first successful transaction creates the bootstrap marker, built-in Owner/Analyst/Viewer roles, Owner workspace membership, and an empty resource-grant collection.

Concurrent bootstrap requests cannot both initialize the same workspace as different owners.

## Partial recovery

If initialization writes the bootstrap marker but membership is incomplete, retrying with the same authenticated UID and same bootstrap credential can repair the missing Owner membership.

A different Firebase user cannot take over an initialized workspace.

## Last-Owner protection

Owner removal/demotion is checked against the active workspace Owner set. If the target is the last active Owner, the backend rejects the change.

The same guard is used before an Owner role is disabled. Any future suspension endpoint must call the same guard before suspending an Owner.

## After bootstrap

Use backend role-management APIs to create/update workspace roles, assign workspace-scoped roles, and grant resource-specific permissions.

Do not write these records directly from the browser.

## Production safety

This repository change does not initialize a production Owner and does not deploy RTDB rules.

Before production bootstrap:
1. verify the production FIREBASE_DATABASE_URL exactly matches the regional database above;
2. verify the service credential belongs to the intended Firebase project;
3. set a unique bootstrap secret in the backend secret store;
4. authenticate the intended first Owner;
5. perform the bootstrap once;
6. remove or rotate the bootstrap secret after initialization according to your operational policy.

No workbook contents are part of the bootstrap request or Firebase authorization records.