#!/usr/bin/env python3
"""One switch for the CKFF provider group (off by default since 2026-10-04).

Order of precedence:
  1. LITELLM_ENABLE_CKFF environment variable (1/true/yes/on or 0/false/no/off)
  2. `ckff_enabled:` in config/providers.yaml
  3. off

start-litellm.ps1 reads the same two places, so keep the file format flat.
Run `python scripts/provider_switch.py` to print "ckff=on" or "ckff=off".
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROVIDERS_FILE = ROOT / "config" / "providers.yaml"
ENV_VAR = "LITELLM_ENABLE_CKFF"
CKFF_API_BASE_MARKERS = ("ckffai.com", "ckff.dev")

_TRUE = {"1", "true", "yes", "on"}
_FALSE = {"0", "false", "no", "off"}


def _parse_bool(value: str | None) -> bool | None:
    if value is None:
        return None
    v = value.strip().strip("'\"").lower()
    if v in _TRUE:
        return True
    if v in _FALSE:
        return False
    return None


def file_setting(path: Path = PROVIDERS_FILE) -> bool | None:
    if not path.is_file():
        return None
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        m = re.match(r"^\s*ckff_enabled\s*:\s*([^#\s]+)", line)
        if m:
            return _parse_bool(m.group(1))
    return None


def ckff_enabled(env: dict | None = None, path: Path = PROVIDERS_FILE) -> bool:
    env = os.environ if env is None else env
    from_env = _parse_bool(env.get(ENV_VAR))
    if from_env is not None:
        return from_env
    from_file = file_setting(path)
    return bool(from_file) if from_file is not None else False


def is_ckff_deployment(entry: dict) -> bool:
    """True for a model_list entry that routes to CKFF."""
    if not isinstance(entry, dict):
        return False
    params = entry.get("litellm_params") or {}
    base = str(params.get("api_base") or "").lower()
    key = str(params.get("api_key") or "").lower()
    # ckff-*, ckff_* and CKFF_* names (ckff_astra included) all count.
    return any(m in base for m in CKFF_API_BASE_MARKERS) or key.startswith("os.environ/ckff")


if __name__ == "__main__":
    print("ckff=on" if ckff_enabled() else "ckff=off")
    sys.exit(0)
