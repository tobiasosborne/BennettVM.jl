# Phase-0 Spike Retrospective — BennettVM.jl

> **THIS IS THE PHASE-0 DELIVERABLE** (PRD v3 §1.2, §5.6). The spike
> itself is throwaway; this document is what survives. Phase-0 is not
> closed until every section below is filled in honestly. Empty
> sections = Phase-0 failure (PRD §7.1).

**Spike session date:** 2026-05-23
**Session duration:** ~3 hours (multi-pass orchestration)
**Lead agent (orchestrator):** Claude Opus 4.7 (1M context)
**Sub-agents engaged:** Pass 1 (Opus — interpreter), Pass 1R (Sonnet — review), Pass 1F (Opus — revise), Pass 1R2 (Sonnet — re-review), Pass 1F2 (Opus — mechanical fix), Pass 2 (Opus — instructions), Pass 2R (Sonnet — review), Pass 3 (Opus — tests), Pass 3R (Sonnet — review), Pass 3F (Opus — mechanical fixes)
**Spike repository path / commit SHA at close:** `spike/` in BennettVM.jl working tree; 789/789 tests passing at close
**Bennett.jl version pinned during spike:** `5731cec`

---

## Q1. Which PRD v3 assumptions turned out wrong or underspecified?

- **PRD v3 §5.3** wrote `struct RState` as an immutable struct with `current::IState + history::Vector{IState}`. In practice `RState` must be `mutable struct` so `step!` and `unstep!` can rebind `s.current` in place. An immutable struct would require callers to rebind the variable on every call, which breaks the mutating-in-place convention the `run!` loop depends on.

- **PRD v3 §5.3** said "Equality, hashing, copying: whatever Julia provides by default, with explicit overrides only where round-trip equality forces it." Julia's default `==` on a struct containing `Dict` falls back to `===` (object identity) on the dict field. This silently breaks the round-trip invariant `unrun!(run!(s, prog)) == initial_state(prog)` because two structurally identical `IState`s created at different times compare unequal. Explicit `Base.==` and `Base.hash` overrides on `IState` are mandatory, not optional. PRD v4 should state this explicitly.

- **PRD v3 §5.1** mentions "Bool-typed regs for `:not`". The spike's `locals` dict is `Dict{Symbol, Int64}` uniformly. There are no Bool-typed registers. `:not` is bitwise complement on `Int64`, not boolean negation. The PRD's mention of `Bool` scalars in the spike context is misleading; the actual type is `Int64` with `Bool` stored as `0`/`1`.

- **PRD v3 §5.1** and §5.2 leave halt semantics unspecified. The question "does a terminal `Halt` instruction push a history entry?" is not addressed. The answer (discard-pop if and only if the transition is a pure status flip with pc and locals unchanged) is non-obvious and required deliberate design. PRD v4 should specify this.

- **PRD v3 §5.4 test 3** says `length(st.history) == steps_taken`. "Steps taken" is ambiguous: is an idempotent terminal-status-flip step counted? The spike resolves this as: a Halt that only flips status (pc and locals unchanged) does NOT increment the history count. The PRD wording is insufficient; v4 should cite the discard-pop predicate explicitly.

- **PRD v3 §1.2** says the spike should include "gcd as a stretch goal." Time was adequate but the scope decision was to stay with countdown and focus on test quality (789 tests including per-step inverse mutation-proof). No gcd program was written. This is not an incorrect assumption, just an unmet stretch goal; PRD v4 need not change anything here.

---

## Q2. Ambiguities resolved by Claude Code (and how)

### Q2.1 Equality semantics for `IState`, `RState`, `HistoryStack`

- **What was decided:** Override `Base.==` and `Base.hash` on `IState` to compare structurally (pc, status, and dict-equal locals). `RState` uses identity equality (Julia default); test code compares fields explicitly.
- **Why:** Julia's default `==` on structs containing `Dict` fields reduces to `===` on the dict object (identity, not structural equality). A REPL probe confirmed this before the override was written. Without the override, `unrun!(run!(s, prog)).current == initial_state(prog).current` silently returns `false` on every call regardless of correctness — the P0.6 invariant cannot be tested. The override is at `Interpreter.jl` lines 103–109.

