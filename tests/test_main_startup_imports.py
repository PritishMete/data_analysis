"""Regression tests for fast API startup without eager Gemini/Google ADK imports."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


def test_main_import_does_not_eagerly_load_google_adk_stack():
    """The ASGI module must import promptly so Render can detect its port."""
    repository_root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="insightflow-startup-test-") as runtime_dir:
        env = os.environ.copy()
        env["DATA_ANALYSIS_RUNTIME_DIR"] = runtime_dir
        env["INSIGHTFLOW_PRIVACY_MODE"] = "local_only"
        script = """
import builtins
import traceback

_original_import = builtins.__import__
def _trace_google_ai_import(name, globals=None, locals=None, fromlist=(), level=0):
    if name == "google.adk" or name.startswith("google.adk.") or name == "google.cloud.aiplatform" or name.startswith("google.cloud.aiplatform."):
        print("\\n=== Google AI import triggered by: " + name + " ===", flush=True)
        traceback.print_stack(limit=24)
    return _original_import(name, globals, locals, fromlist, level)

builtins.__import__ = _trace_google_ai_import
import sys
import main
heavy_modules = sorted(
    name for name in sys.modules
    if name == "google.adk"
    or name.startswith("google.adk.")
    or name == "google.cloud.aiplatform"
    or name.startswith("google.cloud.aiplatform.")
)
if heavy_modules:
    raise AssertionError(
        "Importing main:app eagerly loaded optional Google AI modules: "
        + ", ".join(heavy_modules[:20])
    )
"""
        result = subprocess.run(
            [sys.executable, "-c", script],
            cwd=repository_root,
            env=env,
            capture_output=True,
            text=True,
            timeout=90,
            check=False,
        )
        assert result.returncode == 0, (
            "Importing main:app must complete without loading the optional "
            "Google ADK stack. The import stack is printed below to identify "
            "the module that still imports Google AI eagerly.\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
