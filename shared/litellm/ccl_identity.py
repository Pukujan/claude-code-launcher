"""GET /ccl/identity: lets the launcher tell its own proxy from any other one (issue #61).

The proxy answers loopback callers with {"app": "claude-code-launcher", "instance": <id>},
where <id> is CCL_INSTANCE_ID (set from install.json by start-litellm.ps1 in packaged
mode, empty otherwise). A port whose server doesn't answer this way, or answers with
another instance, is not ours.
"""
APP = "claude-code-launcher"
IDENTITY_PATH = "/ccl/identity"
_LOOPBACK = {"127.0.0.1", "::1", "localhost", "::ffff:127.0.0.1"}


def identity_payload(env) -> dict:
    return {"app": APP, "instance": str(env.get("CCL_INSTANCE_ID") or "")}


def is_loopback(host) -> bool:
    return isinstance(host, str) and host in _LOOPBACK


def matches(payload, instance) -> bool:
    return (isinstance(payload, dict) and payload.get("app") == APP
            and str(payload.get("instance") or "") == str(instance or ""))
