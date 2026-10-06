# Jev Context Engine — design history and transcript

Issue: #86  
Branch: `feat/jev-context-engine`  
Date: 2026-10-06

## Why this document exists

This records how the idea evolved from graph/RAG and deterministic software-factory thinking into a different architecture:

> **Harvest the repository state before the expensive coding model starts reasoning, use Jev to classify what matters and what is missing, compile a bounded context/task capsule, and let ordinary Claude Code spend its intelligence on the actual code.**

The end goal is an alternate Claude Code behavior engine or CLI wrapper, not a replacement model and not a giant hand-authored workflow graph.

## Accuracy note

The earliest graph/RAG discussion is reconstructed from the surviving design context and repository work. It is **not presented as verbatim quotation** where the exact turn text is unavailable.

The later Jev discussion is recorded from the current chat and preserves the user's wording closely, including typos, because those corrections materially changed the architecture.

---

# 1. Starting point: graph engineering and RAG

## Reconstructed discussion

The original question was how to make long-running coding agents cheaper, faster and more repeatable.

The first architecture emphasized a deterministic software factory around a coding model:

```text
spec
  |
  v
scaffold
  |
  v
validate
  | pass
  +-------> finish
  |
  | fail
  v
coding worker
  |
  v
validate again
```

The core mental model was:

```text
Agent performance
≈ model × context × tools × feedback × state management × domain priors
```

The initial conclusion was that things with deterministic answers should not require expensive inference:

- compilers;
- typecheckers;
- linters;
- test runners;
- AST transforms;
- project generators;
- browser automation;
- structured build/deploy steps.

This led to the `graph-engineering-study` repository and an explicit typed graph around scaffolding, validation, bounded repair and evidence.

At that stage, the graph was treated as the main external control structure and RAG/context retrieval as a supporting capability.

---

# 2. Dyad changed the question

The next important observation was that Dyad-like app builders often make even weaker models look unusually strong at frontend work.

The useful property is not simply that the underlying model is better.

The environment removes a huge amount of open-ended search:

```text
framework already selected
component system already selected
routing already present
theme already present
UI primitives already present
preview already available
current component/page already known
```

So instead of asking a model to rediscover the application before every change, the harness keeps the world constrained and legible.

That suggested a broader hypothesis:

> Maybe the main opportunity is not a more elaborate workflow graph. Maybe it is to **compile the working context so well that the coding model rarely has to explore.**

---

# 3. Question: do Claude Code and Codex already have state machines?

The answer was yes.

Both already have an internal agent loop with state around:

- conversation/thread;
- tool calls;
- shell/editor operations;
- checkpoints;
- subagents;
- context;
- approvals;
- results.

That moved the question from:

> “Do they have a state machine?”

to:

> “What useful state is *outside* the model, and how much of the model's time is wasted reconstructing that state?”

The first answer still leaned too heavily toward an external engineering state machine.

---

# 4. Question: is CLAUDE.md / AGENTS.md already enough?

The next correction was that a strong `CLAUDE.md` / `AGENTS.md`, plus hooks and scripts, can already encode a lot of process.

That produced a useful three-level comparison:

```text
A. instructions only

B. instructions + hooks/scripts/CI

C. explicit external graph
```

This raised the possibility that a manually authored graph might be unnecessary if the harness can simply make the model's environment sufficiently structured.

That was the first major simplification.

---

# 5. Jev enters the design

The next question was whether Jev, a cheap fast classifier/decision model, could be used to constrain a coding model.

The first interpretation was too narrow.

It framed Jev as:

- a guardrail;
- a semantic gate;
- a cheap judge;
- a model/tool router;
- a way to decide whether to escalate to a stronger model.

Those uses are valid, but they were not the intended architecture.

---

# 6. User correction: Jev should replace difficult state-machine routing

## User

> i think you try to put too many things into deterministic gates, models are already good enough to have strong guardrails, however the constraining part im talking about is not to enforce guardrails or policy in of itself, im talking about a way to make coding tasks itself easier so it can lay out a graph or plan for long coding stessions, to replace a difficult to use statemachine with a reusable cheap fast model like jev

