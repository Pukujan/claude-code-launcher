#!/usr/bin/env python3
"""Install, remove or check the launcher's planner sub-agent (issue #53).

What it manages, both under the Claude Code config folder (~/.claude, or
CLAUDE_CONFIG_DIR, or --claude-dir):
  agents/planner.md   the read-only planner sub-agent (model: opus), copied from
                      shared/claude/agents/planner.md
  CLAUDE.md           one block between these markers, telling Claude to hand
                      planning to a sub-agent on opus:
                        <!-- claude-code-launcher:planner:start -->
                        <!-- claude-code-launcher:planner:end -->
                      Everything outside the markers is left exactly as it was.

install is idempotent (it rewrites only what differs) and never touches a
planner.md that someone else wrote: the launcher's copy carries a marker line,
and a file without it is left alone with a warning. uninstall removes the
launcher's planner.md and the CLAUDE.md block, and nothing else. status prints
one line per item. Nothing here sets a plan mode or changes settings.json.

  python install_planner.py install|uninstall|status [--claude-dir DIR]
Exit codes: 0 ok, 1 something could not be written, 2 bad arguments.
Standard library only.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
AGENT_SRC = HERE / "agents" / "planner.md"
BLOCK_SRC = HERE / "claude-md-planning.md"
START = "<!-- claude-code-launcher:planner:start -->"
END = "<!-- claude-code-launcher:planner:end -->"
OWNER = "<!-- installed by claude-code-launcher (install_planner.py); edits are overwritten -->"


def claude_dir(arg: str | None, env=None) -> Path:
    env = os.environ if env is None else env
    if arg:
        return Path(arg)
    if env.get("CLAUDE_CONFIG_DIR"):
        return Path(env["CLAUDE_CONFIG_DIR"])
    return Path.home() / ".claude"


def agent_text() -> str:
    """planner.md with the owner marker right after the front matter."""
    src = AGENT_SRC.read_text(encoding="utf-8")
    head, sep, body = src.partition("\n---\n")
    if not sep:  # no front matter end found; keep the file as is
        return src.rstrip("\n") + "\n\n" + OWNER + "\n"
    return head + sep + "\n" + OWNER + "\n" + body.lstrip("\n")


def block_text() -> str:
    return START + "\n" + BLOCK_SRC.read_text(encoding="utf-8").strip() + "\n" + END


_CRLF: set = set()


def _read(p: Path) -> str | None:
    try:
        raw = p.read_bytes()
    except FileNotFoundError:
        return None
    if b"\r\n" in raw:
        _CRLF.add(str(p))  # written back with the same line endings
    return raw.decode("utf-8-sig").replace("\r\n", "\n")


def _write(p: Path, text: str) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(p.name + ".ccl-tmp")
    tmp.write_text(text, encoding="utf-8", newline="\r\n" if str(p) in _CRLF else "\n")
    os.replace(tmp, p)


def split_block(text: str) -> tuple[str, str | None, str]:
    """(before, block or None, after) for the managed block in CLAUDE.md text."""
    i = text.find(START)
    if i < 0:
        return text, None, ""
    j = text.find(END, i)
    if j < 0:  # a start without an end: treat the rest as the block
        return text[:i], text[i:], ""
    j += len(END)
    return text[:i], text[i:j], text[j:]


def with_block(text: str | None) -> str:
    text = text or ""
    before, old, after = split_block(text)
    if old is None:
        base = text.rstrip("\n")
        return (base + "\n\n" if base else "") + block_text() + "\n"
    return before + block_text() + after


def without_block(text: str) -> str:
    before, old, after = split_block(text)
    if old is None:
        return text
    before = before.rstrip("\n")
    after = after.lstrip("\n")
    if before and after:
        return before + "\n\n" + after
    return (before or after).rstrip("\n") + ("\n" if (before or after) else "")


def install(d: Path) -> list[str]:
    notes = []
    agent = d / "agents" / "planner.md"
    cur = _read(agent)
    want = agent_text()
    if cur is not None and OWNER not in cur:
        notes.append(f"kept {agent}: it was not written by the launcher (planner not updated)")
    elif cur != want:
        _write(agent, want)
        notes.append(f"{'updated' if cur else 'installed'} {agent}")
    else:
        notes.append(f"unchanged {agent}")
    md = d / "CLAUDE.md"
    cur = _read(md)
    want = with_block(cur)
    if cur != want:
        _write(md, want)
        notes.append(f"{'updated' if cur else 'created'} the planning block in {md}")
    else:
        notes.append(f"unchanged planning block in {md}")
    return notes


def uninstall(d: Path) -> list[str]:
    notes = []
    agent = d / "agents" / "planner.md"
    cur = _read(agent)
    if cur is None:
        notes.append(f"no {agent}")
    elif OWNER in cur:
        agent.unlink()
        notes.append(f"removed {agent}")
    else:
        notes.append(f"kept {agent}: it was not written by the launcher")
    md = d / "CLAUDE.md"
    cur = _read(md)
    if cur is not None and START in cur:
        new = without_block(cur)
        if new.strip():
            _write(md, new)
        else:
            md.unlink()  # the launcher created it and nothing else is in it
        notes.append(f"removed the planning block from {md}")
    else:
        notes.append(f"no planning block in {md}")
    return notes


def status(d: Path) -> list[str]:
    agent = d / "agents" / "planner.md"
    cur = _read(agent)
    a = ("missing" if cur is None else "current" if cur == agent_text()
         else "outdated" if OWNER in cur else "someone else's file")
    md = _read(d / "CLAUDE.md") or ""
    _, block, _ = split_block(md)
    b = "missing" if block is None else "current" if block == block_text() else "outdated"
    return [f"planner agent: {a} ({agent})", f"CLAUDE.md planning block: {b} ({d / 'CLAUDE.md'})"]


def main(argv=None) -> int:
    # Paths can hold any character (a non-ASCII install folder); never crash on a narrow console.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="backslashreplace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=("install", "uninstall", "status"))
    ap.add_argument("--claude-dir", default=None)
    ap.add_argument("--quiet", action="store_true", help="print only changes and warnings")
    a = ap.parse_args(argv)
    d = claude_dir(a.claude_dir)
    try:
        notes = {"install": install, "uninstall": uninstall, "status": status}[a.action](d)
    except OSError as e:
        print(f"install_planner: {e}", file=sys.stderr)
        return 1
    for n in notes:
        if not (a.quiet and n.startswith(("unchanged", "no "))):
            print(f"planner: {n}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
