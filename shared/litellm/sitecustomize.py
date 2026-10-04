"""Make non-latin-1 model ids survive Starlette response headers.

LiteLLM copies the upstream model id (e.g. "[官4][次] glm-5.2") into a response
header. Starlette encodes header values as latin-1, so a CJK id raises
UnicodeEncodeError and the request 500s *after* the upstream call has already
succeeded and been billed.

Python imports `sitecustomize` automatically at startup when it is on sys.path,
so this patches the class before LiteLLM ever builds a response. Only values
that would otherwise crash are touched; everything latin-1-safe is untouched.
"""
import starlette.datastructures as _sd


def _encodable(ch):
    try:
        ch.encode("latin-1")
        return True
    except UnicodeEncodeError:
        return False


def _latin1_safe(value):
    if not isinstance(value, str):
        return value
    try:
        value.encode("latin-1")
        return value
    except UnicodeEncodeError:
        # Escape rather than replace. "?" is lossy, and two ids that differ ONLY
        # in a CJK tag then collapse to the same header value - e.g. the
        # per-token "[官4][量] glm-5.2" and the per-request "[官4][次] glm-5.2"
        # both became "[?4][?] glm-5.2", so the response could not say which
        # model answered. \uXXXX stays latin-1 safe, readable, and reversible.
        return "".join(c if _encodable(c) else "\\u%04x" % ord(c) for c in value)


for _cls in (_sd.MutableHeaders,):
    _orig_setitem = _cls.__setitem__

    def _setitem(self, key, value, _o=_orig_setitem):
        return _o(self, key, _latin1_safe(value))

    _cls.__setitem__ = _setitem

    if hasattr(_cls, "append"):
        _orig_append = _cls.append

        def _append(self, key, value, _o=_orig_append):
            return _o(self, key, _latin1_safe(value))

        _cls.append = _append


# Streaming responses never touch MutableHeaders.__setitem__; they build raw
# headers directly in Response.init_headers:
#     raw_headers = [(k.lower().encode("latin-1"), v.encode("latin-1")) ...]
# so that path needs sanitising too or every CJK model 500s when stream=True.
import starlette.responses as _sr

_orig_init_headers = _sr.Response.init_headers


def _init_headers(self, headers=None, _o=_orig_init_headers):
    if headers:
        try:
            headers = {k: _latin1_safe(v) for k, v in headers.items()}
        except Exception:
            pass
    return _o(self, headers)


_sr.Response.init_headers = _init_headers

print("[sitecustomize] latin-1 header guard installed (headers + responses)", flush=True)


