# test/test_liveness.jl — M7.5 unit tests for the stub liveness /
# min-cut analysis (bd `bennettvm-46p`).
#
# # What this file pins
#
# `src/analysis/liveness.jl` defines the L2 layer's "which instructions
# need a DeltaEntry?" pre-computation per PRD v4 §3.3 layer 2 and ADR
# 0002 §"Design decisions that ripple to M7.2–M7.7" decision 5. M7.5
# ships the **stub** — every non-injective instruction (per M6.1's
# `is_injective` trait) is in the must-cache set; the true min-cut
# tightening is deferred (ADR 0002 §"What M7.5 ships" — the upgrade
# is gated on the M1 cost-measurement bead, PRD v4 §Part IX).
#
# The tests below pin (Rule 4 — every @test pins a specific value):
#
#   1. **Empty program.** A VMProgram with no blocks (the M0.2 digest-
#      stub shape) produces an empty must-cache set. This pins that
#      the stub is safe for the digest-only case `lower_vm` still
#      returns.
#   2. **All-injective block.** A single block holding only injective
#      body instructions (SwapInstruction) produces an empty set —
#      the M6.1 type-level `true` flows through the stub unchanged.
#   3. **Non-injective ArithmeticAssignment :add.** A single block
#      with one `ArithmeticAssignment(:add)` produces a singleton
#      `{(block_label, 1)}` set — M6.1's value-level
#      `is_injective(::ArithmeticAssignment)` returns `false` for
#      non-`:xor` modops, and the stub forwards that classification.
#   4. **Injective ArithmeticAssignment :xor.** Same shape but with
#      `modop === :xor`; M6.1's value-level method returns `true`
#      and the stub correctly omits it from the set.
#   5. **MemoryAssignment.** M6.1 leaves `MemoryAssignment` at the
#      conservative type-level `false` (no value-level
#      specialisation — ADR 0002 §Open Questions item 3 documents
#      this asymmetry with ArithmeticAssignment); it is non-injective
#      AND L2-capable (`is_l2_capable(MemoryAssignment) == true`), so
#      the stub includes it in the must-cache set.
#   6. **CallInstruction.** M6.1's type-level fallback is `false`
#      (non-injective), but it is NOT L2-capable — its `make_delta`
#      raises (cross-call deltas v5-deferred, ADR 0002 §Open Questions
#      item 4). Per bd `bennettvm-5pp` it is therefore EXCLUDED from
#      the set (it falls through to L3). This testset was UPDATED by
#      `bennettvm-5pp` — it previously asserted inclusion, which relied
#      on the pre-5pp "every non-injective slot" behaviour that made
#      `compute_must_cache(vm)` raise when later passed to `run!`.
#   7. **Multi-block countdown(3).** The canonical fixture
#      `countdown_program(3)` from `test/reference/countdown.jl`
#      (M8.1 — bd `bennettvm-do7`). Layout per the file-private
#      `_decrement_block` helper there: `:b_start` has empty body,
#      `:b_step1`..`:b_step3` each have two non-injective
#      ArithmeticAssignments (`:sub` then `:add`), `:b_done` has
#      empty body. Expected set:
#        {(:b_step1, 1), (:b_step1, 2),
#         (:b_step2, 1), (:b_step2, 2),
#         (:b_step3, 1), (:b_step3, 2)}.
#      This is the same six steps ADR 0002 §"Worked example:
#      countdown(3)" identifies as L2-push steps in the flat-stream
#      walk-through.
#   8. **`must_cache` query.** O(1) membership predicate over the
#      countdown(3) set: present entries return `true`, absent
#      entries (and labels with empty bodies) return `false`.
#   9. **Element type.** The returned `Set` has element type exactly
#      `Tuple{Symbol, Int}` (not `Tuple{Any, Any}` or some looser
#      type) — pins the typed-shape contract ADR 0002 decision 5
#      locks for M7.6's consumption.
#
# # bd `bennettvm-5pp` — the L2-capability gate (added testsets 10-12)
#
#  10. **The forcing/regression test (THE bug 5pp fixes).** A lowered
#      dynamic-array program (`_dyn_alloca_vm` here — DynAlloca + VarGEP
#      + MemoryStore + MemoryLoad) is the witness: pre-5pp,
#      `compute_must_cache(vm)` marked the L3-only `VarGEP` / `MemoryLoad`
#      slots, and passing that set to `run!` RAISED on the generic
#      `make_delta` fallback the moment they executed. Post-5pp the set
#      EXCLUDES those slots (and the L3-only `Define`), INCLUDES the
#      L2-capable `DynAlloca` / `MemoryStore`, AND the program runs
#      forward + round-trips with `must_cache_set = compute_must_cache(vm)`
#      WITHOUT raising. This is the load-bearing test.
#  11. **Trait-matches-reality.** For each of the four L2-capable types
#      (`ArithmeticAssignment`, `MemoryAssignment`, `MemoryStore`,
#      `DynAlloca`) `is_l2_capable` is `true`; for the six L3-only types
#      (`Define`, `VarGEP`, `MemoryLoad`, `CastInstruction`,
#      `SelectInstruction`, `CallInstruction`) it is `false`. AND the
#      trait is cross-checked against the machinery: an L2-capable
#      instruction can build a DeltaEntry (via `predelta_payload` or
#      `make_delta`) and invert it; a non-L2-capable one's `make_delta`
#      RAISES — proving WHY it must be excluded.
#  12. **Empty / all-injective regression.** Re-confirms the empty set
#      and the all-injective set are unchanged by the gate.
#
# # What this file deliberately does NOT do
#
#   * **No `step!` integration test.** M7.5 ships the analysis
#     function only; integration into the push gate is M7.6's job.
#     Calling `step!` here would conflate the M7.5/M7.6 milestone
#     boundary.
#   * **No VMProgram mutation.** The bead's description suggests
#     modifying VMProgram to carry the set; M7.5 explicitly does
#     NOT (per the scoping decision in the M7.5 task brief — leaves
#     storage-shape choice to M7.6).
#
# # Ref
#
#   * `src/analysis/liveness.jl` — the implementation; the
#     top-of-module docstring expands the rationale in full.
#   * `docs/adr/0002-enzyme-min-cut-mapping.md` §"Design decisions
#     that ripple to M7.2–M7.7" decision 5 — locks the
#     `Set{Tuple{Symbol, Int}}` shape and (block_label, instr_idx)
#     coordinate.
#   * `docs/adr/0002-enzyme-min-cut-mapping.md` §"Worked example:
#     countdown(3)" — the six L2-push steps the multi-block test
#     pins.
#   * `bennettvm_prd.md` (PRD v4) §3.3 layer 2; §2.7.
#   * `src/history/Injective.jl` (M6.1) — the trait the stub queries.
#   * CLAUDE.md Rule 4 — every @test pins a specific value;
#     Rule 5 — mutation citations per testset.

