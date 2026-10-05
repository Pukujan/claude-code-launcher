"""GET /ccl/identity: lets the launcher tell its own proxy from any other one (issue #61).

The proxy answers loopback callers with {"app": "claude-code-launcher", "instance": <id>},
where <id> is CCL_INSTANCE_ID (set from install.json by start-litellm.ps1 in packaged
mode, empty otherwise). A port whose server doesn't answer this way, or answers with
another instance, is not ours.
"""
import ipaddress

APP = "claude-code-launcher"
IDENTITY_PATH = "/ccl/identity"


def identity_payload(env) -> dict:
    return {"app": APP, "instance": str(env.get("CCL_INSTANCE_ID") or "")}


def is_loopback(host) -> bool:
    """True for any address in 127.0.0.0/8, ::1, either written v4-mapped (::ffff:127.x.y.z),
    in brackets or with an IPv6 zone, and for "localhost". False for anything else."""
    if not isinstance(host, str):
        return False
    h = host.strip()
    if h.startswith("[") and h.endswith("]"):
        h = h[1:-1]
    if h.lower() == "localhost":
        return True
    h = h.split("%", 1)[0]
    try:
        ip = ipaddress.ip_address(h)
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return ip.is_loopback


def matches(payload, instance) -> bool:
    return (isinstance(payload, dict) and payload.get("app") == APP
            and str(payload.get("instance") or "") == str(instance or ""))
