# test/test_forward_interpreter.jl — M3.8 capstone integration test
# (bd `bennettvm-mqh`).
#
# This is the first end-to-end test that exercises the full M3 forward
# interpreter on a multi-block program: `countdown(N)`, built as N
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
# The factory `countdown_program` (in `test/reference/countdown.jl`,
# co-located with the `countdown_ref` oracle per PRD v4 §3.14) holds
# every block label, every SSA name, and every cross-block edge fixed
# and inspectable in one place — exactly the regression-anchor shape
# Rule 4 demands.
#
# Ref:
#   * CLAUDE.md Rule 4 — every test asserts a known-correct value.
#   * CLAUDE.md Phase-0 P0.5 — golden-master required (countdown_ref).
#   * PRD v4 §3.6.2 — countdown family of motivating cases.
#   * PRD v4 §3.14 — golden-master co-location; the rule that puts
#     `countdown_program` next to `countdown_ref` in
#     `test/reference/countdown.jl` (M8.1 / bd `bennettvm-do7`).
#   * bd `bennettvm-mqh` (M3.8) — this milestone.
#   * src/interpreter/Interpreter.jl §M3.6 — the cross-block dispatch
#     layer this test exercises end-to-end.

using Test
using BennettVM

include(joinpath(@__DIR__, "reference", "countdown.jl"))

# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------

@testset "countdown(3) forward integration (M3.8)" begin
    vm = countdown_program(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    run!(rs, vm)
    @test is_halted(rs)
    @test result(rs)[Symbol("steps", 3)] == countdown_ref(Int64(3))
    @test result(rs)[Symbol("steps", 3)] == 3
end

@testset "countdown(5) forward integration (M3.8)" begin
    vm = countdown_program(5)
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
    vm = countdown_program(0)
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
    vm = countdown_program(7)
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
