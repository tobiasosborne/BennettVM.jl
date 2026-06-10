# test/test_revmap_roundtrip.jl — hand-built IRMap* round-trip unit gate
# (SC9 Case B EXECUTABLE PROOF; ADR 0008 Decision 4a/6, Consequences bead 2;
# bead `bennettvm-l49`).
#
# # What this gate is, and why it is the milestone's reason to exist
#
# ADR 0008 Decision 4a/6 names this file the **executable proof of the
# `RevMap` ADT**: a HAND-BUILT `VMProgram` (NOT a Bennett.jl ingest — there
# is no `IRMap*` in ParsedIR; that recognition arm is the BLOCKED Rule-14
# bead `bennettvm-0do` / `Bennett-800b`, ADR 0008 Decision 4b) that drives
# the three `IRMap*` ops (`src/ir/revmap.jl`) through the FULL interpreter
# loop — `run!` forward, `unrun!` backward — asserting BOTH (a) forward
# correctness against an irreversible Julia `Dict` oracle AND (b) the
# load-bearing round-trip invariant `unrun!(run!(s,prog)) == initial(s) &&
# isempty(s.history)` (PRD v4 §6 SC9; Phase-0 gating P0.6). The op-level
# unit test (`test/test_revmap.jl`, bead `jrc`) already pinned each op's
# `forward`/`predelta_payload`/`inverse`/`is_injective` in isolation; THIS
# file is the complementary integration gate — the ops driven end-to-end
# through `step!`/`unstep!`/`run!`/`unrun!`, exactly as `test_store_delta.jl`
# / `test_dyn_roundtrip.jl` are the integration siblings of the `MemoryStore`
# op unit test.
#
# # Two parts (ADR 0008 Consequences bead 2)
#
#   * **Part A — straight-line `fdict` gate** (ADR 0008 Decision 4a/6,
#     l.633). The canonical motivating program `fdict(k,v) = (d=Dict();
#     d[k]=v; d[k])` as a single-block `VMProgram`: `IRMapInsert(k,v)` then
#     `IRMapGet(result,k)`, framed by `Begin`/`End`. Forward result is
#     asserted against the oracle `fdict_ref` (`fdict_ref(3,7) == 7`,
#     ADR 0008 l.633); round-trip is asserted BOTH ways — (a) default empty
#     `must_cache_set` → the `IRMapInsert` reverses via the L3
#     checkpoint-replay fallback (the `s.initial` restore at
#     `src/history/Replay.jl` step (3)); (b) `must_cache_set =
#     compute_must_cache(prog)` → the `IRMapInsert` reverses via its L2
#     `(key, prior)` NamedTuple `inverse()` — the REAL inverse call site
#     (the M8.2 blind-spot lesson: drive the L2 path explicitly or the
#     `inverse()` is never tested; see `test_store_delta.jl` §"Why an
#     EXPLICIT must_cache_set").
#
#   * **Part B — loop-body scenarios** (ADR 0008 Decision 6, BINDING — the
#     reviewer's gate). A GENUINE hand-built BACK-EDGE loop CFG (NOT a
#     step-level fallback; the bead's preferred option) structured like the
#     collatz / countdown loop CFG: a header block with a `ConditionalEntry`
#     (two predecessors — `entry` and the `body` back-edge) and a
#     `ConditionalExit` (continue → `body`, exit → `done`), a body block
#     that on EACH iteration does an `IRMapInsert` (key = loop index `i_in`,
#     value = `i_in*10`) AND an `IRMapGet` into a dest SSA name (`:cur`) that
#     is RE-DEFINED every iteration — the cross-iteration crux (ADR 0008
#     Consequences bead 2 bullet: "The unit gate MUST reuse a get-dest SSA
#     name across a loop ... not just a single straight-line get").
#
# # Why a real back-edge loop, and why it round-trips (the design crux)
#
# The loop is built from `Define` (NOT `ArithmeticAssignment`) for its
# value computation, deliberately: `ArithmeticAssignment.forward` is
# Mogensen-form RSSA and DELETES its `source` (`src/ir/arithmetic_assignment.jl`
# l.234), so it cannot read the loop counter `i_in` four times in one block
# without consuming it. `Define` is the NON-destructive create (operands
# read, never deleted, `src/ir/define_instruction.jl` l.147-149) that ALSO
# computes the `:slt` loop predicate (ADR 0012 §D2 — comparisons live on
# `Define`, not `ArithmeticAssignment`) and OVERWRITES a re-defined target
# across iterations (the cross-iteration crux it shares with `MemoryLoad` /
# `IRMapGet`). This is exactly the shape `lower_vm` emits for collatz
# (`test/reference/collatz.jl`), so the hand-built CFG here is a faithful
# reversible loop, verified forward against the oracle and reversed to empty
# history.
#
# The resulting history is a MIXED L2/L3 stack — the deep interaction
# Rule 2 warns about (the `frtN` rung-7 lesson, `test_dyn_roundtrip.jl`):
# under `compute_must_cache(prog)`, each `IRMapInsert` pushes an L2
# `(key, prior)` `DeltaEntry` (the REAL inverse call site), while the
# `Define`s, the `IRMapGet`-into-`:cur` (L3-only — its SSA dest is
# non-injective on the loop re-definition, ADR 0008 Finding 4), and the
# control-flow transitions are reversed by L3 `CheckpointEntry` replay. The
# round-trip-to-empty-history assertion proves these interleave correctly
# (a per-iteration insert delta sandwiched between control-flow checkpoints,
# with the get-dest reversed by L3 across the same iterations). The probe
# (n=3) hits the `{0 => 0}` binding (insert key 0 → value 0) — the
# missing-sentinel trap (ADR 0008): the L2 inverse MUST `delete!` key 0
# rather than leave a phantom `{0=>0}`, or `rs.current.revmap != {}` and the
# round-trip FAILS. So the loop exercises the absent-key insert inverse
# end-to-end, not merely in the op unit test.
#
# # Mutation-proof (Rule 5) — performed manually, reverted, NOT in tree
#
# ROUND-TRIP-specific perturbation (per the bead's guidance — distinct from
# the op-unit perturbations in `test_revmap.jl`): in
# `inverse(::IRMapInsert, s, p::NamedTuple)` (`src/ir/revmap.jl` l.299-307),
# REMOVE the map mutation — replace the `if p.prior === missing ... end`
# body with nothing, leaving only `s.pc -= 1` (i.e. the L2 inverse no-ops
# on the map instead of reversing the insert). The op unit test
# (`test_revmap.jl`) cannot catch a "did the WHOLE run reverse" regression
# this way without its own round-trip; THIS file does:
#
#   * The RED signal is the `per_step_inverse_check` scaffold, NOT the
#     aggregate `@test rs.current == rs.initial`. Verified empirically
#     (hostile review): under this mutation the aggregate round-trip
#     assertion STAYS GREEN — `unstep!`'s L3 `s.initial` fallback restores
#     the (empty) initial revmap wholesale regardless of whether the L2
#     `inverse()` corrupted the intermediate state, so the end-of-run
#     `rs.current == rs.initial` is blind to a broken per-op inverse. This
#     IS the M8.2 blind-spot. What catches the mutation is the per-STEP
#     backward sweep: `per_step_inverse_check` walks `unstep!` one step at a
#     time asserting per-step IState equality, so it sees that after
#     reversing the insert step the intermediate `revmap` still holds the
#     binding (`{3=>7}` in Part A; the per-iteration `{i=>i*10}` in Part B)
#     → RED at that step.
#   * Part A path (b) (`must_cache` populated → L2 inverse fires): the
#     `per_step_inverse_check` at line ~245 goes RED. (Captured: RED.)
#   * Part B (`compute_must_cache` → inserts take L2): the
#     `per_step_inverse_check` (K=1, K=4) goes RED. (Captured: RED.)
#   * Restored → GREEN. `git diff src/` empty.
#
# (Part A path (a), the L3 fallback, exercises no per-op `inverse()` at all
# and so is GREEN even at the per-step level under this mutation. That
# asymmetry is WHY path (b) + `per_step_inverse_check` are mandatory —
# without them the L2 `inverse()` is untested, the exact M8.2 blind-spot:
# the aggregate round-trip alone never exercises the per-op inverse.)
#
# # Ref
#
#   * `docs/adr/0008-dict-reversibility.md` — Decision 4a (hand-built unit
#     gate is the only executable ADT proof until Rule-14 lands),
#     Decision 6 (canonical `fdict` + loop-body requirement),
#     Consequences bead 2 (forward-vs-oracle + round-trip-to-empty +
#     reuse-get-dest-across-a-loop).
#   * `src/ir/revmap.jl` — the three `IRMap*` ops under integration test.
#   * `src/ir/IState.jl` — `revmap` field + `==`/`hash` (so the round-trip
#     SEES the map; ADR 0008 Finding 3).
#   * `test/test_store_delta.jl` / `test/test_dyn_roundtrip.jl` — the
#     MemoryStore L2/L3 integration siblings whose `must_cache_set` +
#     `per_step_inverse_check` idiom this file mirrors.
#   * `test/test_collatz_roundtrip.jl` / `test/reference/countdown.jl` —
#     the looping / multi-block VMProgram CFG templates.
#   * `test/test_revmap.jl` — the op-LEVEL unit test this integration
#     gate complements (does NOT duplicate).
#   * `src/ir/define_instruction.jl` — `Define`, the non-destructive create
#     used for the loop's value/predicate computation.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known-correct invariants),
#     Rule 5 (mutation-proof), Rule 11 (literate).

