# test/test_matrix_tri_roundtrip.jl — TRIANGULAR nested-loop round-trip
# acceptance gate (bead `bennettvm-e4l`, the IRCast end-to-end gate of
# `bennettvm-hek`; ADR 0012 / ADR 0013).
#
# # What this gate is, and why it is the case's reason to exist
#
# `matrix_tri_while(::Int8)` is a doubly-nested `while` whose INNER trip
# count VARIES with the outer index (`j` counts DOWN from `i`), computing
# the triangular sum `sum_{i=1}^{n} i(i+1)/2`. It is the program that
# surfaced the within-edge synthetic-constant φ-name collision (bead
# `bennettvm-e4l`): its `top → L7.preheader` edge sends the SAME constant
# from `top` into two distinct φ-param slots (value 0 → `indvars.iv14` AND
# `value_phi18`; value 1 → `indvars.iv10` AND `value_phi7`). The pre-fix
# ingest deduped synthetic constant names by VALUE within a predecessor,
# so the edge's arg list repeated a name and `UnconditionalExit`'s
# `allunique(args)` check (correctly) rejected the lowering. THIS file is
# the end-to-end witness that the fix (cross-edge sharing + within-edge
# fresh counter-based creates, `src/ir/ingest.jl`, ADR 0012 §D5) lets the
# triangular nest lower, run forward matching the oracle, AND round-trip.
# matrix_tri also exercises the IRCast lowering (`bennettvm-hek`): without
# `CastInstruction` the program does not lower at all.
#
# # Triangular reversal is the whole point (vs. matrix_sum's rectangle)
#
# matrix_sum (`test_matrix_sum_roundtrip.jl`) reverses a RECTANGULAR nest:
# the inner loop runs a fixed `n` times for each of `n` outer iterations.
# matrix_tri reverses a NON-RECTANGULAR (triangular) nest: the inner loop
# runs `i` times on outer iteration `i`, and the outer back-edge RE-PRIMES
# the inner counter `j=i` (a different value each pass, NOT a constant) on
# every outer step. The reversal therefore has to unwind a variable-length
# inner loop's history independently within each outer iteration. Under L3
# checkpoint-replay this is AUTOMATIC (same mechanism as matrix_sum /
# collatz): periodic full snapshots capture every overwritten temporary,
# so `unstep!`'s L3 path (`src/history/Replay.jl`) restores the nearest
# `CheckpointEntry` and replays forward — it never needs a per-loop history
# layer because the trace tape (the snapshots) records the inner counter's
# value at each checkpoint regardless of how the outer loop re-primed it.
# The aggregate run!/unrun! reversing the FULL triangular run therefore
# inherently exercises BOTH the inner- and outer-loop history under one
# mechanism.
#
# # Why matrix_tri reverses via L3 checkpoint-replay ONLY (the crux)
#
# Identical to matrix_sum / collatz (ADR 0012 §"cross-iteration
# reversibility crux"). The lowered program's value instructions are
# `Define` / `SelectInstruction` / `CastInstruction`, all
# `is_injective == false`; their per-instruction `inverse()` is DEFERRED
# (ADR 0012 R3 / ADR 0013) because the loop nest's SSA temporaries are
# redefined every iteration — overwriting a value without a record is
# irreversible, and the chosen recovery is the Bennett-1973 trace tape
# realised as the existing L3 checkpoint-replay layer. Two consequences
# shape every assertion below:
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
#      non-injective body slots, and the forward sweep reaches
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
#   * e4l FIX mutation — WITHOUT the within-edge-uniqueness fix the program
#     does not lower at all: `lower_vm` raises at the `UnconditionalExit`
#     constructor ("duplicate arg names in [:_phi_const_top_0,
#     …, :_phi_const_top_0, :_phi_const_top_1]"), so EVERY testset below
#     goes RED at `matrix_tri_vm()` (the factory raises before any
#     assertion runs). WITH the fix the duplicate is gone (the trampoline
#     args carry `:_phi_const_top_0_dup1` / `:_phi_const_top_1_dup2` for
#     the repeat slots) and the suite is GREEN.
#
#   * ORACLE mutation — perturbing `matrix_tri_ref` from
#     `sum i(i+1)÷2` to `… + 1`: the oracle table self-check (testset 0)
#     and the oracle-anchored forward assertion in testset (2) go RED
#     immediately (`@test result(rs)[KEY] == c.oracle` fails: VM produced
#     10, mutated oracle wanted 11 for n=3). This pins that the gate is
#     anchored to a known-correct value, not just self-consistent.
#     Reverted; `git diff test/reference/matrix_tri.jl` clean.
#
# The reversal-bug class (eliding the L3 restore deepcopy at
# `src/history/Replay.jl`) is mutation-proofed once, generically, by the
# collatz / matrix_sum gates and the M8 property suite; this gate inherits
# that coverage (the per_step_inverse_check scaffold is shared). The e4l
# and oracle mutations are the matrix_tri-specific RED evidence.
#
# # Why these inputs (Rule 4 — trajectory-verified)
#
# Per the width caveat, agreement holds only while the result `<= 127`
# (`n <= 8`). Each input below was REPL-traced (oracle value, forward
# dispatch count) before being hardcoded:
#
#   n | oracle (tri-sum) | fwd dispatches | path exercised
#   --+------------------+----------------+-------------------------------------
#   1 |        1         |       31       | outer×1, inner×1 — minimal both-loops
#   2 |        4         |       51       | outer×2 — first multi-iter both
#   3 |       10         |       71       | THE headline (matrix_tri_while(3)==10)
#   4 |       20         |       91       | outer×4 — longer; varying inner length
#   5 |       35         |      111       | outer×5 — longest standard input
#   6 |       56         |      131       | outer×6 — deeper nest
#   7 |       84         |      151       | outer×7 — near the i8 ceiling
#   8 |      120         |      171       | outer×8 — the largest i8-safe input
#
# n=1 pins the minimal both-loops-entered path; n=2 is the first input
# where BOTH loops iterate more than once; n=3 is the headline; n=4..8
# grow the outer trip count to guard the loop-carried φ of both counters
# with a VARYING inner length (the triangular distinction). All eight were
# confirmed `vm_result == oracle` and round-trip-clean in a REPL probe.
#
# # Ref
#
#   * docs/adr/0012-collatz-lowering.md §D5 (synthetic-constant φ-incoming
#     lowering — the within-edge uniqueness the e4l fix supplies),
#     §"cross-iteration reversibility crux", §D1/§D3 (deferred `inverse`),
#     R3 (L3-only).
#   * docs/adr/0013-*.md §D-5 — the IRCast lowering matrix_tri exercises.
#   * src/ir/ingest.jl — `_phi_const_name` / `_phi_const_dup_name` (bead e4l).
#   * test/reference/matrix_tri.jl — oracles + `matrix_tri_vm`.
#   * test/test_per_step_inverse.jl — the `per_step_inverse_check`
#     scaffold (M8.2, `bennettvm-3d8`) this gate consumes.
#   * test/test_matrix_sum_roundtrip.jl — the rectangular-nest analogue
#     this gate mirrors exactly.
#   * bennettvm_prd.md (PRD v4) §3.6.2 Case C, §3.13 (per-step inverse),
#     §3.14 (golden-master), §6 SC9; P0.6 (round-trip is load-bearing).
#   * CLAUDE.md Rule 1 (fail loud), Rule 2 (deep bugs), Rule 4
#     (known-correct values), Rule 5 (mutation-proof), Rule 11 (literate).

