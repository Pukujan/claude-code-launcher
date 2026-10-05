#!/usr/bin/env python3
"""Merge the launcher's keys into Claude Code's settings.json (issue #61).

  sync    sets model = "sonnet", advisorModel = "fable" and modelPicker.options,
          and adds env.CLAUDE_CODE_GLOB_TIMEOUT_SECONDS = "120" unless env already
          has a value for it (issue #69), keeping every other key as it is.
          Creates the file (and its folder) when it is missing.
  unsync  removes those keys again, but only when they still hold the launcher's
          values, so a user's own choices survive an uninstall. The search
          timeout goes only when the launcher's sync added it (issue #72): sync
          records that in .ccl-settings-sync.json next to settings.json, and
          "120" and 120 count the same. An env is removed only when it is empty
          and the launcher's sync created it. unsync deletes the record.
          --only-if-ours: change nothing unless there is proof the launcher
          wrote this file (its model picker, or the record); for a config the
          uninstaller can't tie to an install.

The settings file is --settings, else $CLAUDE_CONFIG_DIR/settings.json, else
~/.claude/settings.json. The picker options come from --options-file (a JSON
list); without it the four slot options are used. An empty or whitespace-only
file counts as {}. A file that is not valid JSON (or not a JSON object) is never
overwritten (exit 1), and neither is a read-only one (exit 3). Notes go to
stderr; stdout stays empty so the launcher's --print-env output is not
disturbed. Standard library only.

Exit codes: 0 ok or unchanged, 1 invalid JSON or a write error, 2 a bad
options file, 3 the settings file is read-only.

  python settings_sync.py sync|unsync [--settings PATH] [--options-file FILE]
"""
from __future__ import annotations

import argparse
import json
import os
import stat
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


RECORD_NAME = ".ccl-settings-sync.json"
RECORD_SCHEMA = "claude-code-launcher.settings-sync.v1"


def sync(settings: dict, options: list) -> dict:
    """A copy of settings with the launcher's keys set: model, advisorModel and
    modelPicker.options, plus env.CLAUDE_CODE_GLOB_TIMEOUT_SECONDS = "120" when env
    has no value for it (issue #69). A dict env keeps its other keys; an env that is
    not a dict is left as it is. Nothing else changes. sync_record() tells what this
    added, so unsync() can take back only that."""
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


def sync_record(before: dict, after: dict, record: dict | None = None) -> dict:
    """What sync added going from before to after, merged into an earlier record."""
    rec = {"glob_timeout_added": False, "env_created": False}
    if isinstance(record, dict):
        rec["glob_timeout_added"] = bool(record.get("glob_timeout_added"))
        rec["env_created"] = bool(record.get("env_created"))
    env_b = before.get("env")
    env_a = after.get("env")
    had = isinstance(env_b, dict) and env_b.get(GLOB_TIMEOUT_KEY) not in (None, "")
    if not had and isinstance(env_a, dict) and _is_our_timeout(env_a.get(GLOB_TIMEOUT_KEY)):
        rec["glob_timeout_added"] = True
        if "env" not in before:
            rec["env_created"] = True
    return rec


def _is_our_timeout(value) -> bool:
    # "120" and 120 are the same setting to Claude Code; a bool is not a number here.
    if isinstance(value, bool):
        return False
    return value == GLOB_TIMEOUT or value == int(GLOB_TIMEOUT)


def has_proof(settings: dict, record: dict | None) -> bool:
    """True when this file shows the launcher wrote it: its picker or a sync record."""
    return isinstance(record, dict) or _picker_is_ours(settings.get("modelPicker"))


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


