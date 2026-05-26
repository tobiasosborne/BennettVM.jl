# test/test_swap_instruction.jl — M2.7 unit tests for the
# `SwapInstruction` instruction (bd `bennettvm-ti3`).
#
# # What this file pins
#
# `src/ir/swap_instruction.jl` defines the second concrete
# `Instruction` subtype in BennettVM's twelve-class RSSA taxonomy
# (row 2 in `docs/adr/0001-rc3-rvm-smoke.md` §Observations) — the
# RC3 four-field `x, y := z, w` register-exchange form. The tests
# below pin:
#
#   1. **Forward semantics** for the four-field form: source1's
#      value lands at target1, source2's value lands at target2,
#      both sources are deleted, both targets are created, `pc`
#      bumps by 1 (Rule 4 — every @test pins a specific value).
#   2. **Round-trip invariant** — the load-bearing Phase-2 property
#      for injective instructions: `inverse(forward(s), nothing)
#      == s`. The `deepcopy(s)` snapshot before `forward` makes the
#      assertion meaningful given `IState`'s mutability; the
#      assertion uses the content-comparing `Base.==` overridden
#      in M2.2.
#   3. **Constructor validation** (Rule 1): the three degenerate
#      cases — `target1 === target2`, `source1 === source2`, and
#      target/source name overlap — all raise `ErrorException`.
#   4. **Injectivity property** — sweep representative `(a, b)`
#      pairs (incl. `Int64` boundary values) and confirm forward
#      moves the values to the named targets and inverse restores
#      the exact pre-state. This is the "no history needed"
#      observable contract: the inverse is structurally
#      reconstructible, irrespective of the specific integer
#      contents.
#
# # Why a fresh `IState` per testset
#
# `IState` is mutable and `forward`/`inverse` mutate in place.
# Each testset constructs its own `IState` and uses `deepcopy` to
# snapshot the initial image for the round-trip check, matching
# the convention established in `test_arithmetic_assignment.jl`.
#
# Ref: src/ir/swap_instruction.jl (the implementation; full
#      rationale in its top-of-module docstring).
# Ref: docs/adr/0001-rc3-rvm-smoke.md §Observations row 2 — the
#      RC3 four-field form and self-inverse decision.
# Ref: CLAUDE.md Rule 1 (constructor validates inputs), Rule 4
#      (every @test pins a specific value).

@testset "SwapInstruction forward + round-trip (M2.7)" begin
    instr = BennettVM.SwapInstruction(:x, :y, :z, :w)
    s = BennettVM.IState(0,
        Dict(:z => Int64(11), :w => Int64(22)),
        :running)
    s_before = deepcopy(s)

    s2 = BennettVM.forward(instr, s)
    @test s2.locals[:x] == 11
    @test s2.locals[:y] == 22
    @test !haskey(s2.locals, :z)
    @test !haskey(s2.locals, :w)
    @test s2.pc == 1

    s3 = BennettVM.inverse(instr, s2, nothing)
    @test s3 == s_before
    @test s3.pc == 0
    @test s3.locals[:z] == 11
    @test s3.locals[:w] == 22
    @test !haskey(s3.locals, :x)
    @test !haskey(s3.locals, :y)
end

@testset "SwapInstruction constructor validation (M2.7)" begin
    # target1 === target2 — would lose one source value.
    @test_throws ErrorException BennettVM.SwapInstruction(:x, :x, :z, :w)
    # source1 === source2 — would leave one target uninitialised.
    @test_throws ErrorException BennettVM.SwapInstruction(:x, :y, :z, :z)
    # SSA single-assignment violation — target1 reuses a source name.
    @test_throws ErrorException BennettVM.SwapInstruction(:x, :y, :x, :w)
    # SSA single-assignment violation — target2 reuses a source name.
    @test_throws ErrorException BennettVM.SwapInstruction(:x, :y, :z, :y)
    # SSA single-assignment violation — target1 reuses source2.
    @test_throws ErrorException BennettVM.SwapInstruction(:x, :y, :z, :x)
    # SSA single-assignment violation — target2 reuses source1.
    @test_throws ErrorException BennettVM.SwapInstruction(:x, :y, :y, :w)
end

@testset "SwapInstruction injectivity property (M2.7)" begin
    # The "no history needed" property: forward moves values to the
    # named targets and inverse reconstructs the initial state
    # exactly, irrespective of the specific integer contents. Sweep
    # representative pairs including Int64 boundary values to pin
    # that the property holds without any value-specific code path.
    for (a, b) in [(0, 0), (1, 2), (-5, 17),
                   (typemax(Int64), typemin(Int64))]
        instr = BennettVM.SwapInstruction(:p, :q, :u, :v)
        s = BennettVM.IState(0,
            Dict(:u => Int64(a), :v => Int64(b)),
            :running)
        s_before = deepcopy(s)
        s2 = BennettVM.forward(instr, s)
        @test s2.locals[:p] == a
        @test s2.locals[:q] == b
        @test !haskey(s2.locals, :u)
        @test !haskey(s2.locals, :v)
        s3 = BennettVM.inverse(instr, s2, nothing)
        @test s3 == s_before
    end
end
