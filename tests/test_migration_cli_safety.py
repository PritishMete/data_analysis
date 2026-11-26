import os
import subprocess
import sys
from pathlib import Path

from tools import run_authz_migrations as runner

ROOT = Path(__file__).resolve().parents[1]


def test_migration_discovery_is_explicit_and_ordered():
    versions = [path.stem for path in runner.migration_files()]
    assert versions == sorted(versions)
    assert "0042_diagnostic_admin" in versions


def test_production_apply_requires_explicit_confirmation_without_connecting():
    environment = os.environ.copy()
    environment["INSIGHTFLOW_ENV"] = "production"
    environment.pop("DATABASE_URL", None)
    result = subprocess.run(
        [sys.executable, "tools/run_authz_migrations.py"],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 2
    assert "--confirm-production" in result.stderr
    assert "postgresql://" not in result.stdout + result.stderr


def test_inspect_mode_does_not_require_production_confirmation():
    environment = os.environ.copy()
    environment["INSIGHTFLOW_ENV"] = "production"
    environment.pop("DATABASE_URL", None)
    result = subprocess.run(
        [sys.executable, "tools/run_authz_migrations.py", "--inspect"],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "--confirm-production" not in result.stderr
    assert "postgresql://" not in result.stdout + result.stderr