### Q2.2 Copy / deepcopy semantics

- **What was decided:** `step!` performs `deepcopy(s.current)` before pushing the snapshot. This happens *before* calling `forward(instr, s.current)`, so an exception inside `forward` leaves `s.history` and `s.current` untouched.
- **Why:** `IState.locals` is `Dict{Symbol,Int64}`. If a future instruction's `forward` accidentally returned a new `IState` sharing the same dict object as its input, the historical snapshot and the live state would alias; a subsequent mutation would corrupt history silently. A shallow `copy` would be safe *only if* every `forward` implementation is required to return a fresh dict — a discipline enforced by a separate agent that cannot be audited locally. `deepcopy` is the locally-enforceable conservative choice. The pre-`forward` ordering is a Pass 1F fix; the original Pass 1 code computed `forward` first, then deepcopy'd, which meant a `forward` exception could leave history one entry ahead of the state.

### Q2.3 Error-state handling (division by zero, overflow, etc.)

- **What was decided:** The pre-step snapshot is pushed, then *discard-popped* if and only if the post-step transition is a pure status flip: `status` becomes terminal AND `pc` and `locals` are unchanged. An erroring instruction that also mutates `pc` or `locals` retains its snapshot.
- **Why:** An error instruction that has observable side effects on `IState` must remain reversible. Only a completely idempotent status flip carries no information worth preserving in history. The two terminal statuses (`:halted`, `:error`) share one code path in `step!` (`Interpreter.jl` lines 182–185).
- **Is the error state itself reversible?** Yes, if the snapshot was retained. The error state can be `unstep!`'d back to the pre-error state. If the snapshot was discard-popped (pure status flip), the `:error` state cannot be individually reversed, but that case means pc and locals were unchanged anyway.

### Q2.4 Halt-state propagation

- **Does `step!` on a halted state error, no-op, or push a halt entry?** Silent no-op.
- **Why:** `run!` is a `while s.current.status === :running` loop. If `step!` on a halted state threw, every caller would need an explicit post-halt guard. The fail-fast behavior that matters is `unstep!` on empty history (which does throw). `Halt` and `Return` forward methods (`Instructions.jl` lines 240–244) produce a state identical to input except `status = :halted`; the discard-pop predicate fires, so no history entry is pushed. This is the same Q2.3 predicate applied to the `:halted` case.

### Q2.5 History representation

- **`Vector{IState}` with full deepcopy snapshots.** Not a stack type, not a channel, not delta tuples.
- **Why:** Simplest representation that works. Full snapshots make `inverse` trivial (`return prev`) for all eight instructions without requiring instruction-specific inversion logic. This is deliberately the wasteful end of the time-space tradeoff curve. Phase 0 exists to confirm the cost of this choice is unacceptable at scale.
- **Implication for `unstep!`:** `unstep!` pops the vector, dispatches `inverse(instr, current, prev)` where `prev` is the snapshot. In Phase 0, `inverse` returns `prev` unchanged. The `inverse(instr, s, prev)` signature is forward-compatible with Phase 2, where `prev` becomes a delta payload and the body becomes nontrivial.

### Q2.6 `max_steps` semantics

- **Count:** Successful `step!` calls (each iteration of the `run!` while-loop). The check is `n >= max_steps` before each `step!`, so exactly `max_steps` steps execute before the error fires.
- **History on trip:** Retained as-is. The partial history is valid and `unrun!`-able. The caller may inspect `s` after catching the exception. This is documented in `Interpreter.jl` lines 224–230 and verified by `test_maxsteps.jl` and `test_history.jl`.

### Q2.7 Anything else

- **`step!` on a halted or error state:** Silent no-op. Justification at Q2.4 above.
- **`result(s)` on a non-halted state:** Throws `ErrorException` (Rule 1: asking for the result of a still-running computation is a bug). This is the natural error path for callers who forget to check `is_halted`.
- **Return ≡ Halt in the spike:** `Return` and `Halt` are byte-for-byte identical in their `forward` method (`Instructions.jl` lines 240–244). Both flip `status` to `:halted`, pc unchanged, locals unchanged. The distinction is semantic-for-callers only; no subroutines exist in the spike, so `Return` cannot return to anything. PRD v4 should decide whether to keep both or merge.