# LiteLLM's dashboard sidebar is a normal flex child at mobile widths. Its fixed
# 280px width leaves only a narrow strip for the page content, and the stock
# collapse control is then difficult to reach/use. Inject a small responsive
# override into the dashboard HTML. This is intentionally scoped to <=767px and
# does not alter the desktop layout.
_MOBILE_UI_PATCH = b"""
<style id="codex-mobile-sidebar-fix">
@media (max-width: 767px) {
  aside[data-slot=\"sidebar\"] {
    position: fixed !important;
    inset: 0 auto 0 0 !important;
    width: min(280px, calc(100vw - 48px)) !important;
    height: 100dvh !important;
    z-index: 50 !important;
    box-shadow: 8px 0 24px rgba(0, 0, 0, .18);
  }
  aside[data-slot=\"sidebar\"][data-collapsed=\"true\"] {
    width: 56px !important;
  }
  aside[data-slot=\"sidebar\"] + * {
    width: 100% !important;
    min-width: 0 !important;
  }
  main {
    width: 100% !important;
    min-width: 0 !important;
  }
  #codex-mobile-sidebar-toggle {
    position: fixed;
    top: 64px;
    left: 8px;
    z-index: 60;
    width: 40px;
    height: 40px;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--background);
    color: var(--foreground);
    box-shadow: 0 2px 10px rgba(0, 0, 0, .16);
    font-size: 20px;
    line-height: 1;
  }
  #codex-mobile-sidebar-toggle[hidden] {
    display: none;
  }
}
</style>
<script id="codex-mobile-sidebar-fix-script">
(() => {
  let initialized = false;
  const setup = () => {
    const sidebar = document.querySelector('aside[data-slot="sidebar"]');
    if (!sidebar) {
      setTimeout(setup, 100);
      return;
    }
    let toggle = document.getElementById('codex-mobile-sidebar-toggle');
    if (!toggle) {
      toggle = document.createElement('button');
      toggle.id = 'codex-mobile-sidebar-toggle';
      toggle.type = 'button';
      toggle.title = 'Open sidebar';
      toggle.setAttribute('aria-label', 'Open sidebar');
      toggle.textContent = String.fromCharCode(9776);
      document.body.appendChild(toggle);
      toggle.addEventListener('click', () => {
        const control = sidebar.querySelector(
          'button[aria-label="Collapse sidebar"], button[aria-label="Expand sidebar"]',
        );
        if (control) control.click();
        setTimeout(sync, 0);
      });
    }
    const sync = () => {
      const mobile = window.matchMedia('(max-width: 767px)').matches;
      const collapsed = sidebar.getAttribute('data-collapsed') === 'true';
      toggle.hidden = !mobile || !collapsed;
      toggle.title = collapsed ? 'Open sidebar' : 'Close sidebar';
      toggle.setAttribute('aria-label', collapsed ? 'Open sidebar' : 'Close sidebar');
    };
    if (!initialized) {
      initialized = true;
      if (window.matchMedia('(max-width: 767px)').matches &&
          sidebar.getAttribute('data-collapsed') !== 'true') {
        const collapse = sidebar.querySelector('button[aria-label="Collapse sidebar"]');
        if (collapse) collapse.click();
      }
    }
    sync();
    const observer = new MutationObserver(sync);
    observer.observe(sidebar, { attributes: true, attributeFilter: ['data-collapsed'] });
    window.addEventListener('resize', sync);
  };
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', setup);
  } else {
    setup();
  }
})();
</script>
"""

_orig_render = _sr.Response.render


def _render_with_mobile_ui(self, content, _o=_orig_render):
    rendered = _o(self, content)
    media_type = getattr(self, "media_type", "") or ""
    if "text/html" in media_type and isinstance(rendered, bytes):
        marker = b"</head>"
        if marker in rendered and b"codex-mobile-sidebar-fix" not in rendered:
            rendered = rendered.replace(marker, _MOBILE_UI_PATCH + marker, 1)
    return rendered


_sr.Response.render = _render_with_mobile_ui
print("[sitecustomize] mobile sidebar UI patch installed", flush=True)


# The dashboard itself is served by Starlette StaticFiles/FileResponse, so its
# HTML never passes through Response.render. Patch that path as well, buffering
# only .html responses long enough to add the same small mobile override.
_orig_file_call = _sr.FileResponse.__call__


async def _file_call_with_mobile_ui(self, scope, receive, send, _o=_orig_file_call):
    path = str(getattr(self, "path", "")).lower()
    if not path.endswith(".html"):
        return await _o(self, scope, receive, send)

    chunks = []
    start_message = None

    async def _send(message):
        nonlocal start_message
        if message.get("type") == "http.response.start":
            start_message = message
            return
        if message.get("type") != "http.response.body":
            return await send(message)
        chunks.append(message.get("body", b""))
        if message.get("more_body", False):
            return
        body = b"".join(chunks)
        marker = b"</head>"
        if marker in body and b"codex-mobile-sidebar-fix" not in body:
            body = body.replace(marker, _MOBILE_UI_PATCH + marker, 1)
        if start_message is not None:
            patched_start = dict(start_message)
            headers = []
            for key, value in patched_start.get("headers", []):
                if key.lower() != b"content-length":
                    headers.append((key, value))
            headers.append((b"content-length", str(len(body)).encode("ascii")))
            patched_start["headers"] = headers
            await send(patched_start)
        patched_body = dict(message)
        patched_body["body"] = body
        patched_body["more_body"] = False
        return await send(patched_body)

    return await _o(self, scope, receive, _send)


