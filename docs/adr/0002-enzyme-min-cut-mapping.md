# ADR 0002 — Enzyme Min-Cut → RSSA Dataflow Mapping (M7.1)

**Status:** In progress (M7.1) — gates M7.2–M7.7. M7.2 through M7.7 (delta
entries, push site, liveness stub, integration, sub-linear assertion)
all block on this document.

**Date:** 2026-05-27.

**Bead:** `bennettvm-80a` (M7.1).
Downstream blockers: `bennettvm-c4m` (M7.2 — DeltaEntry type),
`bennettvm-vk8` (M7.3 — make_delta per-instruction),
`bennettvm-bk5` (M7.4 — inverse NamedTuple signature),
`bennettvm-46p` (M7.5 — liveness pass stub),
`bennettvm-7e7` (M7.6 — step! integration),
`bennettvm-94m` (M7.7 — sub-linear-history assertion).

**PRD anchor:** PRD v4 §3.3 layer 2 ("delta entries with min-cut
selection") — the mandate that this ADR exists to discharge; §3.2
("instruction classes"); §2.7 (Enzyme cache analysis).

**Motivation.** PRD v4 §3.3 (lines 472–475) reads verbatim:

> **Enzyme min-cut adaptation ADR.** Before the delta-history selector
> is implemented, an ADR MUST identify which Phase-2 RSSA dataflow
> constructs correspond to Enzyme's LLVM-IR value-dependency graph
> edges. Filed as `docs/adr/0002-enzyme-min-cut-mapping.md`.

The Phase-2 history is three-layered (PRD §3.3): L1 (no log, M6 — done),
L2 (delta with min-cut, M7 — *this ADR's domain*), L3 (periodic
full-state checkpoints, M4.2 — done). Without this ADR, M7's code has
no binding reference for which structures in our RSSA IR carry the
information Enzyme's LLVM-IR analysis caches. This document closes that
gap and locks the six per-bead design decisions every M7.2–M7.7 coder
will inherit.

---

## § Enzyme min-cut: the problem statement

Per PRD v4 §2.7 (lines 325–330):

> Enzyme decides per-instruction whether to cache or recompute, using
> alias analysis, activity analysis, and a cost model. The min-cut
> analysis is the Bennett-1989 pebble problem specialized to dataflow
> graphs, solved heuristically at LLVM IR.

The problem, restated for Phase-2:

Given a forward computation as a dataflow graph G with *value-dependency
edges* (vertex = an SSA-form value produced by some instruction; edge =
"this value is read by this later instruction"), the reverse pass needs
*some subset* of intermediate values to recover the forward state at
every step. Two extremes bracket the design space:

| Strategy | Space | Time | Where it lives in Phase-2 |
|---|---|---|---|
| **Cache everything** (full snapshot per step) | O(T) | O(T) | Spike anti-pattern; PRD §3.3 prohibits ("MUST NOT appear in Phase 2"). |
| **Cache nothing** (rerun forward from start on each backward step) | O(1) | O(T²) | Pure replay — degenerate L3 with K=∞. |
| **Min-cut** (cache the minimum vertex set sufficient for inversion) | O(min-cut(G)) | O(T) | The Enzyme heuristic; **L2**. This ADR. |

Bennett 1989's pebble game is the theoretical underpinning (PRD §2.1):
the min-cut problem is exactly the pebble-game problem instantiated on
the dataflow DAG with one pebble per cacheable value. Enzyme's
contribution (Moses–Churavy 2020 §2 "Cache") is a *heuristic* solver —
alias + activity + cost — operating on LLVM IR. The optimal solver is
NP-hard in general (per the pebble-game literature); the heuristic
gives a "good enough" cache set in polynomial time.

**Phase-2 cost model.** M7 ships with a *stub* liveness analysis (M7.5)
in lieu of Enzyme's full alias+activity+cost machinery. The stub
returns "all non-injective instructions must be cached" — a strict
upper bound on the true min-cut, but already a substantial improvement
over L3-only fallback (which checkpoints every K steps regardless of
injectivity). The PRD's reuse-map row (§Part IV, line 930) anticipates
this:

> Min-cut delta-history selection: Reuse from Enzyme (Moses–Churavy
> 2020). Port from LLVM IR to Phase-2 IR; algorithm verbatim. ADR 0002.

The literal port is deferred behind the stub; M7.5 is the place to
*upgrade* the stub once the M1 cost-measurement bead (§Part IX M1)
produces concrete data justifying the engineering cost. The ADR locks
the *interface* (a `must_cache` query) so the upgrade path is type-
preserving.

[CITE-GAP: Enzyme §2 "Cache" exact algorithm — Moses–Churavy 2020
NeurIPS PDF not on disk at this session. The PRD's distillation
(§2.7) is sufficient to lock the interface and the heuristic's
inputs (alias / activity / cost), but the per-step recurrence
relation the heuristic minimises (`min over cached subsets S of
recompute_cost(G \ S) + |S|`) would ideally cite the paper directly.
Close by acquiring `references/ad-and-checkpointing/enzyme-2020.pdf`
and re-citing in M7.5's implementation file.]

---

## § Phase-2 RSSA dataflow: what the edges look like

One row per concrete instruction type. Read sets / write sets are
extracted from each instruction's `forward` method body (file:line in
the right margin). "Destroys" lists fields whose *prior* value is
*overwritten by a computation that depends on it* (not merely
overwritten — a swap doesn't destroy). "Inverse requires" lists the
information the current `inverse(instr, s, prev)` consults; "M6.1
injective?" reflects `src/history/Injective.jl` (M6.1, commit
e9eb994) and the value-level discrimination for `ArithmeticAssignment`.

| # | Type | Forward read | Forward write | Destroys | Inverse requires | M6.1 injective? |
|---|---|---|---|---|---|---|
| 1 | `ArithmeticAssignment` (`modop=:xor`) | `locals[source]`, `locals[lhs]?`, `locals[rhs]?` | `locals[target]` | `locals[source]` (overwritten by xor-of-itself) | current state only (`dual_modop(:xor)=:xor`) | **true** (value-level) |
| 2 | `ArithmeticAssignment` (`modop=:add`) | same | `locals[target]` | `locals[source]` | current state only (`dual_modop(:add)=:sub`) | **false** (conservative; `bennettvm-ack` would broaden) |
| 3 | `ArithmeticAssignment` (`modop=:sub`) | same | `locals[target]` | `locals[source]` | current state only (`dual_modop(:sub)=:add`) | **false** (conservative; same bead) |
| 4 | `SwapInstruction` | `locals[source1]`, `locals[source2]` | `locals[target1]`, `locals[target2]` | nothing (permutation) | current state only | **true** |
| 5 | `MemoryAssignment` (`modop=:xor`) | `locals[lhs]?`, `locals[rhs]?`, `memory[addr]` | `memory[addr]` | `memory[addr]` (xor-of-itself) | current state only | **false** (M6 didn't specialise — see "Open questions") |
| 6 | `MemoryAssignment` (`modop=:add/:sub`) | same | `memory[addr]` | `memory[addr]` | current state only | **false** |
| 7 | `MemoryInterchange` | `locals[source]`, `memory[addr]` | `locals[target]`, `memory[addr]` | nothing (permutation; pre-destroy `locals[source]` lands in `memory[addr]`) | current state only | **true** |
| 8 | `MemorySwap` | `memory[addr1]`, `memory[addr2]` | `memory[addr1]`, `memory[addr2]` | nothing (permutation) | current state only | **true** |
| 9 | `BeginInstruction` | `pc` only | `pc` only | nothing | nothing | **true** |
| 10 | `EndInstruction` | `pc` only | `pc` only | nothing | nothing | **true** |
| 11 | `UnconditionalEntry` | `pc` only (cross-block rename in M3.6) | `pc` only | nothing (rename is a permutation on `locals` keys) | nothing | **true** |
| 12 | `UnconditionalExit` | `pc` only (cross-block rename in M3.6) | `pc` only | nothing | nothing | **true** |
| 13 | `ConditionalEntry` | `locals[condition]` (read live) | `pc` only | nothing (predicate stays live) | nothing — predicate live in locals | **true** |
| 14 | `ConditionalExit` | `locals[condition]` (read live) | `pc` only | nothing | nothing — predicate live in locals | **true** |
| 15 | `CallInstruction` | `args` (destroyed by callee), `targets` (created by callee) | `args`, `targets` via callee | deferred to v5 (cross-call boundary) | deferred to v5 | **false** (conservative) |

(15 rows rather than the requested 12 because `ArithmeticAssignment` is
modop-discriminated at the value level per M6.1 and `MemoryAssignment`
warrants the same future treatment; rows 9–14 are the six control-flow
markers, all trivially pc-only at this layer per
`src/ir/control_instructions.jl`.)

**Sources for the table.** `src/ir/arithmetic_assignment.jl:196-206`
(forward) + `:220-230` (inverse); `src/ir/swap_instruction.jl:153-162`
(forward) + `:179-188` (inverse); `src/ir/memory_instructions.jl`
`:146-155, :181-198` (MemoryAssignment) + `:373-382, :420-436`
(MemoryInterchange) + `:607-631, :659-682` (MemorySwap);
`src/ir/control_instructions.jl` (all six control markers are pc-only,
verified by direct file read);
`src/ir/call_instruction.jl:266-291` (Call's pc-only at this layer;
sub-execution deferred to M3.x interpreter).

---

## § The mapping: Enzyme cache vertex → RSSA must-delta instruction

The core deliverable. Two columns.

| Enzyme cache-vertex semantics | RSSA equivalent in BennettVM |
|---|---|
| **Injective LLVM IR value** (e.g., a permutation, a self-inverse computation): no cache needed; the value is recoverable from later live SSA values. | Rows 4, 7, 8 of the table above (`SwapInstruction`, `MemoryInterchange`, `MemorySwap`) AND rows 9–14 (all six control-flow markers). M6.1 `is_injective` returns `true`; **no DeltaEntry pushed.** |
| **Self-inverse modop on a live operand**: `x = x XOR e` where `e` is recomputable from live locals. No cache needed. | Row 1: `ArithmeticAssignment` with `modop=:xor`. M6.1 value-level `is_injective` returns `true`; **no DeltaEntry pushed.** |
| **Paired-inverse modop on a live operand**: `x = x +/− e` where `e` is recomputable AND the dual modop recovers x. *Structurally* recomputable; Enzyme would cache only if the recompute cost is high (it isn't here — `e` is a single binop). | Rows 2, 3 (ArithmeticAssignment `:add`/`:sub`), rows 5, 6 (MemoryAssignment, all three modops). M6.1 conservatively returns `false`; M7 default treats them as must-cache UNTIL `bennettvm-ack` and the MemoryAssignment counterpart land. **DeltaEntry pushed** by default; payload may be empty (the inverse uses current state alone). |
| **Genuinely information-destroying op** (e.g., LLVM `udiv` where the residue is lost): Enzyme MUST cache. | Phase-2 IR rules these out at the *instruction-class* level (§3.2): non-injective ops are represented as injective core + ancilla. The ADR therefore has no "must-cache the destroyed value" row at this milestone — the IR has already pre-empted it. If a Phase-2.x bead introduces a genuinely-non-injective primitive (e.g., a `div`-with-rounding ancilla pair), the ancilla is the equivalent of Enzyme's cached value, and the DeltaEntry payload would carry it. |
| **Cross-procedure boundary**: Enzyme handles this with whole-program activity analysis. | Row 15: `CallInstruction` — deferred to v5 per `src/ir/call_instruction.jl`'s top-of-module docstring. Phase-2 (this iteration) treats `CallInstruction` as conservatively non-injective; M3.x interpreter does not yet recurse into the callee. |

**Decision.** Every non-injective Phase-2 instruction is *by default*
in the must-cache set. The min-cut analysis (M7.5) refines this —
instructions whose output is recomputable from later live values can
be removed from the must-cache set. Until M7.5 implements that
analysis, M7.6's `step!` integration falls back to "every non-injective
step pushes a DeltaEntry" (still a strict improvement over the L3
full-snapshot fallback because the payload is *typically empty* — see
the next section).

The L3 fallback is preserved as a safety net per PRD §3.3 lines 461–465
("a safety net" for "long-running regions"); see "Composition with M6"
below for the gate ordering.

---

## § DeltaEntry payload schema (M7.2 design decision)

The M7.2 bead `bennettvm-c4m` implements this type. ADR locks the
schema; M7.2 codes it.

```julia
"""
    DeltaEntry{T<:Instruction} <: AbstractHistoryEntry

The L2 reversibility-tape entry for non-injective instructions whose
inverse needs more than current-state information. Parametric on the
instruction type so per-instance specialisation (`make_delta(::T, ...)`,
`inverse(::T, s, payload::NamedTuple)`) dispatches without `Any`.
"""
struct DeltaEntry{T<:Instruction} <: AbstractHistoryEntry
    instruction::T
    payload::NamedTuple
    step::Int
end
```

Fields, with the rationale that downstream beads MUST follow:

- **`instruction::T`**. The instruction whose forward was just executed.
  Carried so that `unstep!`'s dispatch can call
  `inverse(entry.instruction, s, entry.payload)` without re-deriving
  the instruction from the program. Mirrors the way `CheckpointEntry`
  carries `snapshot` — the entry self-describes what it inverts.

- **`payload::NamedTuple`**. The minimal information the inverse needs
  beyond current state. Per-instruction-type schema below.

- **`step::Int`**. The post-increment `step_count` at which the delta
  was pushed. Mirrors `CheckpointEntry.step`
  (`src/history/CheckpointEntry.jl:264-273`); Replay.jl's polymorphic
  search-from-step uses this uniformly across L2 and L3 entries.

**Per-instruction payload schemas.** Worked from the table above:

| Instruction type | DeltaEntry payload (NamedTuple fields) | Why |
|---|---|---|
| `ArithmeticAssignment` (`modop ∈ {:xor, :add, :sub}`) | `NamedTuple()` (empty) | The forward uses `dual_modop` (`src/ir/arithmetic_assignment.jl:138-143`) and recomputes `(lhs op rhs)` from current locals (`:220-230`). **No payload required.** This finding broadens M6.1 (see "Open questions"): `ArithmeticAssignment` may be promoted to injective wholesale in `bennettvm-ack`. |
| `MemoryAssignment` (`modop ∈ {:xor, :add, :sub}`) | `NamedTuple()` (empty) | Same structural argument: `inverse(::MemoryAssignment, s, prev)` (`src/ir/memory_instructions.jl:181-198`) uses `dual_modop` on the *current* cell value. The cell's post-forward value plus the operands (live in locals) suffices. **No payload required.** |
| `CallInstruction` | deferred to v5 | The callee's reversibility is structural (per RC3 `Direction` flip; ADR 0001 row 6); M7 does not handle cross-call deltas. A future Phase-2.x bead extends DeltaEntry to record "the callee snapshot" or recurses delta-collection into the callee. Currently `CallInstruction.forward` only bumps `pc` (`src/ir/call_instruction.jl:266-274`); when the callee dispatch lands at M3.x, a follow-up bead revisits this row. |

**Consequence — the empty-payload finding.** Every non-injective row in
the table above turns out to have an empty payload at this milestone.
This is the load-bearing finding of the ADR: under the *current* IR,
M7's DeltaEntry pushes carry only the instruction reference and the
step index — no captured destroyed values. M7's space win over L3 is
therefore the size difference between a `DeltaEntry{T}` (small —
instruction reference + empty NamedTuple + Int) and a `CheckpointEntry`
(full `deepcopy` of `IState`). On `countdown(n)` (see Worked Example),
this is roughly two orders of magnitude per entry.

This also surfaces the open `bennettvm-ack` bead from the other side:
if ArithmeticAssignment's all three modops carry empty payloads, the
ADR's "must-cache" classification for them is conservative-only, and
they belong in M6.1's injective set proper. The conservative path is
preserved here (M7 ships pushing empty-payload DeltaEntries for them)
*explicitly* so that M7 can land without coupling to `bennettvm-ack`'s
resolution — `bennettvm-ack` then collapses the empty-payload pushes
into M6 no-pushes.

---

## § Composition with M6's injective gate

The binding composition rule for `step!` post-M7. This MUST be
implemented in M7.6 (bead `bennettvm-7e7`) at the existing push site
(`src/interpreter/Interpreter.jl:744-763`):

```julia
# Post-M7.6: three-way decision at the push site.
s.step_count += 1
if is_injective(instr)
    # L1: nothing pushed. M6.2's existing branch.
elseif must_cache(instr, vm, s.step_count)
    # L2: minimal-payload delta. M7.5's must_cache query returns
    # true for every non-injective instruction at the stub level;
    # M7.6's integration calls make_delta(instr, s_pre) at the
    # appropriate point in the forward sequence (see "Payload
    # construction order" below).
    push!(s.history, make_delta(instr, s_pre, s.step_count))
elseif (s.step_count > 0 && s.step_count % checkpoint_interval == 0)
    # L3: periodic full snapshot. M4.2's existing branch, preserved
    # as safety net for long-running deterministic regions
    # (PRD §3.3 lines 461-465).
    push!(s.history, CheckpointEntry(s.current, s.step_count))
end
```

The L3 branch is preserved as a safety net (PRD §3.3 lines 461–465).
**M7.5's stub `must_cache` returns `true` for every non-injective
instruction**, which collapses the L3 branch to dead code under the
current ruleset (the L2 branch always fires first). This is intentional:
the L3 fallback only becomes active again when M7.5's analysis is
upgraded to a real liveness pass that *correctly* rejects some non-
injective instructions as needing-no-cache. Re-enabling L3 is the right
move once `must_cache` is accurate, because L3 amortises the snapshot
cost across multiple non-injective steps in long deterministic regions.

**Payload construction order.** M7.6 must construct the delta payload
*before* mutating `s.current` (analogous to M3.x's forward-before-push
ordering at PRD §3.11). For empty-payload instructions this is trivial
(no captured values); for any future non-empty payload it matters.
M7.2's `make_delta` signature accepts the pre-step IState so the
payload-construction site is unambiguous:

```julia
make_delta(instr::T, s_pre::IState, step::Int) :: DeltaEntry{T}
```

Per-instruction `make_delta` lives in the instruction's own file (see
Design Decision 3 below), so the captured-fields specification is
co-located with `forward` and `inverse` for the same `T`.

---

## § Worked example: `countdown(3)`

Using the canonical fixture `countdown_program(3)` from
`test/reference/countdown.jl` (M8.1, bd `bennettvm-do7`; previously
called `build_countdown_vm` in `test/test_forward_interpreter.jl`
prior to the M8.1 hoist). The countdown(3) VM has 5 blocks (b_start,
b_step1, b_step2, b_step3, b_done) with a total of `2 + 3*4 + 2 = 16`
flat-stream instructions per the regression assertion in
`test/test_forward_interpreter.jl`'s `countdown(7)` testset (same
formula).

