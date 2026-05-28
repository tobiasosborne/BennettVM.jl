# test/test_matrix_sum_roundtrip.jl — SC9 Case C (nested loops) round-trip
# acceptance gate (`bennettvm-k7b`, ADR 0010 / ADR 0012).
#
# # What this gate is, and why it is the case's reason to exist
#
# `matrix_sum_while(::Int8)` (PRD v4 §3.6.2 Case C) is the doubly-nested
# counting loop the *circuit* backend cannot represent — a loop NEST
# whose total trip count (`n*n`) is statically unknown. It is a
# load-bearing SC9 motivating case (PRD v4 §6): the VM backend closes the
# gap the circuit target leaves open for nested control flow.
# `test_matrix_sum_forward.jl` pinned that the lowered VMProgram runs
# FORWARD matching the irreversible oracle bit-for-bit; THIS file is the
# finer-grained *round-trip* gate, proving the nested loop reverses to
# empty history across multiple inputs at the per-step granularity the
# aggregate run cannot reach (`spike/RETROSPECTIVE.md` Q4).
#
# # Nested-loop reversal is the whole point (vs. collatz's single loop)
#
# Collatz (Case D, `test_collatz_roundtrip.jl`) reverses a SINGLE `while`
# loop. Case C reverses a `while` NEST: the inner loop runs `n` times for
# each of the `n` outer iterations, and the outer back-edge RE-PRIMES the
# inner counter `j=1` on every pass. The reversal therefore has to unwind
# the inner loop's history independently within each outer iteration —
# exactly what bead `bennettvm-of5` ("independent per-inner-loop history")
# asks for. Under L3 checkpoint-replay this is AUTOMATIC (same as
# collatz): periodic full snapshots capture every overwritten temporary,
# so `unstep!`'s L3 path (`src/history/Replay.jl`) restores the nearest
# `CheckpointEntry` and replays forward — it never needs a per-loop
# history layer because the trace tape (the snapshots) records the inner
# counter's value at each checkpoint regardless of how many times the
# outer loop re-primed it. The aggregate run!/unrun! reversing the FULL
# nested run therefore inherently exercises BOTH the inner- and
# outer-loop history under one mechanism — see testset (2)'s explicit
# nested-history assertion.
#
# # Why matrix_sum reverses via L3 checkpoint-replay ONLY (the crux)
#
# Identical to collatz (ADR 0012 §"cross-iteration reversibility crux").
# The lowered program's value instructions are `Define` /
# `SelectInstruction`, both `is_injective == false`; their per-instruction
# `inverse()` is DEFERRED (ADR 0012 R3) because the loop nest's SSA
# temporaries are redefined every iteration — overwriting a value without
# a record is irreversible, and the chosen recovery is the Bennett-1973
# trace tape realised as the existing L3 checkpoint-replay layer. Two
# consequences shape every assertion below:
#
#   1. The round-trip gate drives `per_step_inverse_check` in L3 mode: a
#      finite `checkpoint_interval` and an EMPTY `must_cache_set` (the
#      default). With the must-cache set empty, M7.6's L2-push gate never
#      fires, so no `DeltaEntry` lands on `rs.history`; every backward step
#      falls through to L3 forward-replay — the only path that reverses
#      this program.
#
#   2. The L2 path is the EXPECTED boundary, not a bug: driving the
#      scaffold with `must_cache_set = compute_must_cache(vm)` selects the
#      non-injective `Define` body slots, and the forward sweep reaches
#      `make_delta(::Define, …)`, which raises. Testset (4) PINS that
#      raise so the L3-only reversal contract is an executable assertion.
#
# # What the L3 gate catches — and what it does NOT (Rule 5)
#
# L3 reversal is forward-replay. As long as the forward semantics are
# DETERMINISTIC, the backward walk replays the same forward and the
# round-trip closes EVEN IF the forward semantics are wrong. So the
# per-step / round-trip invariant alone does NOT catch a forward-semantic
# bug — that is why testset (2) anchors the round-trip to a CORRECT
# forward run via the oracle (Rule 4). Mutation-proof evidence (performed
# manually, then reverted; NOT left in the tree):
#
#   * ORACLE mutation — changing `matrix_sum_ref` from `n*n` to `n*n + 1`:
#     the oracle table self-check (testset 0) and the oracle-anchored
#     forward assertion in testset (2) went RED immediately
#     (`@test result(rs)[KEY] == c.oracle` failed: VM produced 9, mutated
#     oracle wanted 10 for n=3). This pins that the gate is anchored to a
#     known-correct value, not just self-consistent (Rule 4 / Rule 5).
#     Reverted; `git diff test/reference/matrix_sum.jl` clean.
#
# The reversal-bug class (eliding the L3 restore deepcopy at
# `src/history/Replay.jl`) is mutation-proofed once, generically, by the
# collatz gate and the M8 property suite; this gate inherits that coverage
# (the per_step_inverse_check scaffold is shared). The oracle mutation is
# the Case-C-specific RED evidence required by the brief.
#
# # Why these six inputs (Rule 4 — trajectory-verified)
#
# Per the width caveat, agreement holds only while `n*n <= 127`
# (`n <= 11`). Each input below was REPL-traced (oracle value, forward
# dispatch count) before being hardcoded:
#
#   n | oracle (n*n) | fwd dispatches | path exercised
#   --+--------------+----------------+--------------------------------------
#   1 |      1       |       19       | outer×1, inner×1 — minimal both-loops
#   2 |      4       |       41       | outer×2, inner×2 — first multi-iter both
#   3 |      9       |       73       | THE headline (matrix_sum_while(3) == 9)
#   4 |     16       |      115       | outer×4 — longer; off-by-one φ guard
#   5 |     25       |      167       | outer×5 — longest standard input
#   6 |     36       |      229       | outer×6 — deepest nest exercised here
#
# n=1 pins the minimal both-loops-entered path; n=2 is the first input
# where BOTH loops iterate more than once (so the inner back-edge AND the
# outer re-prime of `j=1` both fire); n=3 is the headline; n=4/5/6 grow
# the outer trip count to guard the loop-carried φ of both counters. All
# six were confirmed `vm_result == oracle` and round-trip-clean in a REPL
# probe.
#
# # Ref
#
#   * docs/adr/0010-nested-loops.md — the while-form finding (Case C).
#   * docs/adr/0012-collatz-lowering.md §"cross-iteration reversibility
#     crux", §D1/§D3 (deferred `inverse`), R3 (L3-only).
#   * test/reference/matrix_sum.jl — oracles + `matrix_sum_vm`.
#   * test/test_per_step_inverse.jl — the `per_step_inverse_check`
#     scaffold (M8.2, `bennettvm-3d8`) this gate consumes.
#   * test/test_collatz_roundtrip.jl — the single-loop (Case D) analogue
#     this gate mirrors.
#   * test/test_matrix_sum_forward.jl — the forward gate this broadens.
#   * bennettvm_prd.md (PRD v4) §3.6.2 Case C, §3.13 (per-step inverse),
#     §3.14 (golden-master), §6 SC9; P0.6 (round-trip is load-bearing).
#   * bd `bennettvm-720` (ingest multi-level BasicBlock),
#     `bennettvm-of5` (independent per-inner-loop history) — both
#     satisfied by the existing ingest + L3 layer (this gate is the
#     evidence).
#   * CLAUDE.md Rule 1 (fail loud), Rule 2 (deep bugs), Rule 4
#     (known-correct values), Rule 5 (mutation-proof), Rule 11 (literate).

