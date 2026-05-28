# test/test_matrix_sum_forward.jl — SC9 Case C forward gate
# (`bennettvm-k7b`, ADR 0010 / ADR 0012).
#
# # What this test pins
#
# The real `lower_vm` ingest (ADR 0012 §D1–D5) applied to a *nested*
# loop: a Bennett.jl `ParsedIR` for `matrix_sum_while(::Int8)` lowered to
# a runnable `VMProgram` whose FORWARD `run!` reproduces the irreversible
# Julia oracle bit-for-bit (Rule 4 — known-correct value, not "didn't
# throw"; PRD v4 §3.14 golden-master co-location). `matrix_sum_while` is
# PRD v4 §3.6.2 Case C — the doubly-nested counting loop the circuit
# backend cannot represent — and a load-bearing SC9 motivating case.
#
# This is the *nested-loop* analogue of `test_collatz_forward.jl` (single
# loop, Case D). The critical finding (ADR 0010): the EXISTING ingest
# lowers the 5-block nested-loop CFG to a 12-block VMProgram and runs it
# forward matching the oracle with ZERO changes to `src/` — confirming
# bead `bennettvm-720` ("ingest multi-level BasicBlock") is satisfied by
# the existing pass. The headline value is `matrix_sum_while(Int8(3)) ==
# 9`.
#
# # Why these inputs (Rule 4 — sufficient known-correct values)
#
# Per the ADR 0012 R1 width caveat, `IState.locals` are `Int64` but the
# oracle is i8; the lowering does not mask to width, so agreement holds
# only for inputs whose accumulator `n*n` stays in i8 range (`n <= 11`).
# n ∈ {1,2,3,4,5} all satisfy that (peak result 25) and walk the
# nested-loop CFG with growing trip counts:
#
#   * n=1 — outer loop runs once, inner loop runs once: 1 increment.
#           Pins the minimal both-loops-entered path.
#   * n=2 — outer×2, inner×2 each: 4 increments. First multi-iteration
#           of BOTH loops; exercises the inner-loop back-edge and the
#           outer-loop back-edge re-priming the inner counter `j=1`.
#   * n=3 — the headline (`matrix_sum_while(Int8(3)) == 9`).
#   * n=4 / n=5 — longer trip counts (16, 25); guard against an
#           off-by-one in the loop-carried φ of either counter.
#
# # Ref
#
#   * docs/adr/0010-nested-loops.md — the while-form finding (Case C).
#   * docs/adr/0012-collatz-lowering.md — the lowering design the
#     existing ingest realises (§D1–D5).
#   * test/reference/matrix_sum.jl — the oracles + `matrix_sum_vm`.
#   * test/test_collatz_forward.jl — the single-loop (Case D) analogue.
#   * bennettvm_prd.md (PRD v4) §3.6.2 Case C, §3.14, §6 SC9, P0.5.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known-correct values).

using Test
using BennettVM

include(joinpath(@__DIR__, "reference", "matrix_sum.jl"))

# The single formal parameter's SSA name (the i8 argument's input key).
const _MATSUM_RESULT_KEY_ARG = Symbol("n::Int8")

# The lowered EndInstruction return operand — the routine result in
# `result(rs)`. Determined empirically: it is the unique key whose value
# equals the oracle across all of n ∈ {2,3,4,5} (n=1 has several
# coincidental matches; only `value_phi1.lcssa` matches everywhere).
const _MATSUM_RESULT_KEY = Symbol("value_phi1.lcssa")

@testset "SC9 Case C — matrix_sum (nested loop) forward gate" begin
    vm = matrix_sum_vm()

    # (a) Structural sanity on the lowered program. Five original blocks
    #     of the nested-loop CFG —
    #       top              (function entry / outer-loop pre-test)
    #       L7.preheader     (inner-loop preheader: primes j=1)
    #       L11              (inner-loop body: s+=1, j+=1, inner back-test)
    #       L7.L14_crit_edge (inner-loop exit → outer back-edge: i+=1)
    #       L16              (function exit / lcssa join)
    #     + seven critical-edge trampolines = twelve blocks. Pins the
    #     edge-split count so a future regression in trampoline synthesis
    #     goes RED here, not silently mid-run.
    @test vm isa VMProgram
    @test length(vm.blocks) == 12
    @test vm.entry_label === :top
    @test vm.arg_widths == [8]
    @test vm.return_widths == [8]
    block_labels = Set(b.label for b in vm.blocks)
    # The five original nested-loop CFG blocks.
    @test :top in block_labels
    @test Symbol("L7.preheader") in block_labels   # inner-loop preheader
    @test :L11 in block_labels                       # inner-loop body
    @test Symbol("L7.L14_crit_edge") in block_labels # inner-exit / outer back-edge
    @test :L16 in block_labels                       # function exit

    # (b) Forward golden-master agreement on five in-range inputs. Each
    #     must equal the closed-form oracle exactly.
    for n in (1, 2, 3, 4, 5)
        rs = initial_state(vm, Dict(_MATSUM_RESULT_KEY_ARG => Int64(n)))
        run!(rs, vm; max_steps = 100_000, checkpoint_interval = 8)
        @test is_halted(rs)
        got = result(rs)[_MATSUM_RESULT_KEY]
        @test got == matrix_sum_ref(Int8(n))          # closed-form oracle
        @test got == Int64(matrix_sum_while(Int8(n)))  # nested-loop oracle
    end

    # Pin the exact known-correct values (Rule 4 — explicit constants):
    # n=1 → 1, n=3 → 9 (the headline), n=5 → 25.
    let rs = initial_state(vm, Dict(_MATSUM_RESULT_KEY_ARG => Int64(1)))
        run!(rs, vm; max_steps = 100_000)
        @test result(rs)[_MATSUM_RESULT_KEY] == 1
    end
    let rs = initial_state(vm, Dict(_MATSUM_RESULT_KEY_ARG => Int64(3)))
        run!(rs, vm; max_steps = 100_000)
        @test result(rs)[_MATSUM_RESULT_KEY] == 9      # SC9 Case C headline
    end
    let rs = initial_state(vm, Dict(_MATSUM_RESULT_KEY_ARG => Int64(5)))
        run!(rs, vm; max_steps = 100_000)
        @test result(rs)[_MATSUM_RESULT_KEY] == 25
    end
end
