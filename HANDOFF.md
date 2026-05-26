# HANDOFF — BennettVM.jl

> What the next session needs to know. Read top to bottom; do not skim.

## Current state (2026-05-26 — Session 4 close)

- **Phase:** **Phase 2 (production).**
- **PRD:** `bennettvm_prd.md` is v4.
- **Bennett.jl pin:** `877341e` (unchanged this session).
- **Test suite:** **990 / 990 passing.** `julia --project=. -e 'using Pkg; Pkg.test()'`.
- **Setup gotcha:** Manifest.toml is gitignored (per-machine). Fresh
  clones MUST run `julia --project=. -e 'using Pkg; Pkg.develop(path="../Bennett.jl"); Pkg.instantiate()'`
  before tests pass.
- **M4 (history layer L3: checkpoint-replay) — CLOSED this session.**
  All five sub-beads:
  - **M4.1** `cbd6644` — `CheckpointEntry <: AbstractHistoryEntry`,
    deep-copy constructor + structural ==/hash. New file
    `src/history/CheckpointEntry.jl`.
  - **M4.2** `a325be5` — `step!` pushes CheckpointEntry every K steps.
    RState gains `step_count::Int`. `step!` / `run!` gain
    `checkpoint_interval::Int = 64` kwarg. `&& step_count > 0` guard
    is load-bearing for M4.3's replay arithmetic.
  - **M4.3** `9f6cda7` — `unstep!(s, prog)` via find-nearest-checkpoint
    + restore-deepcopy + truncate + replay-forward. New file
    `src/history/Replay.jl`. RState gains `initial::IState` field.
  - **M4.4** `36e2cd3` — `unrun!(s, prog; max_unsteps=10_000)` loops
    unstep! until `step_count == 0`, asserts `isempty(history)` as
    structural post-condition. NO manual status reset.
  - **M4.5** `61c47cd` — M4 milestone capstone round-trip test.
    10 testsets, 141 new assertions, per-step inverse pattern from
    spike Q3. K ∈ {1, 2, 4, 7, 16, 64, typemax(Int)}.

## What you (next session) are picking up

**M6 — history layer L1 (injective no-log) — is the next milestone.**

M6.1 introduces an `is_injective(::Type{<:Instruction})::Bool` trait;
specializations for `SwapInstruction`, all `ControlInstruction`
subtypes, `MemoryInterchange`, `MemorySwap`, `ArithmeticAssignment` when
`modop === :xor`. M6.2 modifies `step!` to skip the checkpoint push for
injective instructions. M6.3 wires the matching `inverse`
reconstruction. M6.4 round-trip test with zero history entries.

After M6: M7 (L2 delta min-cut, Enzyme-style), M8 (per-step inverse
property test). Then the four P0 SC9 motivating cases (M_DICT, M_DYN,
M_NESTED, M_UNBOUNDED).

### Open observation flagged this session

- `bennettvm-kuq` (P2): `unstep!` search loop uses
  `entry isa CheckpointEntry` while the truncation loop uses the
  polymorphic `_entry_step()` helper. Asymmetric. Only matters when
  M6/M7 entry types arrive; the M6 implementer should resolve when
  they touch Replay.jl.

### Session 4 notes

- 31 stale beads (M5/M0/M2/M3 sub-beads) were closed at session start
  to reconcile the tracker with `git log` reality.
- M4.5's hostile review was in progress in the background when the
  session was paused. The reviewer's mutation probe to
  `src/history/Replay.jl` (removing the restore-side deepcopy) was
  caught and reverted on `git status` BEFORE the M4.5 commit. The
  probe DID empirically confirm one matrix entry (restore-side
  deepcopy → M4.5 test 4 RED). Full M4.5 hostile review can be
  resumed next session if any latent doubt remains.

### Earlier state (preserved for history)

## Old state (pre-Session-4, retained for diff context)

- **Phase:** **Phase 2 (production).**
- **PRD:** `bennettvm_prd.md` is v4. v3 archived at `docs/prd/bennettvm_prd_v3.md`.
- **Bennett.jl pin:** `877341e` (repinned 2026-05-26 from `5731cec`,
  docs-only diff).
- **Test suite:** **565 / 565 passing.** Single `julia --project=. -e
  'using Pkg; Pkg.test()'`.
