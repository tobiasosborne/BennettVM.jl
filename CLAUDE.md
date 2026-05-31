# CLAUDE.md — BennettVM.jl

> Identical to `AGENTS.md`. Edit both in the same commit; never let them drift.

If you are an agent (Claude Code, an SDK harness, a downstream tool)
landing in this repo, read this **top to bottom every session**. After a
context compression, re-read. The rules drift out of working memory
faster than you think; that's why they're numbered.

---

## What this is

**BennettVM.jl is the reversible-VM backend for Bennett.jl.** Bennett.jl
compiles Julia functions to a *fixed circuit* (`target = :circuit`) — the
right artifact for a quantum oracle, but it cannot represent unbounded
loops or runtime-sized memory. BennettVM is the second lowering target
(`target = :reversible_vm`) that closes that gap: a reversible interpreter
for terminating computations of statically-unknown length.

The relationship is:

```
                 ┌──────────── target=:circuit ──────►  fixed permutation circuit
Julia source ──► │ Bennett.jl frontend (LLVM IR, lowering, gates)
                 └──────────── target=:reversible_vm ─►  BennettVM (this repo)
```

BennettVM is **not** a fork of Bennett.jl, **not** a replacement for it,
and **not** an extension of the existing circuit backend. The two
backends are semantically distinct (PRD v3 §3.7) and stay distinct.

## Read order

For any task, in order:

1. `bennettvm_prd.md` (PRD v3) — the controlling document.
2. This file (`CLAUDE.md` = `AGENTS.md`).
3. `../Bennett.jl/CLAUDE.md` and `../Bennett.jl/Bennett-ReversibleVM-PRD.md`
   — the upstream artifact and its north-star direction.
4. The relevant section of PRD v3 Part II (literature review) for the
   topic you're touching.
5. The local PDFs under `references/` (once seeded) for any claim you
   plan to make.

If you have not read `bennettvm_prd.md` and this file, you must refuse
to add code or mathematical content. (Gate stated by named files, not
ordinals, to prevent count-drift.)

## Project phase awareness

The PRD is a **two-phase plan**, and the rules differ across phases.
**Know which phase you are in before doing anything.**

- **Phase 0 — Spike.** One Claude Code session. Bennett-1973 trace VM,
  full-state history, eight instructions, integers only, countdown
  program, round-trip test. **Deliberately throwaway.** The artifact is
  the *retrospective*, not the VM. PRD v3 Part V is the controlling
  spec. See "Phase-0 gating" below.
