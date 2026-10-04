"""Claude Code's native model slots and their fallback chains (issue #53).

The launcher no longer has seats of its own (main / advisor / fast). Claude Code
already asks for one of four slots, and the proxy maps each slot to a chain of
real InferHub routes:

  sonnet  the main conversation, and sub-agents that inherit it
  opus    planning: the launcher's planner sub-agent (model: opus) and anything
          else that asks for opus
  haiku   background calls (titles, summaries, WebFetch) and superpowers'
          "cheap" sub-agents, so it must handle tools
  fable   the advisor (advisorModel = fable)

Each slot answers to the Claude-style names Claude Code sends for it (the
ANTHROPIC_DEFAULT_*_MODEL pins the launchers set, the bare aliases, and older
names kept so running sessions keep working). Each slot gets its OWN copies of
its fallback models (ccl-<slot>-2, ccl-<slot>-3, ...), so trouble in one slot
never benches another, and the last model of every chain is never benched.

Where the chains come from, first match wins:
  1. --slot NAME=id1,id2,... on the command line
  2. "slots" in the seat file (config/inferhub_seat.json), written by the
     launchers from the onboarding picks
  3. "slots" in config/inferhub_fallbacks.yaml (the defaults)

CKFF: one switch, ckff_enabled in config/providers.yaml (off), read by
provider_switch.py; LITELLM_ENABLE_CKFF overrides it. While it is off no CKFF
model, alias or fallback lands in runtime.yaml and the proxy never loads CKFF keys.
Only ids containing "ckff" (and CKFF hosts/keys) are CKFF: InferHub's
cb/gpt-6-astra is an ordinary InferHub route.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import provider_switch  # noqa: E402

try:
    import yaml
except ImportError:  # the callers report the missing module
    yaml = None

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FALLBACKS = ROOT / "config" / "inferhub_fallbacks.yaml"

SLOTS = ("sonnet", "opus", "haiku", "fable")

# The names Claude Code (and older launcher sessions) send for each slot. The first
# Claude-style name is the one the launchers pin with ANTHROPIC_DEFAULT_<SLOT>_MODEL.
SLOT_NAMES = {
    "sonnet": ["sonnet", "claude-sonnet-5", "claude-sonnet-5-5",
               "main", "ih-main", "ih-sonnet", "inferhub-sonnet"],
    "opus": ["opus", "claude-opus-5-5", "claude-opus-5", "ih-opus", "inferhub-opus"],
    "haiku": ["haiku", "claude-haiku-4-5-20251001", "claude-haiku-5",
              "small-fast", "ih-haiku", "ih-small-fast", "inferhub-haiku"],
    "fable": ["fable", "claude-fable-5", "claude-fable-5-1", "best",
              "advisor", "ih-advisor"],
}
PINS = {
    "sonnet": "claude-sonnet-5",
    "opus": "claude-opus-5-5",
    "haiku": "claude-haiku-4-5-20251001",
    "fable": "claude-fable-5",
}
# CKFF serves this name; it becomes a haiku name only while CKFF is off.
CKFF_OFF_HAIKU_EXTRA = ["claude-haiku-4-5"]

BUILTIN_DEFAULTS = {
    "sonnet": ["cb/deepseek-v4.1-flash", "ali/qwen3.8-flash", "cbcn/glm-5.3-flash"],
    "opus": ["cb/gpt-6-astra", "cx/gpt-6.1-sol", "ali/qwen3.8-max-0902"],
    "haiku": ["cb/deepseek-v4.1-flash", "ali/qwen3.8-flash", "cbcn/glm-5.3-flash"],
    "fable": ["cbcn/glm-5.3-flash", "ali/qwen3.8-flash", "cb/deepseek-v4.1-flash"],
}



def _doc(path: Path | None) -> dict:
    path = path or DEFAULT_FALLBACKS
    if yaml is None or not path.is_file():
        return {}
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def ckff_enabled(path: Path | None = None, env=None) -> bool:
    """The one CKFF switch (provider_switch.py): LITELLM_ENABLE_CKFF, then providers.yaml."""
    if path is None:
        return provider_switch.ckff_enabled(env)
    return provider_switch.ckff_enabled(env, path)


def is_ckff_id(route: str) -> bool:
    """A CKFF route id or name. InferHub ids (cb/, cx/, ali/, ...) never match, Astra included."""
    return "ckff" in (route or "").lower()


is_ckff_deployment = provider_switch.is_ckff_deployment


def normalize_chain(chain) -> list[str]:
    """Strings only, no blanks, no repeats, no CKFF routes, order kept."""
    out = []
    for c in chain or []:
        c = str(c or "").strip()
        if not c or c in out:
            continue
        if is_ckff_id(c):
            print(f"warning: dropped CKFF route {c} from a slot chain (CKFF is never used)", file=sys.stderr)
            continue
        out.append(c)
    return out


def default_slots(path: Path | None = None) -> dict:
    spec = _doc(path).get("slots") or {}
    out = {}
    for s in SLOTS:
        chain = normalize_chain((spec.get(s) or {}).get("chain") if isinstance(spec.get(s), dict) else spec.get(s))
        out[s] = chain or list(BUILTIN_DEFAULTS[s])
    return out


def parse_slot_arg(text: str) -> tuple[str, list[str]]:
    """'sonnet=a,b,c' -> ('sonnet', ['a', 'b', 'c'])."""
    name, _, ids = (text or "").partition("=")
    name = name.strip().lower()
    if name not in SLOTS:
        raise ValueError(f"unknown slot {name!r} (want one of {', '.join(SLOTS)})")
    return name, normalize_chain(ids.split(","))


def resolve_slots(seat: dict | None, overrides: dict | None = None, path: Path | None = None) -> dict:
    """The chain for every slot: overrides, then the seat file's "slots", then the defaults."""
    out = default_slots(path)
    saved = (seat or {}).get("slots") if isinstance(seat, dict) else None
    if isinstance(saved, dict):
        for s in SLOTS:
            chain = normalize_chain(saved.get(s))
            if chain:
                out[s] = chain
    for s, chain in (overrides or {}).items():
        chain = normalize_chain(chain)
        if s in SLOTS and chain:
            out[s] = chain
    return out


def slot_names(slot: str, ckff_on: bool) -> list[str]:
    names = list(SLOT_NAMES[slot])
    if slot == "haiku" and not ckff_on:
        names += CKFF_OFF_HAIKU_EXTRA
    return names


def rung_name(slot: str, i: int) -> str:
    """Name of the i-th model (2, 3, ...) in *slot*'s chain."""
    return f"ccl-{slot}-{i}"


def all_slot_names(ckff_on: bool = False) -> dict:
    """{served name: slot} for every name the slots answer to."""
    return {n: s for s in SLOTS for n in slot_names(s, ckff_on)}


if __name__ == "__main__":
    # Print the CKFF switch for start-litellm.ps1 and the mac launcher: "ckff=on" / "ckff=off".
    print("ckff=on" if ckff_enabled() else "ckff=off")
