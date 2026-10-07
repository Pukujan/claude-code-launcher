# Agent Operating Contract

This repository holds the Claude Code launcher for Windows and Mac and the shared LiteLLM proxy files both of them run.

## House rules for this repository

- Every task gets a GitHub issue first, and every change lands through a pull request that links it. Never commit to `main`.
- Never print or commit secrets. Only `.env.example` is tracked.
- Never change `127.0.0.1:4000` — no restart, stop, bind, reload or config write. It is the live proxy, serving people. Probing it read-only is fine and expected. Make any change, test or fix on a copy proxy on another port, and merge to 4000 only once it is verified there.
- Do not change the seat or shim routing (`shared/litellm/scripts/apply_inferhub_seat.py`, `merge_litellm_config.py`, `config/inferhub_fallbacks.yaml`) without an issue that says so.

## Pinned stack (release train 2026-10-01)

- **PCM** `4e2385474b4af9249ca009cbdcb38c4498932475` (CLI 0.6.0, protocol 0.1.0-draft): continuity files, checkpoints, PR-only changes to `main`, required CI gates.
- **CGM** `6831f91e165b62d719c05eb492f7375fa932b560` (0.5.12, all eight modules). README and product entry use `writing-direction`; PRs, issues, docs and commits use `human-sounding-writing`; generated file names use `human-output-naming`.
- **OIO** 0.1.0 (`45053848942d39434e5a507f5dd6fc5922aa9034`): the observational-issue form and its triage workflow.
- **ACS** `multi-agent-hotload` 0.1.0 (`38f8f52e8d210db3ce258bf911ebb560c6e0fe4c`): join-order roles, a boss lease in minutes, the claim file in `.coord/`, and an agent-less watchdog.

## Roles and lease

- Join or continue order fills roles. The first live continuer is decision boss, then coder1, coder2 and so on.
- The decision-boss seat is a lease (default 30 minutes, range 15 to 120). Re-read `.coord/boss_claim.json` on every wake. A returning old boss joins the end of the queue.
- The watchdog only checks liveness. It is not failover and does not appoint a boss.

## Start

Read PROJECT → CURRENT → active TASK → minimum relevant spec before editing.

For GitHub repositories, verify the live linked issue with `continuity issue verify <TASK-ID>` before resuming; the issue owns task scope and lifecycle, merged default-branch history owns accepted code, and PR checks/merge records own delivery. Resolve discrepancies from the issue before editing.

When a GitHub issue reference appears in a pull-request description or commit message, use a supported issue-closing keyword only when merging should complete that issue. GitHub treats `close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, and `resolved` followed by an issue reference as a close directive; negation does not cancel it. For progress-only work, link with `Refs #<number>` or the GitHub sidebar. After each merge, verify the live issue state before changing task status. See [GitHub's issue-linking rules](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue).

<!-- pcm:github-progression:start -->
## GitHub-owned progression

GitHub Issues are required for PCM-governed project work and own task scope, acceptance, priority, ownership, dependencies, lifecycle and durable project progression. Merged default-branch history owns accepted code and normative/domain documents; PR checks and merge records own delivery facts. Checked-in PROJECT/CURRENT/TASK/checkpoint/handoff documents are mandatory versioned projections for task state, not a parallel authority. Local files, registries, context packs and chat are ephemeral execution aids. Domain-document ownership stays with the target project.

Every issue progress update MUST link the leaf child issue that owns the work, its parent ancestry and dependencies (or explicitly none). A top-level deliverable identifies itself as the leaf and says parent: none. Create one child per independently deliverable scope, never one per comment. Record task ID, primary writer and branch on the issue before creating its repository projection. Re-read live issues and relevant source revisions before resuming; the issue verifier checks identity/status, not semantic agreement.

Authorized owner/user direction can revise intent: record it on the owning GitHub issue with a correction/supersession link before dependent work. It cannot alter observed CI/merge facts or waive required gates. Stale projections yield to their field's authority. If direction, ownership or evidence conflicts remain unresolved, pause affected work and record uncertainty; continue independent safe work. One primary writer owns each task branch/checkpoint stream. Coordinate shared-document edits through linked issues/PRs, re-read the current base and reconcile concurrent changes; never force-push or overwrite another writer. Issue prose is not an atomic lock.

