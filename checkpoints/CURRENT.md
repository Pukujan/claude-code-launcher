# Current Repository Checkpoint

<!-- continuity:current {"active_task":"CCL-0003","active_task_file":"tasks/TASK-CCL-0003-one-mac-launcher.md","protocol_version":"0.1.0-draft","schema":"project-continuity.current.v1"} -->

This is an as-of projection; live GitHub issues own progression. Link the owning leaf, parent ancestry and dependencies for active work.

## Program state

Phase: one Mac launcher.

## Completed

- continuity protocol initialized.
- **CCL-0001**: the agent stack is on `main` behind the required `gates` check ([issue #1](https://github.com/Pukujan/claude-code-launcher/issues/1), PR #2, merge `0357326`).
- **CCL-0002**: both launchers and the shared LiteLLM files run from this repository ([issue #3](https://github.com/Pukujan/claude-code-launcher/issues/3), PR #8, merge `de5694a`).
- IRE fetch at launch, `shared/ire/` ([issue #4](https://github.com/Pukujan/claude-code-launcher/issues/4) work, PR #10, merge `2b49adf`; another worker).
- **CCL-0006**: fallback ladder picker for main and advisor, applied live ([issue #5](https://github.com/Pukujan/claude-code-launcher/issues/5), PR #12).
- **CCL-0013**: cx primaries in Responses mode, hand-picked ladders, picking from the Top 20 or the frontier list ([issue #13](https://github.com/Pukujan/claude-code-launcher/issues/13), PR #14).

## Active

- **CCL-0003**: fold `macos/` into one `mac/` launcher, fix and require the bash 3.2 check, re-sync shared/litellm to litellm-ckff-ops `de69e68` ([issue #11](https://github.com/Pukujan/claude-code-launcher/issues/11)).

## Queued

- Re-sync `windows/launch-claude-inferhub.ps1` from the PC after the pending fixes there.
- Windows picker on the live IRE table.

## Blockers

None known.

## Next atomic action

Merge PR #15 for CCL-0003 once its required checks (now including `bash 3.2 compatibility`) are green, then close issue #11.
