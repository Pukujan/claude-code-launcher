# Current Repository Checkpoint

<!-- continuity:current {"active_task":"CCL-0061","active_task_file":"tasks/TASK-CCL-0061-windows-installer.md","protocol_version":"0.1.0-draft","schema":"project-continuity.current.v1"} -->

This is an as-of projection; live GitHub issues own progression. Link the owning leaf, parent ancestry and dependencies for active work.

## Program state

Phase: Windows installer for a friend.

## Completed

- continuity protocol initialized.
- **CCL-0001**: the agent stack is on `main` behind the required `gates` check ([issue #1](https://github.com/Pukujan/claude-code-launcher/issues/1), PR #2, merge `0357326`).
- **CCL-0002**: both launchers and the shared LiteLLM files run from this repository ([issue #3](https://github.com/Pukujan/claude-code-launcher/issues/3), PR #8, merge `de5694a`).
- IRE fetch at launch, `shared/ire/` ([issue #4](https://github.com/Pukujan/claude-code-launcher/issues/4) work, PR #10, merge `2b49adf`; another worker).
- **CCL-0006**: fallback ladder picker for main and advisor, applied live ([issue #5](https://github.com/Pukujan/claude-code-launcher/issues/5), PR #12).
- **CCL-0013**: cx primaries in Responses mode, hand-picked ladders, picking from the Top 20 or the frontier list ([issue #13](https://github.com/Pukujan/claude-code-launcher/issues/13), PR #14).
- **CCL-0021**: bench a model after it uses up its retries ([issue #21](https://github.com/Pukujan/claude-code-launcher/issues/21)).

## Active

- **CCL-0061**: one-command Windows installer so a friend needs only an InferHub key ([issue #61](https://github.com/Pukujan/claude-code-launcher/issues/61), branch `ccl-0061-windows-installer`, spec `docs/specs/windows-package.md`).

## Queued

- Re-sync `windows/launch-claude-inferhub.ps1` from the PC after the pending fixes there.
- Windows picker on the live IRE table.

## Blockers

None known.

## Next atomic action

PR #62 is green and set to auto-merge. After it merges, tag `v1.0.0-windows` on the merge commit, create the release with `install.ps1` attached, and close issue #61.