### Flat instruction stream

| step | Instruction | Type | M6 injective? | M7 action |
|---|---|---|---|---|
| 1 | `BeginInstruction(:countdown, [:n0, :steps0])` | Begin | yes | L1 skip |
| 2 | `UnconditionalExit(:b_step1, [:n0, :steps0])` | UncondExit | yes | L1 skip |
| 3 | `UnconditionalEntry(:b_step1, [:n0, :steps0])` | UncondEntry | yes | L1 skip |
| 4 | `ArithmeticAssignment(:n1, :n0, :sub, 1, :and, 1)` | Arith(`:sub`) | **no** (M6 conservative) | **L2 push (empty payload)** |
| 5 | `ArithmeticAssignment(:steps1, :steps0, :add, 1, :and, 1)` | Arith(`:add`) | **no** (M6 conservative) | **L2 push (empty payload)** |
| 6 | `UnconditionalExit(:b_step2, [:n1, :steps1])` | UncondExit | yes | L1 skip |
| 7 | `UnconditionalEntry(:b_step2, [:n1, :steps1])` | UncondEntry | yes | L1 skip |
| 8 | `ArithmeticAssignment(:n2, :n1, :sub, 1, :and, 1)` | Arith(`:sub`) | no | **L2 push** |
| 9 | `ArithmeticAssignment(:steps2, :steps1, :add, 1, :and, 1)` | Arith(`:add`) | no | **L2 push** |
| 10 | `UnconditionalExit(:b_step3, [:n2, :steps2])` | UncondExit | yes | L1 skip |
| 11 | `UnconditionalEntry(:b_step3, [:n2, :steps2])` | UncondEntry | yes | L1 skip |
| 12 | `ArithmeticAssignment(:n3, :n2, :sub, 1, :and, 1)` | Arith(`:sub`) | no | **L2 push** |
| 13 | `ArithmeticAssignment(:steps3, :steps2, :add, 1, :and, 1)` | Arith(`:add`) | no | **L2 push** |
| 14 | `UnconditionalExit(:b_done, [:n3, :steps3])` | UncondExit | yes | L1 skip |
| 15 | `UnconditionalEntry(:b_done, [:n3, :steps3])` | UncondEntry | yes | L1 skip |
| 16 | `EndInstruction(:countdown, [:steps3])` | End | yes | L1 skip |

