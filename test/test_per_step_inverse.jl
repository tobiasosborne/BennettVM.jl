# test/test_per_step_inverse.jl — M8.2 (bd `bennettvm-3d8`).
#
# # Why a scaffold, not another one-off testset
#
# `test/test_roundtrip.jl` already pins the per-step inverse pattern
# (PRD v4 §3.13) — but only for `countdown_program(5)` with K=4
# (the M4.5 capstone). `test/test_zero_history_roundtrip.jl` and
# `test/test_delta_roundtrip.jl` each repeat the same forward-snapshot
# + walk-back loop with subtle parameter tweaks (different programs,
# different K, different must_cache_set). Five copies of the same
# four-line body — capture / step!, deepcopy snapshot, unstep!, assert
# equality — across five test files, each diverging slightly in the
# kwargs handed to `step!` / `unstep!`. That copy-paste is the
# precondition for an off-by-one to creep in unnoticed and is exactly
# what M8.3 (`bennettvm-2kl`, mutation-proof harness), M8.4
# (`bennettvm-bii`, seeded random program generator), and M8.5
# (`bennettvm-tnp`, 100-random-programs property test) are about to
# multiply by 100×.
#
# M8.2 therefore hoists the per-step inverse pattern into a single
# parameterized check function — `per_step_inverse_check` — that the
# rest of the M8 family invokes. The contract:
#
#   1. Forward-sweep `vm` step-by-step on `inputs`, capturing a
#      `deepcopy(rs.current)` after each `step!`. Index by `step_count`
#      so `forward_snapshots[k]` is the state immediately after step k.
#
#   2. Backward-sweep via `unstep!`, asserting after each step that
#      `rs.current == forward_snapshots[rs.step_count]` (mid-sweep) or
#      `rs.current == initial_current` (at step 0). On mismatch, raise
#      `ErrorException` whose message names the **step index** and the
#      **offending IState field** (`pc`, `locals`, `status`, `memory`).
#
# # Why this API surface (kwargs, not Strategy pattern)
#
# Two kwargs cover the entire M7-aware surface:
#
#   * `checkpoint_interval::Int=4` — the M4.2 L3 push period. K=4 is
#     the M4.5 canonical; K=1 and K=typemax(Int) are the two endpoints
#     M6.4 / M7.7 already exercise to pin "every step pushes" and
#     "no step ever pushes". The driver-layer testsets below sweep
#     all three.
#
#   * `must_cache_set::Set{Tuple{Symbol,Int}} = ∅` — the M7.6 L2 gate
#     selector. Required: without it, the scaffold cannot exercise the
#     delta-history path that M7.4's `unstep!` fast-path inverts. The
#     empty default makes the scaffold M7-transparent (an M4-only
#     setup is the empty-set case, just like `step!` itself).
#
# Plus one purely-cosmetic kwarg:
#
#   * `label::AbstractString` — woven into mismatch messages and the
#     wrapping `@testset` for human-readable diagnostics. NOT a
#     functional control.
#
# `replay_mode` is deliberately NOT exposed: it is an internal kwarg
# set by `unstep!`'s replay loop (Replay.jl line ~480), never something
# the caller sets directly on the forward sweep. Per CLAUDE.md Rule 1,
# we keep the failure surface narrow.
#
# A struct + method shape was considered (per the M8.2 brief's
# "struct + method" allowance) and rejected: two kwargs and one label
# fit inside a function signature without ceremony; introducing a
# `PerStepInverseCheck` struct would be five fields where two kwargs
# suffice, violating the brief's "don't over-engineer" guidance and
# Rule 11 (a function is self-documenting; a struct demands its own
# constructor docstring + a separate `run` method).
#
# # Why the N and K choices below
#
#   * `N ∈ {0, 3, 5}`:
#       - N=0 exercises the entry-block-direct-to-done path
#         (countdown_program(0) has a single decrement-free :b_start →
#         :b_done chain). REPL-verified step trace: step 1 =
#         `BeginInstruction` (pc 1 → 2), step 2 = `UnconditionalExit`
#         from :b_start (pc 2 → 4, crossing into :b_done), step 3 =
#         `UnconditionalEntry` of :b_done followed by `EndInstruction`
#         flipping status to :halted (pc 4 → 5). Final `step_count`
#         terminates at **3**, not 2 — the entry+end pair in :b_done
#         is dispatched in a single `step!` call once the entry has
#         consumed the cross-block dispatch arg (M3.5 routing).
#       - N=3 is the smallest non-trivial size with cross-block
#         dispatch on both forward AND replay branches (3 decrement
#         blocks → 12 steps; matches the M7.7 per-step inverse fixture
#         at `test_delta_roundtrip.jl:399`).
#       - N=5 is the M4.5 anchor (`test_roundtrip.jl:202`); the
#         scaffold MUST replicate its behavior on the same fixture or
#         the cross-validation oracle (Rule 5, port-and-verify) has
#         not been met.
#
#   * `K ∈ {1, 4, typemax(Int)}`:
#       - K=1: push every step → M4.3's nearest-checkpoint search
#         always finds the checkpoint exactly at target.
#       - K=4: M4.5 canonical → mixed at-target / fall-through cases.
#       - K=typemax(Int): never push → M4.3 always falls through to
#         `s.initial`. The most adversarial K for the L3 fallback path.
#
# # Why a failure-mode assertion (`@testset "useful failure mode"`)
#
# A scaffold whose error message names the step index and offending
# field is a contract, not a side-effect. Without an explicit test
# pinning the message format, a future refactor could simplify the
# error to a bare "mismatch" string — M8.3's mutation-proof harness
# would then report regressions without pointing at the step that
# failed, and M8.5's 100-program sweep would degenerate to "some
# program failed". The failure-mode testset wraps the scaffold around
# pre-captured `forward_snapshots` whose middle entry has been
# manually corrupted, and asserts (a) `ErrorException` is raised,
# (b) the message contains the step index of the corruption, and
# (c) the message contains the name of the corrupted field. This
# pins the diagnostic surface itself.
#
# To enable (b) and (c) without depending on a real production bug,
# the scaffold accepts an OPTIONAL `_forward_snapshots_override` kwarg
# (underscore-prefixed: private API, test-only). When supplied, the
# scaffold skips the forward sweep and uses the override as the
# expected-snapshots vector during the backward walk. The failure-
# mode testset uses this to inject a corrupted vector and exercise
# the diagnostic path.
#
# # Mutation-proof evidence (Rule 5, port-and-verify): which path the
# # countdown / K=4 testset actually exercises, and which it does NOT
#
# The countdown(5)/K=4 driver-layer testset replicates the exact
# round-trip-equality body of M4.5's load-bearing test 4
# (`test/test_roundtrip.jl:289`), but the per-instruction `inverse()`
# methods are NOT what either test exercises on that fixture. The
# reason is architectural: when `must_cache_set` is empty (the M4.5
# default and the spike-default), the M7.6 L2-push gate never fires,
# so no `DeltaEntry` ever sits on `rs.history` for `unstep!` to invert
# via the M7.4 fast-path (which IS the per-instruction `inverse()`
# call site). Every backward step therefore falls through to the M4.3
# L3 path in `src/history/Replay.jl`, which works by reading the
# nearest `CheckpointEntry`'s snapshot, deepcopying it into
# `rs.current`, and **replaying `forward()` step-by-step** — never
# calling any `inverse()` method. A no-op'd
# `inverse(::ArithmeticAssignment, ...)` therefore leaves both
# countdown(N)/empty-must_cache testsets GREEN; the same regression
# only fires when the L2 path is actually driven (`must_cache_set` is
# non-empty, M7.7's `compute_must_cache(vm)` populated).
#
# M4.5 inherits the same architectural blind spot — round-trip
# correctness via L3 forward-replay is a real invariant, but it is a
# DISTINCT invariant from per-instruction `inverse()` correctness, and
# the two must be tested by distinct paths. The M8.3 mutation-proof
# harness (`bennettvm-2kl`) is the systematic per-instruction
# `inverse()` audit; M8.2's job is to lay down the scaffold so that
# audit becomes mechanical. To ensure the M4.5 anchor *does* drive
# the L2 path at least once, the M7-delta testset below extends the
# M7.7-style coverage from countdown(3) to countdown(5)/K=4 with
# `must_cache_set = compute_must_cache(vm)` — that variant pins the
# L2 path on the M4.5 fixture. The countdown(N)/empty-must_cache
# variant is retained because pinning L3 correctness on its own is
# also a separate invariant worth pinning (the L1/L2/L3 layering of
# `src/history/Replay.jl` is the binding source for this split).
#
# The failure-mode testset additionally mutation-proofs the
# diagnostic surface itself: a synthesised mid-snapshot corruption
# MUST be caught and reported by step index + field name.
#
# # Ref
#
#   * `bennettvm_prd.md` (PRD v4) §3.13 (round-trip / per-step inverse
#     invariant); §3.15 (property-test discipline; M8 family bind).
#   * `spike/RETROSPECTIVE.md` Q4 §"Test patterns worth keeping" —
#     the per-step inverse pattern's origin lesson.
#   * `test/test_roundtrip.jl` lines 49-151 (M4.5 docstring on the
#     per-step inverse pattern) and lines 289-342 (M4.5 test 4, the
#     load-bearing per-step inverse test the scaffold generalizes).
#   * `test/test_zero_history_roundtrip.jl` (M6.4) — analogue at the
#     L1 layer; the scaffold absorbs its per-step loop too.
#   * `test/test_delta_roundtrip.jl` lines 399-442 (M7.7) — analogue
#     at the L2 layer with must_cache_set populated.
#   * `bd bennettvm-3d8` (M8.2) — this milestone; blocks M8.3 / M8.4 /
#     M8.5.
#   * CLAUDE.md Rule 1 (fail loud, descriptive); Rule 4 (every test
#     asserts against a known-correct value, here the captured
#     forward snapshot); Rule 5 (mutation-proof, port-and-verify);
#     Rule 10 (≤200 LOC); Rule 11 (literate docstring).