- **Milestones complete (2026-05-26 orchestration session):**
  - **M5** — RC3 `rvm` pre-read (build + sample run + instruction
    taxonomy). ADR at `docs/adr/0001-rc3-rvm-smoke.md`.
  - **M0** — Bennett.jl handoff smoke (Project.toml, src/BennettVM.jl
    skeleton, lower_vm digest, regression-anchor test). ADR at
    `docs/adr/0000-handoff-smoke.md`.
  - **M2** — IR foundation (18 sub-beads): all 12 RSSA instruction
    types (ArithmeticAssignment, SwapInstruction, MemoryAssignment,
    MemoryInterchange, MemorySwap, CallInstruction, BeginInstruction,
    EndInstruction, UnconditionalEntry/Exit, ConditionalEntry/Exit)
    with forward/inverse + constructor validation + round-trip tests;
    BasicBlock with structural_inverse + reversed(); LabelTable
    with dual-address layout; VMProgram with cross-block container.
  - **M3** — forward-only interpreter (8 sub-beads): initial_state,
    is_halted, result, step!, run! with max-steps guard, cross-block
    dispatch via LabelTable, args→params two-phase rename,
    countdown(N) golden-master integration test against an
    irreversible Julia reference (countdown_ref).
- **Most recent commit:** see `git log -1`.
- **Git tag:** `spike-0-archived` still marks the end of Phase 0. No new
  tag created for v4 ratification.
- **Test suite:** spike `spike/` is frozen (789/789 passing, chmod -w);
  Phase-2 `test/` is empty.

## What you (next session) are picking up

**M3 (forward interpreter) closed. M4 is the next milestone** — history
layer 3 (checkpoint-replay), which is the first step toward `unrun!`
and the reverse direction. After M4 comes M6 (history L1 — injective
no-log), M7 (history L2 — delta min-cut), M8 (per-step inverse +
property test).

After the history layer is in, the four motivating cases (M_DICT,
M_DYN, M_NESTED, M_UNBOUNDED — all P0) become the SC9 acceptance
gate.

Parallel-startable independent tracks:

- **M1.1** (P1) — benchmark harness for history strategies. Independent
  of M4-M8.
- **M_OPCODE** (P1) — audit lower_vm against Bennett.jl's 17 IRInst
  subtypes (only 6 are exercised so far via collatz_steps).
- **M_FP.1** (P1) — ADR documenting SoftFloat-dispatch FP inheritance.

### Earlier handoff (Phase-2 first session: M5 + M0) — DONE

This section is preserved for historical reference; M5 and M0 closed
2026-05-26.

### A. Phase-2 first session: M5 + M0 (recommended)

This is `bennettvm-phase2-epic` first child issues (M5 then M0).

1. **M5 — RC3 `rvm` pre-read** (gates everything).
   - Build `rc3` and `rvm` from `references/implementations/RC3/`. The
     repo uses Maven/CUP; build instructions in its README. **Java
     toolchain required.**
   - Run at least one RSSA program through `rvm`. Sample programs in
     `references/implementations/RC3/compiler/programs/rssa/vm/`.
   - File `docs/adr/0001-rc3-rvm-smoke.md` capturing: (a) build steps;
     (b) the sample RSSA program; (c) `rvm` output; (d) verbatim
     observations about RSSA semantics that should inform Phase-2 IR.
   - The literature pre-read (Mogensen 2016 §3, Deworetzki-Meyer 2021
     §2.2 pp. 66–67) should happen before or during this milestone.

2. **M0 — Bennett.jl handoff smoke** (PRD §6 SC1, §9 M0).
   - Initialize Phase-2 Julia package: `Project.toml` at root,
     `src/BennettVM.jl`, `test/runtests.jl`.
   - Implement a stub `lower_vm(parsed::ParsedIR) :: VMProgram` that
     returns an empty `VMProgram` and prints a digest of the input
     `ParsedIR` (number of blocks, instructions, args).
   - Call it on `collatz_steps(::Int8)` from
     `Bennett.jl/test/test_y986_loop_header_dispatch.jl:129`. Goal:
     verify the import works at pin `5731cec` and the type signature is
     correct.
   - File `docs/adr/0000-handoff-smoke.md` with the digest output.

### B. Alternative first session: M1 (cost measurement)

Independent of M5/M0. Could be done in parallel by a separate session.

- Benchmark, on the spike's countdown(10_000) program (the spike is
  read-only — `chmod -R u+w spike/` first, restore after):
  - Full-snapshot history (the spike baseline).
  - A delta-history sketch (just record `(register, old_value)` tuples).
  - A periodic-checkpoint sketch (snapshot every K steps; replay forward
    from nearest checkpoint to reach an arbitrary step).
- Write up in `docs/measurements/m1-history-cost.md`. Use the data to
  set the default checkpoint interval in v4 §3.3.

### What to NOT do

