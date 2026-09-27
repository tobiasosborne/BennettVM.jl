# test/test_property_roundtrip.jl — M8.5 (bd `bennettvm-tnp`), the
# capstone of the M8 milestone family.
#
# # Why a 100-random-program property test, and why it is the M8 capstone
#
# M8.1 hoisted the countdown reference + oracle. M8.2 laid down the
# reusable `per_step_inverse_check` scaffold. M8.3 mutation-proved the
# per-instruction `inverse()` audit. M8.4 built the seeded random RSSA
# program generator. M8.5 — this file — is where those four pieces
# compose into the load-bearing property gate PRD v4 §3.15 binds:
# *randomly-generated programs WITH control flow* (jumps, conditionals,
# bounded loops), not only straight-line, each round-tripping under
# `run!`/`unrun!` and surviving `per_step_inverse_check` at every
# history regime. The spike's property tests were straight-line-only
# for termination simplicity (PRD v4 §3.15; spike `RETROSPECTIVE.md`
# Q4 §"Test patterns worth keeping" and Q9 — the straight-line
# limitation is exactly what Q9 flags as not-learned). Phase-2's
# RSSA-level CFG (linear / conditional-diamond / unrolled-loop, the
# three generator shapes) plus M8.4's `size_hint`-bounded termination
# make termination-bounded random CFG generation tractable; this file
# is the gate that exercises it 100×.
#
# # Why a SINGLE `default_rng()` walked 100 times (not 100 fresh RNGs)
#
# Determinism is the whole point of `MersenneTwister(0xBE171973)`
# (M8.4 `default_rng()` — `BE1`=Bennett, `1973`=the foundational
# *Logical Reversibility of Computation* paper). Walking one RNG
# instance 100 times pins an exact, replayable program sequence: any
# M8.5 failure is reproducible across machines from the seed alone, no
# `.jld2` fixture files (the JSONL-friendly discipline `.beads/` already
# follows — CLAUDE.md Rule 13 / cft-anyons pattern). The DETERMINISM
# testset below re-runs the whole sweep from a second fresh
# `default_rng()` and asserts every program is structurally identical
# AND every per-program outcome matches — pinning that the property
# gate is not silently RNG-state-dependent.
#
# # Why BOTH L3 and L2 regimes per program (the HANDOFF requirement)
#
# `per_step_inverse_check`'s two history-regime kwargs map to PRD v4
# §3.3's history layering:
#
#   * **L3** (`checkpoint_interval=4`, empty `must_cache_set`): the
#     M4.3 checkpoint-replay path. Backward `unstep!` reads the nearest
#     `CheckpointEntry` and replays `forward()` — never calls any
#     per-instruction `inverse()`. This pins L3 round-trip correctness.
#
#   * **L2** (`checkpoint_interval=typemax(Int)`, `must_cache_set =
#     compute_must_cache(vm)`): the M7.4/M7.6 delta-history path.
#     Backward `unstep!` consumes `DeltaEntry`s via the fast-path,
#     which IS the per-instruction `inverse()` call site for
#     non-injective instructions. This pins L2 inverse correctness.
#
# The two are DISTINCT invariants exercised by DISTINCT code paths
# (the M8.2 scaffold's file docstring §"Mutation-proof evidence" spells
# out why a no-op'd `inverse()` stays GREEN on the L3 path) — so M8.5
# drives every program through BOTH. Empirically 74/100 of the seeded
# sweep have a non-empty `compute_must_cache(vm)` (a reachable
# non-injective `ArithmeticAssignment(:add/:sub)` body step), so the
# L2 path is genuinely driven on the majority of the sweep — verified
# at implementation time (2026-05-28) and re-pinned by the
# `MUTATION_PROOF` testset below, which mutates `inverse()` and
# confirms the sweep goes RED.
#
# # Why `size_hint=6`
#
# The 3-way `:any` shape coin and `size_hint=6` together give shape
# variety (linear / conditional / looping all appear in the 100) AND
# non-trivial body length: linear chains of `3:6` body instructions,
# conditional diamonds with `1:2`-instruction branches, unrolled loops
# of `1:6` iterations. `size_hint=6` matches the M8.4 generator's own
# determinism/shape-coverage testsets (`random_program.jl:483, 500`)
# so the sequences this file walks line up with the coverage M8.4
# already pinned. Max observed `step_count` over the 100 is 15 — orders
# of magnitude below `unrun!`'s `max_unsteps=10_000` default, so the
# default guard never fires spuriously.
#
# # Why the gate checks FORWARD SEMANTICS first (`bennettvm-tghl`)
#
# Everything below the drivers used to be a REVERSIBILITY gate: run,
# unrun, compare, plus a per-step inverse walk. None of it asked
# whether the run was CORRECT. A VM whose forward step computes a
# deterministic wrong answer satisfies all of it, because the wrong
# answer reverses just as faithfully as a right one. Astra VM-ingest F16
# demonstrated that by execution: a program whose oracle is 11 and
# whose VM result is 2 was accepted by `_full_roundtrip!` verbatim
# (`reviews/2026-09-26-astra/VM-ingest.verification.md` §F16).
#
# So every generated program now arrives with a `SemDesc` — a
# source-level description of what it means — and `_full_roundtrip!`
# runs the independent model (`test/generators/semantic_model.jl`, which
# shares no code with the VM) on the same inputs and compares BEFORE it
# un-runs anything. A forward bug cannot cancel out: it is compared
# while the wrong value is still on screen, and only then reversed.
#
# The comparison is deliberately narrow — the program's declared return
# values and the memory cells it touched — because those are the two
# things the program's MEANING pins. The register file's shape is an
# interpreter representation detail (ADR 0022 keeps dead names alive
# across a cross-block rename), so pinning it would be pinning an
# implementation choice instead of a semantic fact.
#
# # Why `_declared_returns` reads the VM program's own End marker
#
# The observable set is taken from the `EndInstruction.returns` the
# generator emitted, not from the description's `output` field. That
# makes the two independent constructions cross-check each other: if
# the generator wired the End to a name the description never produces,
# `sem_check` says so instead of quietly comparing one field with
# itself. This reads construction-time metadata; it is not a second
# path to the forward result.
#
# # Mutation-proof (Rule 5, port-and-verify): why ArithmeticAssignment,
# # and why the eval+delete_method+invokelatest discipline
#
# The 100-program round-trip + per-step-inverse sweep is a *test*; per
# Rule 5 it is only meaningful once it has caught a real regression.
# The `MUTATION_PROOF` testset perturbs the production
# `inverse(::ArithmeticAssignment, s, prev)` body (the non-injective
# `:add`/`:sub` case the generator emits in linear `_chain` bodies and
# looping iteration bodies), confirms the L2 sweep goes RED, then
# restores the canonical method in a `finally` with a post-restore
# GREEN assertion. ArithmeticAssignment is chosen because (a) it is the
# only generator-emitted kind reachable via the L2 path with a
# non-empty `must_cache_set` (the four memory/swap kinds are all
# M6.1-injective, so the M7.6 L1 short-circuit keeps them off L2 — see
# `test/test_mutation_proof.jl` §"L1-injective short-circuit"), and
# (b) the seeded sweep hits it on 74/100 programs including index 1,
# so RED is guaranteed to fire on the very first program.
#
# The mechanism is the EXACT M8.3 discipline (`test/test_mutation_proof.jl`
# §"World-age caveat" and §"Why this mutation strategy"):
# `BennettVM.eval(body)` shadows the canonical method (same signature →
# wins on dispatch); `Base.delete_method` on the set-diff restores it;
# **every call into the freshly-`eval`'d production code goes through
# `Base.invokelatest`** because Julia's world-age semantics make the
# new method invisible to any call from a frame whose compilation
# predates the `eval`. Without `invokelatest` the harness is silently
# GREEN — the trap M8.3 documented empirically. The post-restore GREEN
# assertion (load-bearing) aborts loudly if restoration silently fails
# (Rule 1).
#
# # Ref
#
#   * `bennettvm_prd.md` (PRD v4) §3.13 (per-step inverse / round-trip
#     invariant), §3.15 (property-test discipline; the M8 family bind —
#     seeded + control-flow, not straight-line).
#   * `spike/RETROSPECTIVE.md` Q4 §"Test patterns worth keeping" — the
#     property-test generator pattern's origin; Q9 — the straight-line
#     limitation §3.15 lifts.
#   * `test/generators/random_program.jl` (M8.4 `bennettvm-bii`) —
#     `default_rng`, `random_program`, `_structural_eq`,
#     `_classify_shape`.
#   * `test/test_per_step_inverse.jl` (M8.2 `bennettvm-3d8`) —
#     `per_step_inverse_check` scaffold (the L3/L2 driver).
#   * `test/test_mutation_proof.jl` (M8.3 `bennettvm-2kl`) — the
#     eval+delete_method+invokelatest mutation discipline this file
#     reuses; §"World-age caveat", §"L1-injective short-circuit".
#   * `test/test_unrun.jl` (M4.4), `test/test_zero_history_roundtrip.jl`
#     (M6.4), `test/test_delta_roundtrip.jl` (M7.7) — the round-trip
#     assertion style (`rs.current == rs.initial && isempty(history)`)
#     this file matches.
#   * `src/history/Replay.jl` — `unrun!` (`max_unsteps=10_000` default)
#     and its `rs.current == rs.initial` / `isempty(history)` exit
#     invariant.
#   * `src/analysis/liveness.jl:163` — `compute_must_cache` (the L2
#     selector).
#   * `test/generators/semantic_model.jl` (`bennettvm-tghl`) — the
#     independent forward oracle: `SemDesc`, `sem_eval`, `sem_check`.
#     `test/test_tghl_forward_oracle.jl` mutation-proves it (a wrong
#     `_apply_binop` turns the gate below RED) and checks the model's
#     own binop table against native Julia `Int8` exhaustively.
#   * `bd bennettvm-tnp` (M8.5) — this milestone, the M8 capstone.
#   * CLAUDE.md Rule 1 (fail loud on restoration failure), Rule 4
#     (every test pins a known-correct value — round-trip equality,
#     empty history, RED-on-mutation), Rule 5 (mutation-prove the
#     tests catch regressions), Rule 7 (single Julia process), Rule 10
#     (≤200 LOC), Rule 11 (literate top-of-file docstring).