### History under M4.2 alone (baseline)

`checkpoint_interval = 64` (default per PRD §3.3): on a 16-step program,
no L3 checkpoints fire (no step satisfies `step_count % 64 == 0`).
**Baseline history length: 0.** This baseline is misleading on
countdown(3) specifically because the program is short; on
countdown(100) (1 + 4*100 + 1 = 402 steps), L3 would push 6
checkpoints (at steps 64, 128, 192, 256, 320, 384), each a full
`deepcopy(IState)`.

### History under M7

6 DeltaEntries (steps 4, 5, 8, 9, 12, 13), each carrying:
- one `ArithmeticAssignment` reference (≈48 bytes — three Symbols +
  three small fields, conservative estimate);
- one empty `NamedTuple{(),Tuple{}}` (8 bytes — zero-sized type tag);
- one `Int` step counter (8 bytes).

**Total M7 history bytes (countdown(3)): ~6 × 64 = ~384 bytes.**

### Comparison

| | M4.2 alone | M7 (current bead) | Spike (Phase-0 anti-pattern) |
|---|---|---|---|
| Entries (countdown(3)) | 0 | 6 | 16 (one per step) |
| Per-entry size | full `IState` deepcopy | ~64 bytes | full `IState` deepcopy |
| Total (countdown(3)) | 0 | ~384 bytes | ~16 × 200 bytes ≈ 3200 bytes |
| Total (countdown(100)) | 6 × ~200 = ~1200 bytes | 200 × 64 = ~12800 bytes | 400 × 200 = ~80 000 bytes |
| Sub-linear in T? | yes (O(T/K)) | **no** (O(T) by entry count, but tiny per-entry constant) | no |