using Test
using BennettVM

include(joinpath(@__DIR__, "reference", "matrix_tri.jl"))
include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# The eight trajectory-verified inputs paired with their oracle values
# (the docstring table). Pinned as a constant so testsets (0)/(1)/(2)/(3)
# share one fixture; a future input change is a single-site edit.
const _MATTRI_RT_INPUTS = (
    (n = Int64(1), oracle = Int64(1)),
    (n = Int64(2), oracle = Int64(4)),
    (n = Int64(3), oracle = Int64(10)),
    (n = Int64(4), oracle = Int64(20)),
    (n = Int64(5), oracle = Int64(35)),
    (n = Int64(6), oracle = Int64(56)),
    (n = Int64(7), oracle = Int64(84)),
    (n = Int64(8), oracle = Int64(120)),
)

# The single formal parameter's SSA name (the i8 argument's input key).
const _MATTRI_RT_KEY_ARG = Symbol("n::Int8")

# The lowered EndInstruction return operand — the routine result. Pinned
# empirically: the IRRet operand of `matrix_tri_while`'s exit block is
# `SSAOperand(:value_phi1.lcssa)`, and `value_phi1.lcssa` is the ONLY key
# in `result(rs)` matching the oracle across n=3..8 (the smaller inputs
# alias other slots that happen to equal the small triangular sums).
const _MATTRI_RT_RESULT_KEY = Symbol("value_phi1.lcssa")