using Test
using BennettVM

include(joinpath(@__DIR__, "reference", "countdown.jl"))

# ---------------------------------------------------------------------
# The scaffold
# ---------------------------------------------------------------------

"""
    per_step_inverse_check(vm::VMProgram, inputs::Dict{Symbol,Int64};
                           checkpoint_interval::Int = 4,
                           must_cache_set::Set{Tuple{Symbol,Int}} =
                               Set{Tuple{Symbol,Int}}(),
                           label::AbstractString = "per_step_inverse_check",
                           _forward_snapshots_override::Union{
                               Nothing,Vector{BennettVM.IState}} = nothing)
        -> Nothing

Drive the per-step inverse pattern (PRD v4 §3.13) on `vm` with `inputs`.

Forward-sweeps the program one `step!` at a time, capturing a
deepcopy of `rs.current` after each step. Then backward-sweeps via
`unstep!`, asserting after EACH unstep that `rs.current` equals the
captured forward snapshot at the new `step_count` (or the initial
state, at step 0). Raises `ErrorException` on mismatch with a message
naming the step index AND the offending IState field
(`pc` / `locals` / `status` / `memory`).

Returns `nothing` on success. See the file-level docstring for the
rationale on the API surface (why kwargs, not a struct; why these
defaults; why the failure-mode contract is mandatory).

The `_forward_snapshots_override` kwarg is private (test-only): when
supplied, the forward sweep is skipped and the override is used as
the expected snapshots for the backward walk. This exists ONLY so the
file's "useful failure mode" testset can inject a deliberately-
corrupted snapshot to mutation-proof the diagnostic surface.

# Semantic difference: override path uses `run!`, normal path uses a `step!` loop

The override branch calls `run!(rs, vm; …)` (bulk-forward driver,
M3.4) to populate `rs.history` and advance `rs.step_count` to the
halted-program total in one call, whereas the normal branch loops
`step!` per iteration to capture a snapshot after each step. The two
are *behaviorally* equivalent under the current `step!` /  `run!`
contract on every test we drive (`run!` is documented as
`while !is_halted(rs); step!(rs, vm; kw…); end` modulo the
`max_steps` guard), but they differ in how the intermediate
`rs.history` shape is observable from outside the loop. The override
path is safe for the M8.2 use case because the diagnostic check we
care about runs entirely on the BACKWARD walk; the override only
controls what `rs.current` is compared *against* during that walk,
not what `rs.history` contains or what `unstep!` actually does. Any
correctness divergence between `run!` and a `step!`-loop on the
forward sweep would surface as a separate test failure in
`test_interpreter.jl` / `test_forward_interpreter.jl`, where that
equivalence IS the load-bearing invariant.
"""
function per_step_inverse_check(
        vm::VMProgram, inputs::Dict{Symbol,Int64};
        checkpoint_interval::Int = 4,
        must_cache_set::Set{Tuple{Symbol,Int}} =
            Set{Tuple{Symbol,Int}}(),
        label::AbstractString = "per_step_inverse_check",
        _forward_snapshots_override::Union{
            Nothing,Vector{BennettVM.IState}} = nothing)
    rs = initial_state(vm, inputs)
    initial_current = deepcopy(rs.current)

    # Forward sweep: capture post-step snapshots indexed by step_count.
    # When the private override is supplied, skip the forward sweep and
    # use the override directly — but still drive forward to populate
    # rs.history / rs.step_count so unstep! has something to consume.
    forward_snapshots = if _forward_snapshots_override === nothing
        snaps = BennettVM.IState[]
        while !is_halted(rs)
            step!(rs, vm;
                  checkpoint_interval=checkpoint_interval,
                  must_cache_set=must_cache_set)
            push!(snaps, deepcopy(rs.current))
        end
        snaps
    else
        # Override path: still run forward (so unstep! has state to
        # consume) but use the caller's snapshots as the source of truth.
        run!(rs, vm;
             checkpoint_interval=checkpoint_interval,
             must_cache_set=must_cache_set)
        _forward_snapshots_override
    end

    # Backward sweep: unstep! one at a time, asserting equality with
    # forward_snapshots[step_count] (mid) or initial_current (bottom).
    while rs.step_count > 0
        prev_count = rs.step_count
        unstep!(rs, vm)
        rs.step_count == prev_count - 1 ||
            error("[$label] unstep!: step_count went $prev_count → ",
                  "$(rs.step_count); expected $(prev_count - 1)")
        expected = rs.step_count > 0 ?
            forward_snapshots[rs.step_count] : initial_current
        _assert_istate_eq(rs.current, expected, rs.step_count, label)
    end

    # Post-sweep RState-embedded-initial check. The bottom-of-loop
    # `_assert_istate_eq(rs.current, initial_current, …)` above
    # compares against the locally-captured deepcopy of `rs.current`
    # taken at entry. This second check compares against `rs.initial`
    # — the RState's embedded step-0 snapshot read by M4.3's L3
    # fallback path. Distinct bug classes:
    #
    #   * `initial_current` divergence catches a backward-walk
    #     correctness bug (the unstep!/inverse chain left rs.current
    #     at a state different from where we started).
    #   * `rs.initial` divergence catches an `rs.initial`-mutation
    #     bug — a regression that mid-sweep aliased `rs.initial` to
    #     `rs.current` (skipping the M4.3 deepcopy at the L3 restore
    #     site, `src/history/Replay.jl:385`), causing the embedded
    #     step-0 snapshot to drift as forward replays mutated
    #     `rs.current` in place. M4.5's `test_roundtrip.jl:334`
    #     pins this distinct invariant via `@test rs.current ==
    #     rs.initial`; the scaffold mirrors it here.
    #
    # Both checks coexist by design — neither subsumes the other.
    rs.current == rs.initial || error(
        "[$label] post-sweep rs.current != rs.initial: the RState's ",
        "embedded step-0 snapshot diverged from the backward-walked ",
        "current state. This indicates an `rs.initial`-mutation bug ",
        "(M4.3's L3 deepcopy at `src/history/Replay.jl:385` may have ",
        "been elided, allowing replay forward steps to mutate the ",
        "embedded initial in place). Distinct from the local ",
        "`initial_current` deepcopy check above. ",
        "rs.initial=", repr(rs.initial), " rs.current=", repr(rs.current))

    # Final structural invariants. Phrased as descriptive raises (not
    # @test) so a non-Test consumer (M8.3's mutation harness) sees the
    # same fail-fast behavior the per-step inner loop has.
    rs.step_count == 0 ||
        error("[$label] post-sweep step_count=$(rs.step_count); ",
              "expected 0")
    isempty(rs.history) ||
        error("[$label] post-sweep history non-empty: ",
              "length=$(length(rs.history))")
    return nothing
