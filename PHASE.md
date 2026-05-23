Phase 1 (archive; PRD v4 pending)

Phase 0 closed: 2026-05-23.

## What happened in Phase 0

One Claude Code session, multi-pass serial orchestration.

- **Sub-agent passes:** 11 total (Opus for coding, Sonnet for review/summarization, per user directive).
- **Code result:** Bennett-1973 trace VM in `spike/`, 789/789 tests passing, mutation-proof verified.
- **Deliverable:** `spike/RETROSPECTIVE.md` (264 LOC, all 9 questions answered honestly).
- **Beads:** epic `bennettvm-ua7` with 11 closed child issues.
- **Git artifact:** tagged `spike-0-archived`.
- **Filesystem artifact:** `spike/` chmod'd `-w` recursively at archival.

## What the retrospective surfaced (sharpest items for PRD v4)

1. **`RState` must be `mutable struct`**, not the immutable struct PRD §5.3 wrote. Required by the in-place `step!`/`unstep!`/`run!` convention.
2. **`Base.==` and `Base.hash` overrides on `IState` are MANDATORY**, not optional. Julia's default `==` does identity-compare on `Dict` fields — without the override, round-trip equality silently never holds.
3. **`step!` must call `forward()` BEFORE `push!(history, snapshot)`**, not after. Pass-1's original order corrupted history on `forward` exception. Pass-1F reorder fixed it.
4. **Per-step inverse test pattern** is load-bearing. Aggregate round-trip test alone misses middle-instruction inverse bugs because the leading Const inverse masks corruption.
5. **Return/Halt collapse** in spike (no subroutines) — Phase 2 must decide whether to keep both or unify.
6. **`UnaryOp :not`** is bitwise `~` on `Int64`, not boolean negation — PRD §5.1's "Bool-typed regs" wording is moot until a type system exists.
7. **Bennett 1973 PDF gap** — substitute sources (Vitanyi CF'05 §2, Bennett 1989 §1–2 Lemma 1, BTV 2001 §1) were adequate for Phase-0 Stage 1. Phase-2 Stage 2 ("Output") and Stage 3 ("Cleanup") will need the original. TIB ILL remains the recommended acquisition path.
8. **Q6 cross-check (Law 2 evidence):** none of RC3, TOPPS-janus, jana, janus-vesta, evincarofautumn-janus has a history-tape + round-trip property test in the BennettVM sense. RC3 does compiler-level RSSA reversal (no runtime trace). TOPPS-janus does syntactic `invertStmt` — the Yokoyama-Glück 2007 "no history for reversible source" lesson. The BennettVM design IS distinct, not a rebuild of existing work.

## What's next (Phase 1 → PRD v4)

The PRD v4 author MUST:

- Read **every** §2 reference (Part II literature review). Available in `references/`, manifest-tracked.
- Cross-reference the spike retrospective (`spike/RETROSPECTIVE.md`) section-by-section into v4.
- Resolve PRD v3 §VIII open questions (FP scheme; Bennett.jl integration boundary; Lean vs Coq; pebble-game-as-binding vs ship-in-tree).
- Adopt the BobISA citation correction (Thomsen-Axelsen-Glück 2012, not Axelsen-Yokoyama 2011).
- Acquire Bennett 1973 PDF before Stage 2/3 design begins.

The Phase-2 production VM starts from an empty `src/` + `test/` tree (CLAUDE.md P0.7). **No code from `spike/` is promoted.** Phase 2 design is informed by the retrospective; implementation is fresh.

## How to flip to Phase 2

When PRD v4 lands:
1. Move `bennettvm_prd.md` → `docs/prd/bennettvm_prd_v3.md`.
2. Drop the v4 PRD at `bennettvm_prd.md` (root).
3. Update this file to `Phase 2 (production)` with the v4 ratification date.
4. Start the Phase-2 epic in beads.