_sr.FileResponse.__call__ = _file_call_with_mobile_ui
print("[sitecustomize] static dashboard HTML patch installed", flush=True)


# Final response-level fallback: depending on the LiteLLM build, StaticFiles
# can be wrapped by middleware that bypasses the response class above. Wrapping
# the Starlette app send channel catches the dashboard HTML after all middleware
# while leaving JSON, JS, CSS, and model traffic untouched.
import starlette.applications as _sa

_orig_starlette_call = _sa.Starlette.__call__


async def _starlette_call_with_mobile_ui(self, scope, receive, send, _o=_orig_starlette_call):
    if scope.get("type") != "http" or not str(scope.get("path", "")).startswith("/ui"):
        return await _o(self, scope, receive, send)

    start_message = None
    patch_html = False
    chunks = []

    async def _send(message):
        nonlocal start_message, patch_html
        kind = message.get("type")
        if kind == "http.response.start":
            content_type = b""
            for key, value in message.get("headers", []):
                if key.lower() == b"content-type":
                    content_type = value.lower()
                    break
            patch_html = b"text/html" in content_type
            if not patch_html:
                return await send(message)
            start_message = message
            return
        if not patch_html or kind != "http.response.body":
            return await send(message)
        chunks.append(message.get("body", b""))
        if message.get("more_body", False):
            return
        body = b"".join(chunks)
        marker = b"</head>"
        if marker in body and b"codex-mobile-sidebar-fix" not in body:
            body = body.replace(marker, _MOBILE_UI_PATCH + marker, 1)
        if start_message is not None:
            patched_start = dict(start_message)
            headers = []
            for key, value in patched_start.get("headers", []):
                if key.lower() != b"content-length":
                    headers.append((key, value))
            headers.append((b"content-length", str(len(body)).encode("ascii")))
            patched_start["headers"] = headers
            await send(patched_start)
        patched_body = dict(message)
        patched_body["body"] = body
        patched_body["more_body"] = False
        return await send(patched_body)

    return await _o(self, scope, receive, _send)


_sa.Starlette.__call__ = _starlette_call_with_mobile_ui
print("[sitecustomize] app-level dashboard HTML patch installed", flush=True)
# ---------------------------------------------------------------------------
# InferHub / runtime hot-reload (issue #29)
# POST /workbench/reload_runtime
#   With a master key: Authorization: Bearer <LITELLM_MASTER_KEY> is required.
#   Keyless (no master key): only loopback callers (127.0.0.1 / ::1) are accepted.
# Body: {"scope":"seat"|"all"|"ladder"}  (default seat)
# - seat: upsert Claude seat aliases from config/inferhub_aliases.yaml
# - all:  replace router model_list from config/runtime.yaml
# - ladder: {"scope":"ladder","plan":{...}} applies launcher fallback ladders
#   via shared/ladder/proxy_apply.py; without "plan" it returns current state
# Keeps the :4000 listener up (in-process swap; no process kill).
# Requires PYTHONPATH to include the repo root so this sitecustomize loads.
# ---------------------------------------------------------------------------
import json as _json
import os as _os
from pathlib import Path as _Path

_RELOAD_PATH = "/workbench/reload_runtime"
_WB_SEAT_ALIASES = ("sonnet", "opus", "haiku", "main", "advisor", "claude-sonnet-5", "claude-opus-5-5", "claude-fable-5", "claude-fable-5-1")
_REPO_ROOT = _Path(__file__).resolve().parent