using Test
using BennettVM

# The per-step inverse scaffold (M8.2). Re-include-guarded inside the file;
# runtests.jl loads it earlier, but `include`ing here keeps the single-file
# `julia test/test_revmap_roundtrip.jl` invocation self-contained — the same
# pattern `test_store_delta.jl` uses.
include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

const _BV = BennettVM

# =====================================================================
# Part A — straight-line `fdict` gate (ADR 0008 Decision 4a/6, l.633).
# =====================================================================

"""
    fdict_ref(k::Int64, v::Int64) -> Int64

The irreversible Julia oracle for the canonical Case B program
`fdict(k,v) = (d=Dict(); d[k]=v; d[k])` (ADR 0008 l.633, with `Int64`
keys/values per the v1 width scope, Decision 4). `fdict_ref(3, 7) == 7`.
The golden master the hand-built `_fdict_vm` forward run is checked
against (Rule 4 — assert against a known-correct value, not "didn't
throw"). Irreversible by construction (the `Dict` mutation `d[k]=v` is
not undone); the BennettVM equivalent makes it reversible via the
history tape (ADR 0008 Finding 6 — Bennett-1973 applied to heap).
"""
fdict_ref(k::Int64, v::Int64) = (d = Dict{Int64,Int64}(); d[k] = v; d[k])

