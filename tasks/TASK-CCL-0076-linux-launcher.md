# TASK CCL-0076: Add a Linux launcher

<!-- continuity:task {"acceptance":["A linux/ folder holds a Linux launcher and a setup.sh that installs or repairs in one command, with --check and --uninstall, mirroring mac/.","The launcher starts the same shared/litellm proxy on 127.0.0.1:4000, keyless, and runs claude in a chosen folder with the same model table, seat script and environment as Windows and Mac.","The installer adds ~/.local/bin to PATH in the shell rc that actually exists (~/.bashrc, ~/.zshrc, or ~/.config/fish/config.fish), once, and does not assume zsh or Homebrew.","Bootstrap either works on the Debian/Ubuntu, Fedora and Arch families, or fails with a clear message naming exactly what to install.","No sudo. No secret committed. Tests never touch port 4000.","shellcheck is clean and a Linux dry run passes in CI under bash 5, next to the existing jobs.","windows/, mac/, shared/, the built-in model tables, the seat chains and the fallback chains are unchanged."],"depends_on":[],"goal":"Give the launcher a first-class Linux entry point and installer in a new linux/ folder, reusing the shared/ proxy files and the Linux-proven Mac launcher body, so a Linux user gets the same one-command start without Docker.","id":"CCL-0076","issue_url":"https://github.com/Pukujan/claude-code-launcher/issues/88","next_action":"Add the linux-dry-run CI job next to mac-dry-run, push the branch, and open the #88 pull request with auto-merge.","owner":"Alex; executor agent implements","priority":"P2","protocol_version":"0.1.0-draft","schema":"project-continuity.task.v1","status":"active","why":"The repository ships windows/ and mac/ launchers but no Linux entry point, so a Linux user has to read the Mac scripts and hand-run shared/litellm. mac/setup.sh also assumes macOS: it writes its PATH line into ~/.zshrc and its bootstrap assumes Homebrew and shasum. The Mac launcher body itself is already portable (it branches on uname -s for XDG paths and CI runs it on ubuntu-latest), so the gap is the installer and the entry point, not the launcher logic."} -->

- Status: active
- Owner: Alex; executor agent implements
- Priority: P2
- Depends on: none
- Leaf issue: [#88](https://github.com/Pukujan/claude-code-launcher/issues/88); parent: none
- Primary writer: executor-claude-code-launcher; branch `ccl-0076-linux-launcher`

## Owning issue

- Issue [#88](https://github.com/Pukujan/claude-code-launcher/issues/88). Parent: none.

## Write set

- `linux/launch-claude-inferhub.sh`, `linux/setup.sh`, `linux/stop-litellm.sh`, `linux/README.md`
- `.github/workflows/launcher-ci.yml` (a `linux-dry-run` job)
- `tasks/`, `checkpoints/CURRENT.md`

`shared/`, `windows/` and `mac/` are not touched.

## Acceptance criteria

- [ ] A `linux/` folder holds a Linux launcher and a `setup.sh` that installs or repairs in one command, with `--check` and `--uninstall`, mirroring `mac/`.
- [ ] The launcher starts the same `shared/litellm` proxy on `127.0.0.1:4000`, keyless, and runs `claude` in a chosen folder — same model table, seat script and environment as Windows and Mac.
- [ ] The installer adds `~/.local/bin` to PATH in the shell rc that actually exists (`~/.bashrc`, `~/.zshrc`, or `~/.config/fish/config.fish`), once, and does not assume zsh or Homebrew.
- [ ] Bootstrap either works on the Debian/Ubuntu, Fedora and Arch families, or fails with a clear message naming exactly what to install.
- [ ] No sudo. No secret committed. Tests never touch port 4000.
- [ ] `shellcheck` clean; a Linux dry run passes in CI under bash 5, next to the existing jobs.
- [ ] `windows/`, `mac/`, `shared/`, the built-in model tables, the seat chains and the fallback chains are unchanged.

## Boundaries

Out of scope: `shared/`, `windows/`, `mac/`, the built-in model tables, the seat
chains, the fallback chains, and any scheduled sync.

Follow-ups (proposals, not part of this change):

- Lift the shared launcher body into `shared/` so `mac/` and `linux/` are both
  thin entries. This touches `mac/`, so it needs its own review.
- Make `ensure_node` install Node on Linux (or drop the npm fallback there), so
  the [CC] install does not depend on Node already being present.
- A Docker or Podman image running the proxy (and optionally [CC]) for
  byte-for-byte replication across distributions. Own issue if wanted.

## Checkpoint log

- 2026-10-07: issue #88 opened. Branch `ccl-0076-linux-launcher` cut from `main`.
- 2026-10-07: `linux/` added — `launch-claude-inferhub.sh` and `stop-litellm.sh`
  as thin entries over the Linux-proven shared body, and `setup.sh` as a
  distro-aware, shell-rc-aware installer with `--check`/`--uninstall`.
