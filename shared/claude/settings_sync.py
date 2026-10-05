#!/usr/bin/env python3
"""Merge the launcher's keys into Claude Code's settings.json (issue #61).

  sync    sets model = "sonnet", advisorModel = "fable" and modelPicker.options,
          and adds env.CLAUDE_CODE_GLOB_TIMEOUT_SECONDS = "120" unless env already
          has a value for it (issue #69), keeping every other key as it is.
          Creates the file (and its folder) when it is missing.
  unsync  removes those keys again, but only when they still hold the launcher's
          values, so a user's own choices survive an uninstall. An env left
          empty by that is removed too.

The settings file is --settings, else $CLAUDE_CONFIG_DIR/settings.json, else
~/.claude/settings.json. The picker options come from --options-file (a JSON
list); without it the four slot options are used. A file that is not valid
JSON is never overwritten (exit 1). Notes go to stderr; stdout stays empty so
the launcher's --print-env output is not disturbed. Standard library only.

  python settings_sync.py sync|unsync [--settings PATH] [--options-file FILE]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

MODEL = "sonnet"
ADVISOR = "fable"
# Claude Code stops every ripgrep run (Grep, Glob) after this many seconds, 20 by
# default; cold scans of big folders on Windows take longer (issue #69).
GLOB_TIMEOUT_KEY = "CLAUDE_CODE_GLOB_TIMEOUT_SECONDS"
GLOB_TIMEOUT = "120"
# Descriptions the launcher writes; an option list made only of these is ours.
OUR_MARKERS = ("via local LiteLLM", "InferHub")

SLOT_OPTIONS = [
    {"model": "sonnet", "label": "Sonnet slot (main)", "description": "Main chat chain via local LiteLLM", "behavesAs": "claude-sonnet-5"},
    {"model": "opus", "label": "Opus slot (planning)", "description": "Planning chain via local LiteLLM", "behavesAs": "claude-opus-5-5"},
    {"model": "fable", "label": "Fable slot (advisor)", "description": "Advisor chain via local LiteLLM", "behavesAs": "claude-fable-5"},
    {"model": "haiku", "label": "Haiku slot (background)", "description": "Background chain via local LiteLLM", "behavesAs": "claude-haiku-4-5-20251001"},
]


def sync(settings: dict, options: list) -> dict:
    """A copy of settings with the launcher's three keys set; nothing else changes."""
    out = dict(settings)
    out["model"] = MODEL
    out["advisorModel"] = ADVISOR
    out["modelPicker"] = {"options": list(options)}
    env = out.get("env")
    if env is None:
        out["env"] = {GLOB_TIMEOUT_KEY: GLOB_TIMEOUT}
    elif isinstance(env, dict) and env.get(GLOB_TIMEOUT_KEY) in (None, ""):
        out["env"] = {**env, GLOB_TIMEOUT_KEY: GLOB_TIMEOUT}
    return out


def _picker_is_ours(picker) -> bool:
    if not isinstance(picker, dict):
        return False
    opts = picker.get("options")
    if not isinstance(opts, list) or set(picker) - {"options"}:
        return False
    for o in opts:
        if not isinstance(o, dict):
            return False
        text = " ".join(str(o.get(k) or "") for k in ("description", "label"))
        if not any(m in text for m in OUR_MARKERS):
            return False
    return True


def unsync(settings: dict) -> dict:
    """A copy without the launcher's keys, where they still hold the launcher's values."""
    out = dict(settings)
    if "modelPicker" in out and _picker_is_ours(out["modelPicker"]):
        del out["modelPicker"]
    if out.get("advisorModel") == ADVISOR:
        del out["advisorModel"]
    if out.get("model") == MODEL:
        del out["model"]
    env = out.get("env")
    if isinstance(env, dict) and env.get(GLOB_TIMEOUT_KEY) == GLOB_TIMEOUT:
        env = {k: v for k, v in env.items() if k != GLOB_TIMEOUT_KEY}
        if env:
            out["env"] = env
        else:
            del out["env"]
    return out


def settings_path(arg: str | None, env=None) -> Path:
    env = os.environ if env is None else env
    if arg:
        return Path(arg)
    if env.get("CLAUDE_CONFIG_DIR"):
        return Path(env["CLAUDE_CONFIG_DIR"]) / "settings.json"
    return Path.home() / ".claude" / "settings.json"


def _write(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".settings-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Sync the launcher's keys into Claude Code's settings.json.")
    ap.add_argument("action", choices=("sync", "unsync"))
    ap.add_argument("--settings", default=None)
    ap.add_argument("--options-file", default=None)
    a = ap.parse_args(argv)
    path = settings_path(a.settings)
    existed = path.exists()
    current: dict = {}
    if existed:
        try:
            current = json.loads(path.read_text(encoding="utf-8-sig") or "{}")
        except (OSError, ValueError) as e:
            print(f"settings_sync: {path} is not valid JSON ({type(e).__name__}); left untouched", file=sys.stderr)
            return 1
        if not isinstance(current, dict):
            print(f"settings_sync: {path} is not a JSON object; left untouched", file=sys.stderr)
            return 1
    if a.action == "sync":
        options = SLOT_OPTIONS
        if a.options_file:
            try:
                options = json.loads(Path(a.options_file).read_text(encoding="utf-8-sig"))
            except (OSError, ValueError) as e:
                print(f"settings_sync: bad options file ({type(e).__name__})", file=sys.stderr)
                return 2
            if not isinstance(options, list):
                print("settings_sync: the options file must hold a JSON list", file=sys.stderr)
                return 2
        new = sync(current, options)
    else:
        if not existed:
            print("settings_sync: unchanged (no settings file)", file=sys.stderr)
            return 0
        new = unsync(current)
    if existed and new == current:
        print(f"settings_sync: unchanged {path}", file=sys.stderr)
        return 0
    try:
        _write(path, new)
    except OSError as e:
        print(f"settings_sync: could not write {path} ({type(e).__name__})", file=sys.stderr)
        return 1
    print(f"settings_sync: {'updated' if existed else 'created'} {path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