end

"""
    _assert_istate_eq(actual, expected, step_idx, label) -> Nothing

Per-field comparison of two IStates. On mismatch, raise
ErrorException whose message contains BOTH the step index AND the
field name. This is the diagnostic contract M8.3/M8.4/M8.5 depend on.

Iterating `fieldnames(BennettVM.IState)` so a future-added field is
included automatically. Rule 11 (no silent gaps in coverage).
"""
function _assert_istate_eq(actual::BennettVM.IState,
                           expected::BennettVM.IState,
                           step_idx::Int, label::AbstractString)
    for f in fieldnames(BennettVM.IState)
        a = getfield(actual, f)
        e = getfield(expected, f)
        a == e || error(
            "[$label] per-step inverse MISMATCH at step ",
            step_idx, ": IState field `", f, "` diverged. ",
            "expected=", repr(e), " actual=", repr(a))
    end
    return nothing
end

# ---------------------------------------------------------------------
# A small all-injective program for the M6 / L1 path
# ---------------------------------------------------------------------

"""
    _psi_swap_only_program() -> (VMProgram, Dict{Symbol,Int64})

Single-block all-injective program: Begin + 1 SwapInstruction + End.
Five total dispatched steps; under the M6.2 L1 gate every step is
push-suppressed, so the scaffold exercises the `s.initial` fallback
path in Replay.jl on every backward step. Mirrors M6.4's
`_swap_chain_program` but trimmed to the minimum exercise.
"""
function _psi_swap_only_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:a, :b]),
        BennettVM.Instruction[
            BennettVM.SwapInstruction(:p, :q, :a, :b),
        ],
        BennettVM.EndInstruction(:m, [:p, :q]))
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64, 64], [64, 64])
    return vm, Dict(:a => Int64(11), :b => Int64(22))