Label observed results, repository/external evidence, agent reports and inference separately. Preserve contradictory evidence with source/revision and mark conclusions disputed or unknown until resolved. Append correction/supersession evidence; never rewrite checkpoint history. An upstream correction MUST identify affected descendants and assumptions on their issues; pause, re-plan and revalidate dependent work before resuming. Follow explicit parent/dependency links within the affected scope; cycles or unknown lineage block affected claims. No graph database, local canonical ledger or autonomous polling agent is required.

Before every push, synchronize relevant docs and task/checkpoint projections, CURRENT/HANDOFF when affected, and reviewed catalog/generated index. Record leaf/parent/dependency links, source issue/comment revision, as-of status, evidence, blockers and next action. Commit product/docs first; `continuity checkpoint` then commits and synchronously pushes the checkpoint with a stable request ID. After every successful push, manually publish a leaf issue receipt keyed by request ID and exact pushed SHA, linking changed docs/checkpoint, PR, tests and pending gates; add a linked parent progression update. Retry a missing receipt without another checkpoint/push; inspect for the same key before posting. --receipt-repo and --receipt-issue are opt-in and still require a proven lookup; omit them and the receipt stays manual. Automatic issue-comment synchronization is not implemented; issue #67 is CLOSED (owner freeze decision 2026-09-25) and its unmet guaranteed-completion acceptance transferred to #110.

Required CI and GitHub auto-merge are mandatory. Arm auto-merge only after the increment's final push: a later push races the merge window and strands outside accepted history. Verify protection, required reviews/checks on the exact current-base or merge-queue candidate, and auto-merge; missing, failed, skipped, stale or unverified gates fail closed: no completion or cleanup. After CI/merge, append the exact check results, PR/merge SHA and live issue status to the leaf and link the parent update; fetch and verify accepted history. Reconcile material doc/status corrections in a new synchronized increment. Receipt-only transitions need no recursive doc commit: docs retain an explicit as-of/pending state and point to the live issue. Never label local-only or merely pushed work delivered. Preserve unsafe resources and keep incomplete issues open.
<!-- pcm:github-progression:end -->

<!-- pcm:issue-log-format:start -->
## Issue log format (issue-log-format 1.2.0)

<!-- pcm:policy {"id":"issue-log-format","policy_version":"1.2.0","protocol_version":"0.1.0-draft"} -->

Write issue logs, progress updates, and pull requests in one plain-language shape a newcomer can follow. Pick the tier by the kind of issue, not by preference. **Core tier (every issue log):** title states the problem and intended direction; a 1-3 paragraph summary naming who/what is affected, the consequence, and what this proposes; identity and lineage (leaf owning issue, parent ancestry or none, task ID, primary writer, branch); observed facts vs interpretation, with inferences labelled *inferred*; acceptance criteria with numeric thresholds marked *(proposed)* when untested; boundaries/non-goals and one next action. **Investigation tier (incidents, failures, research, design issues):** numbered symptoms; hypotheses with Status, confirm/refute, and experiment; evidence with provenance; a **Counter-signal** entry when one exists; honest caveat; problems-vs-gaps; a **Proposal** labelled *(proposal)* stating none of it exists unless named as existing. **Pull requests open reader-first:** problem and consequence, what changes, how to verify, and what stays unchanged; lineage links; evidence and one next action; long logs collapsed or linked; reference issues with "Refs #<number>" and use closing keywords only when closing at merge is intended. **Diagrams (mermaid):** when a record describes a flow with 4+ ordered steps or 2+ branches, add a fenced mermaid diagram *and* keep an adjacent text list or table so the record survives render failure; default to `graph TD` (vertical) because wide `LR` flows shrink to illegible strips on phones — reserve `LR` for 4 or fewer short nodes; cap 8 nodes and 6-word labels; wrap diagrams that may exceed the container width inside `<details>` (GitHub mounts the renderer lazily on expand); preview the rendered diagram before publishing (broken syntax shows a visible parse error) and never cite renderer URLs as standalone sources. **Readability rules:** give every SHA, comment id, flag, file path, or tool name a plain-word meaning in the same sentence before it carries load; write evidence as the claim first, numbers as support (“nothing this change could break failed (263 tests, same six machine-environment failures as before)”), never bare counts; no unexplained acronym or bare identifier on first use in any tier; PR openings and checkpoint Completed/Next lines start with one problem sentence a newcomer can follow; the rule set applies to CURRENT projections and checkpoint entries exactly as to issue logs. No private absolute paths or secrets; link rather than paste long logs. See `docs/ISSUE_LOG_FORMAT.md` for the full format, exemplar, and examples.
<!-- pcm:issue-log-format:end -->