using Test
using Random
using BennettVM

# `per_step_inverse_check` (M8.2) and the generator (M8.4) are included
# by `runtests.jl` ahead of this file, so they are already in scope
# under the suite. For per-file autonomy (the project's per-file
# include idiom), include them directly when they are not yet defined —
# guarded so the suite does not double-include (which would re-run
# their bottom testsets).
isdefined(@__MODULE__, :per_step_inverse_check) ||
    include(joinpath(@__DIR__, "test_per_step_inverse.jl"))
isdefined(@__MODULE__, :random_program) ||
    include(joinpath(@__DIR__, "generators", "random_program.jl"))
isdefined(@__MODULE__, :sem_eval) ||
    include(joinpath(@__DIR__, "generators", "semantic_model.jl"))

# ---------------------------------------------------------------------
# Knobs (pinned in the docstring above)
# ---------------------------------------------------------------------

const _N_PROGRAMS = 100
const _SIZE_HINT  = 6
const _L3_K       = 4               # small checkpoint interval → L3 path

# ---------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------

"""
    _declared_returns(vm::VMProgram) -> Vector{Symbol}

The names the program declares it returns: the `returns` list of the
unique `EndInstruction` block marker. Raises if the program has zero or
several such blocks — a program that does not say what it returns has
no observable for the forward oracle to check (Rule 1).
"""
function _declared_returns(vm::VMProgram)
    ends = filter(bb -> bb.exit isa BennettVM.EndInstruction, vm.blocks)
    length(ends) == 1 ||
        error("property-roundtrip: expected exactly one EndInstruction ",
              "block, found $(length(ends)) — the forward oracle needs a ",
              "single declared output set to compare against")
    return ends[1].exit.returns
