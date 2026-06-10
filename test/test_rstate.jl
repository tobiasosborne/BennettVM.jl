# test/test_rstate.jl — M2.3 unit tests for `RState` and the
# `AbstractHistoryEntry` supertype (bd `bennettvm-teu`).
#
# # Why these tests exist
#
# `src/ir/RState.jl` introduces the history-bearing wrapper around
# `IState`. M2.3's exit criterion is "RState and AbstractHistoryEntry
# defined and load without error", but per Rule 4 a passing test
# asserts an invariant against a known-correct value, not just
# "didn't throw". Each `@test` below pins one structural fact about
# the new types that downstream milestones (M3.x forward dispatch;
# M4/M6/M7 concrete history entries) will rely on:
#
#   - `AbstractHistoryEntry` is the supertype reserved for L1/L2/L3
#     entries (PRD v4 §3.3) — concrete subtypes do NOT exist yet
#     (M2.3 must not pre-empt M4/M6/M7).
#   - `RState` wraps an `IState` by reference, not by copy — the
#     `r.current === s` identity assertion below pins this. M3.x's
#     `step!` will mutate `BennettVM.active_locals(s.current)` through the alias.
#   - `RState` is mutable: the `history` field can be reassigned
#     (and, downstream, `push!`/`pop!`'d) in place. We can't yet
#     `push!` a real entry — no concrete `AbstractHistoryEntry`
#     subtype exists at M2.3 — so we exercise mutability via
#     reassignment (option (b) in the bead task description). The
#     `push!`/`pop!` exercise lands when M4/M6/M7 introduce real
#     subtypes.
#   - `Base.==` / `Base.hash` overrides on `RState` (added
#     proactively per Rule 1; mirrors the M2.2 override on `IState`)
#     compare *structurally* across both fields. Without these, the
#     load-bearing `unrun!(run!(s, prog)) == initial(s)` invariant
#     would silently fail when the two `RState`s held distinct
#     `Vector{AbstractHistoryEntry}` instances — the exact Dict-
#     identity trap M2.2 closed for `IState`, one level up the
#     containment hierarchy.
#
# Ref: src/ir/RState.jl (the types under test; full rationale in
#      its docstrings).
# Ref: bennettvm_prd.md §3.9 (RState mutability / fields binding),
#      §3.3 (three history layers).
# Ref: spike/RETROSPECTIVE.md Q1 (RState mutability), Q2.1 (Dict-
#      identity trap that motivates the ==/hash mirror).
# Ref: CLAUDE.md Rule 4 (every @test asserts a specific value).

using Test
using BennettVM

@testset "RState + AbstractHistoryEntry (M2.3)" begin
    # The abstract type exists and is abstract (no concrete instances
    # yet — M4/M6/M7 introduce them).
    @test BennettVM.AbstractHistoryEntry isa Type
    @test isabstracttype(BennettVM.AbstractHistoryEntry)

    s = BennettVM.IState(0, Dict(:x => Int64(1)), :running)
    r = BennettVM.RState(s, BennettVM.AbstractHistoryEntry[])

    # `RState` aliases the underlying `IState` by reference, NOT by
    # copy. M3.x's `step!` will mutate `BennettVM.active_locals(s.current)` in place
    # through this alias; an accidental defensive-copy in the
    # constructor would silently break that loop.
    @test r.current === s
    @test isempty(r.history)

    # `RState` is mutable: prove by reassigning a field. We can't yet
    # `push!` a real entry — no concrete `AbstractHistoryEntry` subtype
    # exists at M2.3 — but `r.history = ...` would error on an
    # immutable struct (Julia raises `setfield!: immutable struct`),
    # so this single line pins the mutability requirement.
    # (Option (b) in the bead's task description; preferred over
    # defining a test-only concrete subtype, which would pre-empt
    # M4/M6/M7.)
    r.history = BennettVM.AbstractHistoryEntry[]
    @test isempty(r.history)

    # Structural equality (proactive M2.2-style override). Two
    # `RState`s built from independently-constructed `IState`s and
    # `Vector{AbstractHistoryEntry}` instances must compare equal —
    # otherwise the round-trip invariant `unrun!(run!(s, prog)) ==
    # initial(s)` would silently never hold. The two `Vector`s are
    # *not* `===`-equal (assert that first so the `==` check is
    # load-bearing); the `IState` `==` override from M2.2 carries
    # the `current` side.
    r2 = BennettVM.RState(
        BennettVM.IState(0, Dict(:x => Int64(1)), :running),
        BennettVM.AbstractHistoryEntry[],
    )
    @test r.history !== r2.history
    @test r.current !== r2.current
    @test r == r2
    @test hash(r) == hash(r2)

    # The override must CATCH real differences (mutation-proof style).
    # Differ in `current`: locals value changed.
    r3 = BennettVM.RState(
        BennettVM.IState(0, Dict(:x => Int64(99)), :running),
        BennettVM.AbstractHistoryEntry[],
    )
    @test r != r3
end
