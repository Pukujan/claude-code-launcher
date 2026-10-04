"""The fast seat gets a max_tokens floor so reasoning models still answer."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "shared" / "litellm"))
import fast_min_tokens as fmt  # noqa: E402
sys.path.insert(0, str(ROOT / "shared" / "litellm" / "scripts"))


def test_fast_aliases_match_the_haiku_slot():
    import slots
    assert fmt.FAST_ALIASES == set(slots.slot_names("haiku", ckff_on=False))


def test_floor_raises_small_fast_requests_only():
    assert fmt.apply_floor({"model": "small-fast", "max_tokens": 512}, 4096)["max_tokens"] == 4096
    assert fmt.apply_floor({"model": "claude-haiku-5", "max_completion_tokens": 100}, 4096)["max_completion_tokens"] == 4096
    assert fmt.apply_floor({"model": "small-fast", "max_tokens": 8000}, 4096)["max_tokens"] == 8000
    assert fmt.apply_floor({"model": "claude-sonnet-5", "max_tokens": 512}, 4096)["max_tokens"] == 512
    assert fmt.apply_floor({"model": "small-fast", "max_tokens": 512}, 0)["max_tokens"] == 512
    assert "max_tokens" not in fmt.apply_floor({"model": "small-fast"}, 4096)


def test_floor_env():
    assert fmt.floor_from_env({}) == 4096
    assert fmt.floor_from_env({"CCL_FAST_MIN_MAX_TOKENS": "0"}) == 0
    assert fmt.floor_from_env({"CCL_FAST_MIN_MAX_TOKENS": "2048"}) == 2048
    assert fmt.floor_from_env({"CCL_FAST_MIN_MAX_TOKENS": "x"}) == 4096
