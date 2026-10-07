# Claude Code Launcher — Project Contract

<!-- continuity:project {"id":"claude-code-launcher","protocol_version":"0.1.0-draft","schema":"project-continuity.project.v1","title":"Claude Code Launcher"} -->

<!-- pcm:github-progression:start -->
## GitHub-owned progression

GitHub Issues are required for PCM-governed project work and own task scope, acceptance, priority, ownership, dependencies, lifecycle and durable project progression. Merged default-branch history owns accepted code and normative/domain documents; PR checks and merge records own delivery facts. Checked-in PROJECT/CURRENT/TASK/checkpoint/handoff documents are mandatory versioned projections for task state, not a parallel authority. Local files, registries, context packs and chat are ephemeral execution aids. Domain-document ownership stays with the target project.

Every issue progress update MUST link the leaf child issue that owns the work, its parent ancestry and dependencies (or explicitly none). A top-level deliverable identifies itself as the leaf and says parent: none. Create one child per independently deliverable scope, never one per comment. Record task ID, primary writer and branch on the issue before creating its repository projection. Re-read live issues and relevant source revisions before resuming; the issue verifier checks identity/status, not semantic agreement.

Authorized owner/user direction can revise intent: record it on the owning GitHub issue with a correction/supersession link before dependent work. It cannot alter observed CI/merge facts or waive required gates. Stale projections yield to their field's authority. If direction, ownership or evidence conflicts remain unresolved, pause affected work and record uncertainty; continue independent safe work. One primary writer owns each task branch/checkpoint stream. Coordinate shared-document edits through linked issues/PRs, re-read the current base and reconcile concurrent changes; never force-push or overwrite another writer. Issue prose is not an atomic lock.

Label observed results, repository/external evidence, agent reports and inference separately. Preserve contradictory evidence with source/revision and mark conclusions disputed or unknown until resolved. Append correction/supersession evidence; never rewrite checkpoint history. An upstream correction MUST identify affected descendants and assumptions on their issues; pause, re-plan and revalidate dependent work before resuming. Follow explicit parent/dependency links within the affected scope; cycles or unknown lineage block affected claims. No graph database, local canonical ledger or autonomous polling agent is required.

Before every push, synchronize relevant docs and task/checkpoint projections, CURRENT/HANDOFF when affected, and reviewed catalog/generated index. Record leaf/parent/dependency links, source issue/comment revision, as-of status, evidence, blockers and next action. Commit product/docs first; `continuity checkpoint` then commits and synchronously pushes the checkpoint with a stable request ID. After every successful push, manually publish a leaf issue receipt keyed by request ID and exact pushed SHA, linking changed docs/checkpoint, PR, tests and pending gates; add a linked parent progression update. Retry a missing receipt without another checkpoint/push; inspect for the same key before posting. --receipt-repo and --receipt-issue are opt-in and still require a proven lookup; omit them and the receipt stays manual. Automatic issue-comment synchronization is not implemented; issue #67 is CLOSED (owner freeze decision 2026-09-25) and its unmet guaranteed-completion acceptance transferred to #110.

Required CI and GitHub auto-merge are mandatory. Arm auto-merge only after the increment's final push: a later push races the merge window and strands outside accepted history. Verify protection, required reviews/checks on the exact current-base or merge-queue candidate, and auto-merge; missing, failed, skipped, stale or unverified gates fail closed: no completion or cleanup. After CI/merge, append the exact check results, PR/merge SHA and live issue status to the leaf and link the parent update; fetch and verify accepted history. Reconcile material doc/status corrections in a new synchronized increment. Receipt-only transitions need no recursive doc commit: docs retain an explicit as-of/pending state and point to the live issue. Never label local-only or merely pushed work delivered. Preserve unsafe resources and keep incomplete issues open.
<!-- pcm:github-progression:end -->

## Main goal

Keep one launcher, in one repository, that starts Claude Code on Alex's Windows PC and Mac and routes it through a local LiteLLM proxy to InferHub, with both platforms built from the same proxy config and routing scripts.

## Why

The launcher used to live in three places at once: a Desktop copy on the PC, a module in agent-custom-setup, and the LiteLLM workbench in litellm-ckff-ops. The copies drifted. The Desktop copy was newer than the module, and the Mac port had to clone the workbench to work at all. One source of truth stops that drift.

## Scope

- `windows/`: the PowerShell launcher and the LiteLLM start and stop scripts.
- `mac/`: the double-click `.command` launcher and its tests.
- `shared/litellm/`: the proxy config, seat and merge scripts, fallback chains and pinned requirements that both launchers run.
- `docs/`: how the two launchers compare and where each file came from.
- `history/`: older launcher versions kept as a record, never run.

## Non-goals

- Changing how model names are routed to InferHub seats. The routing scripts are copied, not rewritten.
- Changing port 4000 from CI or from agents: no restart, stop, bind, reload or config write. That is the live proxy. Read-only probing is fine; a change is tested on a copy proxy on another port and merged to 4000 only once verified.
- Hosting the proxy anywhere other than the local machine.
- Storing secrets. Only `.env.example` is tracked.

## Definition of success

Both launchers run the proxy from this repository with no other checkout, CI lints them and runs the Mac dry run and the Python unit tests on every pull request, and every copied file can be traced to a source repository, path and commit.
