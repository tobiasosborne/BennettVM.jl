# HANDOFF — BennettVM.jl

> What the next session needs to know. Read top to bottom; do not skim.

## Current state (2026-05-25)

- **Phase:** **Phase 2 (production).** Flipped from Phase 1 on 2026-05-25.
- **PRD:** `bennettvm_prd.md` is v4 (1223 LOC, hostile-reviewer-passed).
  v3 archived at `docs/prd/bennettvm_prd_v3.md`.
- **Open bd issue:** `bennettvm-phase2-epic` (created at Phase-2 open;
  M0–M12 milestones from v4 §Part IX as child issues).
- **Closed bd issue:** `bennettvm-pb2` (Phase-1 PRD-v4 epic, closed
  2026-05-25 with this PRD as the deliverable).
- **Most recent commit:** see `git log -1` — PRD v4 ratification.
- **Git tag:** `spike-0-archived` still marks the end of Phase 0. No new
  tag created for v4 ratification.
- **Test suite:** spike `spike/` is frozen (789/789 passing, chmod -w);
  Phase-2 `test/` is empty.

## What you (next session) are picking up

Phase 2 milestone M0 — but **gated by M5** (RC3 `rvm` pre-read; v4 §6 SC6).
Do NOT start writing Phase-2 IR code before M5 is documented in
`docs/adr/0001-rc3-rvm-smoke.md`.

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