@testset "matrix_tri round-trip (triangular nested loops; e4l + IRCast)" begin
    vm = matrix_tri_vm()

    # (0) Pre-pin the oracle table itself against BOTH references, before
    #     any VM assertion can blame the lowering for an oracle bug
    #     (Rule 2: diagnose the real root cause). Each input's hardcoded
    #     oracle must equal both the nested `while` and the closed form.
    @testset "oracle table self-check (Int8 fixture is sound)" begin
        for c in _MATTRI_RT_INPUTS
            @test Int64(matrix_tri_while(Int8(c.n))) == c.oracle
            @test matrix_tri_ref(Int8(c.n)) == c.oracle
        end
    end

    # ------------------------------------------------------------------
    # (1) Per-step inverse (L3) — the finer-grained load-bearing gate.
    # ------------------------------------------------------------------
    # `per_step_inverse_check` forward-sweeps capturing a deepcopy after
    # each `step!`, then walks back via `unstep!` asserting `IState`
    # equality at EVERY step. A mid-NEST reversal bug (e.g. failing to
    # restore the VARYING inner counter `j` across an outer re-prime)
    # therefore surfaces as a specific step-indexed MISMATCH, not a masked
    # aggregate pass. Driven in L3 mode (empty `must_cache_set`) at two
    # checkpoint densities — K=1 (push every step) and K=4 (sparse
    # multi-step replay). Each call returns `nothing` on success (raises on
    # any per-step divergence), so `=== nothing` is the known-correct pin.
    @testset "per-step inverse (L3, empty must_cache)" begin
        for c in _MATTRI_RT_INPUTS
            for K in (1, 4)
                @test per_step_inverse_check(
                    vm, Dict(_MATTRI_RT_KEY_ARG => c.n);
                    checkpoint_interval = K,
                    label = "matrix_tri/n=$(c.n)/K=$K") === nothing
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
    # assert the full P0.6 exit invariant. Reversing the FULL triangular
    # run is precisely what unwinds BOTH the inner- and outer-loop history
    # under the one L3 mechanism: the forward dispatch count grows linearly
    # in n (31→171 for n=1..8) because each outer iteration `i` adds an
    # inner loop of length `i`, so the backward walk has to replay every
    # variable-length inner-loop iteration nested inside every outer-loop
    # iteration. We pin `step_count > oracle` so a regression that flattened
    # the nest goes RED here, and pin `rs.initial` did not drift.
    @testset "aggregate run!/unrun! (oracle-anchored, P0.6)" begin
        for c in _MATTRI_RT_INPUTS
            rs = initial_state(vm, Dict(_MATTRI_RT_KEY_ARG => c.n))
            initial_snap = deepcopy(rs.initial)

            run!(rs, vm; max_steps = 500_000, checkpoint_interval = 8)
            @test is_halted(rs)
            @test rs.step_count > 0
            # The nest dispatches more steps than the accumulator value:
            # > oracle forward dispatches confirms both loops actually
            # iterate (the nested-history witness).
            @test rs.step_count > c.oracle
            # Anchor: forward result is bit-for-bit the irreversible oracle.
            @test result(rs)[_MATTRI_RT_RESULT_KEY] == c.oracle

            unrun!(rs, vm)
            @test rs.current == rs.initial          # P0.6 — reversed to start
            @test isempty(rs.history)               # P0.6 — history drained
            @test rs.step_count == 0                # P0.6 — step counter reset
            @test rs.initial == initial_snap        # rs.initial never mutated
        end
    end

    # ------------------------------------------------------------------
    # (3) THE headline assertion.
    # ------------------------------------------------------------------
    # The case's reason to exist, as one clearly-named claim:
    # `matrix_tri_while` (the triangular nested loop the circuit backend
    # CANNOT represent, and the program that surfaced bead e4l) compiles
    # under the VM backend, runs to halt matching the irreversible oracle
    # (== 10 for n=3), AND round-trips to empty history. n=3 at a sparse
    # checkpoint_interval so the L3 multi-step replay carries the full
    # triangular-nest reversal.
    @testset "headline: triangular loop compiles, runs to 10, round-trips" begin
        n3 = Int64(3)
        rs = initial_state(vm, Dict(_MATTRI_RT_KEY_ARG => n3))

        # Compiles under target=:vm (the lowered VMProgram exists & dispatches).
        @test rs.current isa BennettVM.IState

        # Runs to halt matching the oracle (the nested loop terminates).
        run!(rs, vm; max_steps = 500_000, checkpoint_interval = 8)
        @test is_halted(rs)
        @test result(rs)[_MATTRI_RT_RESULT_KEY] == Int64(matrix_tri_while(Int8(3)))
        @test result(rs)[_MATTRI_RT_RESULT_KEY] == 10         # explicit constant

        # Round-trips to empty history (BOTH loops reverse — P0.6). The
        # forward dispatch count (71 for n=3) far exceeds the 10 inner
        # additions — the surplus is the nested control-flow plumbing the
        # backward L3 replay must unwind in nested order.
        forward_dispatches = rs.step_count
        @test forward_dispatches > 10   # more VM dispatches than the tri-sum
        unrun!(rs, vm)
        @test rs.current == rs.initial
        @test isempty(rs.history)
        @test rs.step_count == 0
    end

    # ------------------------------------------------------------------
    # (4) compute_must_cache set is globally L2-usable (bead `bennettvm-5pp`).
    # ------------------------------------------------------------------
    # PRE-5pp this testset pinned the OPPOSITE: `compute_must_cache(vm)`
    # then marked matrix_tri's non-injective `Define` body slots, so
    # driving the scaffold with that set reached `make_delta(::Define, …)`
    # and RAISED (`Define`'s L2 inverse is deferred, ADR 0012 R3). Bead 5pp
    # made `compute_must_cache` mark ONLY L2-capable non-injective slots
    # (those with a working `make_delta` / `predelta_payload`), so the
    # L3-only creates (`Define`/`VarGEP`/`MemoryLoad`/`Cast`) are EXCLUDED
    # (only the `MemoryStore` writes remain) — the set is now PASSABLE as a
    # global `must_cache_set` without raising, the improvement 5pp shipped.
    # (The fail-loud-on-forced-`Define`-in-L2 contract — `make_delta(::Define)`
    # raises — now lives in `test/test_liveness.jl` testset 11.)
    @testset "compute_must_cache set is L2-usable (5pp): runs + round-trips" begin
        set = BennettVM.compute_must_cache(vm)
        # Every marked slot is L2-capable (the 5pp invariant) — here the
        # `MemoryStore` element writes; `Define`/`VarGEP`/`MemoryLoad` excluded.
        for b in vm.blocks
            for (i, instr) in enumerate(b.instructions)
                (b.label, i) in set && @test BennettVM.is_l2_capable(typeof(instr))
            end
        end
        # The set is now usable: run + round-trip under it (real K so the
        # L3-only slots get checkpoints) — a genuinely MIXED L2/L3 stack —
        # reaches the oracle and reverses to empty history. Pre-5pp: raised.
        rs = initial_state(vm, Dict(_MATTRI_RT_KEY_ARG => Int64(3)))
        run!(rs, vm; max_steps = 500_000, checkpoint_interval = 8,
             must_cache_set = set)
        @test is_halted(rs)
        @test result(rs)[_MATTRI_RT_RESULT_KEY] == 10
        unrun!(rs, vm)
        @test rs.current == rs.initial
        @test isempty(rs.history)
        @test rs.step_count == 0
    end
end
