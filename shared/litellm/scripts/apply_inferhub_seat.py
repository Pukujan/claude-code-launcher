#!/usr/bin/env python3
"""Write the slot names Claude Code calls into config/inferhub_aliases.yaml.

Claude Code has four model slots (sonnet, opus, haiku, fable; see slots.py). Each
slot is a chain of real InferHub routes. This writes, for every slot:
  - one entry per name the slot answers to (sonnet, claude-sonnet-5, ...), all
    pointing at the slot's first model;
  - one entry per fallback model, named ccl-<slot>-2, ccl-<slot>-3, ...: the slot's
    own copies, so a bench caused by one slot's traffic never benches another.
merge_litellm_config.py then wires the fallbacks, retries and benching.

Seat file (config/inferhub_seat.json), written by the launchers from the onboarding picks:
  {
    "version": 2,
    "slots": {"sonnet": ["cb/deepseek-v4.1-flash", "ali/qwen3.8-flash", "cbcn/glm-5.3-flash"],
              "opus": [...], "haiku": [...], "fable": [...]},
    "main_inferhub_id": ..., "advisor_inferhub_id": ..., "fast_inferhub_id": ...   # first models, for older readers
  }
A slot missing from the file uses the default chain in config/inferhub_fallbacks.yaml.
Older seat files (main/advisor/fast only) are read as "no picks yet": the defaults apply.

Command line:
  --slot sonnet=id1,id2,id3   set one slot's chain (repeatable)
  --main / --advisor / --fast ID   older launchers: the first model of sonnet / fable /
                              haiku, keeping the rest of that slot's chain (empty = keep)

cx/ routes go through LiteLLM's Responses mode. CKFF routes are never written.

After writing, optionally merge into config/runtime.yaml and hot-reload the
running proxy via POST /workbench/reload_runtime. Use --no-reload / --no-merge
when the proxy is not expected to be up (e.g. during start-litellm.ps1 boot).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import slots  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SEAT = ROOT / "config" / "inferhub_seat.json"
DEFAULT_OUT = ROOT / "config" / "inferhub_aliases.yaml"
DEFAULT_API_BASE = "https://api.inferhub.dev/v1"
LEGACY_FLAG_SLOT = {"main": "sonnet", "advisor": "fable", "fast": "haiku"}


def yaml_escape(s: str) -> str:
    if any(c in s for c in [":", "#", "{", "}", "[", "]", ",", "&", "*", "!", "|", ">", "%", "@", "`", "'", '"']):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return s


def litellm_model(inferhub_id: str) -> str:
    """cx/ routes go through LiteLLM's Responses API mode. Over Chat Completions,
    InferHub's cx rail turns the system prompt into a developer message and forces
    the instructions field to a stock prompt; /v1/responses keeps instructions as
    sent (IRE frontier list: preferred_endpoint=/v1/responses). Every other route
    is unchanged."""
    if inferhub_id.startswith("cx/"):
        return f"openai/responses/{inferhub_id}"
    return f"openai/{inferhub_id}"


def entry(name: str, inferhub_id: str, api_base: str, slot: str, rung: int, last: bool) -> list[str]:
    what = "first model" if rung == 1 else f"fallback {rung}"
    return [
        f"  - model_name: {yaml_escape(name)}",
        "    litellm_params:",
        f"      model: {litellm_model(inferhub_id)}",
        f"      api_base: {api_base}",
        "      api_key: os.environ/INFERHUB_API_KEY",
        "    model_info:",
        f"      description: {yaml_escape(f'Claude Code slot {slot}, {what} -> {inferhub_id}')}",
        f"      ccl_slot: {slot}",
        f"      ccl_rung: {rung}",
        f"      ccl_last: {'true' if last else 'false'}",
        "",
    ]


def run_helper(script: str, args: list[str]) -> int:
    cmd = [sys.executable, str(ROOT / "scripts" / script), *args]
    print(f"+ {' '.join(cmd)}")
    return subprocess.call(cmd)


def read_seat(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        # utf-8-sig: Windows PowerShell 5.1 Set-Content -Encoding UTF8 writes a BOM
        doc = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as e:
        print(f"warning: ignoring unreadable seat file {path}: {e}", file=sys.stderr)
        return {}
    return doc if isinstance(doc, dict) else {}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seat", type=Path, default=DEFAULT_SEAT)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--fallbacks", type=Path, default=slots.DEFAULT_FALLBACKS)
    ap.add_argument("--api-base", default=DEFAULT_API_BASE)
    ap.add_argument("--slot", action="append", default=[], help="NAME=id1,id2,... (repeatable)")
    ap.add_argument("--main", default=None, help="older launchers: first model of the sonnet slot")
    ap.add_argument("--advisor", default=None, help="older launchers: first model of the fable slot")
    ap.add_argument("--fast", default=None, help="older launchers: first model of the haiku slot")
    ap.add_argument("--merge", dest="merge", action="store_true", default=True,
                    help="Also merge into config/runtime.yaml (default)")
    ap.add_argument("--no-merge", dest="merge", action="store_false", help="Skip merge_litellm_config.py")
    ap.add_argument("--reload", dest="reload", action="store_true", default=True,
                    help="Hot-reload the running proxy (default)")
    ap.add_argument("--no-reload", dest="reload", action="store_false", help="Skip live reload (proxy may be down)")
    ap.add_argument("--base-url", default=None, help="Proxy base URL for reload")
    args = ap.parse_args()

    seat = read_seat(args.seat)
    overrides = {}
    try:
        for spec in args.slot:
            name, chain = slots.parse_slot_arg(spec)
            overrides[name] = chain
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2
    chains = slots.resolve_slots(seat, overrides, args.fallbacks)
    for flag, slot in LEGACY_FLAG_SLOT.items():
        first = (getattr(args, flag) or "").strip()
        if first and slot not in overrides:
            chains[slot] = slots.normalize_chain([first] + [c for c in chains[slot] if c != first])
    ckff_on = slots.ckff_enabled(args.fallbacks)

    base = args.api_base.rstrip("/")
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines = [
        "# GENERATED by scripts/apply_inferhub_seat.py — do not hand-edit.",
        f"# Generated: {now}",
        "# Claude Code slots -> InferHub routes (first model, then fallbacks). Never CKFF.",
    ]
    lines += [f"# {s}: {' -> '.join(chains[s])}" for s in slots.SLOTS]
    lines.append("model_list:")
    for s in slots.SLOTS:
        chain = chains[s]
        for name in slots.slot_names(s, ckff_on):
            lines.extend(entry(name, chain[0], base, s, 1, len(chain) == 1))
        for i, route in enumerate(chain[1:], start=2):
            lines.extend(entry(slots.rung_name(s, i), route, base, s, i, i == len(chain)))

    out_seat = {
        "version": 2,
        "slots": {s: chains[s] for s in slots.SLOTS},
        "main_inferhub_id": chains["sonnet"][0],
        "advisor_inferhub_id": chains["fable"][0],
        "fast_inferhub_id": chains["haiku"][0],
        "updated_at": now,
    }
    args.seat.parent.mkdir(parents=True, exist_ok=True)
    args.seat.write_text(json.dumps(out_seat, indent=2) + "\n", encoding="utf-8")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    print(f"Wrote slot names to {args.out}")
    for s in slots.SLOTS:
        print(f"Slot {s}: {' -> '.join(chains[s])}")

    if args.merge:
        rc = run_helper("merge_litellm_config.py", ["--no-reload"])
        if rc != 0:
            return rc
    if args.reload:
        # "all": the slot chains change fallbacks too, not only the names
        reload_args = ["--scope", "all"]
        if args.base_url:
            reload_args.extend(["--base-url", args.base_url])
        rc = run_helper("reload_runtime.py", reload_args)
        if rc != 0:
            return rc
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