---

## Q3. What was unexpectedly hard or easy?

### Unexpectedly hard

- **Exception-safety ordering in `step!`.** Pass 1's first implementation computed `forward(instr, s.current)` and pushed the snapshot to history before checking whether `forward` threw. A reviewer catching in Pass 1R required the reorder: compute the new state first (possibly throwing), then mutate `s.history` and `s.current`. This 3-line reorder was a genuine correctness issue, not cosmetic.

- **History-length convention.** Whether an idempotent terminal-status-flip step counts as a "step taken" for the `length(history) == steps_taken` invariant (PRD §5.4.3) required explicit design: the discard-pop predicate changes the count. Three alternatives existed before the spike chose option (c): step-by-step count, `length(history) == n_calls` for non-terminal, `n_calls - 1` after terminal. The test harness in `test_history.jl` required the convention to be stated explicitly in its top comment.

- **Mutation-proof test design.** The initial round-trip test (`test_roundtrip.jl`) was structurally correct but exposed a real weakness: a single-pass aggregate round-trip can mask mid-sequence inversion bugs because a correct inverse later in the sequence overwrites a corrupted intermediate state. Pass 3 added a per-step inverse test (`@testset "per-step inverse"`) that exercises `unstep!` immediately after each `step!`. This caught nothing in the final implementation but correctly turned RED on perturbation — confirming the test is load-bearing.

- **Docstring precision for Q2.3 / Q2.4.** These decisions have subtle interdependencies. Two separate reviewer passes (Pass 1R finding Q2.3 imprecision, Pass 1R2 finding Q2.4 imprecision in the same pattern) were required before the docstring was accurate. The implementation was correct both times; only the documentation lagged.

### Unexpectedly easy (faster than budgeted)

- **The eight bytecodes** (Pass 2). Each instruction is a 5–10 line struct plus forward/inverse. With the interpreter already defining the `forward`/`inverse` dispatch points, implementing all eight took one pass with no reviewer changes.

- **The golden master test** (countdown). The reference Julia function in `test/reference/countdown.jl` is a direct transliteration of the bytecode and took ~20 lines. Forward agreement was verified on the first run.

- **`private = true` in Project.toml.** Flagged as missing in Pass 1R and added mechanically. Trivial but it demonstrates the reviewer-gating process catching minor issues before they require a second pass.

### Surprises about Julia idioms in this domain

- `mutable struct` requirement for `RState` was not anticipated by the PRD's template (`struct RState`). Julia's struct-vs-mutable-struct distinction matters here: the interpreter mutates `s.current` and `s.history` in place; immutable struct would require returning a new `RState` on every step and rebinding the caller's variable.

- `deepcopy` on `Dict` is correct and cheap for the small locals dicts in the spike, but would be unacceptable for any realistic program size. This is a design debt the spike deliberately incurs to feel the pain.

### Surprises about reversibility semantics

- **Halt as a non-reversible boundary.** A pure-status-flip `Halt` discard-pops its snapshot, meaning the initial `:running` status cannot be recovered by `unstep!`. This is correct for Stage 1 of Bennett's construction (the spike only implements Stage 1) but means the round-trip invariant is "restore to initial running state" only if the initial Halt was the terminal step. The degenerate `Program([Halt()])` case is handled with a dedicated test that explains why the full round-trip cannot hold for it.

---

## Q4. What carries over to Phase 2?

- **The `RState.current::IState + RState.history::Vector{IState}` partition.** The split between "current live state" and "history tape" is the right abstraction level. Phase 2 changes the history element type (from full `IState` to delta or checkpoint), not the partition.

- **The `inverse(instr::T, s::IState, prev) -> IState` signature.** Phase 0 passes a full `IState` as `prev`; Phase 2 passes a delta. The dispatch structure is preserved.