end

# ---------------------------------------------------------------------
# Driver-layer testsets
# ---------------------------------------------------------------------

@testset "M8.2 — scaffold on countdown(N) across K ∈ {1, 4, typemax}" begin
    # Cross-validation: countdown(5)/K=4 must replicate the M4.5 test
    # 4 behavior (port-and-verify oracle per Rule 5). The other
    # combinations sweep the M4 L3 endpoints (K=1 dense, K=typemax
    # pure-replay) across the N ∈ {0, 3, 5} program-shape spectrum
    # described in the file docstring.
    for N in (0, 3, 5)
        for K in (1, 4, typemax(Int))
            vm = countdown_program(N)
            inputs = Dict(:n0 => Int64(N), :steps0 => Int64(0))
            @test per_step_inverse_check(vm, inputs;
                checkpoint_interval=K,
                label="countdown($N) K=$K") === nothing
        end
    end
end

@testset "M8.2 — scaffold under M7 delta-history path (must_cache populated)" begin
    # Drive the scaffold with `must_cache_set = compute_must_cache(vm)`
    # so M7.6's L2 branch fires on every non-injective step. The
    # `unstep!` backward walk MUST consume DeltaEntries via M7.4's
    # fast-path; if the scaffold's diagnostic-on-mismatch contract is
    # sound, any L2 inversion bug would surface as a step-indexed
    # error from `_assert_istate_eq`, not a generic mismatch. N=3 is
    # the M7.7 fixture size (test_delta_roundtrip.jl:399).
    vm3 = countdown_program(3)
    inputs3 = Dict(:n0 => Int64(3), :steps0 => Int64(0))
    set3 = BennettVM.compute_must_cache(vm3)
    @test length(set3) == 6   # 3 blocks × 2 non-inj body steps
    @test per_step_inverse_check(vm3, inputs3;
        checkpoint_interval=typemax(Int),    # suppress L3 entirely
        must_cache_set=set3,
        label="countdown(3) L2 only") === nothing

    # M4.5-anchor L2 coverage: countdown(5)/K=4 with `must_cache_set`
    # populated. The empty-must_cache countdown(5)/K=4 testset above
    # exercises ONLY the L3 forward-replay path (see file docstring
    # §"Mutation-proof evidence"); this variant pins the L2 path on
    # the SAME M4.5 fixture so the per-instruction `inverse()`
    # methods (`src/ir/arithmetic_assignment.jl:220`, the M7.4
    # NamedTuple specialisation at line ~297) are actually called
    # during the backward walk. Without this, a no-op'd
    # `inverse(::ArithmeticAssignment, ...)` would leave the
    # M4.5-anchor testsets GREEN — the M8.2 scaffold's worst
    # failure mode pre-fix. K=4 is retained (not `typemax(Int)`) for
    # symmetry with the M4.5 anchor fixture; empirically the
    # populated must_cache_set drives every push through the L2 path
    # (10 DeltaEntries, 0 CheckpointEntries on countdown(5)) because
    # the L1 gate filters injective boundary steps to no-push and
    # the L2 gate captures the non-injective body steps before L3
    # would see them. The L3 K=4 setting therefore degenerates to a
    # documentation marker on this fixture, which is fine — the
    # purpose is L2 inversion coverage, and the K choice keeps the
    # call shape identical to the M4.5 anchor for the diff-on-call-
    # site readability M8.3 will exploit.
    vm5 = countdown_program(5)
    inputs5 = Dict(:n0 => Int64(5), :steps0 => Int64(0))
    set5 = BennettVM.compute_must_cache(vm5)
    @test length(set5) == 10  # 5 blocks × 2 non-inj body steps
    @test per_step_inverse_check(vm5, inputs5;
        checkpoint_interval=4,
        must_cache_set=set5,
        label="countdown(5) K=4 L2") === nothing
