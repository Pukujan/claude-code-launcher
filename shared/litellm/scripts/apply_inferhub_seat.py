#!/usr/bin/env python3
"""Write Claude-facing InferHub seat aliases into config/inferhub_aliases.yaml.

Seat file (config/inferhub_seat.json):
  {
    "main_inferhub_id": "cb/deepseek-v4.1-flash",
    "advisor_inferhub_id": "cbcn/glm-5.3"   # or null / omit when OFF
  }

Aliases (InferHub seats; include Claude Code API ids so local Claude works):
  main / sonnet / claude-sonnet-5 / ih-main / ih-sonnet / inferhub-sonnet  -> main seat
  advisor / opus / claude-opus-5-5 / claude-fable-5 / claude-fable-5-1 /
    ih-advisor / ih-opus / inferhub-opus -> advisor seat
  (if advisor OFF, advisor aliases also point at main so /advisor opus still resolves)
  haiku / claude-haiku-5 / claude-haiku-4-5-20251001 / small-fast / ih-haiku / ih-small-fast / inferhub-haiku
    -> fast seat (Claude Code background/small-fast calls). Default fast seat is
    cb/deepseek-v4.1-flash; set "fast_inferhub_id" in the seat file or pass --fast
    (empty string = use the main seat). The fast aliases get their own fallback
    chain in config/inferhub_fallbacks.yaml (role "fast"). claude-haiku-4-5 (no date) is
    also aliased to the fast seat while CKFF is off (the default since 2026-10-04,
    config/providers.yaml); with CKFF on it is left alone because CKFF serves that
    name. The dated id is Claude Code's own haiku name, so the launchers pin the
    haiku tier to it.

Opt-in seats (never the default): cx/gpt-6.1-sol may be picked as main or
advisor with --main/--advisor or in the seat file. cx routes go over chat
completions and send the system prompt as a "developer" message.

These Claude Code ids (claude-sonnet-5, claude-opus-5-5, claude-fable-*) are distinct
from CKFF catalog names (e.g. claude-sonnet-4-5) and must be InferHub seat aliases.

After writing, optionally merge into config/runtime.yaml and hot-reload the
running proxy via POST /workbench/reload_runtime (no :4000 downtime).
Use --no-reload / --no-merge when the proxy is not expected to be up
(e.g. during start-litellm.ps1 boot).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import provider_switch  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SEAT = ROOT / "config" / "inferhub_seat.json"
DEFAULT_OUT = ROOT / "config" / "inferhub_aliases.yaml"
DEFAULT_API_BASE = "https://api.inferhub.dev/v1"

MAIN_ALIASES = ["main", "sonnet", "claude-sonnet-5", "ih-main", "ih-sonnet", "inferhub-sonnet"]
FAST_ALIASES = ["haiku", "claude-haiku-5", "claude-haiku-4-5-20251001", "small-fast", "ih-haiku", "ih-small-fast", "inferhub-haiku"]
# Only used when CKFF is off; with CKFF on, CKFF owns this name.
CKFF_OWNED_FAST_ALIASES = ["claude-haiku-4-5"]
DEFAULT_FAST_ID = "cb/deepseek-v4.1-flash"
# The old default. Every seat file written before the change carries it even though no
# launcher ever offered a fast-seat pick, so it is read as "not picked".
OLD_DEFAULT_FAST_ID = "ali/qwen3.8-flash"
# Seats that are allowed but never chosen by default. Any other id is passed
# through as-is (Top 20 ids are the normal choice).
OPT_IN_SEAT_IDS = {
    "cx/gpt-6.1-sol": "cx route: chat completions; system prompt is sent as a developer message",
}
ADVISOR_ALIASES = [
    "advisor",
    "opus",
    "claude-opus-5-5",
    "claude-fable-5",
    "claude-fable-5-1",
    "ih-advisor",
    "ih-opus",
    "inferhub-opus",
]


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


def entry(alias: str, inferhub_id: str, api_base: str, role: str) -> list[str]:
    return [
        f"  - model_name: {yaml_escape(alias)}",
        "    litellm_params:",
        f"      model: {litellm_model(inferhub_id)}",
        f"      api_base: {api_base}",
        "      api_key: os.environ/INFERHUB_API_KEY",
        "    model_info:",
        f"      description: {yaml_escape(f'InferHub Claude seat ({role}) -> {inferhub_id}')}",
        "",
    ]


def run_helper(script: str, args: list[str]) -> int:
    cmd = [sys.executable, str(ROOT / "scripts" / script), *args]
    print(f"+ {' '.join(cmd)}")
    return subprocess.call(cmd)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seat", type=Path, default=DEFAULT_SEAT)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--api-base", default=DEFAULT_API_BASE)
    ap.add_argument("--main", default=None, help="Override main InferHub model id")
    ap.add_argument("--advisor", default=None, help="Override advisor id; empty string = OFF")
    ap.add_argument("--fast", default=None,
                    help=f"Override fast/haiku seat id (default {DEFAULT_FAST_ID}); empty string = use main seat")
    ap.add_argument("--merge", dest="merge", action="store_true", default=True,
                    help="Also merge into config/runtime.yaml (default)")
    ap.add_argument("--no-merge", dest="merge", action="store_false",
                    help="Skip merge_litellm_config.py")
    ap.add_argument("--reload", dest="reload", action="store_true", default=True,
                    help="Hot-reload running proxy seat aliases (default)")
    ap.add_argument("--no-reload", dest="reload", action="store_false",
                    help="Skip live reload (proxy may be down)")
    ap.add_argument("--base-url", default=None, help="Proxy base URL for reload")
    args = ap.parse_args()

    seat = {}
    if args.seat.is_file():
        # utf-8-sig: Windows PowerShell 5.1 Set-Content -Encoding UTF8 writes a BOM
        seat = json.loads(args.seat.read_text(encoding="utf-8-sig"))
    main_id = args.main if args.main is not None else seat.get("main_inferhub_id")
    if args.advisor is not None:
        advisor_id = args.advisor.strip() or None
    else:
        advisor_id = seat.get("advisor_inferhub_id") or None

    if not main_id:
        print("ERROR: main_inferhub_id required (seat file or --main)", file=sys.stderr)
        return 1

    if args.fast is not None:
        fast_id = args.fast.strip() or None
    elif "fast_inferhub_id" in seat and seat.get("fast_inferhub_id") != OLD_DEFAULT_FAST_ID:
        fast_id = seat.get("fast_inferhub_id") or None
    else:
        fast_id = DEFAULT_FAST_ID
    fast_effective = fast_id or main_id

    for role, mid in (("main", main_id), ("advisor", advisor_id), ("fast", fast_id)):
        if mid in OPT_IN_SEAT_IDS:
            print(f"note: opt-in {role} seat {mid} ({OPT_IN_SEAT_IDS[mid]})")

    advisor_effective = advisor_id or main_id
    advisor_role = "advisor" if advisor_id else "advisor-OFF-fallback-main"

    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines = [
        "# GENERATED by scripts/apply_inferhub_seat.py — do not hand-edit.",
        f"# Generated: {now}",
        f"# main -> {main_id}",
        f"# advisor -> {advisor_effective} ({'ON' if advisor_id else 'OFF'})",
        f"# fast/haiku -> {fast_effective}",
        "# Claude Code expands sonnet/opus to claude-sonnet-5 / claude-opus-5-5 / fable ids; map those to InferHub seats (not CKFF).",
        "model_list:",
    ]
    for a in MAIN_ALIASES:
        lines.extend(entry(a, main_id, args.api_base.rstrip("/"), "main"))
    for a in ADVISOR_ALIASES:
        lines.extend(entry(a, advisor_effective, args.api_base.rstrip("/"), advisor_role))
    fast_aliases = list(FAST_ALIASES)
    if not provider_switch.ckff_enabled():
        fast_aliases += CKFF_OWNED_FAST_ALIASES
    for a in fast_aliases:
        lines.extend(entry(a, fast_effective, args.api_base.rstrip("/"), "fast" if fast_id else "fast-fallback-main"))

    out_seat = {
        "main_inferhub_id": main_id,
        "advisor_inferhub_id": advisor_id,
        "fast_inferhub_id": fast_id,
        "updated_at": now,
    }
    args.seat.parent.mkdir(parents=True, exist_ok=True)
    args.seat.write_text(json.dumps(out_seat, indent=2) + "\n", encoding="utf-8")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    print(f"Wrote aliases to {args.out}")
    print(f"Seat: main={main_id} advisor={advisor_id or 'OFF'} fast={fast_effective}")

    if args.merge:
        # merge itself may reload; pass --no-reload here and reload once below
        rc = run_helper("merge_litellm_config.py", ["--no-reload"])
        if rc != 0:
            return rc

    if args.reload:
        reload_args = ["--scope", "seat"]
        if args.base_url:
            reload_args.extend(["--base-url", args.base_url])
        rc = run_helper("reload_runtime.py", reload_args)
        if rc != 0:
            return rc

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
