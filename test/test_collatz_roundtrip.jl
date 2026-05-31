# test/test_collatz_roundtrip.jl — M_UNBOUNDED.3 / SC9 Case D round-trip
# acceptance gate (`bennettvm-hvx`, ADR 0012).
#
# # What this gate is, and why it is the milestone's reason to exist
#
# `collatz_steps(::Int8)` (PRD v4 §3.6.2 Case D) is the unbounded `while`
# the *circuit* backend cannot compile — a loop whose iteration count is
# statically unknown. It is the load-bearing SC9 motivating case (PRD v4
# §6): the existence proof that the VM backend closes the gap the circuit
# target leaves open. M_UNBOUNDED.1 (`test_collatz_forward.jl`) pinned
# that the lowered VMProgram runs *forward* matching the irreversible
# oracle bit-for-bit, plus a single x=7 round-trip SMOKE. THIS file is the
# broader, finer-grained *round-trip* gate: it proves the loop reverses to
# empty history across multiple inputs, at the per-step granularity that
# the aggregate smoke deliberately cannot reach (`spike/RETROSPECTIVE.md`
# Q4 — "the aggregate round-trip masks mid-loop reversal bugs; the
# per-step inverse pattern is what surfaces them").
#
# # Why collatz reverses via L3 checkpoint-replay ONLY (the design crux)
#
# The lowered program's value instructions are `Define` / `SelectInstruction`
# (ADR 0012 §D1, §D3), both classified `is_injective == false`. Their
# per-instruction `inverse()` is DEFERRED (ADR 0012 R3): it raises
# descriptively if reached, because the loop's SSA temporaries (`__v3`,
# `__v4`, …) are the same names redefined every iteration — overwriting a
# value without a record is irreversible, and the chosen recovery is the
# Bennett-1973 trace-tape realised as the existing L3 checkpoint-replay
# history layer (ADR 0012 §"The cross-iteration reversibility crux"; user
# decision 2026-05-28). `unstep!` on the L3 path
# (`src/history/Replay.jl:385`) restores the nearest `CheckpointEntry`
# snapshot and **replays forward** — it never calls per-instruction
# `inverse()`. Periodic full snapshots capture overwritten temporaries
# automatically, so the loop reverses regardless of name reuse.
#
# Two consequences shape every assertion below:
#
#   1. The round-trip gate drives `per_step_inverse_check` in **L3 mode**:
#      a finite `checkpoint_interval` and an **EMPTY `must_cache_set`**
#      (the default). With the must-cache set empty, M7.6's L2-push gate
#      never fires, so no `DeltaEntry` ever lands on `rs.history` for
#      `unstep!`'s M7.4 fast-path (the per-instruction `inverse()` call
#      site) to consume — every backward step falls through to L3
#      forward-replay. This is the only path that can reverse collatz.
#
#   2. The L2 path is the EXPECTED boundary, not a bug: driving the
#      scaffold with `must_cache_set = compute_must_cache(vm)` selects the
#      non-injective `Define` body slots, and the forward sweep then
#      reaches `make_delta(::Define, …)` — which raises (the deferred-L2
#      boundary). The final testset PINS that raise so the L3-only
#      reversal contract is documented as an executable assertion, not a
#      comment.
#
# # What the L3 gate catches — and, honestly, what it does NOT (Rule 5)
#
# L3 reversal is *forward-replay*. As long as the forward semantics are
# DETERMINISTIC, the backward walk replays the same forward and the
# round-trip closes — EVEN IF the forward semantics are wrong. So the
# per-step / round-trip invariant alone does NOT catch a forward-semantic
# bug. Mutation-proof evidence (manually performed, then reverted; NOT
# left in the tree):
#
#   * FORWARD-SEMANTIC mutation — flipping the `:slt` arm in
#     `_apply_binop` (`src/ir/arithmetic_assignment.jl:206`) from
#     `Int64(a < b)` to `Int64(a >= b)`: forward result for x=7 became 0
#     (oracle = 16). The pure per-step / round-trip check stayed GREEN
#     ("OK") — L3 replayed the wrong-but-deterministic forward and closed
#     the loop. What went RED was the **oracle-anchored forward
#     assertion** in testset (2): `@test got == collatz_steps(x)` failed
#     (got=0, want=16). This is WHY testset (2) anchors the round-trip to
#     a *correct* forward run (Rule 4): without the oracle anchor, a
#     forward-semantic regression would slip past a pure round-trip gate.
#
#   * REVERSAL mutation — eliding the mandatory deepcopy at the L3 restore
#     site (`src/history/Replay.jl:385`, `s.current = restore_snap`
#     instead of `deepcopy(restore_snap)`): this aliases the checkpoint
#     snapshot so replay's forward steps mutate it in place. The
#     `per_step_inverse_check` scaffold went RED immediately — a per-step
#     `IState` MISMATCH (field `pc`, expected 2 / actual 5) at the first
#     diverging step. This is the reversal-bug class the L3 per-step gate
#     EXISTS to catch.
#
# Both mutations were reverted; `git diff src/` is empty. The division of
# labour is the point: testset (1)'s per-step inverse catches reversal
# bugs; testset (2)'s oracle anchor catches forward-semantic bugs;
# together they form the complete SC9 Case D acceptance proof.
#
# # Why these six inputs (Rule 4 — sufficient, trajectory-verified)
#
# Per ADR 0012 R1, `IState.locals` are `Int64` but collatz is i8; the
# lowering does not mask to width, so VM↔oracle agreement holds only for
# inputs whose ENTIRE trajectory stays in i8 range, and the `steps <
# Int8(20)` self-cap means a faithful round-trip needs trajectories that
# terminate *naturally* (≤ ~20 steps) rather than hitting the cap. Each
# input below was REPL-traced (oracle value, max trajectory value,
# overflow flag, cap flag) before being hardcoded:
#
#   x | oracle | max traj | i8-safe | hits 20-cap | path exercised
#   --+--------+----------+---------+-------------+-------------------------
#   1 |   0    |    1     |  yes    |    no       | loop NOT entered (val>1 false)
#   2 |   1    |    2     |  yes    |    no       | single even-halve iteration
#   4 |   2    |    4     |  yes    |    no       | two even-halve iterations
#   7 |  16    |   52     |  yes    |    no       | longest non-overflow; both arms, peak 52
#   9 |  19    |   52     |  yes    |    no       | 19 steps — one below the cap (off-by-one guard)
#  12 |   9    |   16     |  yes    |    no       | even start, mixed arms, mid-length
#
# x=1 / x=2 / x=4 pin the short / loop-not-taken paths; x=7 / x=9 pin the
# longest non-overflowing trajectories (x=9 at 19 steps guards against an
# off-by-one in the loop-carried `steps` φ — one more iteration would hit
# the cap); x=12 is a mid-length even-start trajectory. All six were
# confirmed `vm_result == oracle` and round-trip-clean in a REPL probe.
#
# # Ref
#
#   * docs/adr/0012-collatz-lowering.md §"The cross-iteration
#     reversibility crux", §D1/§D3 (deferred `inverse`), R3 (L3-only).
#   * test/reference/collatz.jl — oracle `collatz_steps` + `collatz_vm`.
#   * test/test_per_step_inverse.jl — the `per_step_inverse_check`
#     scaffold (M8.2, `bennettvm-3d8`) this gate consumes.
#   * test/test_collatz_forward.jl — the M_UNBOUNDED.1 forward gate +
#     single round-trip smoke this finer-grained gate broadens.
#   * src/history/Replay.jl:385 — the L3 deepcopy restore site.
#   * bennettvm_prd.md (PRD v4) §3.6.2 Case D, §3.13 (per-step inverse),
#     §3.14 (golden-master), §6 SC9; Phase-0 gating P0.6 (round-trip is
#     the load-bearing invariant).
#   * CLAUDE.md Rule 1 (fail loud), Rule 2 (deep bugs), Rule 4
#     (known-correct values), Rule 5 (mutation-proof), Rule 11 (literate).