end

@testset "M8.2 — scaffold under M6 zero-history path (all-injective)" begin
    # Drive the scaffold on a program whose every step is M6.1-
    # injective. The L1 gate at the push site suppresses ALL pushes;
    # every backward `unstep!` must succeed via Replay.jl's
    # `s.initial` fallback. Pinned across both K=1 (aggressive push
    # regime that the L1 gate must override) and K=typemax(Int)
    # (passive regime where L1 and L3 agree on "no push").
    for K in (1, typemax(Int))
        vm, inputs = _psi_swap_only_program()
        @test per_step_inverse_check(vm, inputs;
            checkpoint_interval=K,
            label="swap-only K=$K") === nothing
    end
end

@testset "M8.2 — scaffold reports step index + field on mismatch" begin
    # THE diagnostic-contract testset. Capture a valid forward
    # snapshot vector from countdown(3)/K=4, deliberately corrupt the
    # middle snapshot's `:n2` local, re-invoke the scaffold with the
    # private override, and assert (a) ErrorException is raised,
    # (b) the message contains "step <K>" where K is the corruption
    # site, AND (c) the message contains the field name `locals`.
    # Without this assertion, the scaffold's error message format is
    # an undocumented side-effect; with it, M8.3 / M8.4 / M8.5 can
    # rely on the diagnostic surface as a stable contract.
    vm = countdown_program(3)
    inputs = Dict(:n0 => Int64(3), :steps0 => Int64(0))

    # Capture the valid forward snapshots by running the scaffold's
    # forward half by hand.
    rs0 = initial_state(vm, inputs)
    snaps = BennettVM.IState[]
    while !is_halted(rs0)
        step!(rs0, vm; checkpoint_interval=4)
        push!(snaps, deepcopy(rs0.current))
    end
    @test length(snaps) == 12      # countdown(3): 3*3 + 3 = 12

    # Corrupt the snapshot at step 6 (mid-sweep, post-second-decrement-
    # block, well clear of edge-of-sweep effects). The countdown(3)
    # trace at step 6 has locals=[:n2, :steps1] (verified empirically;
    # cf. M3.8's countdown trace and the per-step layout in
    # `test/reference/countdown.jl`'s `_decrement_block` docstring) —
    # so :n2 is the natural pin for the corruption fixture.
    corrupted_step = 6
    snaps[corrupted_step] = deepcopy(snaps[corrupted_step])
    @assert haskey(BennettVM.active_locals(snaps[corrupted_step]), :n2) "fixture drift: " *
            "countdown(3) snapshot at step 6 should contain :n2; " *
            "scaffold-mismatch fixture needs updating"
    BennettVM.active_locals(snaps[corrupted_step])[:n2] = Int64(-999_999_999)

    err = try
        per_step_inverse_check(vm, inputs;
            checkpoint_interval=4,
            label="MISMATCH_FIXTURE",
            _forward_snapshots_override=snaps)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("step $corrupted_step", err.msg)   # (b) step index
    @test occursin("frames", err.msg)                  # (c) field name — CW-B2
                                                        # (ADR 0019 §1): the register
                                                        # file moved from the removed
                                                        # `locals` field into `frames`
                                                        # (frames[end].locals), so the
                                                        # diverged-field name reported by
                                                        # `_assert_istate_eq` is now
                                                        # `frames` (which contains the
                                                        # corrupted register dict). Intent
                                                        # unchanged: the error names the
                                                        # diverged field.
    @test occursin("MISMATCH_FIXTURE", err.msg)        # label propagation
    @test occursin("MISMATCH", err.msg)                # the literal verb
end