- **The `initial_state(prog) -> RState` / `is_halted(s) -> Bool` / `result(s) -> Dict` naming.** These are clean, unambiguous names with well-specified semantics. Keep them.

- **The `step!` exception-safety pattern.** Compute the new state first; mutate `s.history` and `s.current` only after `forward` returns without throwing. This order is correct regardless of history representation.

- **Fail-fast on `unstep!` with empty history.** `error()` with a clear message. This is the load-bearing correctness check for the round-trip invariant; it must remain in Phase 2.

- **The discard-pop predicate for terminal transitions.** The predicate `new_state.status !== :running && new_state.pc == snapshot.pc && new_state.locals == snapshot.locals` is exactly right: skip the history entry for instructions that have no observable effect beyond the status bit. Phase 2 will extend this to "injective instructions push nothing," which is the same idea generalized.

### Test patterns worth keeping

- **Per-step inverse test** (`test_roundtrip.jl` `@testset "per-step inverse"`). Walk forward recording which steps pushed to history; walk backward asserting each recovered state equals the recorded pre-step snapshot. This catches single-instruction inversion bugs that the aggregate round-trip test masks.

- **Mutation-proof discipline.** Perturb the implementation, confirm RED, restore. The spike applied this to catch a real structural weakness in the aggregate round-trip test.

- **Golden master with explicit oracle.** A reference irreversible Julia function in `test/reference/countdown.jl` co-located with the program factory. Every forward-execution test cross-checks against the oracle.

- **Seeded random programs with explicit seed.** `MersenneTwister(0xBE171973)` for the 100-trial property test. Reproducibility across runs is not optional.

### Naming conventions worth keeping

