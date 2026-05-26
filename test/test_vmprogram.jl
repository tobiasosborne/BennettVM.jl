# test/test_vmprogram.jl — M2.17 VMProgram real-shape unit tests.
#
# # Why this test exists
#
# M2.17 (bd `bennettvm-tot`) replaces the M0.2 four-field digest stub
# `VMProgram` with the real RSSA-derived shape: `blocks`, `label_table`,
# `entry_label`, plus the preserved `arg_widths` / `return_widths`
# handoff metadata. This file pins the new struct's three contracts:
#
#   1. The full-arity constructor wires the new fields correctly and
#      `n_instructions` / `Base.length` / `Base.show` derive their
#      outputs from `blocks` (M2.17 reshape decision: counts are
#      derived, not stored).
#   2. The inner-constructor invariants (Rule 1) fire on the malformed
#      inputs the docstring promises they will: mismatched
#      `length(label_table)` vs `length(blocks)`, and `entry_label`
#      absent from `label_table`.
#   3. The M0.2-compatibility digest-stub constructor
#      `VMProgram(arg_widths, return_widths)` continues producing the
#      empty-blocks shape that `src/lower_vm.jl` (still digest-only)
#      relies on; the M0.3 handoff smoke depends on this shape.
#
# # Why this test file is separate from test_basic_block.jl
#
# The M2.15 BasicBlock tests pin BasicBlock-level invariants (entry/
# exit slot validation, body must not contain control instructions,
# `reversed()` reverse-of-reverse). M2.17's VMProgram concerns are
# strictly higher-level (block COLLECTIONS, label tables, entry-label
# resolution) and a new file keeps the per-construct test landscape
# easy to navigate. Per Rule 4, every test below asserts an invariant
# against a known-correct value.
#
# # Ref
#
#   * `src/ir/VMProgram.jl` (M2.17) — the struct under test and the
#     `n_instructions` helper.
#   * `src/ir/basic_block.jl` (M2.15) — `BasicBlock` constructor used
#     to build the two-block fixtures below.
#   * `src/ir/label_table.jl` (M2.16) — `LabelTable` constructor used
#     to build the matching label-table fixtures.
#   * CLAUDE.md Rule 1 (constructor-validation tests fail loud);
#     Rule 4 (every test asserts against a known-correct value).

using Test
using BennettVM

@testset "VMProgram real shape (M2.17)" begin
    # Build two simple blocks. bb1 has one body instruction
    # (ArithmeticAssignment with `:and` — `:and` is in BINARY_OPERATORS,
    # see src/ir/operators.jl), bb2 has one as well. The
    # `1 + length(body) + 1` flat-stream layout (M2.16) then gives:
    #   bb1: 1 (entry) + 1 (body) + 1 (exit) = 3
    #   bb2: 1 (entry) + 1 (body) + 1 (exit) = 3
    # so n_instructions(vm) == 6 below.
    body1 = BennettVM.Instruction[
        BennettVM.ArithmeticAssignment(:y, :x, :xor, :a, :and, :b),
    ]
    body2 = BennettVM.Instruction[
        BennettVM.ArithmeticAssignment(:z, :w, :xor, :a, :and, :b),
    ]
    bb1 = BennettVM.BasicBlock(
        :B1,
        BennettVM.UnconditionalEntry(:B1, Symbol[]),
        body1,
        BennettVM.UnconditionalExit(:B2, Symbol[]),
    )
    bb2 = BennettVM.BasicBlock(
        :B2,
        BennettVM.UnconditionalEntry(:B2, Symbol[]),
        body2,
        BennettVM.UnconditionalExit(:B3, Symbol[]),
    )
    blocks = [bb1, bb2]
    lt = BennettVM.LabelTable(blocks)
    vm = VMProgram(blocks, lt, :B1, [64], [64])

    @test length(vm.blocks) == 2
    @test vm.entry_label === :B1
    # n_instructions sums 1 + length(body) + 1 across blocks; with one
    # body instruction per block, that's 3 + 3 = 6.
    @test BennettVM.n_instructions(vm) == 6
    @test vm.arg_widths == [64]
    @test vm.return_widths == [64]

    # Base.length(::VMProgram) returns block count, matching the
    # docstring promise that "length" is the program's RSSA sense
    # (number of basic blocks).
    @test length(vm) == 2

    # Base.show single-line summary; the entry label appears in the
    # repr for REPL-debugging purposes.
    repr_str = sprint(show, vm)
    @test occursin("blocks=2", repr_str)
    @test occursin("instructions=6", repr_str)
    @test occursin("entry=:B1", repr_str)
end

@testset "VMProgram constructor validation (M2.17)" begin
    # Fixture: one block + a matching label_table.
    bb1 = BennettVM.BasicBlock(
        :B1,
        BennettVM.UnconditionalEntry(:B1, Symbol[]),
        BennettVM.Instruction[],
        BennettVM.UnconditionalExit(:B2, Symbol[]),
    )
    lt = BennettVM.LabelTable([bb1])

    # (1) entry_label missing from label_table — must fail loud per
    #     Rule 1 because the interpreter would otherwise hit a
    #     KeyError at the first dispatch step.
    @test_throws ErrorException VMProgram([bb1], lt, :NotThere, Int[], Int[])

    # (2) Mismatched block / label_table counts — drop the block, keep
    #     the label_table built from one block. The empty-blocks
    #     branch in the inner constructor short-circuits the haskey
    #     check (because the digest-stub shape has empty blocks AND
    #     empty label_table), so to trigger the length mismatch we
    #     need a non-empty label_table paired with an empty blocks
    #     vector — exactly this case.
    @test_throws ErrorException VMProgram(
        BennettVM.BasicBlock[],
        lt,
        :B1,
        Int[],
        Int[],
    )
end

@testset "VMProgram digest-shim constructor (M2.17)" begin
    # The M0.2-compatibility convenience constructor used by
    # `src/lower_vm.jl`. Produces the empty-blocks shape that the M0.3
    # handoff smoke depends on; widths are the ParsedIR-handoff
    # metadata flowing through unchanged.
    vm = VMProgram([8], [8])
    @test isempty(vm.blocks)
    @test length(vm.label_table) == 0
    @test vm.entry_label === :main
    @test vm.arg_widths == [8]
    @test vm.return_widths == [8]

    # The empty-blocks case is the ONLY case the inner constructor
    # allows `entry_label` (`:main`) to be absent from `label_table`;
    # check that the digest-stub VMProgram is in fact constructible
    # without the haskey check firing.
    @test BennettVM.n_instructions(vm) == 0
    @test length(vm) == 0
end
