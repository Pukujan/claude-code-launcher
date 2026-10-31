# Claude Code

<!-- acs:claude-bridge:start -->
## Claude Code: load the stack's rules

Other agents read `AGENTS.md` by themselves; Claude Code reads this file. The import below gives Claude the same rules every other agent follows. They bind here exactly as they do there.

@AGENTS.md

### GitHub is the authority

Live GitHub state decides scope, status and what is accepted: the issues, pull requests, checks and merged default branch of this repository. Read them with `gh` before you plan, resume or report, and work through them: a branch and a pull request, never a push to the default branch. Local files are projections and caches (checkpoints, `HANDOFF.md`, `.oio/`, `.content-system/`, `.coord/`, any clone under `~/.cache`). When one disagrees with GitHub, GitHub wins; say so on the owning issue.

The stack's rules live in [`Pukujan/agent-stack-train`](https://github.com/Pukujan/agent-stack-train) at commit `2e32f2c5ef01`, the certified release in its `stack-releases.json`. This repository still pins the four component repositories; until it moves to the one-checkout stack, read a stack file there, not from a local copy or one of the four frozen component repositories.

### Boot rules

CGM ALWAYS-ON WRITING RULE (every adopter that pins this helper)

Before you write ANY human-facing output — including HTML reports, compare HTML/UIs, appendable HTML, PR/issue/commit prose, docs, posts, papers, or other readable artifacts — you MUST load and apply [modules/human-sounding-writing/SKILL.md](https://github.com/Pukujan/agent-stack-train/blob/2e32f2c5ef010e784a28253e88e4aeeadf9cba5f/cgm/modules/human-sounding-writing/SKILL.md) (hsw).

This rule is always on. Opt-in is forbidden. Do not wait for a per-task, per-report, or per-HTML flag.

Exceptions (only these):
- README.md / product entry pages → load [modules/writing-direction/SKILL.md](https://github.com/Pukujan/agent-stack-train/blob/2e32f2c5ef010e784a28253e88e4aeeadf9cba5f/cgm/modules/writing-direction/SKILL.md) instead
- Human-facing research plans, architecture explanations, and evidence briefs → load [modules/writing-direction/SKILL.md](https://github.com/Pukujan/agent-stack-train/blob/2e32f2c5ef010e784a28253e88e4aeeadf9cba5f/cgm/modules/writing-direction/SKILL.md) (reader-facing explanation, not a manuscript or data writeup)
- Generated artifact filenames / asset-manifest paths / media basenames / filename legends → load [modules/human-output-naming/SKILL.md](https://github.com/Pukujan/agent-stack-train/blob/2e32f2c5ef010e784a28253e88e4aeeadf9cba5f/cgm/modules/human-output-naming/SKILL.md) (hon) for basenames; visible prose inside HTML still uses hsw

Marketing intro sites, sales sites, and technical demo pages are not one of those exceptions. Load [modules/writing-direction/SKILL.md](https://github.com/Pukujan/agent-stack-train/blob/2e32f2c5ef010e784a28253e88e4aeeadf9cba5f/cgm/modules/writing-direction/SKILL.md) and [modules/human-sounding-writing/SKILL.md](https://github.com/Pukujan/agent-stack-train/blob/2e32f2c5ef010e784a28253e88e4aeeadf9cba5f/cgm/modules/human-sounding-writing/SKILL.md) together, plus [modules/visual-direction/SKILL.md](https://github.com/Pukujan/agent-stack-train/blob/2e32f2c5ef010e784a28253e88e4aeeadf9cba5f/cgm/modules/visual-direction/SKILL.md), [modules/brand-foundation/SKILL.md](https://github.com/Pukujan/agent-stack-train/blob/2e32f2c5ef010e784a28253e88e4aeeadf9cba5f/cgm/modules/brand-foundation/SKILL.md), and [modules/html-demo/SKILL.md](https://github.com/Pukujan/agent-stack-train/blob/2e32f2c5ef010e784a28253e88e4aeeadf9cba5f/cgm/modules/html-demo/SKILL.md), and follow the marketing_intro_site review checklist. Product-entry bold stays one short scan anchor. The human-sounding tell scrub and the verified-number rule still apply. Words and pictures come from the brand feeling.

HTML reports, compare HTML, and compare UIs have NO skip path. An exception reason is not allowed for those surfaces.

If you cannot load the skill file from the pinned CGM checkout, stop and report that — do not draft jargon-heavy or tool-dump HTML instead.

Filenames: use [scripts/human_filename](https://github.com/Pukujan/agent-stack-train/blob/2e32f2c5ef010e784a28253e88e4aeeadf9cba5f/cgm/scripts/human_filename.py) (speakable basenames; optional safe_twin) and keep a per-feature legend. Hash may stay a separate manifest field.

Dev root hygiene (ACS): the dev root (ACS_DEV_ROOT; default D:\development on Windows, ~/development elsewhere) holds exactly one main checkout per repo. Never create git worktrees, dependency or sibling clones, scratch folders, or caches there. Put them under the ACS cache instead: %LOCALAPPDATA%\acs\{deps,scratch,worktrees} on Windows, ~/.cache/acs/{deps,scratch,worktrees} on macOS/Linux (ACS_CACHE_DIR overrides). Check with scripts/dev_root_check.py.
<!-- acs:claude-bridge:end -->