async def _wb_json_response(send, status: int, payload: dict):
    body = _json.dumps(payload).encode("utf-8")
    headers = [
        (b"content-type", b"application/json; charset=utf-8"),
        (b"content-length", str(len(body)).encode("ascii")),
        (b"cache-control", b"no-store"),
    ]
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": body, "more_body": False})


_LOOPBACK_HOSTS = {"127.0.0.1", "::1", "::ffff:127.0.0.1", "localhost"}


def _wb_is_loopback(host) -> bool:
    if not host or not isinstance(host, str):
        return False
    host = host.strip().strip("[]").lower()
    if host in _LOOPBACK_HOSTS:
        return True
    try:
        import ipaddress

        addr = ipaddress.ip_address(host)
        mapped = getattr(addr, "ipv4_mapped", None)
        return bool(addr.is_loopback or (mapped is not None and mapped.is_loopback))
    except ValueError:
        return False


def _wb_client_host(scope):
    client = scope.get("client")
    if isinstance(client, (list, tuple)) and client:
        return client[0]
    return None


def _wb_authorize(master, token, client_host):
    """Return None when the caller may reload, else (status, error message).

    - Master key configured: the bearer token must match it (any client).
    - No master key (keyless local proxy): only loopback clients are allowed.
    """
    if master:
        import hmac

        if token and hmac.compare_digest(str(token).encode("utf-8"), str(master).encode("utf-8")):
            return None
        return (401, "unauthorized")
    if _wb_is_loopback(client_host):
        return None
    return (403, "forbidden: keyless proxy only accepts reload from 127.0.0.1/::1")


def _wb_read_bearer(scope) -> str | None:
    for key, value in scope.get("headers") or []:
        if key.lower() == b"authorization":
            text = value.decode("latin-1", errors="ignore")
            if text.lower().startswith("bearer "):
                return text[7:].strip()
            return text.strip()
    return None


def _wb_resolve_secrets(params: dict) -> dict:
    out = dict(params)
    try:
        from litellm.secret_managers.main import get_secret
    except Exception:
        get_secret = None
    for k, v in list(out.items()):
        if isinstance(v, str) and v.startswith("os.environ/"):
            if get_secret is not None:
                try:
                    out[k] = get_secret(v)
                    continue
                except Exception:
                    pass
            env_name = v.split("/", 1)[1]
            out[k] = _os.environ.get(env_name)
    return out


def _wb_load_yaml_models(path: _Path) -> list:
    import yaml

    if not path.is_file():
        raise FileNotFoundError(str(path))
    doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    models = doc.get("model_list") or []
    if not isinstance(models, list):
        raise ValueError(f"model_list must be a list in {path}")
    return models


def _wb_upsert_models(llm_router, entries: list) -> dict:
    """Upsert deployments by model_name, reusing existing ids when present."""
    from litellm.types.router import Deployment, LiteLLM_Params, ModelInfo
    import copy

    updated = []
    aliases = {}
    for raw in entries:
        if not isinstance(raw, dict):
            continue
        entry = copy.deepcopy(raw)
        name = entry.get("model_name")
        params = entry.get("litellm_params") or {}
        info = dict(entry.get("model_info") or {})
        if not name or not isinstance(params, dict):
            continue
        params = _wb_resolve_secrets(params)
        existing_ids = []
        try:
            existing_ids = list(llm_router.get_model_ids(model_name=name) or [])
        except Exception:
            existing_ids = []
        keep_id = existing_ids[0] if existing_ids else None
        for extra in existing_ids[1:]:
            try:
                llm_router.delete_deployment(id=extra)
            except Exception as e:
                print(f"[sitecustomize] warn delete extra id {extra}: {e}", flush=True)
        if keep_id:
            info["id"] = keep_id
        deployment = Deployment(
            model_name=name,
            litellm_params=LiteLLM_Params(**params),
            model_info=ModelInfo(**info),
        )
        llm_router.upsert_deployment(deployment=deployment)
        updated.append(name)
        if name in _WB_SEAT_ALIASES:
            aliases[name] = params.get("model")
    return {"updated": len(updated), "names": updated, "aliases": aliases}