using Test
using BennettVM

include(joinpath("reference", "collatz.jl"))

# The six trajectory-verified inputs paired with their oracle step-counts
# (the docstring table). Pinned as a constant so testsets (1)/(2)/(3) share
# the same fixture and a future input change is a single-site edit.
const _COLLATZ_RT_INPUTS = (
    (x = Int64(1),  oracle = Int64(0)),
    (x = Int64(2),  oracle = Int64(1)),
    (x = Int64(4),  oracle = Int64(2)),
    (x = Int64(7),  oracle = Int64(16)),
    (x = Int64(9),  oracle = Int64(19)),
    (x = Int64(12), oracle = Int64(9)),
)

# The single formal parameter's SSA name (the i8 argument's input key).
const _COLLATZ_RESULT_KEY_ARG = Symbol("x::Int8")

# The lowered IRRet operand name — the routine result in `result(rs)`.
const _COLLATZ_RESULT_KEY = Symbol("value_phi1.lcssa")

@testset "M_UNBOUNDED.3 — collatz round-trip (SC9 Case D)" begin
    vm = collatz_vm()

    # Pre-pin the oracle table itself against the irreversible reference,
    # independent of the VM. If `collatz_steps` ever drifts (or an input's
    # trajectory silently leaves i8 range / hits the cap), this fails here
    # FIRST — before any VM assertion blames the lowering for an oracle
    # bug (Rule 2: diagnose the real root cause, not the symptom).
    @testset "oracle table self-check (Int8 fixture is sound)" begin
        for c in _COLLATZ_RT_INPUTS
            @test Int64(collatz_steps(Int8(c.x))) == c.oracle
        end
    end

    # ------------------------------------------------------------------
    # (1) Per-step inverse (L3) — the finer-grained load-bearing gate.
    # ------------------------------------------------------------------
    # `per_step_inverse_check` forward-sweeps capturing a deepcopy after
    # each `step!`, then walks back via `unstep!` asserting `IState`
    # equality at EVERY step. A mid-loop reversal bug therefore surfaces
    # as a specific step-indexed MISMATCH, NOT a masked aggregate pass
    # (the spike RETROSPECTIVE Q4 lesson). Driven in L3 mode (empty
    # `must_cache_set`) at two checkpoint densities:
    #   * K=1     — push every step; maximally dense L3, the nearest-
    #               checkpoint search always lands exactly at target.
    #   * K=4     — sparse; exercises multi-step forward replay between
    #               checkpoints (the realistic L3 regime).
    # Each call returns `nothing` on success (it raises on any per-step
    # divergence), so `=== nothing` is the known-correct pin (Rule 4).
    @testset "per-step inverse (L3, empty must_cache)" begin
        for c in _COLLATZ_RT_INPUTS
            for K in (1, 4)
                @test per_step_inverse_check(
                    vm, Dict(_COLLATZ_RESULT_KEY_ARG => c.x);
                    checkpoint_interval = K,
                    label = "M_UNBOUNDED.3/collatz/x=$(c.x)/K=$K") === nothing
            end
        end
    end

    # ------------------------------------------------------------------
    # (2) Aggregate run!/unrun! anchored to the oracle (P0.6).
    # ------------------------------------------------------------------
    # For each input: snapshot the initial state, `run!` to halt, ASSERT
    # the forward result equals the oracle (so the round-trip is anchored
    # to a CORRECT forward run — without this anchor a forward-semantic
    # regression slips past a pure round-trip; see the docstring's
    # mutation-proof §), then `unrun!` and assert the full P0.6 exit
    # invariant: `rs.current == rs.initial`, empty history, step_count 0.
    # We also pin `rs.initial` did not drift (the `rs.initial`-mutation
    # bug class — distinct from the backward-walk bug; cf.
    # `test_per_step_inverse.jl`'s post-sweep `rs.initial` check).
    @testset "aggregate run!/unrun! (oracle-anchored, P0.6)" begin
        for c in _COLLATZ_RT_INPUTS
            rs = initial_state(vm, Dict(_COLLATZ_RESULT_KEY_ARG => c.x))
            initial_snap = deepcopy(rs.initial)

            run!(rs, vm; max_steps = 10_000, checkpoint_interval = 8)
            @test is_halted(rs)
            @test rs.step_count > 0
            # Anchor: forward result is bit-for-bit the irreversible oracle.
            @test result(rs)[_COLLATZ_RESULT_KEY] == c.oracle

            unrun!(rs, vm)
            @test rs.current == rs.initial          # P0.6 — reversed to start
            @test isempty(rs.history)               # P0.6 — history drained
            @test rs.step_count == 0                # P0.6 — step counter reset
            @test rs.initial == initial_snap        # rs.initial never mutated
        end
    end

    # ------------------------------------------------------------------
    # (3) THE SC9 Case D headline assertion.
    # ------------------------------------------------------------------
    # The milestone's reason to exist, stated as one clearly-named claim:
    # `collatz_steps` (PRD v4 §3.6.2 Case D — the unbounded `while` the
    # circuit backend CANNOT compile) compiles under the VM backend, runs
    # to halt matching the irreversible oracle, AND round-trips to empty
    # history. Uses x=7 (the longest non-overflowing trajectory: 16 oracle
    # steps, 198 VM dispatches, peak value 52, both select arms exercised)
    # at a sparse checkpoint_interval so the L3 multi-step replay carries
    # the full loop reversal.
    @testset "SC9 Case D: unbounded while compiles, runs, round-trips" begin
        x7 = Int64(7)
        rs = initial_state(vm, Dict(_COLLATZ_RESULT_KEY_ARG => x7))

        # Compiles under target=:vm (the lowered VMProgram exists & dispatches).
        @test rs.current isa BennettVM.IState

        # Runs to halt matching the oracle (the unbounded loop terminates).
        run!(rs, vm; max_steps = 10_000, checkpoint_interval = 8)
        @test is_halted(rs)
        @test result(rs)[_COLLATZ_RESULT_KEY] == Int64(collatz_steps(Int8(7)))
        @test result(rs)[_COLLATZ_RESULT_KEY] == 16          # explicit constant

        # Round-trips to empty history (the loop reverses — P0.6).
        forward_dispatches = rs.step_count
        @test forward_dispatches > 16    # more VM dispatches than oracle steps
        unrun!(rs, vm)
        @test rs.current == rs.initial
        @test isempty(rs.history)
        @test rs.step_count == 0
    end

    # ------------------------------------------------------------------
    # (4) compute_must_cache set is globally L2-usable (bead `bennettvm-5pp`).
    # ------------------------------------------------------------------
    # PRE-5pp this testset pinned the OPPOSITE: `compute_must_cache(vm)`
    # then marked collatz's non-injective `Define`/`Select` slots, so
    # driving the scaffold with that set reached `make_delta(::Define, …)`
    # and RAISED (`Define`'s L2 inverse is deferred, ADR 0012 R3). Bead 5pp
    # made `compute_must_cache` mark ONLY L2-capable non-injective slots
    # (those with a working `make_delta` / `predelta_payload`), so the
    # L3-only creates (`Define`/`Select`/`VarGEP`/`MemoryLoad`/`Cast`) are
    # EXCLUDED — the set is now PASSABLE as a global `must_cache_set`
    # without raising, which is the improvement 5pp shipped. (The
    # fail-loud-on-forced-`Define`-in-L2 contract — `make_delta(::Define)`
    # raises — now lives in `test/test_liveness.jl` testset 11.)
    @testset "compute_must_cache set is L2-usable (5pp): runs + round-trips" begin
        set = BennettVM.compute_must_cache(vm)
        # Every marked slot is L2-capable (the 5pp invariant). collatz's
        # creates are all `Define`/`Select` (L3-only), so the set is empty
        # here — the loop is vacuous but pins the contract if that changes.
        for b in vm.blocks
            for (i, instr) in enumerate(b.instructions)
                (b.label, i) in set && @test BennettVM.is_l2_capable(typeof(instr))
            end
        end
        # The set is now usable: run + round-trip under it (real K so the
        # L3-only slots get checkpoints) reaches the oracle and reverses to
        # empty history — pre-5pp this raised at `make_delta(::Define)`.
        rs = initial_state(vm, Dict(_COLLATZ_RESULT_KEY_ARG => Int64(7)))
        run!(rs, vm; max_steps = 10_000, checkpoint_interval = 8,
             must_cache_set = set)
        @test is_halted(rs)
        @test result(rs)[_COLLATZ_RESULT_KEY] == 16
        unrun!(rs, vm)
        @test rs.current == rs.initial
        @test isempty(rs.history)
        @test rs.step_count == 0
    end
end