- **Do NOT promote spike code into Phase 2.** PRD v4 §1.1, §5.3, §7.7.
  Phase 2 starts from an empty `src/`+`test/` tree. The spike is tagged
  `spike-0-archived` and `chmod -R -w`. Use as a *pattern source*, not
  source to fork. The reviewer specifically called this out as
  load-bearing.
- **Do NOT modify Bennett.jl source.** CLAUDE.md Rule 14. v4 §3.7
  Handoff A is specifically designed so that Phase-2 M0 does not require
  any Bennett.jl mutation. If you find yourself wanting to add an export
  to Bennett.jl (e.g., for `IRBasicBlock`), STOP and ask the user. The
  qualified-access pattern (`Bennett.IRBasicBlock`) suffices.
- **Do NOT skip the RC3 pre-read.** PRD v4 §3.1 and SC6 are explicit.
  Writing Phase-2 IR before reading RC3's `instances/` directory is a
  Law-2 violation.
- **Do NOT add a `target=:reversible_vm` dispatch arm to Bennett.jl
  unilaterally.** That is Handoff B (v4 §3.7), ADR 0003, requires user
  approval and 3+1 protocol.
- **Do NOT introduce floating-point support.** v4 §3.6: out of scope for
  Phase-2 initial release. Emit a clear "FP not supported" error if a
  `ParsedIR` carries an FP `IRBinOp`.

## Key v4 normative requirements (cheat sheet)

Sections to re-read often:

- **§3.1** RSSA IR; isomorphic to RC3 taxonomy (12 concrete subclasses).
  φ-equivalents on BOTH joins AND splits. Variable-destroying uses.
- **§3.2** Injective / non-injective / control-flow partition. Memory =
  exchange. Jumps = source-label-encoded.
- **§3.3** Three-layer history: no-log / delta-min-cut / checkpoint-replay.
  Full snapshots forbidden.
- **§3.7** Consume `Bennett.ParsedIR` (`Bennett.jl/src/ir_types.jl:347`).
  `IRBasicBlock`/`IRInst` not exported; access qualified. `IRLoad`/`IRStore`
  → `Exchange` translation pass required pre-RSSA.
- **§3.9–§3.17** Spike-derived API + invariants (mutable RState, structural
  `==`, forward-before-push, discard-pop predicate, per-step inverse test,
  golden master co-location, seeded random programs WITH control flow).

## Tools you should know about

- **`bd ready`** — find available work. After Phase-2 epic opens, M0/M5
  will appear.
- **References are not in git.** `references/` is ~127 MB and intentionally
  untracked. SHA256 manifest at `references/manifest/SOURCES.md`.
- **Bennett 1973 PDF on disk** at `references/foundational/bennett-1973-logical-reversibility.pdf`
  (user-supplied 2026-05-25; SHA256 `e61ad668…0687`). v3's blocker is
  resolved.
- **`playwright-cli` with `--browser chromium --headed`** still works for
  paywall acquisition. ACM DL still blocked.
- **`spike/`** is `chmod -w`. If you need to re-run a probe (e.g., for M1
  cost measurement), `chmod -R u+w spike/`, run, then `chmod -R -w spike/`.

## Bennett.jl pin

- Pinned SHA: `5731cec22a1fd29efe02d4dc21c2a57e655ecb47`.
- Pin date: 2026-05-23. Confirmed still current 2026-05-25.
- See [`BENNETT_JL_PIN.md`](./BENNETT_JL_PIN.md) for repinning policy.
- Phase 2's Handoff A (v4 §3.7) is designed to be insensitive to most
  Bennett.jl changes; only `ParsedIR` struct breakage requires repinning.

## Open questions for the user (deferred from v3 §VIII)

(Reduced from six to two genuine items; see v4 §8.1.)

1. **Floating-point reversibility scheme.** Residual tape vs posit-with-
   sticky vs opaque snapshots. v4 defers to v5 after a Phase-2 prototype.
2. **Divergence handling.** Whether Phase 2 inherits Bennett.jl's
   `max_loop_iterations` style or implements a separate termination
   analysis.

## Quick session-start checklist

When the next agent arrives:

- [ ] `cat PHASE.md` — confirm Phase 2.
- [ ] `bd ready` — what's claimable. Expect Phase-2 milestones.
- [ ] Read `bennettvm_prd.md` (v4) §0, §1, §3, §6, §9 at minimum.
- [ ] Read this `HANDOFF.md` top to bottom.
- [ ] Read `CLAUDE.md` top to bottom (Rule 16: re-read after every context
      compression).
- [ ] Skim `WORKLOG.md` Session 2 for what landed.
- [ ] Read `spike/RETROSPECTIVE.md` if not done in prior session.
- [ ] Only then start work — and start with M5, not M0.
