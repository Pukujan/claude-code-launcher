# Current Repository Checkpoint

<!-- continuity:current {"active_task":null,"active_task_file":null,"protocol_version":"0.1.0-draft","schema":"project-continuity.current.v1"} -->

This is an as-of projection; live GitHub issues own progression. Link the owning leaf, parent ancestry and dependencies for active work.

## Program state

Phase: the launcher's built-in picker tables track IRE's current Top 20, and the launcher has a first-class Linux entry point and installer on `main`.

## Completed

- continuity protocol initialized.
- **CCL-0001**: the agent stack is on `main` behind the required `gates` check ([issue #1](https://github.com/Pukujan/claude-code-launcher/issues/1), PR #2, merge `0357326`).
- **CCL-0002**: both launchers and the shared LiteLLM files run from this repository ([issue #3](https://github.com/Pukujan/claude-code-launcher/issues/3), PR #8, merge `de5694a`).
- IRE fetch at launch, `shared/ire/` ([issue #4](https://github.com/Pukujan/claude-code-launcher/issues/4) work, PR #10, merge `2b49adf`; another worker).
- **CCL-0006**: fallback ladder picker for main and advisor, applied live ([issue #5](https://github.com/Pukujan/claude-code-launcher/issues/5), PR #12).
- **CCL-0013**: cx primaries in Responses mode, hand-picked ladders, picking from the Top 20 or the frontier list ([issue #13](https://github.com/Pukujan/claude-code-launcher/issues/13), PR #14).
- **CCL-0021**: bench a model after it uses up its retries ([issue #21](https://github.com/Pukujan/claude-code-launcher/issues/21)).
- **CCL-0061**: one-command Windows installer ([issue #61](https://github.com/Pukujan/claude-code-launcher/issues/61), PR #62, merge `1f046f7`, release `v1.0.0-windows`).
- **CCL-0063**: Windows installer v1.0.1: the six holdout fixes, one self-contained install folder (private tools, `CLAUDE_CONFIG_DIR` inside), poppler for PDF pages, #70's ripgrep limit kept ([issue #63](https://github.com/Pukujan/claude-code-launcher/issues/63), PR #66, release `v1.0.1-windows`).
- **CCL-0072**: Windows installer v1.0.2: uninstall never edits a Claude config it can't prove it wrote, cleanup works without `app\`, a user-set search timeout survives unsync ([issue #72](https://github.com/Pukujan/claude-code-launcher/issues/72)).
- **CCL-0064**: every launcher key from one gitignored `.env` in the launcher folder, the IRE and Desktop env files only as a fallback ([issue #64](https://github.com/Pukujan/claude-code-launcher/issues/64)).
- **CCL-0073**: the picker and the bundle show the cheapest well-supplied ask (rank-1 DeepSeek V4.1 Flash at 0.00015 in / 0.0006 out, not the 0.022 blend), the four built-in tables are refreshed to IRE's current Top 20, and an old list warns once it is past 7 days ([issue #76](https://github.com/Pukujan/claude-code-launcher/issues/76), PR #79, merge `c8e45b3`).
- **CCL-0074**: the launcher's vendored `sync_inferhub_top20.py` prices each generated `ih/` deployment from its best route's ask, writes both the input and output cost, and names the basis, so rank 1 comes out at 1.5e-10 in and 6e-10 out ([issue #80](https://github.com/Pukujan/claude-code-launcher/issues/80), PR #81, merge `a534be9`).
- **CCL-0075**: the four built-in picker tables are refreshed to IRE's current Top 20, so the offline fallback marks GPT 5.6 Luna not eligible, drops Gemini 3.8 Flash and Hy4 Preview, and adds the model 4.6 and Muse Spark 1.3 Contributor ([issue #84](https://github.com/Pukujan/claude-code-launcher/issues/84), PR #85, merge `288fa4e`).
- **CCL-0076**: a first-class Linux entry point and installer in a new `linux/` folder, so a Linux user gets the same one-command start without Docker. `linux/launch-claude-inferhub.sh` and `linux/stop-litellm.sh` are thin entries over the Linux-proven shared launcher body, and `linux/setup.sh` is a distro-aware, shell-rc-aware installer with `--check`/`--uninstall` ([issue #88](https://github.com/Pukujan/claude-code-launcher/issues/88), PR #89, merge `a903844`).
- `linux-dry-run` is a required status check on `main` (repository settings, 2026-10-07). The job already existed and passed; it is now enforced next to `gates`, `lint`, `mac-dry-run`, `python-tests` and `bash 3.2 compatibility`.
- **CCL-0077**: the shared launcher body gets the Windows launcher's model-slots step, so Mac and Linux can set all four [CC] slots (sonnet, opus, fable, haiku), each a first model and up to two fallbacks, instead of only sonnet's and fable's first models. Merged with `lint`, `gates`, `mac-dry-run`, `linux-dry-run`, `python-tests` and `bash 3.2 compatibility` all passing ([issue #91](https://github.com/Pukujan/claude-code-launcher/issues/91), PR #92, merge `82169e1`).

## Active

- None.

## Queued

- Re-sync `windows/launch-claude-inferhub.ps1` from the PC after the pending fixes there.

## Blockers

- None.

## Next atomic action

Re-sync `windows/launch-claude-inferhub.ps1` from the PC after the pending fixes there.
