# test/test_forward_interpreter.jl — M3.8 capstone integration test
# (bd `bennettvm-mqh`).
#
# This is the first end-to-end test that exercises the full M3 forward
# interpreter on a multi-block program: `countdown(N)`, hand-built as N
# unrolled decrement blocks chained via `UnconditionalExit` →
# `UnconditionalEntry` cross-block dispatch.
#
# Why countdown is the right capstone shape
# ------------------------------------------
# Per PRD v4 §3.6.2 the four motivating cases (fdict, frtN, matrix_sum,
# collatz_steps) all involve loops; countdown is the smallest non-
# trivial member of that family — a single straight-line loop body
# repeated N times. The Phase-2 interpreter does NOT yet have true
# loops (those land at M_UNBOUNDED), so for M3.8 we unroll countdown(N)
# into N decrement blocks. Each iteration becomes its own basic block
# (one `UnconditionalEntry`, one body of two `ArithmeticAssignment`s,
# one `UnconditionalExit`); cross-block dispatch via M3.6's
# `_handle_cross_block_dispatch!` chains them. This is structurally
# honest: every cross-block edge in the resulting VMProgram exercises
# the args→params positional rename plus the `LabelTable`-mediated pc
# relocation, which are exactly the two M3.6 mechanisms that have no
# coverage in `test_interpreter.jl`'s single-block fixtures.
#
# Why a hand-built fixture (not a `lower_vm` round-trip)
# -------------------------------------------------------
# `lower_vm` is still the M0.2 digest-stub at this milestone; it does
# not yet produce a populated `Vector{BasicBlock}`. M3.8's job is to
# pin the forward interpreter's behavior against a golden-master
# reference (per Phase-0 gating P0.5), not to test the lowering pass.
# Hand-building the VMProgram in test code lets us hold every block
# label, every SSA name, every cross-block edge fixed and inspectable
# in one place — exactly the regression-anchor shape Rule 4 demands.
#
# The decrement-block shape
# -------------------------
# Each decrement block does two things reversibly:
#
#   1. `n_out := n_in - (1 AND 1)` — destroys `:n_in`, produces `:n_out`.
#   2. `s_out := s_in + (1 AND 1)` — destroys `:s_in`, produces `:s_out`.
#
# The `op=:and, lhs=Int64(1), rhs=Int64(1)` pattern is the cheapest way
# to materialise the constant `1` inside an `ArithmeticAssignment`
# without consuming an SSA variable: `_apply_binop(:and, 1, 1) === 1`
# (src/ir/arithmetic_assignment.jl `_apply_binop` clause `op === :and ?
# a & b`). Both `lhs` and `rhs` are `Int64` literals, so neither reads
# from `locals` — the only locals consumed are `n_in` (for modop) and
# the destination's pre-image, which is the standard
# `ArithmeticAssignment` semantics (M2.6).
#
# The naming convention
# ---------------------
# Block :b_start uses :n0, :steps0 (the input SSA names).
# Block :b_stepK reads :n{K-1}, :steps{K-1}; produces :nK, :stepsK.
# Block :b_done holds the final :n{N}, :steps{N}. Identity rename
# across every cross-block edge (sender args == receiver params),
# which simultaneously exercises and stress-tests the two-phase
# capture-delete-assign protocol in `_rename_args_to_params!` (M3.6).
#
# Ref:
#   * CLAUDE.md Rule 4 — every test asserts a known-correct value.
#   * CLAUDE.md Phase-0 P0.5 — golden-master required (countdown_ref).
#   * PRD v4 §3.6.2 — countdown family of motivating cases.
#   * bd `bennettvm-mqh` (M3.8) — this milestone.
#   * src/interpreter/Interpreter.jl §M3.6 — the cross-block dispatch
#     layer this test exercises end-to-end.

using Test
using BennettVM

include(joinpath(@__DIR__, "reference", "countdown.jl"))

# ---------------------------------------------------------------------
# Hand-built VMProgram helpers.
# ---------------------------------------------------------------------

"""
    _decrement_block(label, n_in, s_in, n_out, s_out, next_label) -> BasicBlock

Build a single decrement basic block: `UnconditionalEntry(label,
[n_in, s_in])` → two `ArithmeticAssignment`s that decrement n_in and
increment s_in → `UnconditionalExit(next_label, [n_out, s_out])`.

The `op=:and, lhs=Int64(1), rhs=Int64(1)` pattern produces the
literal `1` inside `_apply_binop` (M2.6) without consuming an SSA
variable. Both operands are `Int64` literals — `ArithmeticAssignment`'s
constructor accepts `Union{Symbol,Int64}` for both `lhs` and `rhs`
(M2.6 inner-constructor signature).
"""
function _decrement_block(label::Symbol, n_in::Symbol, s_in::Symbol,
                          n_out::Symbol, s_out::Symbol, next_label::Symbol)
    BennettVM.BasicBlock(
        label,
        BennettVM.UnconditionalEntry(label, [n_in, s_in]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(n_out, n_in, :sub,
                                           Int64(1), :and, Int64(1)),
            BennettVM.ArithmeticAssignment(s_out, s_in, :add,
                                           Int64(1), :and, Int64(1)),
        ],
        BennettVM.UnconditionalExit(next_label, [n_out, s_out]),
    )
