#!/usr/bin/env python3
"""Write Claude-facing InferHub seat aliases into config/inferhub_seats.yaml.

macOS port of litellm-ckff-ops/scripts/apply_inferhub_seat.py. Same seat file
and same alias contract, so a seat chosen here behaves identically to one
chosen by the Windows launcher.

Seat file (config/inferhub_seat.json):
  {
    "main_inferhub_id": "cb/deepseek-v4.1-flash",
    "advisor_inferhub_id": "cbcn/glm-5.3"   # or null / omit when OFF
  }

Alias contract (from the Windows workbench):
  main    -> main, sonnet, claude-sonnet-5, ih-main, ih-sonnet, inferhub-sonnet
  advisor -> advisor, opus, claude-opus-5-5, claude-fable-5, claude-fable-5-1,
             ih-advisor, ih-opus, inferhub-opus
  When the advisor is OFF, advisor aliases point at the main seat so that
  /advisor opus still resolves instead of 404ing.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SEAT = ROOT / "config" / "inferhub_seat.json"
DEFAULT_OUT = ROOT / "config" / "inferhub_seats.yaml"
API_BASE = "https://api.inferhub.dev/v1"

MAIN_ALIASES = ["main", "sonnet", "claude-sonnet-5", "claude-sonnet-5-5",
                "claude-sonnet-4-6", "claude-sonnet-4-5", "ih-main", "ih-sonnet",
                "inferhub-sonnet", "default"]
ADVISOR_ALIASES = ["advisor", "opus", "claude-opus-5-5", "claude-opus-4-6",
                   "claude-opus-4-5", "claude-fable-5", "claude-fable-5-1",
                   "ih-advisor", "ih-opus", "inferhub-opus"]
SMALL_FAST_ALIAS = "ih/ali/qwen3.8-flash"
SMALL_FAST_ID = "ali/qwen3.8-flash"

# The IRE Top 20, so every ranked route is individually addressable through the
# proxy (not just the two seats). Order matches the recommendation_rank column.
# Each entry: (family, primary slug, cost USDC per 1M tokens, eligible)
# The IRE Top 20, read live from inference-recommendation-engine and cached
# (see ire_live_models.py). Each entry is (family, cost_usdc_per_1m, eligible,
# [vendor slugs in IRE's preference order]) — every vendor id IRE lists is
# registered, because a route can 402 on its first vendor while another answers.
IRE_TOP20 = [
    ("DeepSeek V4.1 Flash", 0.022108, True, ["cb/deepseek-v4.1-flash", "cbcn/deepseek-v4.1-flash", "ali/deepseek-v4.1-flash", "cp/cline-pass/deepseek-v4.1-flash", "ocg/deepseek-v4.1-flash"]),
    ("GLM 5.3 Flash", 0.032924, True, ["cbcn/glm-5.3-flash", "cp/zai/glm-5.3-flash", "cmc/z-ai/glm-5.3-flash", "zai/glm-5.3-flash", "ocg/glm-5.3-flash"]),
    ("Gemini 3.8 Flash", 0.066345, False, ["ag/gemini-3.8-flash-high"]),
    ("DeepSeek V4 Flash", 0.046688, True, ["cbcn/deepseek-v4-flash", "cmc/deepseek/deepseek-v4-flash", "ocg/deepseek-v4-flash"]),
    ("DeepSeek V4 Pro 0813", 0.08298, False, ["ali/deepseek-v4-pro-0813"]),
    ("Qwen3.8 Max 0902", 0.078043, False, ["ali/qwen3.8-max-0902"]),
    ("Qwen3.8 Flash", 0.008056, True, ["ali/qwen3.8-flash", "ocg/qwen3.8-flash"]),
    ("Muse Spark 1.3 Contributor", 0.040076, False, ["cmc/meta/muse-spark-1.3-contributor"]),
    ("GPT 5.6 Luna", 0.04015, False, ["cx/gpt-5.6-luna", "cb/gpt-5.6-luna", "ocg/gpt-5.6-luna"]),
    ("MiniMax M3", 0.052142, True, ["cbcn/minimax-m3", "cb/minimax-m3", "cp/cline-pass/minimax-m3", "ocg/minimax-m3"]),
    ("DeepSeek V4 Flash 0731", 0.091326, False, ["ali/deepseek-v4-flash-0731"]),
    ("Gemini 3.7 Flash", 0.077005, False, ["ag/gemini-3.7-flash-high"]),
    ("Gemini 3.6 Flash", 0.080802, False, ["ag/gemini-3.6-flash-high"]),
    ("DeepSeek V4 Pro", 0.138399, True, ["cbcn/deepseek-v4-pro", "cmc/deepseek/deepseek-v4-pro", "cp/cline-pass/deepseek-v4-pro"]),
    ("GLM 5.2", 0.180507, True, ["ali/glm-5.2", "cbcn/glm-5.2", "cb/glm-5.2", "cmc/zai-org/GLM-5.2"]),
    ("Hy4 Preview", 0.077408, False, ["cb/hy4-preview", "cbcn/hy4-preview"]),
    ("Muse Spark 1.2 Contributor", 0.028751, False, ["cmc/meta/muse-spark-1.2-contributor"]),
    ("Qwen 3.8 Max", 0.169559, True, ["ali/qwen3.8-max", "cp/cline-pass/qwen3.8-max", "ocg/qwen3.8-max"]),
    ("GLM 5.3", 0.26708, True, ["cbcn/glm-5.3", "cb/glm-5.3", "ali/glm-5.3", "zai/glm-5.3", "cp/cline-pass/glm-5.3", "ocg/glm-5.3"]),
    ("Kimi K2.7 Code", 0.155677, True, ["ali/kimi-k2.7-code", "cbcn/kimi-k2.7", "cmc/moonshotai/Kimi-K2.7-Code", "ocg/kimi-k2.7-code"]),
]


def yaml_escape(s: str) -> str:
    if any(c in s for c in ': #{}[]&*!|>%@`\'"'):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return s


def entry(alias: str, inferhub_id: str, role: str) -> list[str]:
    return [
        f"  - model_name: {yaml_escape(alias)}",
        "    litellm_params:",
        f"      model: openai/{inferhub_id}",
        f"      api_base: {API_BASE}",
        "      api_key: os.environ/INFERHUB_API_KEY",
        "    model_info:",
        f"      description: {yaml_escape(f'InferHub ({role}) -> {inferhub_id}')}",
        "",
    ]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--main", required=True, help="main InferHub model id")
    ap.add_argument("--advisor", default="", help="advisor id, or empty for OFF")
    ap.add_argument("--seat-file", default=str(DEFAULT_SEAT))
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    args = ap.parse_args()

    main_id = args.main.strip()
    advisor_id = (args.advisor or "").strip() or None
    if not main_id:
        print("--main is required", file=sys.stderr)
        return 2
    if advisor_id == main_id:
        print("refusing to seat advisor == main; they must differ", file=sys.stderr)
        return 2

    seat = {
        "main_inferhub_id": main_id,
        "advisor_inferhub_id": advisor_id,
        "updated_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    Path(args.seat_file).parent.mkdir(parents=True, exist_ok=True)
    Path(args.seat_file).write_text(json.dumps(seat, indent=2) + "\n", encoding="utf-8")

    lines: list[str] = [
        "# InferHub seats for local LiteLLM on macOS.",
        "# Generated by scripts/apply_seat.py - do not edit by hand.",
        f"# main={main_id}  advisor={advisor_id or 'OFF (aliases fall back to main)'}",
        f"# generated_at={seat['updated_at']}",
        "model_list:",
    ]
    for a in MAIN_ALIASES:
        lines += entry(a, main_id, "main")
    for a in ADVISOR_ALIASES:
        lines += entry(a, advisor_id or main_id,
                       "advisor" if advisor_id else "advisor OFF -> main")
    lines += entry(SMALL_FAST_ALIAS, SMALL_FAST_ID, "small/fast side model")

    # Every IRE-ranked route, individually addressable as ih/<slug>. IRE lists
    # several vendor ids per model family; a route can 402 on its first vendor
    # while another answers, so every vendor is registered and chained.
    fallback_chains: list[tuple[str, list[str]]] = []
    for rank, (fam, cost, elig, slugs) in enumerate(IRE_TOP20, start=1):
        role = f"IRE #{rank:02d} {fam} ~{cost:.3f} USDC/1M"
        if not elig:
            role += " [gated by IRE]"
        primary, *rest = slugs
        lines += entry(f"ih/{primary}", primary, role)
        for alt in rest:
            lines += entry(f"ih/{alt}", alt, f"{role} (alt vendor)")
        if rest:
            fallback_chains.append((f"ih/{primary}", [f"ih/{a}" for a in rest]))

    lines += [
        "",
        "litellm_settings:",
        "  # No master key: single-user proxy bound to loopback. Claude Code still",
        "  # needs an ANTHROPIC_API_KEY value, so the launcher passes a dummy that",
        "  # LiteLLM ignores rather than duplicating the real key in two places.",
        "  drop_params: true",
        "  request_timeout: 600",
        "  num_retries: 2",
        "  telemetry: false",
        "",
        "# Alternate vendor ids for one model family, tried in IRE's order.",
        "# A route can 402 on its first vendor while another answers.",
    ]
    if fallback_chains:
        lines += ["router_settings:", "  fallbacks:"]
        for primary, alts in fallback_chains:
            alist = ", ".join(f'"{a}"' for a in alts)
            # Exactly one key: LiteLLM's Router.validate_fallbacks rejects both a
            # bare list and a dict with model_name+fallbacks.
            lines.append(f'    - "{primary}": [{alist}]')
    lines += [
        "",
        "general_settings:",
        "  # Loopback only. Do not bind 0.0.0.0 - there is no auth on this proxy.",
        "  host: 127.0.0.1",
        "  port: 4000",
        "",
    ]

    Path(args.out).write_text("\n".join(lines), encoding="utf-8")
    print(f"seated main={main_id} advisor={advisor_id or 'OFF'}")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())