Two observations from this exercise:

1. The current M7 layout is *not* sub-linear in T (one entry per
   non-injective step), so SC4 ("sublinear-in-T peak history bytes for
   the injective-dominated subset" — PRD §Part VI) is not yet
   achievable on countdown specifically because countdown is 50%
   non-injective by step count. SC4's correct framing is **the
   injective-dominated subset must scale sub-linearly**; countdown is
   the wrong canonical for SC4 and the right canonical for the
   *empty-payload-finding* result. (See M7.7 design decision 6.)

2. If `bennettvm-ack` lands (broadening M6 to all three modops),
   countdown(3)'s history collapses to 0 entries — every step becomes
   L1-skip. This is the design symmetry that justifies the
   empty-payload approach: it's a placeholder for a class of
   instructions that *should* be injective in M6 but isn't yet.

---

## § Design decisions that ripple to M7.2–M7.7

Six numbered decisions; each rationale cites the source it
specifically inherits from. Subsequent M7 sub-beads MUST follow these.

1. **`DeltaEntry{T<:Instruction}` is parametric on the instruction
   type.** Allows per-T method specialisation of `make_delta` and
   `inverse` without dispatching through `Any`, mirroring the
   compiler-friendly pattern in `CheckpointEntry`
   (`src/history/CheckpointEntry.jl:264-273`). The parametric type
   does cost one method table per `T` but the eight `T`s are static
   (sealed-by-convention per `src/ir/instructions.jl:36-48`).
   *Rationale:* Julia idiom — parametric structs are how the language
   expresses Enzyme-style specialisation.

2. **Payload is `NamedTuple`** (not a per-T struct, not a `Dict`, not
   `Any`). Extensible (add a field without changing the type),
   value-type (stack-allocated, no GC pressure), hashable (interacts
   correctly with the `Base.==`/`hash` overrides on M6's history
   entries), lightweight (empty NamedTuple is 0 bytes payload + 8
   bytes type tag).
   *Rationale:* matches Julia's idiomatic "structural record" usage;
   chosen over per-T struct because the dominant case (this ADR's
   finding) is *empty* payload and we don't want twelve empty struct
   declarations.

3. **`make_delta(instr, s_pre, step)` lives in the instruction's own
   file** (`src/ir/<instr>.jl`), NOT in a central `delta.jl`. The
   per-instruction file already houses `forward` and `inverse` for
   the same `T`; adding `make_delta` there keeps the three forward-
   inverse-delta methods literally adjacent and makes the
   captured-fields specification co-located with the
   destroyed-fields specification.
   *Rationale:* CLAUDE.md Rule 11 (literate exposition) — keep
   per-instruction semantics in one file; no orphan methods.

4. **`inverse(instr, s, payload::NamedTuple)` extends the existing
   `inverse(instr, s, prev)` signature.** `prev` becomes a
   `NamedTuple` for non-injective instructions, stays `nothing` for
   injective (per M6.3's contract — see `src/history/Injective.jl`
   M6.3's no-op short-circuit semantics). Method dispatch handles
   the difference; no instruction's `inverse` body changes signature
   *at the call site* because Julia's `nothing`-vs-NamedTuple is a
   trivial pattern.
   *Rationale:* `src/ir/instructions.jl:182-188` fallback already
   accepts `prev::Any` — the extension here is to specialise on
   `NamedTuple` for the L2 path; no breaking changes to existing
   inverse methods.
   *Source cross-check (verified 2026-05-27 review pass):* every
   existing concrete `inverse(instr::T, s, prev)` method declares
   `prev` without a type annotation, so it dispatches at the
   `::Any` slot. Confirmed at the twelve method sites:
   `src/ir/arithmetic_assignment.jl:220`, `src/ir/swap_instruction.jl:179`,
   `src/ir/memory_instructions.jl:181`, `:420`, `:659`,
   `src/ir/control_instructions.jl:231`, `:243`, `:510`, `:520`,
   `:882`, `:892`, `src/ir/call_instruction.jl:288`. The new
   `inverse(::T, s, payload::NamedTuple)` specialisation is strictly
   additive; existing call sites that pass `nothing` (M6.3's
   contract tests at `test/test_injective_inverse.jl`) and `prev`
   (the M4/M7 path) continue to dispatch to the existing methods
   under the `::Any` slot.

5. **M7.5's liveness pass produces a `Set{Tuple{Symbol, Int}}` of
   `(block_label, instruction_index)` pairs.** M7.6's `step!` queries
   the set via `must_cache(instr, vm, step_count)` which translates
   to "is this (current block, current instruction-index) in the
   set?". The set is computed once at lowering time, lives on
   `VMProgram`, and is read-only during execution.
   *Rationale:* a set membership query is O(1) per step; the set
   itself is computed at lowering (not per-run) per Enzyme's
   architecture (analysis is one-shot, codegen consumes the result).
   The (block_label, instruction_index) coordinate is more stable
   under future IR reshapes than a flat-stream pc index would be.

6. **Sub-linear history scaling (M7.7) is asserted as
   `length(rs.history) / rs.step_count ≤ 0.5`** for an
   injective-dominated program (>50% injective by step count).
   Concretely: M7.7's regression test builds a program whose flat
   stream is at least 80% injective (e.g., countdown(N) with `:xor`
   modops once `bennettvm-ack` lands; pre-`ack`, a hand-built program
   stacking SwapInstructions interleaved with single ArithAssigns)
   and asserts the ratio.
   *Rationale:* SC4 (PRD §Part VI) demands "sublinear-in-T peak
   history bytes for the injective-dominated subset"; 50% is a
   conservative threshold that distinguishes "improving over L3"
   from "actually sub-linear". A tighter bound (10%) is a follow-up
   once M7.5 produces a real liveness analysis (the conservative
   stub forces 50% for any program with that injective fraction).

---

## § Open questions / [CITE-GAP] markers

These are points where the PRD's distillation is sufficient to lock
the interface but a re-acquired PDF would strengthen the citation, or
where the design is *intentionally* open to be closed by a downstream
bead rather than this ADR.

1. **[CITE-GAP — Enzyme min-cut algorithm].** PRD v4 §2.7 quotes
   Enzyme's "decides per-instruction whether to cache or recompute"
   but does not reproduce the exact heuristic. The ADR locks the
   interface (`must_cache(instr, vm, step)` query, set-based
   precomputed cache) without depending on the specifics. Closing
   citation: re-acquire `references/ad-and-checkpointing/enzyme-2020.pdf`
   and re-cite the §2 "Cache" paragraph in M7.5's source comments.

2. **[CITE-GAP — Bennett 1989 pebble game vs Enzyme min-cut
   equivalence].** The PRD §2.1 cites Bennett 1989 Theorem 1 (the
   recursion `RS(z,x,n,m,d)`) but does not explicitly state the
   equivalence "Enzyme min-cut on a dataflow graph G ≡ Bennett-1989
   pebble game on G with pebble = cached value". This equivalence is
   load-bearing for the time-space-tradeoff argument and would
   ideally cite a survey (Buhrman–Tromp–Vitanyi 2001 is the natural
   home). Closing citation: re-acquire BTV 2001 PDF and cite the
   relevant lemma.

3. **`MemoryAssignment` is not value-level injective.** The table
   above shows `MemoryAssignment`'s inverse uses current state alone
   (just like `ArithmeticAssignment`'s does), but M6.1
   (`src/history/Injective.jl:147-156`) leaves it at the
   conservative `false` default — *no* value-level method was
   defined for `MemoryAssignment` in M6.1. This is by-design per
   M6.1's file docstring (deliberately conservative; a separate
   follow-up bead would specialise). The ADR notes the asymmetry:
   `ArithmeticAssignment` has a `:xor`-specialised value-level
   method; `MemoryAssignment` does not. A follow-up of
   `bennettvm-ack` (call it `bennettvm-ack-mem`) should add the
   `MemoryAssignment` specialisation in parallel. **This ADR does
   NOT close the question** — it surfaces it for the M6 owner.

4. **`CallInstruction`'s delta semantics are deferred to v5.** The
   current `CallInstruction.forward` only bumps `pc`
   (`src/ir/call_instruction.jl:266-274`); the actual sub-execution
   of the callee will land at M3.x once `VMProgram`'s callee
   registry exists. Once it does, a Phase-2.x bead will revisit
   whether the call site needs a DeltaEntry to record "the callee
   was executed in direction X" or whether
   `effective_call_direction` (`:353-368`) suffices for backward
   reconstruction. **Not in M7's scope** — explicitly out.

5. **The empty-payload finding may be wrong for a future
   non-self-inverse modop.** If a Phase-2.x bead adds a new modop
   (e.g., `:mul`-by-constant with a fixed inverse, motivated by some
   lowering pattern), the structural reversibility argument breaks
   (multiplicative inverse over `Int64` is not unconditional). The
   ADR's empty-payload schema must be re-evaluated in that bead;
   the contract here is "for the M2.6-locked modop set
   `{:xor, :add, :sub}`, all DeltaEntry payloads are empty
   NamedTuples." A future agent adding `:mul` MUST re-open this
   ADR.

6. **Checkpoint interval default (`K=64`) interaction with M7.5
   upgrade.** Once M7.5 upgrades to a real liveness analysis,
   `must_cache` will return `false` for *some* non-injective
   instructions (those whose values are recomputable from later
   live values). The L3 branch in the composition rule above will
   then activate again, and the right `K` value depends on the
   *non-L2-covered* non-injective frequency. The PRD §3.3 line 478
   defers this to the M1 measurement bead. **Not in M7's scope** —
   the K=64 default carries forward unchanged.

---

## § References

Local citations (no PDFs cited where they are not on disk per the
file-acquisition state at session start):

- PRD v4 §2.7 (lines 323–330) — Enzyme cache analysis distillation.
- PRD v4 §3.2 (lines 415–446) — injective/non-injective partition,
  modop set lock, anti-pattern from spike.
- PRD v4 §3.3 (lines 449–479) — three-layer history scheme; min-cut
  ADR mandate; L3 fallback semantics; full-per-step prohibition.
- PRD v4 §Part IV reuse-map row (line 930) — "Min-cut delta-history
  selection: Reuse from Enzyme … algorithm verbatim. ADR 0002."
- PRD v4 §Part VI SC4 — sublinear-in-T peak history bytes target.
- `docs/adr/0001-rc3-rvm-smoke.md` §Observations Structural-Pattern
  point 1 ("Reversibility is structural, not historical") — the
  conceptual grounding for the empty-payload finding.
- `src/ir/instructions.jl:182-188` — `inverse(instr, s, prev)`
  fallback signature, the extension point for M7.4.
- `src/ir/arithmetic_assignment.jl:138-143` (`dual_modop`),
  `:220-230` (`inverse`) — establishes the empty-payload finding
  for row 1.
- `src/ir/swap_instruction.jl:179-188` — the prototypical
  injective inverse; `prev` documented as unused.
- `src/ir/memory_instructions.jl:181-198, :420-436, :659-682` —
  inverse methods for the three memory instructions.
- `src/ir/control_instructions.jl` (M2.8/M2.9/M2.10) — all six
  control-flow markers, pc-only at dispatch layer.
- `src/ir/call_instruction.jl:266-291` — Call's deferred
  sub-execution.
- `src/history/Injective.jl` (M6.1, commit `e9eb994`) — the L1
  trait; the value-level discrimination pattern; the conservative
  `false` default; the `ArithmeticAssignment`-on-`:xor`
  specialisation.
- `src/history/CheckpointEntry.jl` (M4.1, commit `6b59824`) — the
  L3 entry type, the structural model for `DeltaEntry`'s shape;
  the `step::Int` mirror.
- `src/interpreter/Interpreter.jl:744-763` — the existing M4.2
  push site; the M6.2 L1 gate; the M7.6 integration point.
- `test/test_forward_interpreter.jl:122-216` — the canonical
  countdown(N) fixture used in the Worked Example.
- Bead `bennettvm-ack` — open follow-up to broaden M6.1's
  `ArithmeticAssignment` specialisation to all three modops; the
  ADR's empty-payload finding strengthens its case.

**[CITE-GAP] markers:**

- `[CITE-GAP: Enzyme §2 "Cache"]` — re-acquire
  `references/ad-and-checkpointing/enzyme-2020.pdf`; cite the per-
  instruction cache decision and the alias/activity/cost inputs in
  M7.5's source comments.
- `[CITE-GAP: Bennett 1989 ↔ Enzyme equivalence]` — re-acquire
  `references/foundational/buhrman-tromp-vitanyi-2001.pdf` and cite
  the formal pebble-game ≡ dataflow-min-cut lemma for the
  time-space tradeoff argument.
