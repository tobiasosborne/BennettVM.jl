# test/test_collatz_forward.jl — M_UNBOUNDED.1 forward + round-trip-smoke
# gate (`bennettvm-c39`, ADR 0012).
#
# # What this test pins
#
# The real `lower_vm` ingest (ADR 0012 §D1–D5): a Bennett.jl `ParsedIR`
# for `collatz_steps(::Int8)` lowered to a runnable `VMProgram` whose
# FORWARD `run!` reproduces the irreversible Julia oracle bit-for-bit
# (Rule 4 — known-correct value, not "didn't throw"; PRD v4 §3.14
# golden-master co-location). `collatz_steps` is PRD v4 §3.6.2 Case D —
# the unbounded `while` the circuit backend cannot compile — and the
# load-bearing SC9 motivating case.
#
# # Why these three inputs (Rule 4 — sufficient known-correct values)
#
# Per ADR 0012 R1, `IState.locals` are `Int64` but collatz is i8; the
# lowering does not mask to width, so oracle agreement holds only for
# inputs whose trajectory stays in i8 range. The chosen inputs all
# satisfy that AND exercise distinct control-flow paths:
#
#   * x=1  — the loop is NEVER entered (`val > 1` false at the top), so
#            the `top → L46` edge fires and the result is the `Const(0)`
#            φ-incoming. Pins the synthetic-constant materialisation
#            (§D5) and the loop-not-taken path.
#   * x=7  — 16 steps, terminates via `val < 2` (well under the 20-step
#            cap). Trajectory peaks at 52 (in i8 range). Pins the loop
#            body: both `select` arms (even-halve / odd-3x+1), the φ
#            back-edge rename, and the L3 checkpoint-replay loop.
#   * x=9  — 19 steps, also terminates via `val < 2` (one below the cap).
#            A second, longer non-overflowing trajectory; guards against
#            an off-by-one in the loop-carried `steps` φ.
#
# # Round-trip smoke (NOT the full M_UNBOUNDED.3 gate)
#
# After a forward `run!`, a single `unrun!` must drive the RState back to
# its initial state (`rs.current == rs.initial`) with an empty history
# (`isempty(rs.history)`) — confirming the L3 checkpoint-replay layer
# (ADR 0012 "cross-iteration crux") reverses the loop despite the
# per-iteration SSA-name reuse. The full per-step-inverse / property
# round-trip gate is the separate M_UNBOUNDED.3 bead (`bennettvm-hvx`);
# this smoke only asserts the structural exit invariant.
#
# # Ref
#
#   * docs/adr/0012-collatz-lowering.md — the lowering design (§D1–D5)
#     and §"The cross-iteration reversibility crux" (L3 trace-tape).
#   * test/reference/collatz.jl — the oracle + `collatz_vm` factory.
#   * bennettvm_prd.md (PRD v4) §3.6.2 Case D, §3.14, §6 SC9, P0.6.
#   * CLAUDE.md Rule 1 (fail loud), Rule 2 (deep bugs), Rule 4
#     (known-correct values).

using Test
using BennettVM

include(joinpath("reference", "collatz.jl"))

@testset "M_UNBOUNDED.1 — collatz forward + round-trip smoke" begin
    vm = collatz_vm()

    # (a) Structural sanity on the lowered program. Three original blocks
    #     (top, L8, L46) + four critical-edge trampolines
    #     (top→L46, top→L8, L8→L46, L8→L8) = seven blocks. Pins the
    #     edge-split count so a future regression in trampoline synthesis
    #     goes RED here, not silently mid-run.
    @test vm isa VMProgram
    @test length(vm.blocks) == 7
    @test vm.entry_label === :top
    @test vm.arg_widths == [8]
    @test vm.return_widths == [8]
    block_labels = Set(b.label for b in vm.blocks)
    @test :top in block_labels
    @test :L8 in block_labels
    @test :L46 in block_labels
    # The four critical-edge trampolines, by their `:e_<src>_<dst>`
    # synthesised labels (ADR 0012 §2 critical-edge splitting). The
    # last is the self back-edge `L8 → L8`.
    @test Symbol("e_top_L46") in block_labels
    @test Symbol("e_top_L8") in block_labels
    @test Symbol("e_L8_L46") in block_labels
    @test Symbol("e_L8_L8") in block_labels

    # (b) Forward golden-master agreement on three non-overflowing inputs.
    #     `result[:value_phi1.lcssa]` is the lowered IRRet operand (the
    #     routine result). Each must equal the i8 oracle exactly.
    for x in (Int64(1), Int64(7), Int64(9))
        rs = initial_state(vm, Dict(Symbol("x::Int8") => x))
        run!(rs, vm; max_steps=10_000)
        @test is_halted(rs)
        got = result(rs)[Symbol("value_phi1.lcssa")]
        want = Int64(collatz_steps(Int8(x)))
        @test got == want
    end

    # Pin the exact known-correct values (Rule 4 — explicit constants,
    # not just "agrees with oracle"): x=1 → 0 (loop not entered),
    # x=7 → 16, x=9 → 19.
    let rs = initial_state(vm, Dict(Symbol("x::Int8") => Int64(1)))
        run!(rs, vm; max_steps=10_000)
        @test result(rs)[Symbol("value_phi1.lcssa")] == 0
    end
    let rs = initial_state(vm, Dict(Symbol("x::Int8") => Int64(7)))
        run!(rs, vm; max_steps=10_000)
        @test result(rs)[Symbol("value_phi1.lcssa")] == 16
    end
    let rs = initial_state(vm, Dict(Symbol("x::Int8") => Int64(9)))
        run!(rs, vm; max_steps=10_000)
        @test result(rs)[Symbol("value_phi1.lcssa")] == 19
    end

    # (c) Round-trip smoke (x=7): forward to halt, then a single unrun!
    #     drives back to the initial state with empty history. Confirms
    #     L3 checkpoint-replay reverses the loop (ADR 0012 crux). A
    #     modest checkpoint_interval=8 exercises multiple L3 snapshots
    #     across the 198 forward dispatches.
    let rs = initial_state(vm, Dict(Symbol("x::Int8") => Int64(7)))
        run!(rs, vm; max_steps=10_000, checkpoint_interval=8)
        @test is_halted(rs)
        steps_taken = rs.step_count
        @test steps_taken > 0
        unrun!(rs, vm)
        @test rs.current == rs.initial
        @test isempty(rs.history)
        @test rs.step_count == 0
    end
end