- **Phase 1 — Archive and learnings.** Spike repo is archived
  read-only; retrospective is written; **PRD v4 is authored** (the
  spike's output, not its input). No Phase-2 code until v4 exists.
- **Phase 2 — Production.** Built on RSSA-style IR, Pendulum/BobISA
  instruction set, Enzyme-style min-cut delta histories, Bennett-1989
  pebble-game lowering, optional Unqomp/Reqomp/Qurts integration. Lean
  formalization of *abstract VM semantics only*. PRD v4 is the
  controlling spec (does not yet exist).

The current phase is recorded in `PHASE.md` (create it if absent). At
session start, `cat PHASE.md` and abort if your task does not match.

---

## The Laws

Three laws. Unconditional. If a "fast path" conflicts with any, choose
the Law.

**Law 1 — Ground truth before code.** Every implementation decision
cites a local source — a PDF in `references/`, a section of `bennettvm_prd.md`,
a file path in `../Bennett.jl/`, or an entry in PRD v3 Part II. If the
source isn't local, **acquire it before writing the code that depends
on it**. No paraphrasing the Bennett-1973 construction from memory; no
guessing the RSSA φ-node semantics; no inferring BobISA branch
encoding by analogy. Cite the local file path and line number / page
in code comments and commit messages, in the project house style
(Feynfeld Rule 2, Bennett.jl §1):

```julia
# Ref: references/bennett-1973-logical-reversibility.pdf, §3 (p. 528)
#   "the history tape records, at each step, which transition rule was applied"
```

**Law 2 — Reuse before reinvention.** PRD v3 Part IV (the Reuse Map)
is binding. Every Phase-2 design decision must answer the question
*"what published work does this replace, and why?"* before being
accepted. The default response to discovering prior art is **reuse or
wrap**, not reimplement. Specifically: do not invent a reversible SSA
form (use Mogensen RSSA); do not invent a reversible instruction set
(use Pendulum/BobISA); do not reimplement min-cut history selection
(port Enzyme's analysis); do not reimplement pebble-game lowering
without first reading Knill 1995 and Meuli et al 2019. Phase-0
exception: the spike *is* a literal port of Bennett 1973 §3 and is
allowed to ignore the rest of the map.

**Law 3 — Phase discipline.** Phase 0's output is the retrospective.
Phase 2's input is PRD v4. There is no shortcut from spike code to
production code. If you find yourself "just polishing" the spike, or
"just starting" Phase 2 work in the spike branch, **stop**: you are
violating PRD v3 §1.4 and §7.8.

---

## The Rules

Numbered, non-negotiable. Re-read after compaction.

0. **Laws 1, 2, 3 apply.** Always.

1. **Fail fast, fail loud.** Assertions, not silent returns. Crashes
   with context, not corrupted state or quiet `nothing`. If a history
   stack is empty when `unstep!` is called, if an instruction is
   unsupported, if `unrun!` would leave non-empty history — `error()`
   immediately with a clear message. Reversibility violations are
   correctness bugs; they must not be papered over.

2. **All bugs are deep.** No bandaids. No "temporary fixes." A
   round-trip test failure that "looks like an off-by-one" is more
   often a halt-state-propagation bug, a history-stack ordering bug,
   or an equality-semantics bug. Investigate the root cause; a fix
   that passes one test but breaks the round-trip invariant elsewhere
   is not a fix.

3. **Skepticism.** Verify subagent output, previous-session claims,
   prior-PR descriptions, and your own memory against the current
   state of the repo. `git log`, `Read`, and the local PDFs are
   authoritative; conversation context is not. Especially: be
   skeptical of LLM-generated summaries of reversible-computing
   papers — open the PDF.

4. **"Runs without errors" is not a passing test.** Every test asserts
   an invariant against a known-correct value: round-trip equality
   after `unrun!`, history empty after full reversal, history length
   equals step count, golden-master agreement with the reference
   irreversible Julia interpreter on the same bytecode. A test that
   only asserts "didn't throw" is broken.

5. **TDD discipline (two valid shapes).**
   - **Spec-from-scratch:** classic RED → GREEN → refactor. Write the
     failing `@test` before the implementation.
   - **Port-and-verify:** for ports of published algorithms (Bennett
     1973 trace VM, RSSA φ-resolution, Knill 1995 pebble-game
     recursion), port the algorithm faithfully, capture invariants
     in tests, **mutation-prove** the tests catch regressions
     (perturb the impl, confirm RED, restore), and cross-validate
     against an independent oracle (the reference irreversible Julia
     interpreter for the spike; RC3's behavior for Phase 2).
   The discipline is *"tests have caught a real regression,"* not
   "the test was committed before the impl."

6. **Reviewer-gating + tiered workflow.** Any non-trivial change goes
   through a reviewer subagent (distinct from the author). The
   `Review:` line in the commit message records the verdict.
   - **Trivial** (≤5 LOC; typo / comment / formatting; no semantic
     content): direct edit; reviewer-exempt; note `Review: mechanical, exempt`.
   - **Small** (≤30 LOC; one file; uses already-defined abstractions):
     direct edit; **one reviewer subagent before commit**.
   - **Core** (cross-file; new IR concept; new instruction; new
     history strategy; new Lean theorem; new Bennett.jl integration
     surface): bd issue first; for contested design choices, **2–3
     research subagents independently before implementing (the 3+1
     pattern from Bennett.jl)**; hostile reviewer always.

7. **No parallel Julia agents.** Julia precompile-cache contention
   makes parallel `Pkg.add` / `Pkg.precompile` / `Pkg.test` brittle.
   **One Julia process at a time across all subagents.** Read-only
   research subagents (literature review, PDF reading, no `julia`
   invocation) may run in parallel; anything that touches the Julia
   package may not.

8. **Get feedback fast.** Run the relevant test after every
   non-trivial change. Don't code blind for 500 lines then check;
   check every ~50 LOC. Quick REPL probes are fine — `julia --project
   -e 'using BennettVM; ...'`. For the spike: `julia --project
   test/test_roundtrip.jl` is the canonical single-file gate.

9. **Senior-engineer-grade only.** No "good enough for now"; no "v2
   will fix it." If a v1-acceptable corner exists, file it as a
   deferred bead with the exact condition that would force v2 work.
   This is the rule that distinguishes the production VM (Phase 2)
   from the spike (Phase 0) — the spike *is* allowed to be
   throwaway-quality, but it is allowed to be that *because* it will
   be thrown away, not because the rule doesn't apply.

10. **LOC limit.** No source file exceeds ~200 LOC (excluding blank
    lines and docstring blocks). When a module approaches this, split.
    Inherited from Feynfeld.jl / PadeTaylor.jl convention.

11. **Literate programming.** Source files are exposition. Top-of-file
    docstring expands into multiple paragraphs explaining *why* the
    code is shaped the way it is — which ground truth it embodies
    (`references/bennett-1973.pdf`, `references/mogensen-rssa.pdf`,
    `references/yokoyama-glueck-2007.pdf`), what pitfalls motivated
    each defensive check, which references it derives from. A fresh
    reader should read `src/spike/Interpreter.jl` top-to-bottom like
    a chapter, not piece intent together from scattered comments.

12. **No GitHub CI, no automated remote runs.** Quality gates run
    locally: `julia --project=. -e 'using Pkg; Pkg.test()'`,
    mutation-proof checks, manual cross-validation against the
    reference Julia interpreter, eventual `lake build` for the Lean
    formalization. The user has explicitly rejected automated CI
    across all their projects (Bennett.jl, Feynfeld.jl, PadeTaylor.jl,
    cft-anyons, scientist-workbench); failure-email noise is worse
    than zero signal. Do NOT create `.github/workflows/`, do NOT
    propose "add CI" beads.

13. **Beads is the only persistent tracker.** `bd create / update /
    claim / close`. No `TodoWrite`, no markdown TODO lists.
    `TaskCreate` is permitted for in-session progress tracking when
    useful (user directive 2026-05-26; supersedes the earlier
    "in-session sub-step tracking only" qualifier and the blanket
    prohibition in the auto-generated Beads Issue Tracker block
    below). Beads remains the only *persistent* tracker; TaskCreate
    is for ephemeral state inside one session. Run `bd ready` at
    session start; `bd close <id> ...` at the end. Cross-device sync
    via `.beads/issues.jsonl` snapshots (the cft-anyons / Feynfeld
    pattern), not via Dolt push. Never `bd init --force`.

14. **No Bennett.jl source mutation without explicit user approval.**
    BennettVM consumes Bennett.jl through a documented IR interface
    (Phase 2) or stands alone (Phase 0). It does not patch Bennett.jl
    internals. PRD v3 §7.5: Bennett.jl is pinned during initial
    development. If you find yourself wanting to edit
    `../Bennett.jl/src/`, **stop and ask the user**.

15. **Lean scope is bounded.** Phase 2 Lean targets are listed in
    PRD v3 §3.8: abstract VM semantics, trace-simulation theorem,
    reversible-RAM-primitive equivs, output-channel non-aliasing,
    pebble-game correctness. **Not** the Julia implementation,
    **not** Bennett.jl, **not** the LLVM frontend. Scope creep here
    has eaten months of project time in adjacent repos; do not
    repeat the mistake. `0 sorry, 0 axiom` is load-bearing when the
    Lean module appears.

16. **Repeat rules.** Re-read this file at session start, after
    `/clear`, after any context compression. The agent that re-reads
    catches drift; the agent that doesn't ships it.

---

## Phase-0 gating (THE SPIKE)

These rules apply *only during the Phase-0 spike session* and override
nothing in §3–§16; they are an additional layer.

P0.1. **One Claude Code session. Hard stop at session end.** Whatever
state the spike is in at session close, that is the deliverable. PRD
v3 §1.2.

P0.2. **Sequential subagents only.** Suggested split: interpreter
agent → instruction-set agent → tests/property-test agent → reviewer
agent. Per Rule 7, never parallel Julia. The reviewer engages after
every core change.

P0.3. **The retrospective is the deliverable, not the VM.** A working
spike with no retrospective is a Phase-0 failure. A broken spike with
a precise retrospective is a Phase-0 success. PRD v3 §1.2, §5.6.

P0.4. **In-scope only what PRD v3 §5.1 lists.** Eight bytecode
instructions (`Const`, `Move`, `UnaryOp`, `BinaryOp`, `Jump`,
`JumpIf`, `Return`, `Halt`). `Int64` and `Bool` scalars only. No
fixed-point. No arrays. No RAM primitives. No oracle mode. No
Bennett.jl integration. No Lean. No serialization. No documentation
beyond the retrospective. **If you catch yourself adding a ninth
instruction, stop.**

P0.5. **Golden master required.** Every test program has a reference
*irreversible* Julia function that computes the same result. Forward
execution must agree bit-for-bit. The reference is the oracle; the
spike is being verified against the reference.

P0.6. **Round-trip is the load-bearing invariant.** `unrun!(run!(s,
prog)) == initial(s) && isempty(s.history)` must hold for every
test program. Failure here is a Phase-0 stop condition.

P0.7. **Repository archived on close.** PRD v3 §7.8: the spike repo
is marked read-only at Phase-0 completion. Phase 2 starts from an
empty directory. Do not promote spike code to Phase 2; do not
"refactor the spike into" the production VM.

P0.8. **PRD v4 ticket opened in beads at Phase-0 close**, with the
retrospective attached. Without this ticket, Phase 0 is not closed.

---

## Hallucination-risk callouts

Pre-emptive warnings about specific mistakes in this domain that look
right but aren't. When you catch yourself about to do one, stop and
re-check the cited reference.

- **Bennett 1973 ≠ Bennett 1989.** The 1973 paper is the three-tape
  trace TM (full history, O(T) extra space). The 1989 paper is the
  pebble-game recursion (O(T^{1+ε}) time, O(log T) space). The spike
  implements 1973. Phase 2 implements 1989 on top of an RSSA IR.
  Confusing the two is the single most common error in popular
  expositions; do not propagate it.

- **Janus has a self-interpreter without history.** Yokoyama–Glück
  2007 PEPM shows the Janus self-interpreter is reversible *without
  a computation history*. The structural lesson — if the source
  language is reversible by construction, no trace tape is required
  — is what Phase 2 must absorb. Do not assume every reversible
  language needs a history tape; the spike does because its source
  is irreversible bytecode, not Janus.

- **RSSA φ-nodes appear on splits AND joins.** Mogensen 2016, §3.
  Forward control flow needs φ at joins; *backward* control flow
  needs φ at splits. The classical-SSA intuition (φ only at joins)
  is wrong in RSSA and will produce un-invertible IR if applied
  naively.

- **PISA memory access is always an exchange.** Vieri 1995/1999. A
  load that doesn't store back is not reversible — it loses the
  pre-load value of the destination register. Any Phase-2 memory
  instruction must follow this rule; "I'll just add a non-exchange
  load for performance" is exactly the design mistake Pendulum
  documented as fatal.

- **BobISA jumps encode the source label.** Axelsen–Yokoyama 2011.
  Reversible jumps must let the predecessor pc be recovered from
  local state. A jump that doesn't is not reversible and breaks
  the no-history-for-control-flow property. Phase-2 control flow
  must follow BobISA, not a classical jump model.

- **Enzyme's min-cut is the algorithm we want.** Moses–Churavy et
  al. The Bennett-1989 pebbling problem specialized to dataflow
  graphs, solved heuristically at LLVM IR. Phase 2 ports this; it
  does not reinvent it. If you find yourself designing a delta-
  history selector from scratch, you are violating Law 2.

- **rr's lesson is "record nondeterminism, replay determinism."**
  O'Callahan–Huey 2017. The VM is fully deterministic (no I/O, no
  concurrency, no RDRAND), so the right base mechanism is
  *periodic checkpoints + deterministic forward replay*, **not**
  per-step logging. Per-step logging is the worst point on the
  time-space curve; the spike does it deliberately so we can hate
  it; Phase 2 must not.

- **Reqomp ≠ Unqomp ≠ Qurts ≠ spooky pebbling.** They occupy
  different points in the quantum-uncomputation design space.
  Unqomp: synthesizes uncomputation, no qubit budget. Reqomp:
  trades qubits for gates under a space bound. Qurts: type-driven
  uncomputation via affine types with lifetimes. Spooky pebbling:
  uses mid-circuit measurement. Picking the wrong one wastes weeks.
  See PRD v3 §2.6.

- **Floating-point reversibility is not solved.** PRD v3 §3.6
  leaves the choice (residual tape vs posit-with-sticky vs opaque
  snapshots) to v4. Do not invent a floating-point reversibility
  scheme in the spike or in Phase 2 ahead of v4. If you find
  yourself drafting one, file a bd issue and stop.

- **"The VM is the quantum target" is wrong.** Per PRD v3 §3.7,
  the VM backend yields a classical reversible interpreter. For
  quantum, the pebble-game lowering pass extracts a uniform-circuit
  family from the VM program. Conflating these is a category error.

- **Don't read RC3 source as a transcription target.** PRD v3 §2.2:
  RC3 (THM) is the closest existing analogue and a listed
  dependency; read it for design lessons, *not* to translate
  Janus-specific decisions into Julia-specific code. The Janus
  source language is reversible-by-construction; Bennett.jl's
  source language (Julia subset) is not. Decisions valid in RC3
  are not automatically valid here.

---

## Reuse-map enforcement

PRD v3 Part IV is the binding reuse map. For Phase 2, every PR
that introduces a non-trivial design choice must include, in the
commit body:

```
Reuse: <name of the published work this builds on / reuses / ports>
  Source: references/<file>.pdf, §<section> (page <n>)
Why not reuse further: <one sentence>
```

Examples of what passes:

- `Reuse: Mogensen RSSA 2016 §3 (φ-nodes on splits and joins). Why not reuse further: extending to handle Julia-specific TypedSlot annotation, not in the original.`
- `Reuse: Enzyme min-cut analysis (Moses-Churavy SC 2021). Why not reuse further: porting from LLVM IR to BennettVM IR; algorithm is identical.`

Examples of what fails:

- "Designed a new reversible SSA form" → violates Law 2. Use RSSA.
- "Implemented a pebble-game scheduler from scratch" → violates Law 2.
  Read Knill 1995 §2.1 first.

---

## Commit discipline

Every commit is atomic and carries provenance.

Commit message template:

```
<scope>: <one-line summary>

Source: <local path or URL>
Source SHA256 (if file): <hash>            # optional, for unstable URLs
Reuse: <published work being ported, or "none — new for this project">
Validation: <which gates were exercised — tests, lint, mutation-proof, golden-master>
Review: <verdict from reviewer subagent, OR "mechanical, exempt">
Rollback: <git revert <commit> | rm -rf <path>>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

- One atomic step per commit.
- Never `git commit --amend` on a pushed commit.
- Never bypass hooks (`--no-verify`).
- Bennett.jl integration commits cite the Bennett.jl commit hash they
  were tested against.

---

## Build & test

Until the Julia package is initialized, this section is aspirational.
Once initialized (Phase 0 task P0.1 in the spike checklist), the
canonical invocations are:

```bash
# Phase 0 — single test
julia --project test/test_roundtrip.jl

# Phase 0 — full suite
julia --project -e 'using Pkg; Pkg.test()'

# Phase 0 — REPL probe
julia --project -e 'using BennettVMSpike; s = initial_state(countdown(5)); run!(s); println(result(s)); unrun!(s); @assert isempty(s.history)'

# Phase 2 — full suite (will exist post-v4)
julia --project -e 'using Pkg; Pkg.test()'

# Phase 2 — Lean (post-v4, when Formalisation/ appears)
lake build
```

Single-file tests must match suite mode (`--check-bounds=yes`) per the
Bennett.jl Bennett-2mj3 lesson; a per-file "green" claim is only
meaningful at the same bounds-checking level as the suite.

---

## Beads

`bd` (beads) is the only persistent task tracker. Backend: embedded
Dolt with JSONL export for cross-device sync (the cft-anyons /
Feynfeld pattern; not the Bennett.jl `bd dolt push` pattern).

```bash
bd ready                                      # find work
bd show <id>
bd create --title="..." --description="..." --issue-type=task --priority=2
bd update <id> --status in_progress           # claim
bd close <id>                                 # done
bd dep add <issue> <depends-on>
bd export -o .beads/issues.jsonl              # snapshot for cross-device
```

Rules:

- File issues for anything that should outlive the conversation.
- Never `bd init --force` (destroys data).
- `bd export -o .beads/issues.jsonl` before every session-ending
  commit if you closed or modified issues.
- `.beads/embeddeddolt/` is per-machine and gitignored; the JSONL is
  the cross-device sync channel, not Dolt push.

---

## Session completion ("landing the plane")

Work is NOT complete until `git push` succeeds.

1. **File beads** for any remaining work surfaced during the session.
2. **Run quality gates** (whichever apply):
   - `julia --project=. -e 'using Pkg; Pkg.test()'` if `src/` or `test/` changed.
   - `lake build` if `Formalisation/` changed (Phase 2).
   - Round-trip property test if any VM internals changed.
3. **Update issue status** — close finished, update in-progress.
4. **Update worklog** (when one exists) with non-obvious lessons.
5. **Push to remote**:
   ```bash
   git pull --rebase
   bd export -o .beads/issues.jsonl
   git add .beads/issues.jsonl
   git push
   git status                                # must show "up to date"
   ```
6. **Verify** all changes committed AND pushed.
7. **Hand off** — short note for the next agent: what landed, what
   was left, why.

Hard rules:

- Work is not complete until `git push` succeeds.
- Never stop before pushing; that leaves work stranded locally.
- Never say "ready to push when you are" — *you* push.

---

## Stop conditions (escalate to user)

Don't push through any of these.

- A choice between two published-prior-art options where the PRD
  defers the decision to v4 (e.g., floating-point scheme, pebble
  game vs Reqomp binding).
- An apparent conflict between PRD v3 and `../Bennett.jl/Bennett-ReversibleVM-PRD.md`.
- A change that would mutate `../Bennett.jl/src/`.
- A change that would add a `sorry` or `axiom` in the Lean
  formalization (Phase 2).
- The round-trip invariant fails on a test the spike committed as
  passing (Phase 0).
- The Phase-0 retrospective cannot be written truthfully because
  the session produced no concrete decisions (PRD v3 §7.1).
- The reuse-map check (Law 2) cannot be satisfied — i.e., you cannot
  identify what published work a design replaces — and you suspect
  the reason is that the work already exists and we missed it.
- A subagent returns a non-actionable verdict ("looks ok" with no
  per-claim signoff). Re-request the review with an explicit
  checklist; if still vague, escalate.

When escalating, attach: the step you were on, what failed, the
specific reproducible command, the relevant PRD section, and the
local-source citation.

---

## File map (proposed; create as needed)

```
bennettvm_prd.md          # PRD v3 (the controlling document, present)
PHASE.md                  # one-line: "Phase 0" | "Phase 1 (archive)" | "Phase 2"
CLAUDE.md / AGENTS.md     # this file (identical pair)
README.md                 # public-facing intro (later)
WORKLOG.md                # sharded session log, Bennett.jl-style (later)

references/               # local PDFs — Bennett 1973, Mogensen RSSA,
                          # Yokoyama-Glück 2007, Knill 1995, Vieri 1995/99,
                          # Axelsen-Yokoyama 2011, Moses-Churavy Enzyme,
                          # Paradis et al Unqomp/Reqomp, Hirata-Heunen Qurts,
                          # Meuli et al 2019, Quist et al 2025 (spooky pebbling).
                          # Acquisition is a prerequisite, not a side quest.
references/manifest/SOURCES.md   # SHA256-verified extraction manifest

# Phase 0 only:
spike/                    # the throwaway. Read-only post-close.
  Project.toml            # name = "BennettVMSpike"; private = true
  src/BennettVMSpike.jl
  test/test_roundtrip.jl
  test/test_countdown.jl
  RETROSPECTIVE.md        # THE Phase-0 deliverable

# Phase 2 (post-v4):
Project.toml              # name = "BennettVM"
src/
  BennettVM.jl
  ir/                     # RSSA-derived IR
  isa/                    # Pendulum/BobISA-derived instructions
  history/                # min-cut delta selection, rr-style checkpoints
  pebble/                 # Bennett-1989 lowering pass
  integration/            # Bennett.jl IR ingestion
test/
Formalisation/            # Lean 4 — abstract VM semantics only
lakefile.lean
docs/
  adr/                    # ADRs for design choices
  prd/                    # frozen PRD versions (v3 archived here once v4 exists)
reviews/                  # frozen review subagent outputs
scripts/
  pre-push                # local git hook running Pkg.test()
.beads/
  issues.jsonl            # cross-device sync channel
```

---

## Tool of last resort

If the Laws conflict with a fast path: choose the Laws. *"Just ship
and fix later"* is not a working mode here. The cost of a Phase-0
spike that survives into Phase 2 — or a Phase-2 instruction set
that quietly diverges from BobISA — is months of unwinding plus loss
of confidence in the artifact; the cost of stopping to acquire the
right PDF or read RSSA §3 again is minutes.

When in doubt: re-read this file, re-read `bennettvm_prd.md`, re-read
the relevant local PDF, then ask the user.


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for persistent task tracking — do NOT use TodoWrite or markdown TODO lists. `TaskCreate` is permitted for ephemeral in-session tracking (see Rule 13).
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
