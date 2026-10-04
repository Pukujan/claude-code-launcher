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

## Active

- **CCL-0003**: fold `macos/` into one `mac/` launcher, fix and require the bash 3.2 check, re-sync shared/litellm to litellm-ckff-ops `de69e68` ([issue #11](https://github.com/Pukujan/claude-code-launcher/issues/11)).

## Queued

- Re-sync `windows/launch-claude-inferhub.ps1` from the PC after the pending fixes there.
- Fallback ladder picker (issue #5, another worker; see `docs/HOOKS.md`).
- Windows picker on the live IRE table; cx frontier routes over `/v1/responses`.

## Blockers

None known.

## Next atomic action

Open the pull request for CCL-0003, make `bash 3.2 compatibility` a required check, and read the CI result.