using Test
using BennettVM

include(joinpath(@__DIR__, "reference", "matrix_sum.jl"))
include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# The six trajectory-verified inputs paired with their oracle values
# (the docstring table). Pinned as a constant so testsets (0)/(1)/(2)/(3)
# share one fixture; a future input change is a single-site edit.
const _MATSUM_RT_INPUTS = (
    (n = Int64(1), oracle = Int64(1)),
    (n = Int64(2), oracle = Int64(4)),
    (n = Int64(3), oracle = Int64(9)),
    (n = Int64(4), oracle = Int64(16)),
    (n = Int64(5), oracle = Int64(25)),
    (n = Int64(6), oracle = Int64(36)),
)

# The single formal parameter's SSA name (the i8 argument's input key).
const _MATSUM_RT_KEY_ARG = Symbol("n::Int8")

# The lowered EndInstruction return operand — the routine result.
const _MATSUM_RT_RESULT_KEY = Symbol("value_phi1.lcssa")

@testset "SC9 Case C — matrix_sum round-trip (nested loops)" begin
    vm = matrix_sum_vm()

    # (0) Pre-pin the oracle table itself against BOTH references, before
    #     any VM assertion can blame the lowering for an oracle bug
    #     (Rule 2: diagnose the real root cause). Each input's hardcoded
    #     oracle must equal both the nested `while` and the closed form.
    @testset "oracle table self-check (Int8 fixture is sound)" begin
        for c in _MATSUM_RT_INPUTS
            @test Int64(matrix_sum_while(Int8(c.n))) == c.oracle
            @test matrix_sum_ref(Int8(c.n)) == c.oracle
        end
    end

    # ------------------------------------------------------------------
    # (1) Per-step inverse (L3) — the finer-grained load-bearing gate.
    # ------------------------------------------------------------------
    # `per_step_inverse_check` forward-sweeps capturing a deepcopy after
    # each `step!`, then walks back via `unstep!` asserting `IState`
    # equality at EVERY step. A mid-NEST reversal bug (e.g. failing to
    # restore the inner counter `j` across an outer re-prime) therefore
    # surfaces as a specific step-indexed MISMATCH, not a masked aggregate
    # pass. Driven in L3 mode (empty `must_cache_set`) at two checkpoint
    # densities — K=1 (push every step) and K=4 (sparse multi-step
    # replay). Each call returns `nothing` on success (raises on any
    # per-step divergence), so `=== nothing` is the known-correct pin.
    @testset "per-step inverse (L3, empty must_cache)" begin
        for c in _MATSUM_RT_INPUTS
            for K in (1, 4)
                @test per_step_inverse_check(
                    vm, Dict(_MATSUM_RT_KEY_ARG => c.n);
                    checkpoint_interval = K,
                    label = "SC9-C/matrix_sum/n=$(c.n)/K=$K") === nothing
            end
        end
    end

    # ------------------------------------------------------------------
    # (2) Aggregate run!/unrun! anchored to the oracle (P0.6).
    # ------------------------------------------------------------------
    # For each input: snapshot the initial state, `run!` to halt, ASSERT
    # the forward result equals the oracle (anchoring the round-trip to a
    # CORRECT forward run — without it a forward-semantic regression slips
    # past a pure round-trip; see the mutation-proof §), then `unrun!` and
    # assert the full P0.6 exit invariant. Reversing the FULL nested run
    # is precisely what unwinds BOTH the inner- and outer-loop history
    # under the one L3 mechanism (bead `bennettvm-of5`): the forward
    # dispatch count grows quadratically in n (19→229 for n=1..6), so the
    # backward walk has to replay every inner-loop iteration nested inside
    # every outer-loop iteration. We pin `step_count` grows with the nest
    # depth so a regression that flattened the nest (e.g. folding to a
    # single loop) goes RED here, and pin `rs.initial` did not drift.
    @testset "aggregate run!/unrun! (oracle-anchored, P0.6)" begin
        for c in _MATSUM_RT_INPUTS
            rs = initial_state(vm, Dict(_MATSUM_RT_KEY_ARG => c.n))
            initial_snap = deepcopy(rs.initial)

            run!(rs, vm; max_steps = 100_000, checkpoint_interval = 8)
            @test is_halted(rs)
            @test rs.step_count > 0
            # The nest dispatches more steps than a single loop would for
            # the same accumulator: > n*n forward dispatches confirms both
            # loops actually iterate (bennettvm-of5 nested-history witness).
            @test rs.step_count > c.oracle
            # Anchor: forward result is bit-for-bit the irreversible oracle.
            @test result(rs)[_MATSUM_RT_RESULT_KEY] == c.oracle

            unrun!(rs, vm)
            @test rs.current == rs.initial          # P0.6 — reversed to start
            @test isempty(rs.history)               # P0.6 — history drained
            @test rs.step_count == 0                # P0.6 — step counter reset
            @test rs.initial == initial_snap        # rs.initial never mutated
        end
    end

    # ------------------------------------------------------------------
    # (3) THE SC9 Case C headline assertion.
    # ------------------------------------------------------------------
    # The case's reason to exist, as one clearly-named claim:
    # `matrix_sum_while` (PRD v4 §3.6.2 Case C — the nested loop the
    # circuit backend CANNOT represent) compiles under the VM backend,
    # runs to halt matching the irreversible oracle (== 9 for n=3), AND
    # round-trips to empty history. n=3 at a sparse checkpoint_interval so
    # the L3 multi-step replay carries the full nested-loop reversal.
    @testset "SC9 Case C: nested loop compiles, runs to 9, round-trips" begin
        n3 = Int64(3)
        rs = initial_state(vm, Dict(_MATSUM_RT_KEY_ARG => n3))

        # Compiles under target=:vm (the lowered VMProgram exists & dispatches).
        @test rs.current isa BennettVM.IState

        # Runs to halt matching the oracle (the nested loop terminates).
        run!(rs, vm; max_steps = 100_000, checkpoint_interval = 8)
        @test is_halted(rs)
        @test result(rs)[_MATSUM_RT_RESULT_KEY] == Int64(matrix_sum_while(Int8(3)))
        @test result(rs)[_MATSUM_RT_RESULT_KEY] == 9          # explicit constant

        # Round-trips to empty history (BOTH loops reverse — P0.6). The
        # forward dispatch count (73 for n=3) far exceeds the 9 inner
        # increments — the surplus is the nested control-flow plumbing the
        # backward L3 replay must unwind in nested order.
        forward_dispatches = rs.step_count
        @test forward_dispatches > 9    # more VM dispatches than n*n increments
        unrun!(rs, vm)
        @test rs.current == rs.initial
        @test isempty(rs.history)
        @test rs.step_count == 0
    end

    # ------------------------------------------------------------------
    # (4) L2-raises boundary — documents the L3-ONLY reversal contract.
    # ------------------------------------------------------------------
    # Driving the scaffold with `must_cache_set = compute_must_cache(vm)`
    # selects matrix_sum's non-injective `Define` body slots for the L2
    # delta-history path. The forward sweep then reaches
    # `make_delta(::Define, …)`, which RAISES — `Define`'s L1/L2 inverse
    # is deferred (ADR 0012 R3); reversal is L3-only. Pinning this raise
    # turns the L3-only contract into an executable assertion (Rule 1)
    # rather than prose. The error names `Define` and the `make_delta`
    # site, so a future regression that silently added an L2 path for
    # `Define` would change the message and fail the `occursin` pins.
    @testset "L2 mode raises (Define inverse deferred → L3-only)" begin
        set = BennettVM.compute_must_cache(vm)
        @test !isempty(set)   # liveness selects matrix_sum's non-injective slots

        err = try
            per_step_inverse_check(
                vm, Dict(_MATSUM_RT_KEY_ARG => Int64(3));
                checkpoint_interval = typemax(Int),  # suppress L3 entirely
                must_cache_set = set,
                label = "SC9-C/matrix_sum/L2-boundary")
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("make_delta", err.msg)   # the L2 push site
        @test occursin("Define", err.msg)        # the deferred non-inj kind
    end
end