Store checkout roots only in the private per-device registry with `continuity workspace register --root <checkout>`. Before creating a worktree, inspect registered roots and Git's worktree list. Reuse one clean, unlocked matching task branch; stop on dirty, locked, conflicting, or ambiguous matches. Do not scan drives or copy absolute paths into shared handoffs.

## Scope

Work only inside the active bounded task. Split or revise the task before materially expanding scope.

## Dev root hygiene

The dev root (`D:\development` on Windows, `~/development` elsewhere, or wherever `ACS_DEV_ROOT` points) holds one main checkout per repo and nothing else.

- Don't create git worktrees, dependency or sibling clones, scratch folders, or caches in the dev root.
- Put them in the ACS cache instead: `%LOCALAPPDATA%\acs\{deps,scratch,worktrees}` on Windows, `~/.cache/acs/{deps,scratch,worktrees}` on macOS and Linux. `ACS_CACHE_DIR` moves the cache.
- Before you finish, push any real work to a branch and remove the worktrees and scratch folders you made. Never delete a checkout that has uncommitted, unpushed, or stashed work just to tidy up.
- To check, run the pinned ACS script: `python <acs>/modules/coordination/multi-agent-hotload/v0.1.0/scripts/dev_root_check.py --dev-root <dev root>`. It prints JSON and exits non-zero when it finds anything other than main checkouts. `--clean` shows a fix and only acts with `--yes`.
- PCM's managed-worktree mode below puts task worktrees at `<canonical-root>/pcm/worktree/<TASK-ID>`, which is inside the dev root, so `dev_root_check.py` reports them as stray worktrees. Until PCM can put them in the ACS cache, prefer sequential work in the main checkout and remove a task worktree as soon as its PR merges.