end

"""
    _full_roundtrip!(vm, inputs, desc) -> Nothing

Build `initial_state(vm, inputs)`, snapshot the initial IState, `run!`
to halt (asserting `is_halted`), compare the forward result against the
INDEPENDENT semantic model, and only then `unrun!` and assert the
canonical "fully reversed" predicate: `rs.current == captured_initial`,
`rs.current == rs.initial`, AND `isempty(rs.history)` (PRD v4 §3.13;
the M4.4 / M6.4 / M7.7 round-trip style). Raises on any violation so a
non-`@testset` caller (the determinism re-run, the mutation sweep) sees
the same fail-loud behavior. Returns `nothing` on success.
"""
function _full_roundtrip!(vm::VMProgram, inputs::Dict{Symbol,Int64},
                          desc::SemDesc)
    rs = initial_state(vm, inputs)
    captured_initial = deepcopy(rs.current)
    Base.invokelatest(run!, rs, vm; max_steps=10_000)
    is_halted(rs) || error("property-roundtrip: program did not halt ",
        "(step_count=$(rs.step_count), status=$(rs.current.status))")
    # FORWARD ORACLE (`bennettvm-tghl`). Runs while the (possibly
    # wrong) result is still in hand: `sem_check` raises with the
    # mismatching register / cell named, and nothing below can mask it,
    # because the un-run that follows never looks at the result again.
    outcome = sem_eval(desc, inputs)
    returns = _declared_returns(vm)
    desc.output in returns ||
        error("property-roundtrip: the description's output :",
              desc.output, " is not among the program's declared returns ",
              returns)
    sem_check(outcome, returns, result(rs), rs.current.memory;
              label="property-roundtrip forward oracle")
    Base.invokelatest(unrun!, rs, vm)
    rs.current == captured_initial || error("property-roundtrip: ",
        "post-unrun! rs.current != captured initial. ",
        "expected=", repr(captured_initial), " actual=", repr(rs.current))
    rs.current == rs.initial || error("property-roundtrip: ",
        "post-unrun! rs.current != rs.initial (embedded step-0 snapshot ",
        "diverged). rs.initial=", repr(rs.initial),
        " rs.current=", repr(rs.current))
    isempty(rs.history) || error("property-roundtrip: post-unrun! ",
        "history non-empty (length=$(length(rs.history)))")
    return nothing
