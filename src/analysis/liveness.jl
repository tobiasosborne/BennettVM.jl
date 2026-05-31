"""
    Liveness / min-cut stub analysis (M7.5)

The Phase-2 history scheme is three-layered (PRD v4 §3.3): L1 (no log,
M6 — done), L2 (delta entries with min-cut selection, M7 — *this
milestone's domain*), L3 (periodic full-state checkpoints, M4.2 —
done). Per ADR 0002 §"Enzyme min-cut: the problem statement" the L2
layer asks, for each non-injective forward step, the question *which
intermediate values are insufficient-via-current-state and therefore
must be captured to invert the step?* — the dataflow-graph min-cut
problem solved heuristically by Enzyme on LLVM IR (Moses–Churavy 2020
NeurIPS §2 "Cache"), instantiated on BennettVM's RSSA IR per ADR 0002.

# What M7.5 ships (+ the bd `bennettvm-5pp` L2-capability gate)

M7.5 is the **stub** liveness pass. It returns the conservative
upper bound on the true min-cut, refined by `bennettvm-5pp` to exclude
the instructions that have no working L2 path: **every non-injective
AND L2-capable instruction is included in the must-cache set; a
non-injective-but-not-L2-capable instruction is NOT included and falls
through to L3**. The classification reads `is_injective` (M6.1,
`src/history/Injective.jl`) AND `is_l2_capable`
(`src/history/delta.jl`). The stub does NOT attempt to identify
L2-capable outputs that are recomputable from later live values and
exclude them — that finer tightening is the upgrade path deferred
behind the M1 cost-measurement bead (PRD v4 §Part IX M1).

The L2-capability gate (bd `bennettvm-5pp`) is a soundness fix, not
just a refinement: the M7.5 original marked EVERY non-injective slot,
but `Define` / `VarGEP` / `MemoryLoad` / `CastInstruction` /
`SelectInstruction` / `CallInstruction` have NO working L2 path (a
raising `make_delta` fallback, a `nothing` `predelta_payload`). Routing
them through the L2 push gate raised the RAISING generic `make_delta`
(`src/history/delta.jl`) the moment they executed, so
`compute_must_cache(vm)` could not be used as the global
`must_cache_set` for any program containing one. Gating on
`is_l2_capable` leaves those L3-only — `step!`'s K-multiple checkpoint
gate handles them, which is the only sound reversal they have. For the
instructions that ARE L2-capable (`ArithmeticAssignment`,
`MemoryAssignment`, `MemoryStore`, `DynAlloca`), the L2 entry (an empty
NamedTuple per ADR 0002 §DeltaEntry payload schema, or a small
pre-state NamedTuple for the memory-floor creates) is a strict space
improvement over the L3-only fallback (which would `deepcopy` the
entire `IState`).

# Why this is correct as a stub

The empty-payload finding (ADR 0002 §"DeltaEntry payload schema") is
load-bearing here: for the currently-locked modop set
`{:xor, :add, :sub}`, the inverse of every non-injective instruction
in the M2.6-locked taxonomy needs no captured pre-state — the inverse
is structural, recomputed from `dual_modop` on the surviving
post-state. So the stub's "push a DeltaEntry for every non-injective"
choice produces small (typically empty-NamedTuple) entries rather
than the full `IState` snapshots an L3 pass would push. The
space win is real even at the stub level; the upgrade to true
min-cut is purely about *eliminating* even those small entries when
the value-level liveness analysis proves they are recomputable.

# Result shape: `Set{Tuple{Symbol, Int}}`

Each element is `(block_label, instr_idx)` where:

  * `block_label` is the `BasicBlock`'s `:label` field (the RSSA
    identity that cross-block dispatch looks up via `LabelTable`).
  * `instr_idx` is **1-based** and counts **only instructions inside
    the block's `instructions` field** — i.e. the non-control body.
    The block's entry / exit `ControlInstruction` markers are NOT
    counted in this index. This matches the `BasicBlock` field
    layout (`src/ir/basic_block.jl`) where `entry` / `exit` live in
    their own slots and `instructions` holds the body only.

This index convention is more stable than a flat-stream pc index
under future IR reshapes: a future M3.x reshape that changes the per-
block flat-stream contribution (e.g. inlining several markers) does
not move the `(block_label, instr_idx)` coordinate, whereas a flat
pc index would shift. Per ADR 0002 §"Design decisions that ripple to
M7.2–M7.7" decision 5, this is the coordinate the M7.6 query path is
designed against.

# Why a `Set`, not a `Vector` or `Dict`

The downstream consumer (M7.6's `step!`) asks one question per
forward step: *"is the current `(block_label, instr_idx)` in the
must-cache set?"* `Set` membership is O(1); a `Vector` would be O(N).
A `Dict` is not needed because the *only* per-entry payload would be
"yes, in the set" — a degenerate value the set's presence already
expresses. The set is computed once at lowering time (analogous to
Enzyme's one-shot analysis on LLVM IR) and then read-only during
execution.

# Where M7.5 stops; what M7.6 picks up

This file ships:

  * `compute_must_cache(prog::VMProgram)` — the stub liveness pass.
  * `must_cache(set, block_label, instr_idx)` — the O(1) query
    predicate M7.6's `step!` will consult at the push site.

This file does NOT:

  * Modify `VMProgram` (no new field). Per the M7.5 scope decision,
    storage of the must-cache set on the VMProgram is M7.6's call —
    M7.6 may store it as a field, pass it as a kwarg, or compute it
    lazily. M7.5 ships a function callable on any VMProgram.
  * Wire the result into `step!`'s push gate. M7.6 (bead
    `bennettvm-7e7`) consumes this analysis at the push site
    (`src/interpreter/Interpreter.jl`).
  * Export anything to the BennettVM top-level. Internal-access only
    until M7.6 settles the public API surface.

# Ref

  * `docs/adr/0002-enzyme-min-cut-mapping.md` §"Enzyme min-cut: the
    problem statement" — the formulation; §"Design decisions that
    ripple to M7.2–M7.7" decision 5 — the `Set{Tuple{Symbol, Int}}`
    coordinate; §"Composition with M6's injective gate" — how M7.6
    will consume the result.
  * `bennettvm_prd.md` (PRD v4) §3.3 layer 2 ("delta entries with
    min-cut selection") — the PRD mandate.
  * `bennettvm_prd.md` (PRD v4) §2.7 — Enzyme cache analysis
    distillation (Moses–Churavy 2020 NeurIPS §2 "Cache").
  * `src/history/Injective.jl` (M6.1) — the `is_injective` trait the
    stub queries. The value-level method on `ArithmeticAssignment`
    (modop-discriminated) is dispatched through transparently.
  * `src/ir/basic_block.jl` (M2.15) — the `BasicBlock` field layout
    that grounds the (block_label, instr_idx) coordinate; the
    `instructions` field is the non-control body only.
  * `src/ir/VMProgram.jl` (M2.17) — the `blocks::Vector{BasicBlock}`
    field the stub iterates over.
  * CLAUDE.md Law 2 — reuse-map row: ADR 0002 locks the interface
    that the future Enzyme port will satisfy. CLAUDE.md Rule 10 —
    this file stays under the 200-LOC cap.
"""

