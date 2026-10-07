# TASK CCL-0078: The launcher names the platform it is running on

<!-- continuity:task {"acceptance":["The startup banner names the platform actually running: 'macOS' on Darwin, 'Linux' on Linux, and uname -s for anything else.","No user-visible string hardcodes macOS off Darwin, including the need_curl failure message and the file's own header comment.","The non-interactive path is unchanged: --non-interactive and --print-env still return before the banner, so Paseo and the env bridge print nothing new.","unit_tests.sh covers the label on both platforms and asserts no banner line hardcodes macOS; shellcheck stays clean and the body stays bash 3.2 compatible."],"depends_on":[],"goal":"Stop the shared launcher body from announcing itself as macOS when linux/launch-claude-inferhub.sh runs it on Linux, by deriving the on-screen platform label from uname -s.","id":"CCL-0078","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/94","next_action":"Push the branch, open the #94 pull request with auto-merge, and verify the required checks.","owner":"Alex; executor agent implements","priority":"P3","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"active","why":"The banner in main() and the need_curl() failure message both hardcode 'macOS', a leftover from when this body was the macOS-only launcher. linux/ reuses the body verbatim, so a Linux user's first line reads 'Launch Claude InferHub (macOS)', and the same string is written to the launcher log. The body already branches on uname -s for the XDG directories, so the platform is known; it was simply never used for the label."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P3
- Depends on: none
- Leaf issue: [#94](https://github.com/Pukujan/claude-code-launcher/issues/94); parent: none
- Primary writer: executor-claude-code-launcher; branch `ccl-0094-platform-label`

## Owning issue

- Issue [#94](https://github.com/Pukujan/claude-code-launcher/issues/94). Reported from use:
  `claude-acs` on Linux printed `=== Launch Claude InferHub (macOS) ... ===`.

## Write set

- `mac/Launch Claude InferHub.command` — add `OS_LABEL` next to `OS_NAME`; use it in the banner
  and in `need_curl()`; correct the header comment, which still described the body as macOS-only.
- `mac/tests/unit_tests.sh` — a "platform label (issue #94)" section.
- `checkpoints/CURRENT.md`, this task file.

## Acceptance criteria

- [ ] The banner reads `(macOS)` on Darwin and `(Linux)` on Linux.
- [ ] `need_curl()` names the running platform instead of calling every machine a Mac.
- [ ] The header comment no longer claims the body is macOS-only.
- [ ] `unit_tests.sh` asserts the label, the interpolation, and the absence of a hardcoded banner.
- [ ] shellcheck clean; bash 3.2 compatible; dry run unaffected.

## What to touch, and what not to

Only the label. The other `macos/` mentions stay: the legacy `macos/` shim variable names, the
bash 3.2 note, and the Homebrew / node-tarball branches are genuinely about macOS or about the
old `macos/` directory. Renaming or relocating `mac/Launch Claude InferHub.command` is out of
scope — lifting the shared body into `shared/` is a separate proposal already noted in the
Linux entry point's header.

## Verification

```bash
bash mac/tests/unit_tests.sh            # new section passes; one pre-existing ultracode failure
uv tool run --from shellcheck-py shellcheck -s bash -x "mac/Launch Claude InferHub.command" mac/tests/*.sh
bash mac/tests/dry_run.sh 4104          # end to end on a test port, never 4000
CLAUDE_IH_SETUP_ONLY=1 script -qec "bash 'mac/Launch Claude InferHub.command'" /dev/null | head -1
```

The last command prints the real banner; it must say Linux on Linux.

## Log

- 2026-10-07: filed #94; added `OS_LABEL` (Darwin -> macOS, else `uname -s`), pointed the banner
  and `need_curl()` at it, corrected the header comment, added 7 unit assertions.
- 2026-10-07: verified — banner and log both print `(Linux)`; shellcheck clean; unit tests 113
  passed with only the pre-existing ultracode arrow-pick failure; ruff clean; pytest 373 passed.