> just like how we know dyad does very good state machine routing for ui and design decision to the point it can many any brok model design a very good frontend in no time, similarly what if we removed all these machinery and let jev do the whole routing so we dont have to spend itme to make difficult state machine we build harness around jev , so jev classifies what the models did last time and can make the whole process fast and repeatable again and again and again for fast decision making

> basioally limiting the llm in such a way that they dont have to spend itme thinking what to do jev clasifies what exact state they should be in and llm just does the tasks

## Design consequence

This changed Jev from “guardrail” to **learned transition function**.

Instead of maintaining a large graph:

```text
if state == X and test == Y:
    goto Z
```

the controller could repeatedly classify the current state and choose the next bounded work mode.

At this stage the architecture looked like:

```text
repo + task + last result
          |
          v
         Jev
          |
   classify state
          |
          v
   task packet
          |
          v
   Claude/Codex
          |
          v
       result
          |
          +----> Jev again
```

This was already simpler than a manually authored graph.

But it was still not the final idea.

---

# 7. User correction: the expensive model should not explore the repo at all

## User

> nope u didnt get me agian what i mean is literally instead of agents havving to read and reason whats there what state we are in grep grop ripgrep, semantic search , blah blah blah,

> we use jev to classify the state letting jev use a state machine, the state machine python function grabs relevant files, literally tells jev whats there, jev classifies whats done not done, then assigns and classifies a list of tasks where to get them, what files exist so agents dont have to read the whole codes anymore and grep glob find things find prior research prior decisions prior tests done, nothing jev routes a harvester that gives it everything, tells the agent where everything is , agent reasons over the information already provided, asks jev if it still needs more a2a communication jev kkeeps either sending or classfying more state and reasoning model + jev agrees enough data and starts executing based on constrants and defined sets of tasks, extremely fast extremely cheap just like how a graph or dyad would

## This is the decisive architectural shift

The target is not primarily “Jev chooses debug vs implement.”

The target is:

> **Remove repository discovery and situational reconstruction from the expensive model's job.**

Today, a coding agent often spends a large fraction of a turn doing:

```text
ls
find
glob
grep
ripgrep
semantic search
read file
follow import
read caller
find test
read test
find issue
find ADR
read old decision
inspect git
inspect prior work
reason about what is already done
ask another agent what changed
```

Only after all of that does it actually reason about the code change.

The proposed engine moves those operations ahead of the reasoning model.

---

# 8. Final architecture: repository-state harvester + Jev context compiler

```text
                         REPOSITORY
                             |
                             v
                      STATE HARVESTER
                             |
             +---------------+---------------+
             |               |               |
            AST            git/history      tests
          symbols          issues/ADRs      results
         imports            research        failures
        dependency graph    agent deltas    specs
             |               |               |
             +---------------+---------------+
                             |
                             v
                  STRUCTURED PROJECT STATE
                             |
                             v
                            JEV
                    semantic classification
                             |
            +----------------+----------------+
            |                |                |
       relevant files   done/not-done    missing context
       symbols/tests    prior decisions  task ownership
            |                |                |
            +----------------+----------------+
                             |
                             v
                     CONTEXT COMPILER
                             |
                             v
                       TASK CAPSULE
                             |
                             v
                      CLAUDE CODE
                             |
                   reason over supplied
                     working set only
                             |
               +-------------+-------------+
               |                           |
             enough                    need more
               |                           |
               v                           v
            execute                 context request
                                           |
                                           v
                                          JEV
                                  classify what is missing
                                           |
                                           v
                                       HARVESTER
                                           |
                                           +----> expanded capsule

after edit:
    harvest delta -> update state -> classify next work -> repeat
```

The expensive model remains a powerful software engineer.

It simply does not have to repeatedly rebuild a mental map of the repository.

---

# 9. Three intelligence tiers

The cleanest decomposition is:

```text
HARVESTER
deterministic / cheap extraction
        |
        v
JEV
cheap semantic classification
        |
        v
CLAUDE / CODEX
expensive deep reasoning
```