end

"""
    _sweep_one!(vm, inputs, desc, idx) -> Nothing

Drive ONE generated program through all three M8.5 gates: full
round-trip (forward oracle included), per-step inverse at L3, per-step
inverse at L2. The `idx` is woven into the scaffold `label` so any RED
names the offending program. Raises on any failure; returns `nothing`
on success. The `Base.invokelatest` wrappers make this driver
mutation-visible (M8.3 world-age discipline) so the mutation sweep
observes a perturbed `inverse()`.
"""
function _sweep_one!(vm::VMProgram, inputs::Dict{Symbol,Int64},
                     desc::SemDesc, idx::Int)
    _full_roundtrip!(vm, inputs, desc)
    # L3 regime: small K, empty must_cache_set (checkpoint-replay path).
    Base.invokelatest(per_step_inverse_check, vm, inputs;
        checkpoint_interval=_L3_K,
        label="M8.5/program-$idx/L3")
    # L2 regime: never checkpoint, populated must_cache_set (delta path
    # → the per-instruction inverse() call site).
    set = BennettVM.compute_must_cache(vm)
    Base.invokelatest(per_step_inverse_check, vm, inputs;
        checkpoint_interval=typemax(Int),
        must_cache_set=set,
        label="M8.5/program-$idx/L2")
    return nothing
end

# ---------------------------------------------------------------------
# 1. The load-bearing 100-program property gate
# ---------------------------------------------------------------------