using Test
using BennettVM
import Bennett   # bd `bennettvm-5pp` — the forcing test ingests a ParsedIR.

# `countdown_program` and `countdown_ref` live in
# `test/reference/countdown.jl` (M8.1 — bd `bennettvm-do7`). Include
# the reference file directly so this test stands alone (no
# transitive include-order dependency on `runtests.jl`); the
# file-level `@assert` in `reference/countdown.jl` re-fires on every
# include but that is intentional — it's the golden-master self-check
# (PRD v4 §3.14).
include(joinpath(@__DIR__, "reference", "countdown.jl"))

# ---------------------------------------------------------------------
# 1. Empty program (M0.2 digest-stub shape).
# ---------------------------------------------------------------------
# Mutation that would catch a regression: replacing `Set{Tuple{Symbol,
# Int}}()` with `Set{Tuple{Symbol, Int}}([(:bogus, 0)])` in the
# compute_must_cache initialiser turns these asserts RED.
@testset "M7.5 — empty program (digest-stub shape)" begin
    vm = VMProgram([8], [8])    # M0.2 digest constructor — empty blocks.
    set = BennettVM.compute_must_cache(vm)
    @test isempty(set)
    @test set isa Set{Tuple{Symbol, Int}}
end

# ---------------------------------------------------------------------
# 2. All-injective block (SwapInstruction body).
# ---------------------------------------------------------------------
# Mutation that would catch a regression: flipping the `!is_injective`
# guard in compute_must_cache to `is_injective` (or removing the `!`)
# turns this RED — the SwapInstruction would erroneously be pushed.
@testset "M7.5 — all-injective block produces empty set" begin
    body = BennettVM.Instruction[
        BennettVM.SwapInstruction(:x, :y, :a, :b),
    ]
    bb = BennettVM.BasicBlock(
        :B1,
        BennettVM.UnconditionalEntry(:B1, Symbol[]),
        body,
        BennettVM.UnconditionalExit(:B2, Symbol[]),
    )
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :B1, Int[], Int[])
    set = BennettVM.compute_must_cache(vm)
    @test isempty(set)
