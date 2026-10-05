# TASK CCL-0072: Windows installer v1.0.2 fixes

<!-- continuity:task {"acceptance": ["-Uninstall of a folder without install.json cleans <folder>\\claude-config and leaves an outside Claude config byte-for-byte alone unless it carries proof the launcher wrote it (a settings-sync record or our modelPicker)", "a normal uninstall with the Claude config outside the folder cleans it even when app\\ was deleted, using logic built into install.ps1", "settings_sync unsync removes env.CLAUDE_CODE_GLOB_TIMEOUT_SECONDS only when our sync added it (tracked in .ccl-settings-sync.json), the same for \"120\" and 120, never drops a non-empty env, and sync()'s docstring names the key", "red tests before the fixes; CI and gates pass; v1.0.2-windows is released with install.ps1 and marked latest; the PC pulls main"], "depends_on": ["CCL-0063"], "goal": "Fix the three holdout defects found in v1.0.1-windows and release v1.0.2-windows.", "id": "CCL-0072", "issue_url": "https://github.com/Pukujan/claude-code-launcher/issues/72", "next_action": "After the PR merges and windows-installer is green: create the v1.0.2-windows release on the merge commit with install.ps1 attached and marked latest, check the download URLs, close issue #72, pull main on the PC.", "owner": "Alex; executor agent implements", "priority": "P2", "protocol_version": "0.1.0-draft", "schema": "project-continuity.task.v1", "status": "active", "why": "The owner's hidden holdout rerun on v1.0.1-windows found that uninstall could edit a Claude config it never wrote, skipped cleanup without app\\, and removed a search timeout the user set."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P2
- Depends on: CCL-0063
- Leaf issue: [#72](https://github.com/Pukujan/claude-code-launcher/issues/72); parent: none (refs #63)
- Primary writer: executor-claude-code-launcher; branch `ccl-0072-windows-v102`

## Owning issue

- Issue [#72](https://github.com/Pukujan/claude-code-launcher/issues/72), refs #63. Branch `ccl-0072-windows-v102`.

## Write set

- `windows/install.ps1`, `shared/claude/settings_sync.py`
- `docs/specs/windows-package.md`, `windows/README-friend.md`
- `tests/`, `tasks/`, `checkpoints/CURRENT.md`, `.coord/`

## Checkpoint log

- 2026-10-04 11:35 PM ET: issue #72 opened, claim taken in `.coord`.
- 2026-10-04 11:36 PM ET: red tests (`b940371`): pytest 13 failed, Pester 6 failed.
- 2026-10-04 11:45 PM ET: three fixes green (pytest 406, Pester 446); version 1.0.2-windows; spec and friend README updated. Claim released for merge.