## Harvester answers facts

Examples:

- what files exist?
- what symbols are in them?
- who imports this module?
- who calls this function?
- which tests failed?
- which files changed?
- what issue/PR/ADR mentions this subsystem?
- what did worker B just change?
- what is the current git revision?

These should not consume frontier-model reasoning.

## Jev answers fuzzy classification

Examples:

- which of these files are relevant?
- which existing tasks are complete vs partial?
- which prior decision applies?
- which subsystem owns this failure?
- what category of context is missing?
- is the current context capsule likely sufficient?
- which worker needs this new artifact?
- can this A2A request be answered from state?
- which bounded task should be handed to the worker?

This is semantic, but usually not frontier-level reasoning.

## Claude/Codex answers hard software questions

Examples:

- why is this distributed race happening?
- what is the minimal correct implementation?
- how should this abstraction change?
- what is the safest migration?
- how should the algorithm be implemented?

This is where expensive intelligence is valuable.

---

# 10. The context capsule

The central runtime artifact should be a compiled context packet.

Example:

```text
TASK
Add session revocation.

CURRENT STATUS
Partially implemented.

RELEVANT IMPLEMENTATION
src/auth/session_service.py
src/auth/models.py
src/api/sessions.py

RELEVANT SYMBOLS
SessionService.revoke
SessionStore.invalidate
Session.is_active

RELEVANT TESTS
tests/auth/test_revocation.py
tests/api/test_sessions.py

DEPENDENCIES
SessionService -> TokenStore -> AuditWriter

EXISTING BEHAVIOR
- issue_session implemented
- validate_session implemented
- revoke_session missing
- DELETE endpoint stub exists

PRIOR DECISIONS
ADR-014: revocation is immediate
ADR-021: audit write occurs after successful state transition

KNOWN FAILURE
case-07 expects revoked session to return 401
current result is 200

SIMILAR IMPLEMENTATION
src/credentials/revoke.py

CURRENT WORKER DELTAS
worker-b changed policy scope serialization in commit/delta X

DO NOT SPEND TIME ON
database connector
frontend
deployment

EXPECTED WORK AREA
3-5 files
```

Claude begins with the working set already assembled.

---

# 11. Incremental project state instead of repeated RAG

The state store should be versioned by repository revision.

Example:

```text
repo SHA abc123
   |
   v
project snapshot K_abc123
```

After a small change:

```text
4 changed files
   |
   v
incremental harvest
   |
   v
project snapshot K_def456
```

Unchanged knowledge is reused.

This is important because repeated semantic search/RAG can itself become a form of repeated exploration.

The stronger idea is:

> **Build and maintain a reusable project world model, then classify against it.**

RAG/search still exists as a fallback and as one harvester input, but it is no longer the primary cognition loop.

---

# 12. A2A becomes context brokerage

Traditional multi-agent communication:

```text
worker A
   |
   v
asks worker B
   |
   v
worker B reasons/searches
   |
   v
worker B answers
```

Proposed engine:

```text
worker A asks:
"how are policy scopes represented?"
        |
        v
      Jev
classifies information need
        |
        v
   state broker
        |
        +--> symbol definition
        +--> callers/references
        +--> relevant tests
        +--> ADR
        +--> worker B latest delta
        |
        v
worker A receives compiled answer
```

Worker B does not need to be interrupted unless the state store cannot answer.

This can make multi-agent work cheaper and less lossy.

---

# 13. Tiny reusable state machine, not a giant workflow graph

The runtime state machine can stay generic:

```text
HARVEST
   |
   v
CLASSIFY
   |
   v
ASSEMBLE CONTEXT
   |
   v
SUFFICIENT?
   | no
   +------> HARVEST MORE
   |
   | yes
   v
EXECUTE
   |
   v
HARVEST DELTA
   |
   +------> loop
```

The semantics of the current project live in harvested state + Jev classifications, not in hundreds of manually maintained transitions.

---

# 14. Product direction: alternate Claude Code behavior engine