end

# ---------------------------------------------------------------------
# 3. Non-injective ArithmeticAssignment :add → single must-cache entry.
# ---------------------------------------------------------------------
# Mutation that would catch a regression: hard-coding the result as
# `Set{Tuple{Symbol, Int}}()` (i.e. always-empty) turns this RED.
@testset "M7.5 — ArithmeticAssignment :add is non-injective" begin
    body = BennettVM.Instruction[
        BennettVM.ArithmeticAssignment(:y, :x, :add, :a, :and, :b),
    ]
    bb = BennettVM.BasicBlock(
        :B1,
        BennettVM.UnconditionalEntry(:B1, Symbol[]),
        body,
        BennettVM.UnconditionalExit(:B2, Symbol[]),
    )
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :B1, Int[], Int[])
    set = BennettVM.compute_must_cache(vm)
    @test set == Set([(:B1, 1)])
end

# ---------------------------------------------------------------------
# 4. Injective ArithmeticAssignment :xor → empty set.
# ---------------------------------------------------------------------
# Mutation that would catch a regression: querying
# `is_injective(typeof(instr))` (type-level only) instead of
# `is_injective(instr)` (value-level) turns this RED — the type-level
# fallback for ArithmeticAssignment is `false`, so the :xor instance
# would erroneously be pushed.
@testset "M7.5 — ArithmeticAssignment :xor is injective (value-level)" begin
    body = BennettVM.Instruction[
        BennettVM.ArithmeticAssignment(:y, :x, :xor, :a, :and, :b),
    ]
    bb = BennettVM.BasicBlock(
        :B1,
        BennettVM.UnconditionalEntry(:B1, Symbol[]),
        body,
        BennettVM.UnconditionalExit(:B2, Symbol[]),
    )
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :B1, Int[], Int[])
    set = BennettVM.compute_must_cache(vm)
    @test isempty(set)
end

# ---------------------------------------------------------------------
# 5. MemoryAssignment — non-injective at M6.1 (no value-level method).
# ---------------------------------------------------------------------
# Mutation that would catch a regression: skipping MemoryAssignment in
# the iterator (e.g. an `isa ArithmeticAssignment` filter) turns this
# RED.
@testset "M7.5 — MemoryAssignment is non-injective" begin
    body = BennettVM.Instruction[
        BennettVM.MemoryAssignment(:addr, :xor, :a, :and, :b),
    ]
    bb = BennettVM.BasicBlock(
        :B1,
        BennettVM.UnconditionalEntry(:B1, Symbol[]),
        body,
        BennettVM.UnconditionalExit(:B2, Symbol[]),
    )
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :B1, Int[], Int[])
    set = BennettVM.compute_must_cache(vm)
    @test set == Set([(:B1, 1)])
end

# ---------------------------------------------------------------------
# 6. CallInstruction — non-injective but NOT L2-capable → EXCLUDED.
# ---------------------------------------------------------------------
# bd `bennettvm-5pp`: CallInstruction is non-injective (M6.1 type-level
# `false`) but is NOT L2-capable (its `make_delta` RAISES — cross-call
# deltas are v5-deferred, ADR 0002 §Open Questions item 4), so it is
# left OUT of the must-cache set and falls through to L3. (Pre-5pp this
# testset asserted `set == Set([(:B1, 1)])`; that relied on the buggy
# "mark every non-injective slot" behaviour which made
# `compute_must_cache(vm)` un-passable to `run!` for any call-bearing
# program — routing the call through L2 hit the raising make_delta.)
# Mutation that would catch a regression: flipping the predicate's `&&`
# to `||` in compute_must_cache (so non-L2-capable slots are marked
# again) turns this RED.
@testset "M7.5/5pp — CallInstruction is non-injective but NOT L2-capable" begin
    body = BennettVM.Instruction[
        BennettVM.CallInstruction([:t1], :sub_label, [:a1], :call),
    ]
    bb = BennettVM.BasicBlock(
        :B1,
        BennettVM.UnconditionalEntry(:B1, Symbol[]),
        body,
        BennettVM.UnconditionalExit(:B2, Symbol[]),
    )
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :B1, Int[], Int[])
    set = BennettVM.compute_must_cache(vm)
    # Non-injective but no L2 path → not marked → falls through to L3.
    @test isempty(set)
    @test !BennettVM.is_injective(body[1])              # genuinely non-injective
    @test !BennettVM.is_l2_capable(BennettVM.CallInstruction)  # but no L2 path
