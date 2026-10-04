# Current Repository Checkpoint

<!-- continuity:current {"active_task":"CCL-0002","active_task_file":"tasks/TASK-CCL-0002-self-contained-launcher.md","protocol_version":"0.1.0-draft","schema":"project-continuity.current.v1"} -->

This is an as-of projection; live GitHub issues own progression. Link the owning leaf, parent ancestry and dependencies for active work.

## Program state

Phase: launcher move.

## Completed

- continuity protocol initialized.
- **CCL-0001**: the agent stack is on `main` behind the required `gates` check ([issue #1](https://github.com/Pukujan/claude-code-launcher/issues/1), PR #2, merge `0357326`).

## Active

- **CCL-0002**: move the Windows and Mac launchers and the shared LiteLLM files here ([issue #3](https://github.com/Pukujan/claude-code-launcher/issues/3)).

## Queued

- Re-sync `windows/launch-claude-inferhub.ps1` from the PC after the pending fixes there.
- `shared/ire/` on-demand IRE fetch (CCL-0004, [issue #4](https://github.com/Pukujan/claude-code-launcher/issues/4); handed to a new worker on branch `task/CCL-0004-ire-fetch`).
- **CCL-0006**: fallback ladder picker for main and advisor, applied live ([issue #5](https://github.com/Pukujan/claude-code-launcher/issues/5), PR #12, merged).
- **CCL-0013**: cx primaries in Responses mode, hand-picked ladders, picking from the Top 20 or the frontier list ([issue #13](https://github.com/Pukujan/claude-code-launcher/issues/13)).

## Blockers

None known.

## Next atomic action

Open the pull request for CCL-0002 and read the CI result.