def _wb_reload_all(llm_router, path: _Path) -> dict:
    import copy

    models = _wb_load_yaml_models(path)
    prepared = []
    aliases = {}
    for raw in models:
        if not isinstance(raw, dict):
            continue
        entry = copy.deepcopy(raw)
        params = entry.get("litellm_params") or {}
        if isinstance(params, dict):
            entry["litellm_params"] = _wb_resolve_secrets(params)
            name = entry.get("model_name")
            if name in _WB_SEAT_ALIASES:
                aliases[name] = entry["litellm_params"].get("model")
        prepared.append(entry)
    llm_router.set_model_list(prepared)
    # Also hot-apply router fallbacks (e.g. generated InferHub seat fallbacks, issue #36).
    try:
        import yaml as _yaml

        _doc = _yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        _fb = (_doc.get("router_settings") or {}).get("fallbacks")
        if isinstance(_fb, list):
            llm_router.update_settings(fallbacks=_fb)
            print(f"[sitecustomize] reload_runtime fallbacks={len(_fb)}", flush=True)
        _rp = (_doc.get("router_settings") or {}).get("model_group_retry_policy")
        if isinstance(_rp, dict):
            from litellm.types.router import RetryPolicy as _RP

            llm_router.update_settings(model_group_retry_policy={k: _RP(**v) for k, v in _rp.items()})
            print(f"[sitecustomize] reload_runtime model_group_retry_policy={len(_rp)}", flush=True)
    except Exception as e:
        print(f"[sitecustomize] warn fallbacks reload: {e}", flush=True)
    return {
        "updated": len(prepared),
        "names": [m.get("model_name") for m in prepared if isinstance(m, dict)],
        "aliases": aliases,
    }


