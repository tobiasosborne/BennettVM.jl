# test/test_interpreter.jl — M3.1 `initial_state` unit tests
# (bd `bennettvm-afj`).
#
# # What this file pins
#
# `src/interpreter/Interpreter.jl` introduces `initial_state(prog,
# input)::RState` — the gateway function for the forward-only
# interpreter milestone (M3). The tests below pin:
#
#   1. **Happy path** — a single-block VMProgram with a `BeginInstruction`
#      entry slot produces an `RState` whose `current.pc` equals the
#      entry block's `fwd_address` (= 1 for the first block); whose
#      `locals` carry the input verbatim; whose `status` is `:running`;
#      whose `memory` is empty; and whose `history` is an empty vector.
#   2. **Empty-program rejection (PRD v4 §3.16)** — the M0.2
#      digest-stub `VMProgram(arg_widths, return_widths)` produces an
#      empty-`blocks` program; `initial_state` MUST raise on it
#      descriptively.
#   3. **Missing entry_label rejection** — this is enforced by
#      `VMProgram`'s inner constructor (M2.17), not by `initial_state`
#      itself, because an unstartable `VMProgram` is never legal to
#      construct. The test verifies the constructor's raise.
#   4. **BeginInstruction.params name validation** — when the entry
#      block's `entry` slot is a `BeginInstruction`, the input keys
#      MUST exactly match its `params` list (both missing-key and
#      extra-key mismatches raise).
#   5. **Non-Begin entry fallback** — when the entry slot is an
#      `UnconditionalEntry` (or any other non-`BeginInstruction`),
#      name validation is skipped and the input is installed verbatim.
#      This is the lowering-pass escape hatch for basic-block-rooted
#      main routines that don't carry an explicit `Begin`.
#   6. **Int64 coercion** — `IState.locals` is declared
#      `Dict{Symbol,Int64}`; narrower input types (`Int32`) are
#      coerced via `Int64(v)` at the boundary, not deferred to the
#      first arithmetic instruction.
#
# Per CLAUDE.md Rule 4, every test asserts an invariant against a
# known-correct value (not just "didn't throw").
#
# # Ref
#
#   * `src/interpreter/Interpreter.jl` (M3.1) — the function under
#     test.
#   * `src/ir/VMProgram.jl` (M2.17) — `VMProgram` constructor and the
#     digest-stub 2-arg form.
#   * `src/ir/label_table.jl` (M2.16) — `LabelEntry.fwd_address` is
#     what `current.pc` ends up holding.
#   * `bennettvm_prd.md` (PRD v4) §3.9 (`initial_state` signature),
#     §3.16 (empty-program validation is binding).
#   * CLAUDE.md Rule 1 (constructor-validation tests fail loud);
#     Rule 4 (every test asserts a known-correct value).

using Test
using BennettVM

@testset "initial_state happy path (M3.1)" begin
    # Hand-build a single-block program that mimics a no-arg-aware main:
    # the BeginInstruction names `:n` as the formal parameter, the body
    # is a single ArithmeticAssignment touching `:n`, and the
    # EndInstruction names `:s` as the return. The body's actual
    # semantics are irrelevant for M3.1 — we only check that
    # initial_state wires up pc / locals / status / memory / history.
    bb = BennettVM.BasicBlock(
        :main,
        BennettVM.BeginInstruction(:main, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:s, :n, :xor, :n, :xor, Int64(0)),
        ],
        BennettVM.EndInstruction(:main, [:s]),
    )
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :main, [64], [64])

    rs = initial_state(vm, Dict(:n => Int64(7)))
    @test rs isa BennettVM.RState
    # fwd_address of the first block is 1 (the entry instruction is the
    # first instruction in the flat stream).
    @test rs.current.pc == 1
    @test rs.current.locals[:n] == 7
    @test rs.current.status === :running
    @test isempty(rs.history)
    @test isempty(rs.current.memory)
end

@testset "initial_state validation: empty program (M3.1)" begin
    # The M0.2 digest-stub `VMProgram(arg_widths, return_widths)`
    # constructor produces an empty-`blocks` program. PRD v4 §3.16
    # makes the empty-program rejection binding.
    vm = VMProgram(Int[], Int[])
    @test_throws ErrorException initial_state(vm, Dict{Symbol,Int64}())
end

@testset "initial_state validation: missing entry_label (M3.1)" begin
    # Construct a candidate VMProgram with an entry_label (`:gone`)
    # that is absent from the LabelTable. The M2.17 inner constructor
    # rejects this directly — `initial_state` never sees the bad
    # program because it cannot be constructed in the first place.
    # This test verifies that gate.
    bb = BennettVM.BasicBlock(
        :onlyblock,
        BennettVM.BeginInstruction(:onlyblock, Symbol[]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:onlyblock, Symbol[]),
    )
    @test_throws ErrorException VMProgram(
        [bb],
        BennettVM.LabelTable([bb]),
        :gone,
        Int[],
        Int[],
    )
end

@testset "initial_state validation: input matches BeginInstruction.params (M3.1)" begin
    # Two-parameter Begin: input keys MUST equal {:n, :m}. Both
    # missing-key and extra-key mismatches raise.
    bb = BennettVM.BasicBlock(
        :main,
        BennettVM.BeginInstruction(:main, [:n, :m]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:main, [:n, :m]),
    )
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :main, [64, 64], [64, 64])

    # Missing :m — the params Set is {:n, :m}, the input Set is {:n}.
    @test_throws ErrorException initial_state(vm, Dict(:n => Int64(1)))
    # Extra key :extra — the input Set is a superset of params.
    @test_throws ErrorException initial_state(
        vm,
        Dict(:n => Int64(1), :m => Int64(2), :extra => Int64(3)),
    )
    # Exact match — succeeds and binds both names.
    rs = initial_state(vm, Dict(:n => Int64(1), :m => Int64(2)))
    @test rs.current.locals[:n] == 1
    @test rs.current.locals[:m] == 2
end

@testset "initial_state fallback when entry isn't Begin (M3.1)" begin
    # When the entry slot is an `UnconditionalEntry` (the basic-block-
    # rooted main shape Phase-2 lowering MAY produce), the param-name
    # validation is skipped and `input` is installed verbatim — even if
    # its keys don't match the entry's `params` list. This is the
    # documented escape hatch from `initial_state`'s docstring.
    bb = BennettVM.BasicBlock(
        :main,
        BennettVM.UnconditionalEntry(:main, [:x]),
        BennettVM.Instruction[],
        BennettVM.UnconditionalExit(:next, [:x]),
    )
    # NOTE: this VMProgram has `:next` referenced by the exit but no
    # `:next` block in the LabelTable. That's M2.18's cross-block
    # validation pass to enforce, not M2.17's inner constructor —
    # which only checks length(label_table) == length(blocks) and
    # haskey(label_table, entry_label). Both pass here.
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :main, [64], [64])

    rs = initial_state(vm, Dict(:anything => Int64(42)))
    @test rs.current.locals[:anything] == 42
    @test rs.current.status === :running
end

@testset "initial_state input coercion to Int64 (M3.1)" begin
    # Narrower input types (Int32 here) MUST be coerced to Int64 at
    # the construction site so the produced `IState.locals` matches
    # its declared element type.
    bb = BennettVM.BasicBlock(
        :main,
        BennettVM.BeginInstruction(:main, [:n]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:main, [:n]),
    )
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :main, [64], [64])

    rs = initial_state(vm, Dict(:n => Int32(5)))
    @test rs.current.locals[:n] == Int64(5)
    @test rs.current.locals[:n] isa Int64
end
