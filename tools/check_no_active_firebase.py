"""Fail CI if active application code/config reintroduces Firebase auth or RTDB.

Historical SQL migrations and isolated test fixtures are intentionally excluded:
they document or exercise the retired system, not runtime persistence.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCAN_ROOTS = (
    ROOT / "firebase_authz",
    ROOT / "dataset_storage",
    ROOT / "flutter_detail_source" / "lib",
    ROOT / ".github" / "workflows",
)
SCAN_FILES = (
    ROOT / "main.py",
    ROOT / "requirements.txt",
    ROOT / "flutter_detail_source" / "pubspec.yaml",
)
FORBIDDEN = (
    re.compile(r"\bimport\s+firebase" + r"_admin\b"),
    re.compile(r"\bfrom\s+firebase" + r"_admin\b"),
    re.compile(r"\binitialize_firebase\s*\("),
    re.compile(r"\bdb\.reference\s*\("),
    re.compile(r"\bFirebaseAuth\b"),
    re.compile(r"\bFirebaseDatabase\b"),
    re.compile(r"Firebase\.initializeApp"),
    re.compile(r"firebase" + r"-admin"),
    re.compile(r"AUTHZ_PERSISTENCE_PROVIDER\s*[,=]\s*[\"']firebase[\"']"),
)

def main() -> int:
    paths = list(SCAN_FILES)
    for root in SCAN_ROOTS:
        if root.is_dir():
            paths.extend(p for p in root.rglob("*") if p.is_file() and p.suffix in {".py", ".dart", ".yaml", ".yml", ".toml"})
    violations = []
    for path in sorted(set(paths)):
        if not path.is_file():
            continue
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError):
            continue
        for number, line in enumerate(lines, 1):
            for pattern in FORBIDDEN:
                if pattern.search(line):
                    violations.append(f"{path.relative_to(ROOT)}:{number}: forbidden active Firebase auth/RTDB reference")
                    break
    if violations:
        print("\n".join(violations), file=sys.stderr)
        return 1
    print("No active Firebase Auth or RTDB persistence references found in application code/configuration.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