The idea belongs naturally in `claude-code-launcher` because this repository already controls how Claude Code is started and already wraps its model/runtime environment.

Possible user-facing shape:

```text
ccl-jevcoder "implement task X"
```

or an opt-in launcher mode:

```text
Launch with:
  Claude Code
  UltraCode
  Jev Context Engine
```

High-level internal flow:

```text
launcher
  |
  v
repository harvester
  |
  v
state store / graph index
  |
  v
Jev classifier
  |
  v
context capsule builder
  |
  v
ordinary Claude Code process
  |
  v
delta/state collector
  |
  +---- repeat
```

The underlying Claude Code binary stays ordinary Claude Code.

What changes is the **behavior engine around it**.

---

# 15. Why this is closer to Dyad

A UI builder often gives the model a precompiled world:

- current app;
- current page;
- component tree;
- selected component;
- design system;
- available primitives;
- theme;
- preview state.

The model is therefore not rediscovering the entire frontend architecture before every operation.

This proposal tries to create the same advantage for arbitrary software repositories:

```text
Dyad:
structured UI world
   -> model executes UI task

Jev Context Engine:
structured repo world
   -> model executes coding task
```

The research question is whether a general software repository can be made as legible to a coding model as a constrained UI builder makes a frontend project.

---

# 16. Benchmark that should decide whether this works

At minimum:

## Arm A — stock Claude Code

Let Claude explore normally.

## Arm B — current launcher + strong CLAUDE.md/planner

Use the existing best setup without the Jev engine.

## Arm C — Jev context engine

Same worker model, but:

- project state is pre-harvested;
- relevant working set is classified;
- task capsule is assembled before execution;
- missing context is requested through the engine;
- project history and agent deltas are brokered through the state store.

Measure:

- time to first useful edit;
- time to complete task;
- total worker input/output/reasoning tokens;
- number of grep/glob/find/ripgrep/semantic-search operations;
- number of files the worker reads before first edit;
- number of context-expansion loops;
- initial capsule sufficiency rate;
- Jev classification latency/cost;
- wrong-context recovery rate;
- worker replans;
- A2A messages avoided;
- final test/acceptance result;
- regression/bug rate;
- long-session degradation.

A particularly important metric is:

```text
frontier-model effort spent on repo discovery
vs
frontier-model effort spent on actual software reasoning
```

---

# 17. Explicit non-goals

This idea is **not**:

- a new authorization/policy engine;
- a giant deterministic guardrail layer;
- a requirement to hand-author a LangGraph DAG for every project;
- a replacement for Claude Code;
- a claim that every decision should be deterministic;
- a plan to remove all search tools from the worker before benchmarking;
- IAM-specific;
- tied to one model vendor.

The hypothesis is about **preparing the coding environment before expensive reasoning starts**.

---

# 18. Central design rule

The concept can be reduced to one sentence:

> **The expensive coding model should reason over already-compiled project information instead of spending most of its turn discovering that information.**

Or, operationally:

```text
harvest facts
   ->
classify relevance/state
   ->
compile working set
   ->
reason
   ->
execute
   ->
harvest delta
   ->
repeat
```

That is the behavior engine issue #86 should preserve even if the implementation changes substantially.

---

# 19. Latest owner direction

## User

> [https://github.com/Pukujan/claude-code-launcher](https://github.com/Pukujan/claude-code-launcher) there you go now make this into an issue log here as well as a document with full transcupt where we got from graph rag to this then ill let my agents build itim thinkin gof making an alternate claude code cli for this that does exactly this to regular claude code and changes its hwole behaviour engine

## Recorded action

- Created issue #86, **“Jev context engine: compile repository state before Claude Code reasons.”**
- Created branch `feat/jev-context-engine`.
- Added this design-history/transcript document.
- Next intended step after this document lands: split implementation into child issues for:
  1. repository harvester/state store;
  2. Jev classifier contract;
  3. context capsule + Claude Code wrapper;
  4. A2A/context brokerage;
  5. benchmark/evaluation.

No implementation of the behavior engine belongs in this documentation-only increment.
