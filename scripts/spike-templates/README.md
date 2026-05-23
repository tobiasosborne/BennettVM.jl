# Phase-0 spike sub-agent prompt templates

> Print before opening the Phase-0 session. PRD v3 §1.2 / §5.5.

The Phase-0 spike is **one Claude Code session, hard stop**. To use
the session well, the orchestrator agent dispatches four sequential
sub-agents — never in parallel (Julia precompile-cache contention; PRD
§5.5; CLAUDE.md Rule 7). The reviewer engages after each core change.

```
                 ┌─────────────────────────────┐
                 │  orchestrator (this session)│
                 └─────────────────────────────┘
                              │
        ┌────────┬────────────┼────────────┬────────┐
        ▼        ▼            ▼            ▼        ▼
  ┌─────────┐ ┌─────────┐ ┌──────────┐ ┌────────┐ ┌──────┐
  │interp.  │→│instrs.  │→│  tests   │→│reviewer│→│ retro│
  │subagent │ │subagent │ │ subagent │ │engages │ │      │
  └─────────┘ └─────────┘ └──────────┘ │ after  │ │      │
                                       │  EACH  │ │      │
                                       └────────┘ └──────┘
```

## Orchestration order

1. **Pre-flight (orchestrator, no subagent yet):**
   - `cat PHASE.md` — must be "Phase 0" (not "Pre-Phase-0").
   - **Bennett 1973 PDF check is WAIVED** by user override
     (PHASE.md "Gate NOT met" section). Use the four substitute
     ground-truth sources listed there instead.
   - Verify `references/reversible-languages/yokoyama-glueck-2007-pepm.pdf`
     exists. If absent, abort.
   - `bd ready` to confirm the Phase-0 bead is claimable.
   - Open `spike/` (subdirectory chosen in CLAUDE.md task #10).
     Initialize Julia package; mark `private = true` in Project.toml.

2. **Interpreter sub-agent** — `01-interpreter.md`. Output:
   `src/{Types.jl, Interpreter.jl}`, plus a one-line API sketch in the
   spike module.

3. **Reviewer engages.** `04-reviewer.md`. Hostile read of the
   interpreter. Commits only after the reviewer's verdict is in the
   commit body.

4. **Instruction-set sub-agent** — `02-instructions.md`. Output:
   `src/Instructions.jl` with the eight bytecodes from PRD v3 §9.1 (v2)
   / §5.1 (v3), forward + inverse semantics for each.

5. **Reviewer engages again.** Particularly: are the instruction
   inverses provably correct? Are the `Halt`/`Return` semantics
   consistent with what the interpreter expects?

6. **Tests sub-agent** — `03-tests.md`. Output:
   `test/{test_roundtrip.jl, test_countdown.jl, test_history.jl,
   test_maxsteps.jl}` and a `test/reference/countdown.jl` golden-master.

7. **Reviewer engages a final time.** Are the tests load-bearing per
   CLAUDE.md Rule 4 (not "didn't throw")? Do they include
   mutation-proof for at least the round-trip invariant?

8. **Retrospective.** Orchestrator opens
   `scripts/spike-templates/RETROSPECTIVE.md`, copies it to the spike
   root as `RETROSPECTIVE.md`, fills it in. **THIS IS THE DELIVERABLE.**

9. **Close.** Mark spike repository read-only; flip `PHASE.md` to
   "Phase 1 (archive)"; file PRD-v4 bead with retrospective attached.

## Hard rules during the session

- **Sequential, not parallel.** No two Julia-touching subagents at
  once (CLAUDE.md Rule 7).
- **Eight instructions only.** If a ninth feels needed, stop — log it
  for PRD v4 instead (PRD §5.1, CLAUDE.md P0.4).
- **Bennett 1973 §3 is the construction.** Cite it in code comments
  per Law 1.
- **Golden master required.** Every test program has a reference
  irreversible Julia function. Forward execution agrees bit-for-bit
  (CLAUDE.md P0.5).
- **Round-trip is load-bearing.** `unrun!(run!(s, prog)) == initial(s)
  && isempty(s.history)` (CLAUDE.md P0.6).
- **Hard stop at session end.** Whatever state, mark it as the
  deliverable (CLAUDE.md P0.1).
- **No Bennett.jl integration.** Spike is standalone (PRD §5.2).
- **No fixed-point, no FP, no RAM, no oracle mode, no Lean.** All
  Phase-2 concerns (PRD §5.2, CLAUDE.md P0.4).