def unsync(settings: dict, record: dict | None = None) -> dict:
    """A copy without the launcher's keys, where they still hold the launcher's values.
    The search timeout and an emptied env go only as far as record says sync added them."""
    out = dict(settings)
    if "modelPicker" in out and _picker_is_ours(out["modelPicker"]):
        del out["modelPicker"]
    if out.get("advisorModel") == ADVISOR:
        del out["advisorModel"]
    if out.get("model") == MODEL:
        del out["model"]
    rec = record if isinstance(record, dict) else {}
    env = out.get("env")
    if rec.get("glob_timeout_added") and isinstance(env, dict) and _is_our_timeout(env.get(GLOB_TIMEOUT_KEY)):
        env = {k: v for k, v in env.items() if k != GLOB_TIMEOUT_KEY}
        if env or not rec.get("env_created"):
            out["env"] = env
        else:
            del out["env"]
    return out


def record_path(path: Path) -> Path:
    return path.parent / RECORD_NAME


def read_record(path: Path) -> dict | None:
    try:
        doc = json.loads(record_path(path).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    return doc if isinstance(doc, dict) else None


def _write_record(path: Path, rec: dict) -> None:
    p = record_path(path)
    if not (rec.get("glob_timeout_added") or rec.get("env_created")):
        if p.exists():
            p.unlink()
        return
    doc = {"schema": RECORD_SCHEMA, "glob_timeout_added": bool(rec.get("glob_timeout_added")),
           "env_created": bool(rec.get("env_created"))}
    p.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8", newline="\n")


def settings_path(arg: str | None, env=None) -> Path:
    env = os.environ if env is None else env
    if arg:
        return Path(arg)
    if env.get("CLAUDE_CONFIG_DIR"):
        return Path(env["CLAUDE_CONFIG_DIR"]) / "settings.json"
    return Path.home() / ".claude" / "settings.json"


def is_read_only(path: Path) -> bool:
    """True when the file exists and must not be changed: the read-only attribute on
    Windows, or no owner write bit / no write access elsewhere."""
    try:
        st = os.stat(path)
    except OSError:
        return False
    if getattr(st, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_READONLY", 0):
        return True
    if not st.st_mode & stat.S_IWUSR:
        return True
    return not os.access(path, os.W_OK)


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
    # Paths can hold any character (a non-ASCII install folder); never crash on a narrow console.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="backslashreplace")
    ap = argparse.ArgumentParser(description="Sync the launcher's keys into Claude Code's settings.json.")
    ap.add_argument("action", choices=("sync", "unsync"))
    ap.add_argument("--settings", default=None)
    ap.add_argument("--options-file", default=None)
    ap.add_argument("--only-if-ours", action="store_true", help="unsync: change nothing without proof the launcher wrote the file")
    a = ap.parse_args(argv)
    path = settings_path(a.settings)
    existed = path.exists()
    current: dict = {}
    if existed:
        try:
            text = path.read_text(encoding="utf-8-sig")
            current = json.loads(text) if text.strip() else {}
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
        record = sync_record(current, new, read_record(path))
    else:
        if not existed:
            print("settings_sync: unchanged (no settings file)", file=sys.stderr)
            return 0
        rec = read_record(path)
        if a.only_if_ours and not has_proof(current, rec):
            print(f"settings_sync: no sign the launcher wrote {path}; left untouched", file=sys.stderr)
            return 0
        new = unsync(current, rec)
        record = None
    if existed and new == current:
        _save_record(path, record)
        print(f"settings_sync: unchanged {path}", file=sys.stderr)
        return 0
    if existed and is_read_only(path):
        print(f"settings_sync: {path} is read-only; left untouched. Clear the read-only flag and run again "
              "to add the launcher's model picker and advisor.", file=sys.stderr)
        return 3
    try:
        _write(path, new)
    except OSError as e:
        print(f"settings_sync: could not write {path} ({type(e).__name__})", file=sys.stderr)
        return 1
    _save_record(path, record)
    print(f"settings_sync: {'updated' if existed else 'created'} {path}", file=sys.stderr)
    return 0


def _save_record(path: Path, record: dict | None) -> None:
    # After sync: the record of what it added. After unsync (record None): gone.
    try:
        if record is None:
            p = record_path(path)
            if p.exists():
                p.unlink()
        else:
            _write_record(path, record)
    except OSError as e:
        print(f"settings_sync: could not update {record_path(path)} ({type(e).__name__})", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