# Hand-built single-block VMProgram for fdict. Layout (one block :main):
#   Begin(:fdict, [:k, :v])
#   body: IRMapInsert(:k, :v)        # d[k] = v
#         IRMapGet(:result, :k)      # result := d[k]
#   End(:fdict, [:result])
# `:result` is the routine return; `result(rs)[:result]` holds d[k].
function _fdict_vm()
    bb = _BV.BasicBlock(
        :main,
        _BV.BeginInstruction(:fdict, [:k, :v]),
        _BV.Instruction[
            _BV.IRMapInsert(:k, :v),
            _BV.IRMapGet(:result, :k),
        ],
        _BV.EndInstruction(:fdict, [:result]),
    )
    return VMProgram([bb], _BV.LabelTable([bb]), :main, [64, 64], [64])
end

@testset "SC9 Case B unit gate — hand-built IRMap* round-trip (ADR 0008 l49)" begin

    @testset "Part A — straight-line fdict (forward + round-trip both L2/L3)" begin
        vm = _fdict_vm()

        # Forward correctness vs the oracle (Rule 4). fdict(3,7) => 7.
        # Asserted once with the default driver before the round-trip sweep.
        rs0 = initial_state(vm, Dict(:k => Int64(3), :v => Int64(7)))
        run!(rs0, vm)
        @test is_halted(rs0)
        @test result(rs0)[:result] == fdict_ref(Int64(3), Int64(7))
        @test result(rs0)[:result] == 7                 # explicit constant (ADR l.633)
        @test rs0.current.revmap == Dict(Int64(3) => Int64(7))   # the map after forward

        # Round-trip BOTH ways (the M8.2 blind-spot discipline):
        #   (a) empty must_cache_set → IRMapInsert reverses via L3
        #       checkpoint-replay (here: the s.initial fallback restore,
        #       since the 3-step program pushes no K-checkpoint).
        #   (b) compute_must_cache(vm) → IRMapInsert reverses via its L2
        #       (key, prior) NamedTuple inverse() — the REAL inverse call
        #       site. IRMapGet is L3-only (not in the set); it reverses via
        #       the same L3 fallback either way.
        for (mode, mc) in (
                ("L3 (empty must_cache)", Set{Tuple{Symbol,Int}}()),
                ("L2 (compute_must_cache)", _BV.compute_must_cache(vm)),
            )
            rs = initial_state(vm, Dict(:k => Int64(3), :v => Int64(7)))
            initial_snap = deepcopy(rs.initial)

            run!(rs, vm; must_cache_set = mc)
            @test is_halted(rs)
            @test result(rs)[:result] == 7              # forward correct under both modes

            ndelta = count(e -> e isa _BV.DeltaEntry, rs.history)
            if isempty(mc)
                # L3 path: no L2 delta pushed for the insert.
                @test ndelta == 0
            else
                # L2 path: the single IRMapInsert pushed exactly one
                # (key, prior) DeltaEntry — proving L2 fired, not just L3
                # happening to work (Rule 4). IRMapGet is L3-only, so it
                # contributes no DeltaEntry.
                @test ndelta == 1
                de = only(filter(e -> e isa _BV.DeltaEntry, rs.history))
                @test de.instruction isa _BV.IRMapInsert
                @test haskey(de.payload, :key) && haskey(de.payload, :prior)
                @test de.payload.key == 3
                @test de.payload.prior === missing      # key 3 absent before insert
            end

            unrun!(rs, vm)
            @test rs.current == rs.initial              # P0.6 — reversed to start
            @test isempty(rs.history)                   # P0.6 — history drained
            @test rs.step_count == 0                    # P0.6 — step counter reset
            @test isempty(rs.current.revmap)            # the map reversed to empty
            @test rs.initial == initial_snap            # rs.initial never mutated
        end

        # Per-step inverse (mid-instruction reversal bugs the aggregate
        # round-trip can mask, the M8.2 lesson) under BOTH regimes.
        @test per_step_inverse_check(
            vm, Dict(:k => Int64(3), :v => Int64(7));
            checkpoint_interval = 1,
            label = "fdict/L3/K=1") === nothing
        @test per_step_inverse_check(
            vm, Dict(:k => Int64(3), :v => Int64(7));
            checkpoint_interval = 1,
            must_cache_set = _BV.compute_must_cache(vm),
            label = "fdict/L2/K=1") === nothing
    end

    # =================================================================
    # Part B — loop-body scenarios (ADR 0008 Decision 6, BINDING).
    # =================================================================

    @testset "Part B — genuine back-edge loop (IRMapInsert + re-defined-dest IRMapGet)" begin
        # ---------------------------------------------------------------
        # The oracle: an irreversible Julia loop computing exactly what
        # the hand-built CFG computes — the map {i => i*10 : 0 <= i < n},
        # the final `cur` (= the LAST get, d[n-1], or unset for n==0),
        # and the terminal index `i == n`. (Rule 4 — every forward value
        # below is checked against THIS function, defined here.)
        # ---------------------------------------------------------------
        function loop_ref(n::Int64)
            d = Dict{Int64,Int64}()
            cur = nothing
            i = Int64(0)
            while i < n
                d[i] = i * 10
                cur = d[i]
                i += 1
            end
            return (map = d, cur = cur, idx = i)
        end

        # ---------------------------------------------------------------
        # The hand-built back-edge loop CFG (NOT the step-level fallback —
        # this is the bead's preferred genuine loop). Four blocks:
        #
        #   :entry  Begin(:loop, [:n0])
        #           Define(:i0, :n0, :sub, :n0)        # i0 := n0 - n0 = 0
        #                                              #   (Define is non-destructive:
        #                                              #    n0 survives for the bound)
        #           -> UncondExit(:hdr, [:n0, :i0])
        #
        #   :hdr    CondEntry(:hdr, [:n, :i], preds={:entry, :body}, cond=:cond)
        #           Define(:cond, :i, :slt, :n)        # cond := (i < n)
        #           CondExit(:cond, :body, :done, [:n, :i])
        #
        #   :body   CondEntry(:body, [:n_in, :i_in], preds={:hdr, _}, cond=:cond)
        #           Define(:val, :i_in, :mul, 10)      # val := i_in * 10
        #           IRMapInsert(:i_in, :val)           # d[i_in] := val   (L2 delta)
        #           IRMapGet(:cur, :i_in)              # cur := d[i_in]   (:cur RE-DEFINED
        #                                              #   every iteration — the crux)
        #           Define(:i_next, :i_in, :add, 1)    # i_next := i_in + 1
        #           -> UncondExit(:hdr, [:n_in, :i_next])   # the BACK-EDGE
        #
        #   :done   CondEntry(:done, [:n_f, :i_f], preds={:hdr, _}, cond=:cond)
        #           End(:loop, [:i_f])
        #
        # `:cond`, `:val`, `:cur`, `:i_next` are RE-DEFINED on every pass —
        # the cross-iteration name reuse that forces the get-dest (`:cur`)
        # and the predicate/index through the L3 checkpoint-replay layer,
        # while the IRMapInsert takes the L2 (key, prior) delta path. The
        # ConditionalEntry constructor forbids the predicate symbol from
        # appearing in `params` (M2.10 shadowing guard), which is why
        # `:cond` is computed fresh in :hdr's body rather than carried as a
        # block param; the `predecessor_false` of the body/done CondEntries
        # is an unused sentinel label (the M2.10 constructor only requires
        # the two predecessors differ — see test_interpreter.jl M3.6).
        # ---------------------------------------------------------------
        function loop_vm()
            entry = _BV.BasicBlock(
                :entry,
                _BV.BeginInstruction(:loop, [:n0]),
                _BV.Instruction[
                    _BV.Define(:i0, :n0, :sub, :n0),   # i0 = 0; n0 preserved
                ],
                _BV.UnconditionalExit(:hdr, [:n0, :i0]),
            )
            hdr = _BV.BasicBlock(
                :hdr,
                _BV.ConditionalEntry(:hdr, [:n, :i], :entry, :body, :cond),
                _BV.Instruction[
                    _BV.Define(:cond, :i, :slt, :n),   # cond = (i < n)
                ],
                _BV.ConditionalExit(:cond, :body, :done, [:n, :i]),
            )
            body = _BV.BasicBlock(
                :body,
                _BV.ConditionalEntry(:body, [:n_in, :i_in], :hdr,
                                     :nonexistent_b, :cond),
                _BV.Instruction[
                    _BV.Define(:val, :i_in, :mul, Int64(10)),  # val = i_in*10
                    _BV.IRMapInsert(:i_in, :val),              # d[i_in] = val (L2)
                    _BV.IRMapGet(:cur, :i_in),                 # cur RE-DEFINED (L3)
                    _BV.Define(:i_next, :i_in, :add, Int64(1)),
                ],
                _BV.UnconditionalExit(:hdr, [:n_in, :i_next]), # back-edge to :hdr
            )
            done = _BV.BasicBlock(
                :done,
                _BV.ConditionalEntry(:done, [:n_f, :i_f], :hdr,
                                     :nonexistent_d, :cond),
                _BV.Instruction[],
                _BV.EndInstruction(:loop, [:i_f]),
            )
            blocks = [entry, hdr, body, done]
            return VMProgram(blocks, _BV.LabelTable(blocks), :entry, [64], [64])
        end

        vm = loop_vm()

        # Trip counts: 0 (loop body never runs — the degenerate case),
        # 1 (single iteration), 3 (multi-iteration; hits the {0=>0}
        # missing-sentinel binding at i=0), 5 (longer, several checkpoints).
        for n in (Int64(0), Int64(1), Int64(3), Int64(5))
            oracle = loop_ref(n)
            # compute_must_cache routes each IRMapInsert to L2; the Defines,
            # the IRMapGet, and the control flow take L3 — a genuinely MIXED
            # stack (verified non-empty below). K=4 forces L3 checkpoints to
            # interleave with the per-iteration L2 inserts (the rung-7 mix).
            mc = _BV.compute_must_cache(vm)
            rs = initial_state(vm, Dict(:n0 => n))
            initial_snap = deepcopy(rs.initial)

            run!(rs, vm; max_steps = 10_000, checkpoint_interval = 4,
                 must_cache_set = mc)
            @test is_halted(rs)

            # (1) Forward: assert final map content, get-dest, and terminal
            #     index against the hand-computed oracle (Rule 4).
            @test rs.current.revmap == oracle.map         # {i => i*10 : i<n}
            @test result(rs)[:i_f] == oracle.idx          # terminal i == n
            if n == 0
                @test !haskey(BennettVM.active_locals(rs.current), :cur)    # body never ran → no :cur
            else
                @test BennettVM.active_locals(rs.current)[:cur] == oracle.cur  # last get = d[n-1]
                @test BennettVM.active_locals(rs.current)[:cur] == (n - 1) * 10
            end

            # The history is genuinely MIXED L2 (insert deltas) + L3
            # (control-flow + get + define checkpoints) — the rung-7 deep
            # interaction this gate must exercise, not isolated L2 or L3.
            ndelta = count(e -> e isa _BV.DeltaEntry, rs.history)
            nckpt  = count(e -> e isa _BV.CheckpointEntry, rs.history)
            @test ndelta == n                             # one insert delta per iteration
            @test all(e -> e.instruction isa _BV.IRMapInsert,
                      filter(e -> e isa _BV.DeltaEntry, rs.history))
            if n >= 1
                @test nckpt >= 1                          # L3 checkpoints present → MIXED
            end

            # (2) unrun!: the FULL P0.6 round-trip. Because revmap is in
            #     IState.== (ADR 0008 Finding 3), this asserts every
            #     per-iteration insert delta (incl. the {0=>0} absent-key
            #     case for n>=1) reversed AND the re-defined :cur and the
            #     control-flow checkpoints reversed, all interleaved.
            unrun!(rs, vm)
            @test rs.current == rs.initial                # reversed to start
            @test isempty(rs.history)                     # history drained
            @test rs.step_count == 0                      # step counter reset
            @test isempty(rs.current.revmap)              # map reversed to empty
            @test rs.initial == initial_snap              # rs.initial never mutated
        end

        # Per-step inverse (mid-loop reversal bugs the aggregate round-trip
        # masks — the spike Q4 lesson) at two checkpoint densities, with the
        # inserts on the L2 fast-path and everything else on L3.
        for K in (1, 4)
            for n in (Int64(1), Int64(3), Int64(5))
                @test per_step_inverse_check(
                    vm, Dict(:n0 => n);
                    checkpoint_interval = K,
                    must_cache_set = _BV.compute_must_cache(vm),
                    label = "revmap_loop/n=$n/K=$K") === nothing
            end
        end
    end
end