end

# ---------------------------------------------------------------------
# 7. Multi-block countdown(3) — the canonical multi-block fixture.
# ---------------------------------------------------------------------
# Mutation that would catch a regression: using `block.entry` or
# `block.exit` in the iterator (instead of `block.instructions`) would
# add control-flow markers to the set and turn this RED.
@testset "M7.5 — countdown(3) must-cache set (6 entries)" begin
    vm = countdown_program(3)
    set = BennettVM.compute_must_cache(vm)
    expected = Set([
        (:b_step1, 1), (:b_step1, 2),
        (:b_step2, 1), (:b_step2, 2),
        (:b_step3, 1), (:b_step3, 2),
    ])
    @test set == expected
    # b_start and b_done have empty bodies — contribute nothing.
    @test !any(t -> t[1] === :b_start, set)
    @test !any(t -> t[1] === :b_done, set)
    # Cardinality pin — six L2-push steps, matching ADR 0002
    # §"Worked example: countdown(3)" flat-stream walk-through.
    @test length(set) == 6
end

# ---------------------------------------------------------------------
# 8. `must_cache` O(1) query predicate.
# ---------------------------------------------------------------------
# Mutation that would catch a regression: implementing `must_cache` as
# `!((block_label, instr_idx) in set)` (sign flip) turns the present-
# entry asserts RED and the absent-entry asserts RED simultaneously.
@testset "M7.5 — must_cache(set, label, idx) query predicate" begin
    vm = countdown_program(3)
    set = BennettVM.compute_must_cache(vm)
    # Present: each step block's two body slots.
    @test BennettVM.must_cache(set, :b_step1, 1)
    @test BennettVM.must_cache(set, :b_step1, 2)
    @test BennettVM.must_cache(set, :b_step3, 2)
    # Absent: out-of-range index in a present block label.
    @test !BennettVM.must_cache(set, :b_step1, 99)
    @test !BennettVM.must_cache(set, :b_step1, 0)
    # Absent: empty-body blocks contribute no entries.
    @test !BennettVM.must_cache(set, :b_start, 1)
    @test !BennettVM.must_cache(set, :b_done, 1)
    # Absent: a label not in the program at all.
    @test !BennettVM.must_cache(set, :nonexistent_block, 1)
end

# ---------------------------------------------------------------------
# 9. Set element type — `Tuple{Symbol, Int}` exactly.
# ---------------------------------------------------------------------
# Mutation that would catch a regression: dropping the `::Set{Tuple{
# Symbol, Int}}` return-type annotation AND replacing the initialiser
# with `Set()` (untyped) would produce `Set{Any}`, turning this RED.
@testset "M7.5 — return type is Set{Tuple{Symbol, Int}}" begin
    vm = countdown_program(3)
    set = BennettVM.compute_must_cache(vm)
    @test set isa Set{Tuple{Symbol, Int}}
    @test eltype(set) === Tuple{Symbol, Int}
    # Also pins the empty-set case retains the typed shape.
    empty_vm = VMProgram([8], [8])
    empty_set = BennettVM.compute_must_cache(empty_vm)
    @test empty_set isa Set{Tuple{Symbol, Int}}
end

# =====================================================================
# bd `bennettvm-5pp` — the L2-capability gate.
# =====================================================================

