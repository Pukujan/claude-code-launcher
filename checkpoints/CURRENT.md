# Current Repository Checkpoint

<!-- continuity:current {"active_task":null,"active_task_file":null,"protocol_version":"0.1.0-draft","schema":"project-continuity.current.v1"} -->

This is an as-of projection; live GitHub issues own progression. Link the owning leaf, parent ancestry and dependencies for active work.

## Program state

Phase: every merged increment through CCL-0083 is reconciled in this projection. The owner's provider-route policy is delivered: IRE fixed its thin-supply selector at the source (IRE #111, `d7014326`, #110 closed), PR #117 landed the regenerated five built-in tables as `91f4d98`, and #113 is closed as completed from the merged state. Issue #115 (the nightly refresh cannot open its own PR, and cannot update hand-written test expectations either) waits on the owner's choice between enabling the Actions setting and switching to a PAT; issues #53 and #41 are owner/human-blocked.

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
- **CCL-0079**: built-in model routes now match IRE's pinned data, Linux/macOS model pickers show 20 Top 20 and 20 frontier routes, and the Linux picker preserves the user's CB DeepSeek choice ([issue #96](https://github.com/Pukujan/claude-code-launcher/issues/96), PRs #97/#98/#99, merges `7891c11`/`d67e0c9`/`5070ced`; all six required checks passed on PR #99). Issue #96 is CLOSED. A later source refresh is tracked separately under #107.
- **CCL-0080**: the port 4000 house rule read "Never connect to, restart, stop or bind `127.0.0.1:4000`", which an agent followed literally and so refused to probe the live proxy, reporting routing as unproven. The rule now forbids changing 4000, keeps read-only probing allowed, and names the copy-proxy-then-merge path, in `AGENTS.md`, `PROJECT.md` and `README.md`. Merged with all six required checks passing ([issue #102](https://github.com/Pukujan/claude-code-launcher/issues/102), PR #105, merge `081970f`).
- **CCL-0078**: the shared launcher body names the platform it is actually running on. `OS_LABEL` (Darwin -> `macOS`, else `uname -s`) feeds the startup banner and the `need_curl()` failure message, so a Linux user no longer reads `(macOS)` in the first line or the launcher log. Merged with all six required checks and the supplemental `windows-installer` check passing ([issue #94](https://github.com/Pukujan/claude-code-launcher/issues/94), PR #95, merge `5665284`).
- **CCL-0081**: regenerated the four built-in Top 20 tables and the Windows offline frontier fallback from pinned IRE commit `c80166a2`, and routed Windows picker defaults, including CKFF-only saved slots, to IRE's current route for the same model family when provider prefixes change. Merged with all six required checks and the supplemental `windows-installer` check passing ([issue #107](https://github.com/Pukujan/claude-code-launcher/issues/107), PR #108, merge `6130d2d`).
- **CCL-0082**: when a slot's first model stays silent, the [CC] stream is held and the next rung is raced on the same prompt; the quiet model is benched with a doubling delay and leads again on a later real call. Merged as `3c7d973` ([issue #109](https://github.com/Pukujan/claude-code-launcher/issues/109), PR #110), and the replay busy-loop follow-up from #111 merged as `2faf4a0` ([PR #112](https://github.com/Pukujan/claude-code-launcher/pull/112)); all six required checks passed on both. Thresholds stay the proposed starting values and the live proxy on port 4000 was not touched.
- **CCL-0083**: delivered the owner's provider-route policy (cb/cbcn for GLM, ali/alicn for
  Qwen Flash/Max) by propagating IRE's post-fix route lists into the five built-in tables.
  The original pinning design was superseded on 2026-10-10 after IRE merged its selector
  fix (IRE #111, `d7014326`; #110 closed) and its regenerated list proved policy-conformant
  for all six families. The nightly run regenerated the tables and pushed them to
  `codex/ire-model-tables-refresh` (`c72c409`) but could not open a PR; PR #117 landed that
  branch with the aligned test expectations and merged as `91f4d98` with all six required
  checks passing (PR #114 carried the tables alone and failed `python-tests`; it is closed
  as superseded). Every GLM family leads with `cb/`/`cbcn/` and every Qwen family with
  `ali/`/`alicn/` at the merge commit; #113 closed as completed with the delivery receipt
  ([issue #113](https://github.com/Pukujan/claude-code-launcher/issues/113), request ID
  `e2577b25b5654984a66f33da8d1da988`).

## Queued

- None.

## Blockers

- None.

## Next atomic action

None for the launcher's own work; no task is active and the queue is empty. Three open
issues wait on the owner or the human operator, not on agent work:

- [#115](https://github.com/Pukujan/claude-code-launcher/issues/115): the nightly IRE refresh
  regenerates its branch but cannot open the pull request (repo Actions setting), and its
  `add-paths` cannot update the hand-written test expectations either. Needs the owner's
  choice between enabling the setting and switching to a scoped PAT.
- [#53](https://github.com/Pukujan/claude-code-launcher/issues/53): per-slot model picks with
  fallback chains. Needs the owner's slot-map / UltraCode decision.
- [#41](https://github.com/Pukujan/claude-code-launcher/issues/41): launcher sessions block
  Artifacts because a dummy `ANTHROPIC_API_KEY` overrides the [CL] login. Needs the human to
  run `/login` and confirm.