@testset "M8.5 — 100 random programs round-trip (L3 + L2)" begin
    # Walk a SINGLE seeded RNG 100 times. For each program assert the
    # full round-trip (forward oracle included, `bennettvm-tghl`) AND
    # per-step inverse at both history regimes. Per-shape counts are
    # accumulated so the gate also pins shape variety (a generator
    # regression that dropped a shape would erode M8.5 coverage
    # silently — Rule 4).
    rng = default_rng()
    counts = Dict(:linear => 0, :conditional => 0, :looping => 0)
    n_l2_driven = 0
    n_forward_checked = 0
    for i in 1:_N_PROGRAMS
        (vm, inputs, desc) = random_program(rng; size_hint=_SIZE_HINT)
        counts[_classify_shape(vm)] += 1
        isempty(BennettVM.compute_must_cache(vm)) || (n_l2_driven += 1)
        @test _sweep_one!(vm, inputs, desc, i) === nothing
        n_forward_checked += 1
    end
    # The forward-oracle leg must have run on EVERY program — a
    # generator regression that stopped emitting a usable description
    # would otherwise leave this gate silently testing reversal only,
    # which is the F16 failure mode. This is the assertion that keeps
    # the new leg load-bearing rather than incidental.
    @test n_forward_checked == _N_PROGRAMS
    # Shape variety: every shape must appear (3-way coin over 100 trials;
    # ≥5 each is comfortable headroom against RNG variance while still
    # catching a shape dropped entirely).
    @test counts[:linear]      >= 5
    @test counts[:conditional] >= 5
    @test counts[:looping]     >= 5
    @test sum(values(counts))  == _N_PROGRAMS
    # The L2 path must be genuinely driven on a substantial fraction —
    # otherwise the L2 half of every `_sweep_one!` degenerates to a
    # no-op and the mutation sweep below could not go RED. Empirically
    # 74/100; pin ≥1 (load-bearing for the mutation proof) plus a
    # generous lower band that still flags a generator regression that
    # stopped emitting non-injective arithmetic entirely.
    @test n_l2_driven >= 1
    @test n_l2_driven >= 20
end

# ---------------------------------------------------------------------
# 2. Determinism: a fresh RNG reproduces the sequence and the outcomes
# ---------------------------------------------------------------------

@testset "M8.5 — property run is deterministic" begin
    # Two fresh `default_rng()` instances must yield identical program
    # sequences (structural + inputs) AND identical per-program sweep
    # outcomes. This pins that the 100-program gate is reproducible from
    # the seed alone — the cross-machine replayability §3.15 binds.
    rng_a = default_rng()
    rng_b = default_rng()
    for i in 1:_N_PROGRAMS
        (vm_a, in_a, d_a) = random_program(rng_a; size_hint=_SIZE_HINT)
        (vm_b, in_b, d_b) = random_program(rng_b; size_hint=_SIZE_HINT)
        @test _structural_eq(vm_a, vm_b)
        @test in_a == in_b
        # The description is part of the determinism contract too: an
        # oracle that drifts between runs is not an oracle (`jpb`).
        @test _sem_desc_eq(d_a, d_b)
        # Outcome determinism: both sides round-trip identically. Drive
        # only the (cheaper) full round-trip here — the L3/L2 per-step
        # coverage is already pinned by the gate above; re-running it
        # 100× a second time would double the suite cost for no new
        # invariant. The round-trip is the load-bearing reproducibility
        # claim.
        @test _full_roundtrip!(vm_a, in_a, d_a) === nothing
        @test _full_roundtrip!(vm_b, in_b, d_b) === nothing
    end
end

# ---------------------------------------------------------------------
# 3. Mutation-proof (Rule 5): perturb inverse(::ArithmeticAssignment)
#    and confirm the L2 sweep goes RED, then GREEN on restore.
# ---------------------------------------------------------------------

# Type-tuple for the canonical inverse method signature (mirrors
# `test/test_mutation_proof.jl`'s `_TYPES` entry for this kind).
const _AA_TYPES =
    (BennettVM.ArithmeticAssignment, BennettVM.IState, Any)

# Set-diff snapshot/restore (the M8.3 robust-to-shadowing primitives).
_aa_snapshot() = Set{Method}(methods(BennettVM.inverse, _AA_TYPES))
function _aa_restore!(before)
    n = 0
    for m in methods(BennettVM.inverse, _AA_TYPES)
        m in before || (Base.delete_method(m); n += 1)
    end
    return n
end