# A lowered dynamic-array program whose body holds a DynAlloca (L2-capable),
# a VarGEP (L3-only), a MemoryStore (L2-capable), and a MemoryLoad (L3-only)
# — the exact mix that made the pre-5pp `compute_must_cache(vm)` raise when
# passed to `run!`. Mirrors `_dyn_alloca_vm()` in `test/test_alloca_delta.jl`
# (kept self-contained here so this file stands alone).
#
#   __arr = alloca i32, n_elems = %__n      (dynamic-N → DynAlloca, L2-capable)
#   __p0  = gep __arr, 0                     (element-0 pointer → VarGEP, L3-only)
#   store 7, __p0                            (region store → MemoryStore, L2-capable)
#   __r   = load __p0                        (read it back → MemoryLoad, L3-only)
#   ret __r
# Oracle: __r == 7 for any n >= 1.
function _dyn_alloca_vm_liveness()
    block = Bennett.IRBasicBlock(
        :entry,
        Bennett.IRInst[
            Bennett.IRAlloca(:__arr, 32, Bennett.SSAOperand(:__n)),
            Bennett.IRVarGEP(:__p0, Bennett.SSAOperand(:__arr),
                             Bennett.ConstOperand(0), 32),
            Bennett.IRStore(Bennett.SSAOperand(:__p0), Bennett.ConstOperand(7), 32),
            Bennett.IRLoad(:__r, Bennett.SSAOperand(:__p0), 32),
        ],
        Bennett.IRRet(Bennett.SSAOperand(:__r), 32),
    )
    parsed = Bennett.ParsedIR(32, [(:__n, 32)], [block], [32])
    return lower_vm(parsed; opts=:dyn_alloca_liveness)
end

# The (block_label, body_idx) of every instruction of a given concrete type.
function _slots_of_type(vm, ::Type{T}) where {T}
    set = Set{Tuple{Symbol,Int}}()
    for b in vm.blocks, (i, instr) in enumerate(b.instructions)
        instr isa T && push!(set, (b.label, i))
    end
    return set
end

# ---------------------------------------------------------------------
# 10. THE forcing/regression test — compute_must_cache(vm) is now a
#     safe global must_cache_set for a program with L3-only creates.
# ---------------------------------------------------------------------
# Mutation that would catch a regression: flipping `is_l2_capable(VarGEP)`
# or `(MemoryLoad)` to `true` (or the predicate `&&` → `||`) re-marks the
# L3-only slots, so the `run!` below RAISES on the generic make_delta
# fallback — the @test_nowarn / round-trip asserts go RED.
@testset "5pp — compute_must_cache(vm) safe for L3-only creates (forcing)" begin
    vm = _dyn_alloca_vm_liveness()
    set = BennettVM.compute_must_cache(vm)

    # The L2-capable slots ARE marked.
    dynalloca_slots = _slots_of_type(vm, BennettVM.DynAlloca)
    store_slots     = _slots_of_type(vm, BennettVM.MemoryStore)
    @test !isempty(dynalloca_slots)            # fixture really has them
    @test !isempty(store_slots)
    @test dynalloca_slots ⊆ set                # DynAlloca marked (L2-capable)
    @test store_slots ⊆ set                    # MemoryStore marked (L2-capable)

    # The L3-only slots are NOT marked (the soundness fix).
    vargep_slots = _slots_of_type(vm, BennettVM.VarGEP)
    load_slots   = _slots_of_type(vm, BennettVM.MemoryLoad)
    define_slots = _slots_of_type(vm, BennettVM.Define)   # bump-alloc pointer Define
    @test !isempty(vargep_slots)
    @test !isempty(load_slots)
    @test isempty(intersect(vargep_slots, set))   # VarGEP NOT marked → L3
    @test isempty(intersect(load_slots, set))     # MemoryLoad NOT marked → L3
    @test isempty(intersect(define_slots, set))   # Define NOT marked → L3
    # The set is EXACTLY the L2-capable slots.
    @test set == union(dynalloca_slots, store_slots)

    # The load-bearing assertion: run forward + round-trip with the
    # AUTOMATIC set. Pre-5pp this RAISED on make_delta(::VarGEP/::MemoryLoad).
    # K=1 forces the L3-only slots to actually push CheckpointEntrys (the
    # path they fall through to), so this exercises the L2/L3 interleave.
    for n in (Int64(1), Int64(3))
        rs = initial_state(vm, Dict(:__n => n))
        run!(rs, vm; checkpoint_interval=1, must_cache_set=set)   # must NOT raise
        @test is_halted(rs)
        @test result(rs)[:__r] == 7            # oracle agreement
        unrun!(rs, vm)
        @test rs.current == rs.initial         # round-trip
        @test isempty(rs.history)              # history drained
        @test rs.step_count == 0
    end
end

