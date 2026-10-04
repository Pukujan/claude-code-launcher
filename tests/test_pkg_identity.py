"""/ccl/identity payload (spec: Port choice and "is it ours")."""
import pytest
from hypothesis import given
from hypothesis import strategies as st

import ccl_identity as ci


@pytest.mark.spec
def test_payload_names_the_app_and_instance():
    assert ci.identity_payload({"CCL_INSTANCE_ID": "ab" * 16}) == {"app": "claude-code-launcher", "instance": "ab" * 16}


@pytest.mark.spec
def test_payload_without_instance():
    assert ci.identity_payload({}) == {"app": "claude-code-launcher", "instance": ""}


@pytest.mark.spec
def test_path_constant():
    assert ci.IDENTITY_PATH == "/ccl/identity"


@pytest.mark.spec
@pytest.mark.parametrize("host,ok", [("127.0.0.1", True), ("::1", True), ("localhost", True),
                                     ("10.0.0.5", False), ("192.168.1.2", False), (None, False)])
def test_loopback_only(host, ok):
    assert ci.is_loopback(host) is ok


@pytest.mark.property
@given(st.text(alphabet="0123456789abcdef", min_size=0, max_size=32), st.text(max_size=12))
def test_matches_only_our_instance(instance, other):
    p = ci.identity_payload({"CCL_INSTANCE_ID": instance})
    assert ci.matches(p, instance)
    if other != instance:
        assert not ci.matches(p, other)
    assert not ci.matches({"app": "litellm", "instance": instance}, instance)
    assert not ci.matches(None, instance)
