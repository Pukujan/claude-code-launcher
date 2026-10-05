# TASK CCL-0063: Windows installer v1.0.1 fixes

<!-- continuity:task {"acceptance": ["the claude-inferhub shim is pure ASCII and finds its install folder from %~dp0, and a real cmd.exe run from a non-ASCII install folder works on windows-latest", "-Uninstall without install.json still unsyncs settings, removes the planner and our secrets, and keeps a folder it can't prove it made", "-StartPort accepts 1-65535 and Select-CclPort never goes outside it", "empty and whitespace-only settings.json are both treated as {}; a read-only settings.json is left untouched with a message and a nonzero helper exit", "ccl_identity.is_loopback accepts 127.0.0.0/8, ::1 and v4-mapped loopback", "red tests before the fixes; CI and gates (with hotload_check) pass; v1.0.1-windows is released with install.ps1 and marked latest"], "depends_on": ["CCL-0061"], "goal": "Fix the six holdout defects in the Windows installer and release v1.0.1-windows.", "id": "CCL-0063", "issue_url": "https://github.com/Pukujan/claude-code-launcher/issues/63", "next_action": "Update docs/specs/windows-package.md for the six defects, then commit red tests.", "owner": "Alex; executor agent implements", "priority": "P1", "protocol_version": "0.1.0-draft", "schema": "project-continuity.task.v1", "status": "active", "why": "The owner's hidden holdout run found six defects in v1.0.0-windows, one of them (non-ASCII profile paths) breaking the command outright."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P1
- Depends on: CCL-0061
- Leaf issue: [#63](https://github.com/Pukujan/claude-code-launcher/issues/63); parent: none (refs #61)
- Primary writer: executor-claude-code-launcher; branch `ccl-0063-windows-v101`

## Owning issue

- Issue [#63](https://github.com/Pukujan/claude-code-launcher/issues/63), refs #61. Branch `ccl-0063-windows-v101`.

## Write set

- `windows/install.ps1`, `shared/claude/settings_sync.py`, `shared/litellm/ccl_identity.py`
- `docs/specs/windows-package.md`, `windows/README-friend.md`, `README.md`
- `tests/`, `.github/workflows/launcher-ci.yml`, `tasks/`, `checkpoints/CURRENT.md`, `.coord/`

## Checkpoint log

- 2026-10-04 8:10 PM ET: issue #63 opened, claim taken in `.coord`.
