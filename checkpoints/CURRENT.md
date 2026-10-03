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
- `shared/ire/` on-demand IRE fetch and the fallback ladder picker (another worker; see `docs/HOOKS.md`).

## Blockers

None known.

## Next atomic action

Open the pull request for CCL-0002 and read the CI result.