end

"""
    build_countdown_vm(n::Int) -> VMProgram

Hand-build the unrolled `countdown(n)` VMProgram. Layout:

  * `:b_start` — `BeginInstruction(:countdown, [:n0, :steps0])` →
    empty body → `UnconditionalExit(:b_step1, [:n0, :steps0])`.
    (Or `:b_done` directly for the degenerate `n == 0` case.)
  * `:b_step1` ... `:b_step{n}` — each one is `_decrement_block` reading
    `:n{i-1}, :steps{i-1}` and producing `:n{i}, :steps{i}`, exiting to
    `:b_step{i+1}` (or `:b_done` for the last block).
  * `:b_done` — `UnconditionalEntry(:b_done, [:n{n}, :steps{n}])` →
    empty body → `EndInstruction(:countdown, [:steps{n}])`.

Total blocks: `n + 2` (entry + n decrement + done). For n=0 the chain
degenerates to `:b_start` → `:b_done` directly.
"""
function build_countdown_vm(n::Int)
    n >= 0 || error("build_countdown_vm: n must be non-negative, got $n")
    blocks = BennettVM.BasicBlock[]

    # Entry block. For n == 0, exit directly to :b_done (skipping the
    # nonexistent :b_step1). For n >= 1, exit to :b_step1.
    first_exit_label = n == 0 ? :b_done : :b_step1
    push!(blocks, BennettVM.BasicBlock(
        :b_start,
        BennettVM.BeginInstruction(:countdown, [:n0, :steps0]),
        BennettVM.Instruction[],
        BennettVM.UnconditionalExit(first_exit_label, [:n0, :steps0]),
    ))

    # n decrement blocks, labelled :b_step1 ... :b_step{n}. Block i
    # reads :n{i-1}, :steps{i-1} and produces :n{i}, :steps{i}, then
    # exits to :b_step{i+1} (or :b_done at the end of the chain).
    for i in 1:n
        next_label = i < n ? Symbol("b_step", i+1) : :b_done
        push!(blocks, _decrement_block(
            Symbol("b_step", i),
            Symbol("n", i-1), Symbol("steps", i-1),
            Symbol("n", i),   Symbol("steps", i),
            next_label,
        ))
    end

    # Done block. Its UnconditionalEntry params MUST match whatever the
    # last sender's args were: for n >= 1 that's :n{n}, :steps{n}; for
    # n == 0 that's :n0, :steps0 (the entry block exits to :b_done
    # directly carrying its inputs).
    done_params = [Symbol("n", n), Symbol("steps", n)]
    push!(blocks, BennettVM.BasicBlock(
        :b_done,
        BennettVM.UnconditionalEntry(:b_done, done_params),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:countdown, [Symbol("steps", n)]),
    ))

    return VMProgram(blocks, BennettVM.LabelTable(blocks), :b_start,
                     [64, 64], [64])
end

# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------

@testset "countdown(3) forward integration (M3.8)" begin
    vm = build_countdown_vm(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    run!(rs, vm)
    @test is_halted(rs)
    @test result(rs)[Symbol("steps", 3)] == countdown_ref(Int64(3))
    @test result(rs)[Symbol("steps", 3)] == 3
end

@testset "countdown(5) forward integration (M3.8)" begin
    vm = build_countdown_vm(5)
    rs = initial_state(vm, Dict(:n0 => Int64(5), :steps0 => Int64(0)))
    run!(rs, vm)
    @test is_halted(rs)
    @test result(rs)[Symbol("steps", 5)] == countdown_ref(Int64(5))
end

@testset "countdown(0) — degenerate empty loop (M3.8)" begin
    # n == 0: no decrement blocks. The entry block exits directly to
    # :b_done carrying :n0, :steps0; the done block's
    # UnconditionalEntry params are [:n0, :steps0] (matching). No
    # ArithmeticAssignment fires. This pins the empty-chain edge case.
    vm = build_countdown_vm(0)
    rs = initial_state(vm, Dict(:n0 => Int64(0), :steps0 => Int64(0)))
    run!(rs, vm)
    @test is_halted(rs)
    @test result(rs)[Symbol("steps", 0)] == countdown_ref(Int64(0))
    @test result(rs)[Symbol("steps", 0)] == 0
end

@testset "countdown(7) — pc trajectory pinning (M3.8)" begin
    # Run countdown(7); verify the total flat-stream instruction count
    # matches the expected layout. This is the regression-anchor
    # assertion: any future change to BasicBlock's flat-stream
    # contribution (currently 2 + length(body) per block) will fail
    # here loudly, where a pure result-check would not.
    vm = build_countdown_vm(7)
    expected_instructions =
        2 +                # b_start: Begin + UnconditionalExit
        7 * 4 +            # 7 decrement blocks × (Entry + 2 × Arith + Exit)
        2                  # b_done: UnconditionalEntry + End
    @test BennettVM.n_instructions(vm) == expected_instructions
    rs = initial_state(vm, Dict(:n0 => Int64(7), :steps0 => Int64(0)))
    run!(rs, vm)
    @test is_halted(rs)
    @test result(rs)[Symbol("steps", 7)] == 7
end