Paste this at session boot along with the CGM `system_block` (it comes from the ACS hotloader's `PROMPT_INJECT.md` at `38f8f52`):

```
Dev root hygiene (ACS): the dev root (ACS_DEV_ROOT; default D:\development on Windows, ~/development elsewhere) holds exactly one main checkout per repo. Never create git worktrees, dependency or sibling clones, scratch folders, or caches there. Put them under the ACS cache instead: %LOCALAPPDATA%\acs\{deps,scratch,worktrees} on Windows, ~/.cache/acs/{deps,scratch,worktrees} on macOS/Linux (ACS_CACHE_DIR overrides). Check with scripts/dev_root_check.py.
```

## Workspace mode: managed task worktrees

The Git repository, remote, and task history stay canonical; the main checkout remains the permanent home base. Use it for sequential work. Create a linked worktree only when parallel work or isolation is actually useful, at `<canonical-root>/pcm/worktree/<TASK-ID>`. Use one per independent active task, not one per session or agent; a new session continuing that task resumes the same tree. Do not create sibling clones or arbitrary worktree paths.

Before creating a tree, PCM checks Git's registered worktrees and the private per-device workspace registry. Register existing checkouts on other drives with `continuity workspace register --root <checkout>`. One clean, unlocked match for the same remote/task/ref is reused; a dirty, locked, conflicting, or ambiguous match stops before creation. PCM does not scan drives. Registry paths are local-only and must never be copied into issues, commits, PRs, or handoffs.

After the task is pushed, required CI passes, its pull request is merged into the remote default branch, and its task record is complete, run `continuity worktree remove <TASK-ID>`. Removal verifies the GitHub PR, required checks, and merged commit; it refuses locked/pinned, dirty, untracked, unpublished, unmerged, or unverifiable work. For a short audit hold, record the reason, expected release date, private workspace ID, and unlock/remove next action in the completed task's checkpoint, then lock it with `git worktree lock --reason "<reason; release YYYY-MM-DD>" <path>`. The lock makes normal cleanup refuse the tree and is not a cleanup exemption. When the audit ends, return to the permanent checkout, run `git worktree unlock <path>`, then `continuity worktree remove <TASK-ID>` to complete verified cleanup. For other Git hosts without a verified CI adapter, it leaves the tree in place. Never force-remove it. Keep unfinished or user-modified work for recovery.

Linked worktrees share the repository's Git object store; they are not full repository clones. Reuse package-manager download/build caches and installed runtimes where supported. Keep mutable `node_modules` and `.venv` environments separate when lockfiles or interpreters differ; store dependency changes in tracked manifests/lockfiles or patch files, not as hidden edits inside an installed environment. Remove the task worktree after verified merge and completion.

## Continuity records

<!-- pcm:policy {"id":"continuity-records","policy_version":"1.3.0","protocol_version":"0.1.0-draft"} -->

For continuity issues, progress updates, pull requests, and project-state documents, explain the human problem and outcome first, then scope, status, linked evidence, and one next action. Cite external claims and tie repository claims to a revision, issue, PR, or CI result. Record reproduction details only when needed. Keep PR openings skimmable; link long logs. Preserve existing project ownership outside continuity. Do not claim automatic tracker synchronization or chat capture unless implemented and tested.

## Checkpoint

Before stopping after meaningful work, append completed work, exact evidence, decisions, changed paths, blockers, and one next atomic action.

If canonical continuity state is temporarily unavailable, treat that as degraded continuity rather than an execution blocker: keep safe authorized work moving, use an already-authorized alternate checkout/host, and run `continuity checkpoint <TASK-ID> --root <canonical-root> --recovery-root <alternate-root> --agent <name> --completed <work> --evidence <result> --next <next-action>` to write the JSON recovery receipt under `.continuity/recovery/`. Do not write an ad-hoc checkpoint under `checkpoints/`, replace the alternate task file, treat a physical worktree as project identity, repair storage merely to write a checkpoint, or request redundant permission. Reconcile later with `continuity recovery reconcile --root <canonical-root> --file <receipt>`.

For a normal checkpoint, commit the product change first and then run `continuity checkpoint`; it prints a stable `REQUEST_ID`, commits, and synchronously pushes the checkpoint to the task branch. If interrupted, retry with the same `--request-id`; the same payload is a no-op and a different payload is rejected. Open or update a PR after pushing. GitHub CI and auto-merge then run asynchronously, gated by required reviews/checks and any merge queue. Confirm the merge before marking complete or removing the worktree.

If `.continuity/documents.json` exists, every fresh session or task takeover/resumption must consult it before deciding the next action, not only before writing documentation. Run `git fetch origin`, then `continuity docs find "<issue title and task-objective terms>" --task <TASK-ID>`; read the returned matches and declared neighbors before deciding that prior work is missing or creating/replacing a document. Investigate `NEEDS_REVIEW`/`REMOTE_UNKNOWN` before relying on old evidence. The generated human view is checked by `continuity validate`.

<!-- oio:issue-log-guidance:start -->
Before filing an observational or operational issue log, read `.oio/ontology/ISSUE_LOG_ONTOLOGY.md`, `.oio/ontology/project.json`, and `.oio/ontology/AGENT_GUIDE.md`. Confirm the exact destination and filing action are authorized. On OIO, ACS, CGM, and PCM, do not submit an issue or write files without explicit human direction for that destination and action. A proposal can remain a local draft until directed. Never treat adoption as permission to write to an adopter or sibling repository.
<!-- oio:issue-log-guidance:end -->
