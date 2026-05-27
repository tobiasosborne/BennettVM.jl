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
#      this asymmetry with ArithmeticAssignment); the stub includes
#      it in the must-cache set unconditionally.
#   6. **CallInstruction.** M6.1's type-level fallback is `false`;
#      the stub includes the call site in the set.
#   7. **Multi-block countdown(3).** The canonical fixture
#      `build_countdown_vm(3)` from `test/test_forward_interpreter.jl`.
#      Layout per the `_decrement_block` helper: `:b_start` has empty
#      body, `:b_step1`..`:b_step3` each have two non-injective
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

# `build_countdown_vm` and `countdown_ref` are defined as top-level
# functions by `test/test_forward_interpreter.jl` (the M3.8 capstone),
# which `runtests.jl` includes BEFORE this file. Re-including it here
# would double-run that file's testsets; relying on the
# already-loaded definitions follows the same convention as
# `test_unrun.jl` and `test_roundtrip.jl`, which reuse
# `build_countdown_vm` without re-include.

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
# 6. CallInstruction — type-level `false`; must-cache.
# ---------------------------------------------------------------------
# Mutation that would catch a regression: returning early on
# CallInstruction (e.g. an explicit `instr isa CallInstruction &&
# continue`) turns this RED.
@testset "M7.5 — CallInstruction is non-injective" begin
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
    @test set == Set([(:B1, 1)])
end

# ---------------------------------------------------------------------
# 7. Multi-block countdown(3) — the canonical multi-block fixture.
# ---------------------------------------------------------------------
# Mutation that would catch a regression: using `block.entry` or
# `block.exit` in the iterator (instead of `block.instructions`) would
# add control-flow markers to the set and turn this RED.
@testset "M7.5 — countdown(3) must-cache set (6 entries)" begin
    vm = build_countdown_vm(3)
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
    vm = build_countdown_vm(3)
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
    vm = build_countdown_vm(3)
    set = BennettVM.compute_must_cache(vm)
    @test set isa Set{Tuple{Symbol, Int}}
    @test eltype(set) === Tuple{Symbol, Int}
    # Also pins the empty-set case retains the typed shape.
    empty_vm = VMProgram([8], [8])
    empty_set = BennettVM.compute_must_cache(empty_vm)
    @test empty_set isa Set{Tuple{Symbol, Int}}
end