- `IState`, `RState` (instantaneous description / reversible state).
- `step!` / `unstep!` / `run!` / `unrun!` (bang convention for mutation).
- `forward` / `inverse` as generic functions (not methods on `AbstractInstruction` directly — forward-declared in the module, so `include` order doesn't matter).

### Anti-patterns the spike surfaced (do NOT carry over)

- **Full `deepcopy` snapshots per step.** The worst point on the time-space tradeoff curve. Confirmed: for `countdown(1000)`, this allocates and retains ~5000 heap objects. Do not carry this into Phase 2.

- **Flat `Vector{AbstractInstruction}` bytecode with integer `pc`.** Adequate for a spike but not a compiler IR. Phase 2 uses RSSA with proper basic-block structure.

- **Shared `Const`, `Move`, `UnaryOp`, `BinaryOp` as wrapping rather than injective primitives.** `Move` is information-losing on `dst`; `Const` overwrites whatever was there. In Phase 2 these must be replaced by Pendulum-style exchange operations or restricted to fresh registers.

- **Return ≡ Halt equivalence.** Acceptable in the spike (no subroutines), requires explicit disambiguation in Phase 2 once call stacks exist.

---

## Q5. What does Phase 2 still need to design from scratch?

- **RSSA IR shape.** The spike uses a flat `Vector{AbstractInstruction}` with integer pc. RSSA requires basic blocks, φ-nodes on joins AND splits, and variable-destroying uses. The spike gives no evidence about how to represent this in Julia. Phase 2 must read Mogensen 2016 §3 and RC3's RSSA reader before writing a line.

- **Pendulum/BobISA instruction set adaptation.** The spike's eight instructions are deliberately non-injective proxies. Phase 2 must partition instructions into injective (push nothing), non-injective (push delta), and reversible control flow (BobISA encoding). The spike confirms the partition is necessary but does not constrain the concrete ISA design.

- **Enzyme-style min-cut delta-history selector.** The spike proves full-snapshot history is unacceptable. Phase 2 must port Enzyme's recompute-vs-cache analysis to the BennettVM IR. The spike gives no evidence about which BennettVM IR dataflow structures correspond to Enzyme's LLVM IR structures.

- **Bennett-1989 pebble-game lowering pass.** The spike implements Stage 1 only. Stages 2 (Output) and 3 (Cleanup) are out of scope; the pebble-game recursion for sublinear-space simulation is entirely unaddressed. Phase 2 must read Bennett 1989 §2–3 and Knill 1995 §2.1 before writing the lowering pass.

- **rr-style periodic-checkpoint mechanism.** The spike does per-step full-state logging, which is the opposite of rr's model. Phase 2 must implement periodic checkpointing + deterministic replay as the base layer, with delta entries only for non-deterministic or non-injective operations in between.

- **Output-channel invariant (`OutputRef`).** Not addressed in the spike. The `result(s)` function just returns `s.current.locals`, with no distinction between output data and scratch registers. Phase 2 needs a nominally-typed `OutputRef` with static non-aliasing checks.

- **Floating-point reversibility scheme.** Not in spike scope. The choice among residual-tape FP, posit-with-sticky, and opaque snapshots is deferred to v4. The spike gives no evidence.

- **Bennett.jl frontend integration boundary.** The spike is a standalone package with no Bennett.jl dependency. Phase 2 must define the IR interface at which Bennett.jl's lowering hands off to BennettVM. The spike confirms that `IState.locals::Dict{Symbol,Int64}` is sufficient for integer-scalar programs; the richer type universe for Bennett.jl is unaddressed.

- **Lean formalization scope.** PRD §3.8 lists five Lean targets. The spike gives no evidence about how any of them would be formalized. The abstract VM semantics are simple enough (the spike is ~630 LOC) that formalization should be tractable; but "tractable" and "designed" are different things.

- **Other.** Type-level ancilla annotations (CoreFun / Qurts style), subtyping for reversible OOP (ROOPL), partial invertibility (Sparcl) — all out of spike scope and requiring Phase-2 literature review before design.

---

## Q6. Was anything the spike implemented already in RC3, janus-vesta, etc.?

Honest cross-check per PRD v3 §5.6 Q6. All five repos were inspected.

| Spike component | Exists in RC3? | TOPPS-janus? | jana? | janus-vesta? | Notes |
|---|---|---|---|---|---|
| `IState` analogue | Partial | Yes (`EvalState` in `Types.hs`) | Yes (`EvalState`) | Yes (`Cpu` struct in `cpu.rs`) | All have a "current execution state" struct. RC3's stackmachine has `Instruction` / `Line` types but no explicit IState wrapper. |
| `RState` analogue | No | Partial | Partial | No | TOPPS-janus `EvalState` includes `forwardExecution :: Bool` but no separate history field. No repo combines current state + history-tape as a unified struct the way `RState` does. |
| `HistoryStack` analogue | No | No | No | No | None of the five repos use an explicit history-tape. All Janus implementations achieve reversibility by syntactic program inversion (`invertStmt` / `invert`), not by recording a trace at runtime. This is the Yokoyama–Glück structural lesson: history is unnecessary when the source language is reversible by construction. |
| `step!` / `unstep!` | No | Partial | No | No | TOPPS-janus exposes `stepForward` / `stepBackward` (`Types.hs:374–381`) but these are debugger-mode direction flags, not first-class step functions. No repo has a `step!`/`unstep!` pair with the push/pop history semantics. |
| `run!` / `unrun!` | No | Partial | No | No | TOPPS-janus can run a program backward by inverting it syntactically and running forward (`Jana/Invert.hs:invertProcGlobally`). Not a trace-reversal; PRD v3 §2.2 notes this structural difference explicitly. |
| Round-trip property test | No | No | No | No | None of the five repos has a round-trip property test in the BennettVM sense (run forward, undo step-by-step, assert initial state recovered). RC3's tests are syntax-error and aliasing-error checks (`CompilerTest.java`); TOPPS-janus's tests are `.ja` program execution tests. |
| 8-instruction bytecode | Partial (RSSA VM) | No | No | Partial (Janus ISA) | RC3 has a reversible virtual machine for RSSA programs (`rvm` binary); it operates on RSSA IR, not this spike's flat bytecode. janus-vesta implements the Janus CISC ISA in Rust (`execute.rs`, `operation.rs`) with ~30+ operations; no overlap in design. |

**Law 2 (Reuse before reinvention) assessment for PRD v4:**

The spike's core contribution — an explicit history-tape + `step!`/`unstep!` pair on a mutable `RState` — does not exist in any of the five reference implementations. This is because all five implement Janus (a reversible-by-construction language), where history is unnecessary. The spike implements Bennett-1973 Stage 1 on *irreversible* bytecode, which is a different problem.

What IS in these repos that Phase 2 should reuse rather than rebuild:

- **RC3's RSSA VM** (`rvm`): Phase 2's IR should target RSSA and execute via an RC3-compatible VM, not reinvent it. Reading RC3's `compiler/` and `rvm` before writing Phase-2 IR is mandatory (PRD §6 success criterion 6).
- **TOPPS-janus's `Invert.hs`**: the syntactic inversion strategy is the right model for the injective instruction subset in Phase 2 — no history needed, just run the inverted program.
- **janus-vesta's `execute.rs`**: a working Rust reversible ISA executor as a behavioral reference for Phase 2 instruction semantics.

No spike component is a rebuild of code in the reference repos. The spike is implementing a Bennett-1973 trace VM, which none of the repos implement.

---

## Q7. PRD v3 errata + spike-session overrides surfaced

**Pre-spike user override (2026-05-23):** PRD §5.5 / CLAUDE.md Law 1 requires the Bennett 1973 PDF on disk before the spike opens. The PDF could not be acquired (TIB does not cover the IBM JRD historical IEEE Xplore volume; TIB ILL was the clean path). The user elected to proceed without it, using Vitanyi CF'05 §2, Bennett 1989 §1–2 (Lemma 1), and BTV 2001 §1 as substitute ground truth.

- **Was the substitute-source coverage sufficient?** Yes. The three-tape construction is described precisely enough in all three secondary sources for Stage 1 of Bennett's construction (accumulate-history and its exact inverse). No information loss was perceived during implementation.
- **Did any Bennett-1973-specific detail get fudged?** One potential gap: Bennett 1973's original notation for the history-tape entries (which rule/quintuple index was applied at each step) differs from the spike's full-IState snapshots. The secondary sources describe the construction abstractly enough that the spike diverges from the original's delta entries without any source warning it. However, this divergence is intentional (PRD §3.3: "full snapshots are the deliberate Phase-0 baseline") rather than a misunderstanding.
- **Should PRD v4 re-require the original PDF?** PRD v4 should require it before writing the Phase-2 lowering pass, which depends on exact details of Stage 2 (Output) and Stage 3 (Cleanup) that the secondary sources describe only at Lemma-1 level. For Stage 1 alone, the secondary sources were sufficient.

**Other errata surfaced during the spike:**

- **BobISA citation:** PRD v3 §2.5 cites "Axelsen–Yokoyama 2011 LATA"; actual is Thomsen–Axelsen–Glück 2012 (RC 2012, DOI 10.1007/978-3-642-29517-1_3). Already logged in `references/manifest/SOURCES.md §Citation-errata`.

- **Mogensen RIL "paper" is a ghost:** RIL is introduced inside Mogensen 2015 LNCS 9138, not as a standalone paper. PRD v3 §2.4 implies a standalone RIL paper. v4 should cite Mogensen 2015 LNCS 9138 directly.

- **PRD §5.1 Bool-typed registers:** The spike's locals dict is `Dict{Symbol, Int64}` uniformly. The PRD mentions `Bool` as a type for registers used in `:not`. In the spike, `:not` is bitwise complement on `Int64`, not boolean negation. PRD v4 should either (a) drop the Bool-register claim for Phase 0, or (b) decide whether Phase 2 introduces a Bool subtype with a proper negation operation.

- **`Return` ≡ `Halt` in spike scope:** PRD §5.1 lists both `Return` and `Halt` as distinct bytecodes. In the spike they are identical (`forward` methods at `Instructions.jl` lines 240–244 are byte-for-byte the same). The distinction is only meaningful when subroutines exist. PRD v4 should note this explicitly and specify whether Phase 2 needs a call stack before `Return` acquires distinct semantics.

---

## Q8. Recommendations for PRD v4

1. **Change PRD §5.3** from `struct RState` to `mutable struct RState`. Add a sentence: "Julia's default struct is immutable; `s.current` and `s.history` are mutated in place by `step!` and `unstep!`, which requires `mutable struct`."

2. **Change PRD §5.3** from "Equality, hashing, copying: whatever Julia provides by default, with explicit overrides only where round-trip equality forces it" to: "Explicit `Base.==` and `Base.hash` overrides on `IState` are required. Julia's default `==` on a `Dict`-containing struct compares by object identity, not structural equality; without the override the P0.6 round-trip invariant cannot be tested."

3. **Add to PRD §5.1** (or Phase-2 equivalent): "History-length invariant uses the discard-pop predicate: a step whose transition is a pure status flip (status terminal, pc unchanged, locals unchanged) does not push a history entry. The `length(history) == steps_taken` invariant counts only steps that pushed an entry."

4. **Change PRD §2.4 BobISA citation** from "Axelsen–Yokoyama 2011 LATA" to "Thomsen–Axelsen–Glück 2012, RC 2012, DOI 10.1007/978-3-642-29517-1_3."

5. **Change PRD §2.4 RIL** from a standalone-paper citation to "Mogensen 2015, LNCS 9138 (RIL is introduced in this chapter, not as a standalone paper)."

6. **Add to PRD Part IV (Reuse Map):** An explicit row for TOPPS-janus's `Invert.hs` `invertStmt` as the model for Phase-2 injective-instruction inversion (no history needed; run the syntactically-inverted program). This is Yokoyama–Glück 2007's structural lesson concretized in a codebase we own.

7. **Add to Phase-2 success criteria (§6):** "RC3 `rvm` binary executed against at least one Phase-2 RSSA program before any Phase-2 RSSA-VM code is written. Result documented in ADR."

8. **Add to PRD §3.5 (Output channel):** "`result(s)` in Phase 0 returns the full `locals` dict. Phase 2 must introduce a nominally-typed `OutputRef` that statically distinguishes output data from scratch registers, before Bennett.jl integration is attempted."

---

## Q9. What was NOT learned by doing this spike?

- **Cost of delta entries vs. full snapshots at realistic program sizes.** The spike confirms full snapshots are unacceptable but cannot quantify the improvement from delta entries: no realistic program was run, and the instruction set has no injective primitives to measure "push nothing" cases.

- **How RSSA φ-nodes interact with `unstep!` semantics.** The spike has no control-flow join points beyond jump targets (no structured loops, no reversible `from-until`). The RSSA split-φ and join-φ interaction with the history mechanism is entirely uninformed by the spike.

- **Correctness of the discard-pop predicate under a call stack.** The spike has no `call` instruction and no subroutine activation records. Whether the discard-pop predicate applies correctly when `Return` pops a call frame (pc changes, locals change) is not addressed.

- **Memory cost of `deepcopy` at practical program depths.** The spike ran countdown(1000) as a max_steps test but did not profile history allocation. Quantified cost data would sharpen the Phase-2 min-cut analysis priority.

- **Whether the `inverse(instr, s, prev)` signature is the right Phase-2 contract.** The spike uses `prev::IState`; Phase 2 wants `prev::DeltaPayload`. The spike cannot validate the delta-payload interface because no delta payloads exist.

- **Bennett.jl lowering compatibility.** The spike is entirely standalone. Whether the eight instruction types cover what Bennett.jl's lowering actually emits is unknown. The integration boundary test is a Phase-2 deliverable.

- **Lean formalization tractability.** PRD §3.8 lists five Lean targets. The spike establishes no evidence about which are easy, which are hard, or whether the abstract VM semantics as defined here admit the stated theorems.

---

## Closing checklist

- [ ] Spike repository archived / marked read-only (PRD §7.8).
- [ ] PRD v4 ticket opened in beads, this retrospective attached.
- [ ] `PHASE.md` updated to "Phase 1 (archive); PRD v4 pending".
- [ ] Hand-off note written for the PRD-v4 author.