async def _wb_handle_reload(scope, receive, send):
    method = scope.get("method", "GET").upper()
    if method == "OPTIONS":
        return await _wb_json_response(send, 200, {"ok": True})
    if method != "POST":
        return await _wb_json_response(send, 405, {"error": "POST required"})

    body = b""
    while True:
        message = await receive()
        if message.get("type") != "http.request":
            continue
        body += message.get("body") or b""
        if not message.get("more_body"):
            break

    token = _wb_read_bearer(scope)
    try:
        from litellm.proxy import proxy_server as ps
    except Exception as e:
        return await _wb_json_response(send, 500, {"error": f"proxy_server import failed: {e}"})

    master = getattr(ps, "master_key", None)
    denied = _wb_authorize(master, token, _wb_client_host(scope))
    if denied is not None:
        return await _wb_json_response(send, denied[0], {"error": denied[1]})

    llm_router = getattr(ps, "llm_router", None)
    if llm_router is None:
        return await _wb_json_response(send, 503, {"error": "llm_router not ready"})

    scope_name = "seat"
    config_path = None
    payload = {}
    if body:
        try:
            payload = _json.loads(body.decode("utf-8"))
            if isinstance(payload, dict):
                scope_name = str(payload.get("scope") or "seat").lower()
                config_path = payload.get("config_path") or payload.get("path")
        except Exception:
            pass

    if scope_name == "ladder":
        # Fallback ladders picked in the launcher (shared/ladder, issue #5).
        # Partial in-memory update: rung deployments, seat fallbacks, retry
        # policy, cooldown. Seat alias targets are never changed. Without
        # "plan" it only reports the current state.
        try:
            import sys as _sys

            _ladder_dir = str(_REPO_ROOT.parent / "ladder")
            if _ladder_dir not in _sys.path:
                _sys.path.insert(0, _ladder_dir)
            import proxy_apply as _pa

            plan = payload.get("plan") if isinstance(payload, dict) else None
            result = _pa.apply_plan(llm_router, plan) if plan else {"ok": True}
            result["state"] = _pa.read_state(llm_router)
            if plan:
                print(f"[sitecustomize] reload_runtime scope=ladder seats={plan.get('seats')}", flush=True)
            return await _wb_json_response(send, 200, _json.loads(_json.dumps(result, default=str)))
        except Exception as e:
            print(f"[sitecustomize] reload_runtime ladder failed: {e}", flush=True)
            return await _wb_json_response(send, 500, {"error": f"{type(e).__name__}: {e}"})

    try:
        if scope_name == "all":
            path = _Path(config_path) if config_path else (_REPO_ROOT / "config" / "runtime.yaml")
            result = _wb_reload_all(llm_router, path)
        else:
            path = _Path(config_path) if config_path else (_REPO_ROOT / "config" / "inferhub_aliases.yaml")
            entries = _wb_load_yaml_models(path)
            result = _wb_upsert_models(llm_router, entries)

        try:
            ps.llm_model_list = llm_router.get_model_list()
        except Exception as e:
            print(f"[sitecustomize] warn llm_model_list sync: {e}", flush=True)
        try:
            if getattr(ps, "proxy_config", None) is not None and path.is_file() and scope_name == "all":
                import yaml

                ps.proxy_config.update_config_state(yaml.safe_load(path.read_text(encoding="utf-8")) or {})
        except Exception as e:
            print(f"[sitecustomize] warn config state sync: {e}", flush=True)

        print(
            f"[sitecustomize] reload_runtime scope={scope_name} updated={result.get('updated')} "
            f"aliases={result.get('aliases')}",
            flush=True,
        )
        return await _wb_json_response(
            send,
            200,
            {
                "ok": True,
                "scope": scope_name,
                "path": str(path),
                "updated": result.get("updated"),
                "aliases": result.get("aliases") or {},
            },
        )
    except FileNotFoundError as e:
        return await _wb_json_response(send, 404, {"error": f"config not found: {e}"})
    except Exception as e:
        print(f"[sitecustomize] reload_runtime failed: {e}", flush=True)
        return await _wb_json_response(send, 500, {"error": str(e)})


_prev_starlette_call = _sa.Starlette.__call__


_bench_hook = {"tried": False}


def _install_bench_hook():
    # Bench a seat or rung once it has used up its retries (see bench_after_retries.py:
    # on the proxy LiteLLM counts all retries of one request as a single failure, so
    # allowed_fails alone never benches it). Lazy, once, never fatal.
    if _bench_hook["tried"]:
        return
    _bench_hook["tried"] = True
    try:
        import sys as _sys

        if str(_REPO_ROOT) not in _sys.path:
            _sys.path.insert(0, str(_REPO_ROOT))
        import bench_after_retries as _bar

        _bar.install()
    except Exception as e:
        print(f"[sitecustomize] bench-after-retries hook not installed: {e}", flush=True)
    # Claude Code's WebSearch gets real results (see web_search.py).
    try:
        import web_search as _ws

        _ws.install()
    except Exception as e:
        print(f"[sitecustomize] web search hook not installed: {e}", flush=True)
    # WebFetch summaries on reasoning models: room to think and still answer.
    try:
        import fast_min_tokens as _fmt

        _fmt.install()
    except Exception as e:
        print(f"[sitecustomize] fast seat max_tokens floor not installed: {e}", flush=True)


async def _starlette_call_with_reload(self, scope, receive, send, _o=_prev_starlette_call):
    if scope.get("type") == "http" and not _bench_hook["tried"]:
        _install_bench_hook()
    if scope.get("type") == "http" and str(scope.get("path", "")) == _RELOAD_PATH:
        return await _wb_handle_reload(scope, receive, send)
    return await _o(self, scope, receive, send)


_sa.Starlette.__call__ = _starlette_call_with_reload
print("[sitecustomize] /workbench/reload_runtime hot-reload endpoint installed", flush=True)
