#!/usr/bin/env bash
set -euo pipefail

# Scan runtime application and configuration only. Historical SQL migrations,
# docs, and test fixtures are intentionally excluded.
roots=(firebase_authz dataset_storage flutter_detail_source/lib .github/workflows)
files=(main.py requirements.txt flutter_detail_source/pubspec.yaml)
violations=0

patterns=(
  'import[[:space:]]+firebase_admin'
  'from[[:space:]]+firebase_admin'
  'initialize_firebase[[:space:]]*\('
  'db\.reference[[:space:]]*\('
  'FirebaseAuth\.instance'
  'FirebaseDatabase\.instance'
  'Firebase\.initializeApp'
  'firebase-admin'
  'AUTHZ_PERSISTENCE_PROVIDER[[:space:]]*[,=][[:space:]]*["'"'"']firebase["'"'"']'
)

for file in "${files[@]}"; do
  [[ -f "$file" ]] || continue
  for pattern in "${patterns[@]}"; do
    if grep -nE "$pattern" "$file"; then
      echo "Forbidden active Firebase Auth/RTDB reference in $file" >&2
      violations=1
    fi
  done
done

while IFS= read -r -d '' file; do
  for pattern in "${patterns[@]}"; do
    if grep -nE "$pattern" "$file"; then
      echo "Forbidden active Firebase Auth/RTDB reference in $file" >&2
      violations=1
    fi
  done
done < <(find "${roots[@]}" -type f \( -name '*.py' -o -name '*.dart' -o -name '*.yaml' -o -name '*.yml' -o -name '*.toml' \) -print0 2>/dev/null)

if [[ "$violations" -ne 0 ]]; then
  exit 1
fi
echo "No active Firebase Auth or RTDB persistence references found in application code/configuration."