# ---------------------------------------------------------------------
# 11. Trait-matches-reality: is_l2_capable agrees with the live machinery.
# ---------------------------------------------------------------------
# Mutation that would catch a regression: flipping any of the four `true`
# specialisations to `false` turns the matching `@test is_l2_capable(...)`
# RED; flipping the default to `true` turns the six `@test !...` RED.
@testset "5pp — is_l2_capable matches the make_delta/predelta machinery" begin
    IS = BennettVM.IState

    # The four L2-capable types.
    for T in (BennettVM.ArithmeticAssignment, BennettVM.MemoryAssignment,
              BennettVM.MemoryStore, BennettVM.DynAlloca)
        @test BennettVM.is_l2_capable(T)
    end
    # The six L3-only types.
    for T in (BennettVM.Define, BennettVM.VarGEP, BennettVM.MemoryLoad,
              BennettVM.CastInstruction, BennettVM.SelectInstruction,
              BennettVM.CallInstruction)
        @test !BennettVM.is_l2_capable(T)
    end
    # The abstract-default is false (fail-safe).
    @test !BennettVM.is_l2_capable(BennettVM.Instruction)

    # Machinery cross-check, L2-capable side: a representative
    # non-injective+L2-capable instruction builds a DeltaEntry and inverts.
    #   (a) ArithmeticAssignment :add — make_delta path (empty payload).
    aa = BennettVM.ArithmeticAssignment(:y, :x, :add, :a, :and, :b)
    @test !BennettVM.is_injective(aa)          # non-injective (modop !== :xor)
    s_aa = IS(1, Dict(:x => Int64(5), :a => Int64(6), :b => Int64(3)), :running)
    BennettVM.forward(aa, s_aa)                # x consumed → y created
    entry_aa = BennettVM.make_delta(aa, s_aa, 1)
    @test entry_aa isa BennettVM.DeltaEntry
    BennettVM.inverse(aa, s_aa, entry_aa.payload)   # NamedTuple dispatch
    @test haskey(BennettVM.active_locals(s_aa), :x) && !haskey(BennettVM.active_locals(s_aa), :y)  # inverted

    #   (b) MemoryStore — predelta_payload path (pre-state capture).
    ms = BennettVM.MemoryStore(:p, Int64(7))
    @test !BennettVM.is_injective(ms)
    s_ms = IS(1, Dict(:p => Int64(100)), :running, Dict{Int64,Int64}())
    payload_ms = BennettVM.predelta_payload(ms, s_ms)
    @test payload_ms !== nothing               # non-nothing → L2 pre-state path
    BennettVM.forward(ms, s_ms)
    @test s_ms.memory[Int64(100)] == 7         # cell overwritten
    BennettVM.inverse(ms, s_ms, payload_ms)    # NamedTuple dispatch
    @test !haskey(s_ms.memory, Int64(100))     # absent cell restored (was_present)

    # Machinery cross-check, NOT-L2-capable side: make_delta RAISES — the
    # exact reason these must be excluded from the must-cache set.
    s_l3 = IS(1, Dict{Symbol,Int64}(), :running)
    @test_throws ErrorException BennettVM.make_delta(
        BennettVM.Define(:t, :a, :add, :b), s_l3, 1)
    @test_throws ErrorException BennettVM.make_delta(
        BennettVM.VarGEP(:d, :base, Int64(0), Int64(1)), s_l3, 1)
    @test_throws ErrorException BennettVM.make_delta(
        BennettVM.MemoryLoad(:d, :p), s_l3, 1)
    @test_throws ErrorException BennettVM.make_delta(
        BennettVM.CallInstruction([:t1], :sub_label, [:a1], :call), s_l3, 1)
    # And their predelta_payload is the `nothing` default.
    @test BennettVM.predelta_payload(BennettVM.Define(:t, :a, :add, :b), s_l3) === nothing
    @test BennettVM.predelta_payload(BennettVM.MemoryLoad(:d, :p), s_l3) === nothing
end

# ---------------------------------------------------------------------
# 12. No regression: empty / all-injective programs still yield empty.
# ---------------------------------------------------------------------
@testset "5pp — empty & all-injective programs unchanged" begin
    # Empty (digest-stub).
    @test isempty(BennettVM.compute_must_cache(VMProgram([8], [8])))
    # All-injective single-block (SwapInstruction body).
    body = BennettVM.Instruction[BennettVM.SwapInstruction(:x, :y, :a, :b)]
    bb = BennettVM.BasicBlock(
        :B1, BennettVM.UnconditionalEntry(:B1, Symbol[]), body,
        BennettVM.UnconditionalExit(:B2, Symbol[]))
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :B1, Int[], Int[])
    @test isempty(BennettVM.compute_must_cache(vm))
end
