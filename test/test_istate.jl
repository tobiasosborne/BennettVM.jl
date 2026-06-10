# test/test_istate.jl — M2.2 unit tests for `IState`'s `==` / `hash`
# overrides (bd `bennettvm-6b4`).
#
# # Why these tests exist
#
# `src/ir/IState.jl` overrides `Base.==` and `Base.hash` to make `IState`
# values comparable by *content*, not by `Dict`-instance identity. The
# motivating failure is documented in `spike/RETROSPECTIVE.md` Q2.1:
# two `IState`s with bit-identical `pc` / `status` / `locals` *content*
# but distinct `Dict` instances would compare unequal under Julia's
# default field-by-field comparison if that fallback ever drifted from
# the `Dict`-aware `==` we now pin. The load-bearing round-trip
# invariant `unrun!(run!(s, prog)) == initial(s)` rests on this being
# *content* equality; if M2.2's override silently regresses, every
# M3.x round-trip test that follows it gives a false positive.
#
# Each `@test` below pins a specific structural fact — per Rule 4
# ("'Runs without errors' is not a passing test"). The most load-
# bearing one is the `haskey(d, s2)` check at the end of the testset:
# it forces `==` *and* `hash` to be consistent with each other, which
# is the single fact that makes `IState` safe as a `Dict` key /
# `Set` element in any later interpreter code.
#
# Ref: src/ir/IState.jl (the override; full rationale in its
#      docstring).
# Ref: spike/RETROSPECTIVE.md Q2.1 (the Dict-identity trap).
# Ref: bennettvm_prd.md §3.10 (override is unconditional).
# Ref: CLAUDE.md Rule 4 (every @test asserts a specific value).

using Test
using BennettVM

@testset "IState ==, hash (M2.2)" begin
    # Two states with bit-identical content but distinct Dict instances.
    s1 = BennettVM.IState(0, Dict(:x => Int64(1), :y => Int64(2)), :running)
    s2 = BennettVM.IState(0, Dict(:x => Int64(1), :y => Int64(2)), :running)

    # The spike Q2.1 trap: the underlying Dicts are *not* the same
    # object. If they happened to be (`===`-equal), the test below
    # would be vacuous — so we assert distinctness first to make the
    # ==/hash invariants load-bearing.
    @test BennettVM.active_locals(s1) !== BennettVM.active_locals(s2)
    @test s1 == s2                  # structural ==.
    @test hash(s1) == hash(s2)      # hash contract: a == b ⟹ hash(a) == hash(b).

    # Verify the override CATCHES real differences (mutation-proof
    # style: perturb one field at a time, confirm RED).

    # locals value differs.
    s3 = BennettVM.IState(0, Dict(:x => Int64(1), :y => Int64(99)), :running)
    @test s1 != s3
    # Hash inequality for distinct small Int values is probabilistic
    # in principle but deterministic for the specific values used
    # here under Julia's current `hash(::Int, ::UInt)` implementation.
    # If this ever fires, either Julia's Int-hashing changed or we
    # genuinely hit a collision — either is a signal worth surfacing.
    @test hash(s1) != hash(s3)

    # status differs.
    s4 = BennettVM.IState(0, Dict(:x => Int64(1), :y => Int64(2)), :halted)
    @test s1 != s4

    # pc differs.
    s5 = BennettVM.IState(1, Dict(:x => Int64(1), :y => Int64(2)), :running)
    @test s1 != s5

    # The load-bearing test: use `IState` as a `Dict` key. `haskey`
    # routes through `hash` to find the bucket, then `==` to confirm
    # the match. If either override is off, this assertion goes RED —
    # so this single line stress-tests the ==/hash contract together,
    # not just each side in isolation.
    d = Dict{BennettVM.IState, Int}(s1 => 1)
    @test haskey(d, s2)
    @test d[s2] == 1
end

# # Why this second testset exists (M2.11 prep)
#
# M2.11 (`bennettvm-jew`) adds a `memory::Dict{Int64,Int64}` field to
# `IState` so the three memory instructions (`MemoryAssignment` M2.11,
# `MemoryExchange` M2.12, `MemorySwap` M2.13) have a heap to mutate.
# The field is **content-equality-participating** by the same rule as
# `locals`: distinct `Dict` instances with bit-identical key/value
# content must compare `==` and hash to the same `UInt`. The tests
# below pin that contract, and additionally pin:
#
#   1. The 3-arg constructor still works (every M2.1–M2.10 call site
#      that passes only `pc, locals, status` continues to compile and
#      receives an empty memory — backwards compatibility).
#   2. The 4-arg constructor accepts an explicit `Dict{Int64,Int64}`
#      and stores it verbatim.
#   3. `==` / `hash` respect memory content (the M2.2 rationale
#      generalised to the heap field).
#
# Ref: src/ir/IState.jl — the `memory` field docstring paragraph and
#      the dual 3-arg / 4-arg inner constructors.
# Ref: docs/adr/0001-rc3-rvm-smoke.md §Observations row 3 (`MemAssign`,
#      the first instruction to touch memory).
# Ref: CLAUDE.md Rule 4 — every @test pins a specific value.
@testset "IState memory field (M2.11 prep)" begin
    # 3-arg constructor: memory defaults to empty.
    s1 = BennettVM.IState(0, Dict(:x => Int64(1)), :running)
    @test s1.memory isa Dict{Int64,Int64}
    @test isempty(s1.memory)

    # 4-arg constructor: explicit populated memory survives intact.
    m = Dict{Int64,Int64}(100 => 42, 200 => 99)
    s2 = BennettVM.IState(0, Dict(:x => Int64(1)), :running, m)
    @test s2.memory == m

    # == respects memory content (the spike-Q2.1 Dict-identity rule
    # generalised to the heap field). `copy(m)` is the load-bearing
    # call: distinct Dict instances with identical content.
    s3 = BennettVM.IState(0, Dict(:x => Int64(1)), :running, copy(m))
    @test s2.memory !== s3.memory   # Distinct instances ...
    @test s2 == s3                   # ... but content-equal IStates.
    @test hash(s2) == hash(s3)       # ... and consistent hash.

    # Mutation-proof: differing memory content makes IStates unequal.
    s4 = BennettVM.IState(0, Dict(:x => Int64(1)), :running, Dict{Int64,Int64}())
    @test s2 != s4
end