"""
    compute_must_cache(prog::VMProgram) -> Set{Tuple{Symbol, Int}}

Stub min-cut analysis. Returns the set of `(block_label, instr_idx)`
pairs whose instructions must push a `DeltaEntry` during forward
execution. A slot is included iff its instruction is **both
non-injective AND L2-capable** — `!is_injective(instr) &&
is_l2_capable(typeof(instr))` (bd `bennettvm-5pp`).

A non-injective-but-**not**-L2-capable instruction (`Define`, `VarGEP`,
`MemoryLoad`, `CastInstruction`, `SelectInstruction`, `CallInstruction`
— each lacking a working `make_delta` / `predelta_payload`, so its only
sound reversal is L3 checkpoint-replay) is **NOT** included; it falls
through to the L3 path at `step!`'s K-multiple gate. Marking it would
route it through the L2 push gate and hit the RAISING generic
`make_delta` fallback (`src/history/delta.jl`), which is the bug
`bennettvm-5pp` fixes: before it, `compute_must_cache(vm)` raised the
moment such an instruction executed and so could not be passed as a
global `must_cache_set` for any program containing one (the dynamic-
array tests had to hand-build L2 sets excluding the L3-only creates).

A future tightening (post-Phase-2 measurements per PRD v4 §Part IX
M1) ports Enzyme's recomputation-cost heuristic to further skip
L2-capable outputs that are derivable from later live values, but the
stub does not attempt this — see this file's top-of-module docstring
"What M7.5 ships" for the rationale.

# How "instruction index" is defined

For each `BasicBlock` in `prog.blocks`, the index ranges over
`1:length(block.instructions)` — i.e., only the body instructions,
not the entry/exit markers (which sit in their own `entry` / `exit`
slots and are always injective per M6.1's type-level methods on the
six control-flow subtypes).

A block with an empty `instructions` vector (legal per
`src/ir/basic_block.jl`'s constructor — a pass-through block whose
only purpose is control-flow pattern-matching) contributes no
entries to the set.

# Example

```julia
julia> set = compute_must_cache(my_program);
julia> (:b_step1, 1) in set
true   # block :b_step1's first body instruction is non-injective
       # (e.g., ArithmeticAssignment(:sub) — paired-inverse modop,
       # M6.1 conservative `false`).
```

# Ref

  * ADR 0002 §"Design decisions that ripple to M7.2–M7.7" decision 5
    — the `Set{Tuple{Symbol, Int}}` shape and the
    (block_label, instr_idx) coordinate are locked there.
  * `src/history/Injective.jl` (M6.1) — the trait this stub queries.
"""
function compute_must_cache(prog::VMProgram)::Set{Tuple{Symbol, Int}}
    result = Set{Tuple{Symbol, Int}}()
    for block in prog.blocks
        for (idx, instr) in enumerate(block.instructions)
            # bd `bennettvm-5pp`: a slot is L2-cached iff it is BOTH
            # non-injective (needs SOME history) AND L2-capable (has a
            # working `make_delta` / `predelta_payload` + NamedTuple
            # `inverse` — `is_l2_capable`, `src/history/delta.jl`). A
            # non-injective-but-not-L2-capable instruction (Define /
            # VarGEP / MemoryLoad / CastInstruction / SelectInstruction /
            # CallInstruction) is NOT marked — it falls through to the L3
            # checkpoint path (`step!`'s K-multiple gate), which is the
            # only sound option for it. Marking it would route it through
            # the L2 push gate and hit the RAISING generic `make_delta`
            # fallback (`src/history/delta.jl`) — the bug `bennettvm-5pp`
            # fixes, which previously made `compute_must_cache(vm)`
            # un-passable as a global must_cache_set for any such program.
            if !is_injective(instr) && is_l2_capable(typeof(instr))
                push!(result, (block.label, idx))
            end
        end
    end
    return result
end

"""
    must_cache(set::Set{Tuple{Symbol, Int}},
               block_label::Symbol, instr_idx::Int) -> Bool

O(1) membership predicate over the must-cache set produced by
`compute_must_cache`. This is the query M7.6's `step!` consults at
the push site to decide whether the current forward step should emit
a `DeltaEntry`.

The function is a thin wrapper around `in` so that the M7.6 push
site reads as `must_cache(set, current_block_label, current_idx)`
rather than constructing a tuple inline at every call — the
documented predicate name makes the gate's intent self-evident in
the interpreter.

# Ref

  * ADR 0002 §"Composition with M6's injective gate" — the three-way
    decision (L1 / L2 / L3) at the push site. M7.6 wires this
    predicate as the L2 gate.
"""
must_cache(set::Set{Tuple{Symbol, Int}},
           block_label::Symbol, instr_idx::Int)::Bool =
    (block_label, instr_idx) in set
