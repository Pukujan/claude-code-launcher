"""Claude Code's search timeout in launcher sessions (issue #69).

Claude Code stops every ripgrep run (Grep and Glob) after CLAUDE_CODE_GLOB_TIMEOUT_SECONDS,
20 s by default. Cold scans of big folders on Windows take longer because Defender scans
each file on first touch, so the launchers hand Claude 120 s. A positive whole number the
user already set wins, and it must survive the launchers' CLAUDE_CODE_* sweep.

Uses the harness of test_noninteractive.py: the real launchers, a tiny health server on a
free port (never the live proxy) and a fake claude.
"""
import json

import pytest

from test_noninteractive import KINDS, base_env, box, health_port, run_launcher  # noqa: F401

GLOB = "CLAUDE_CODE_GLOB_TIMEOUT_SECONDS"


def plan(kind, box, port, **extra):
    out = run_launcher(kind, box, ["--non-interactive", "--print-env", "json"], base_env(box, port, FAKE_LOGIN="1", **extra))
    assert out.returncode == 0, out.stderr
    return json.loads(out.stdout.strip().splitlines()[-1])["set"]


@pytest.mark.parametrize("kind", KINDS)
def test_default_is_120_seconds(kind, box, health_port):
    assert plan(kind, box, health_port)[GLOB] == "120"


@pytest.mark.parametrize("kind", KINDS)
def test_a_user_value_survives_the_claude_code_sweep(kind, box, health_port):
    assert plan(kind, box, health_port, **{GLOB: "300"})[GLOB] == "300"


@pytest.mark.parametrize("kind", KINDS)
@pytest.mark.parametrize("bad", ["0", "-5", "abc", "1.5", ""])
def test_a_value_that_is_not_a_positive_whole_number_becomes_120(kind, bad, box, health_port):
    assert plan(kind, box, health_port, **{GLOB: bad})[GLOB] == "120"


@pytest.mark.parametrize("kind", KINDS)
def test_exec_hands_the_timeout_to_claude(kind, box, health_port):
    out = run_launcher(kind, box, ["--non-interactive", "--", "-p", "hi"], base_env(box, health_port, FAKE_LOGIN="1"))
    assert out.returncode == 0, out.stderr
    got = json.loads(out.stdout.strip().splitlines()[-1])
    assert got["env"][GLOB] == "120"