# The mutation: a "skip the dual_modop flip" wrong-refactor — uses the
# raw `instr.modop` where the canonical inverse uses `dual_modop`. On a
# `:add`/`:sub` body step this produces the WRONG recovered value, so
# the L2 backward walk's `_assert_istate_eq` fires a step-indexed
# `frames`-field MISMATCH (RED). This is the exact mutation M8.3 uses
# for ArithmeticAssignment (`test/test_mutation_proof.jl:316`), proven
# there to be caught on countdown(3); here we re-prove it is caught by
# the SEEDED 100-program sweep (a broader, control-flow-rich oracle).
const _AA_MUTATION = quote
    function inverse(instr::ArithmeticAssignment, s::IState, prev)::IState
        lv = BennettVM._resolve(instr.lhs, s)
        rv = BennettVM._resolve(instr.rhs, s)
        e  = BennettVM._apply_binop(instr.op, lv, rv)
        xval = BennettVM.active_locals(s)[instr.target]
        # BUG: canonical inverse uses dual_modop(instr.modop); this uses
        # the raw modop, so :add/:sub recover the wrong source value.
        yval = BennettVM._apply_modop(instr.modop, xval, e)
        delete!(BennettVM.active_locals(s), instr.target)
        BennettVM.active_locals(s)[instr.source] = yval
        s.pc -= 1; return s
    end
end

# Drive the L2 sweep over the 100 seeded programs; return (red, msg) of
# the FIRST program that goes RED (or (false, "") if none did). Only
# the L2 path is driven here (the path that calls inverse()); the L3
# path is mutation-blind by construction (it forward-replays, never
# calls inverse() — M8.2 file docstring §"Mutation-proof evidence").
function _l2_sweep_first_red()
    rng = default_rng()
    for i in 1:_N_PROGRAMS
        (vm, inputs, _) = random_program(rng; size_hint=_SIZE_HINT)
        set = BennettVM.compute_must_cache(vm)
        isempty(set) && continue       # no L2 step → cannot exercise inverse()
        try
            Base.invokelatest(per_step_inverse_check, vm, inputs;
                checkpoint_interval=typemax(Int),
                must_cache_set=set,
                label="M8.5/MUTATION/program-$i/L2")
        catch e
            e isa ErrorException || rethrow()
            return (true, e.msg)
        end
    end
    return (false, "")
end

@testset "M8.5 — mutation-proof: inverse(::ArithmeticAssignment) RED then GREEN" begin
    # RED: under the skip-dual-modop mutation, at least one of the 100
    # seeded programs (74/100 reach the L2 path; index 1 is the first)
    # MUST fail the per-step inverse check with a step-indexed,
    # `locals`-named diagnostic carrying the program's M8.5 label.
    # GREEN (post-restore, load-bearing): a clean L2 sweep of the first
    # L2-reachable program must succeed again — if restoration silently
    # failed, this aborts loudly (Rule 1).
    before = _aa_snapshot()
    red = false
    msg = ""
    try
        BennettVM.eval(_AA_MUTATION)
        (red, msg) = _l2_sweep_first_red()
    finally
        n = _aa_restore!(before)
        # n>=1 FIRST: if the mutation eval added no method (signature
        # drift), the cycle is meaningless and GREEN would pass on the
        # untouched original — raise before GREEN can mask it (M8.3
        # ordering).
        n >= 1 || error("M8.5/MUTATION: eval added no inverse method ",
            "(n_deleted=0); cycle meaningless. Check mutation signature.")
        # Post-restore GREEN: re-run a clean full sweep on the first
        # L2-reachable seeded program. invokelatest picks up the
        # restored canonical method.
        let rng = default_rng()
            for i in 1:_N_PROGRAMS
                (vm, inputs, desc) = random_program(rng; size_hint=_SIZE_HINT)
                isempty(BennettVM.compute_must_cache(vm)) && continue
                Base.invokelatest(_sweep_one!, vm, inputs, desc, i)
                break    # one clean L2-reachable program is enough proof
            end
        end
    end
    @test red == true                                  # (a) RED fired
    @test occursin("MISMATCH", msg)                    # (b) the verb
    @test occursin("frames", msg)                      # (c) field named — CW-B2
                                                       # (ADR 0019 §1): the register file
                                                       # moved from the removed `locals`
                                                       # field into `frames`
                                                       # (frames[end].locals), so
                                                       # `_assert_istate_eq` now names the
                                                       # diverged field `frames` (it carries
                                                       # the corrupted register dict). Intent
                                                       # unchanged: the diagnostic names the
                                                       # diverged field.
    @test occursin("M8.5/MUTATION", msg)               # (d) label propagated
end
