# InsightFlow authentication and profile PII protection

## Authentication credentials

- Google OAuth is handled by Google and Supabase Auth. InsightFlow does not receive or store a Google account password.
- Email/password signup and sign-in are handled by Supabase Auth. Supabase stores password hashes using bcrypt with a randomly generated salt per password in its private Auth schema.
- InsightFlow application tables must never store passwords, password hashes, password salts, OAuth provider passwords, or client-submitted credential copies.
- The Flutter client sends the password only to Supabase Auth through the Supabase SDK. It must not place passwords in user metadata, application logs, analytics, or profile tables.

## Employee phone and government ID values

The organization_member_profiles table stores only:

- AES-256-GCM authenticated ciphertext for the phone number and ID proof number.
- A separate random 32-byte salt for the phone field and the ID proof field. Salts are generated again when a field is updated.
- A separate keyed HMAC-SHA-256 integrity digest for each encrypted field, using a key derived for that field and its own salt.
- An organization-scoped keyed HMAC fingerprint for ID-proof duplicate detection. This fingerprint is not used to decrypt the ID and does not replace the per-user ID salt or digest.

The encryption and integrity subkeys are derived with HKDF-SHA-256 using distinct purpose labels. AES-GCM uses a fresh 96-bit nonce for every encryption. Associated data binds ciphertext to the organization, principal, field name, and format version. Decryption verifies the HMAC and AES-GCM authentication before returning a value.

The ID fingerprint preserves the existing duplicate-proof check without storing or comparing plaintext ID numbers. Its key is derived with the organization, country, and proof type context, so the same identifier does not produce a cross-organization tracking token.

## Secret configuration

Set INSIGHTFLOW_PROFILE_PII_KEY only in the trusted backend secret store (Render environment variables). It must be a randomly generated 32-byte key encoded as base64url or 64 hexadecimal characters. Never commit it, expose it to Flutter, return it from an API, or print it in logs.

The backend fails closed if the key is missing or invalid when it needs to encrypt or decrypt profile PII. Do not deploy the profile migration until this secret has been configured for the backend.

## Legacy data migration

Migration 0039_encrypt_profile_pii adds ciphertext, salts, HMACs, and the duplicate-detection fingerprint. The migration runner then encrypts existing phone and ID values in a transaction, verifies that no plaintext values remain, and drops the legacy plaintext columns. The runner fails closed if legacy values exist and the key is missing.

The profile table remains protected by RLS and has no grants to PUBLIC, anon, or authenticated. Authorized management responses decrypt values only after the existing users.manage permission and organization/branch scope checks have passed.

## Password salt ownership

Password salts are generated and managed by Supabase Auth. InsightFlow must not create a second password salt or attempt to hash the password in Flutter or the FastAPI backend. Keeping password verification inside the authentication provider avoids a second password database and prevents accidental plaintext or hash duplication.