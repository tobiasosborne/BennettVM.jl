# test/test_arithmetic_assignment.jl — M2.6 unit tests for the
# `ArithmeticAssignment` instruction (bd `bennettvm-lff`).
#
# # What this file pins
#
# `src/ir/arithmetic_assignment.jl` defines the first concrete
# `Instruction` subtype in BennettVM's twelve-class RSSA taxonomy
# (row 1 in `docs/adr/0001-rc3-rvm-smoke.md` §Observations). The
# tests below pin:
#
#   1. **Forward semantics** for each modop (`:xor`, `:add`, `:sub`):
#      a specific input state maps to a specific output state with a
#      hand-computed value (Rule 4: every @test pins a specific
#      value). The XOR case uses bit-pattern operands so the result
#      is verifiable by hand at the bit level.
#   2. **Round-trip invariant** — the load-bearing Phase-2 property:
#      `inverse(forward(s), nothing) == s` for every modop. The
#      `deepcopy(s)` capture before `forward` is what makes the
#      assertion meaningful given `IState`'s mutable struct (otherwise
#      the "before" reference would be aliased to the post-mutation
#      state). This invariant is the bead's exit criterion.
#   3. **Constructor validation** (Rule 1): bad modop and bad op both
#      raise `ErrorException`. The bad-op case includes both `:fadd`
#      (a real FP op that exists in `FP_BINARY_OPERATORS` but is
#      forbidden on the integer arm) and `:nonsense` (a typo), to
#      pin both the integer-only restriction AND the basic typo
#      guard.
#   4. **Constant operands** — `Union{Symbol,Int64}` admits literal
#      `Int64`s as lhs/rhs and they evaluate verbatim.
#   5. **`dual_modop`** — the small helper that flips modops. Pinned
#      separately because `inverse` depends on it; if `dual_modop`
#      breaks, every round-trip test above also breaks, but the
#      diagnostic would be confusing without a direct pin.
#
# # Why a fresh `IState` per testset
#
# `IState` is mutable and `forward` mutates in place. Re-using one
# `IState` across modop cases would tangle the assertions. Each
# testset constructs its own `IState` and uses `deepcopy` to snapshot
# the initial image for the round-trip check.
#
# Ref: src/ir/arithmetic_assignment.jl (the implementation; full
#      rationale in its top-of-module docstring).
# Ref: docs/adr/0001-rc3-rvm-smoke.md §Observations — the modop
#      invertibility decision row that locks {:xor, :add, :sub}.
# Ref: CLAUDE.md Rule 1 (constructor validates inputs), Rule 4 (every
#      @test pins a specific value).

@testset "ArithmeticAssignment :xor (M2.6)" begin
    # x := y XOR (lhs AND rhs) — bitwise example.
    # 0x0f & 0x33 = 0x03; 0xff XOR 0x03 = 0xfc.
    instr = BennettVM.ArithmeticAssignment(:x, :y, :xor, :a, :and, :b)
    s = BennettVM.IState(0,
        Dict(:y => Int64(0xff), :a => Int64(0x0f), :b => Int64(0x33)),
        :running)
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr, s)
    @test s2.locals[:x] == Int64(0xfc)
    @test !haskey(s2.locals, :y)
    @test s2.pc == 1
    # operands a, b survive forward (they are read, not consumed)
    @test s2.locals[:a] == Int64(0x0f)
    @test s2.locals[:b] == Int64(0x33)

    # Round-trip: inverse restores the initial state exactly.
    s3 = BennettVM.inverse(instr, s2, nothing)
    @test s3 == s_before
    @test s3.pc == 0
    @test haskey(s3.locals, :y)
    @test !haskey(s3.locals, :x)
end

@testset "ArithmeticAssignment :add and :sub (M2.6)" begin
    # :add  — x := y + (a * b); 3 * 4 = 12; 10 + 12 = 22.
    instr = BennettVM.ArithmeticAssignment(:x, :y, :add, :a, :mul, :b)
    s = BennettVM.IState(0,
        Dict(:y => Int64(10), :a => Int64(3), :b => Int64(4)),
        :running)
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr, s)
    @test s2.locals[:x] == Int64(22)
    @test !haskey(s2.locals, :y)
    @test s2.pc == 1
    s3 = BennettVM.inverse(instr, s2, nothing)
    @test s3 == s_before

    # :sub — x := y - (a * b); 50 - 12 = 38.
    instr = BennettVM.ArithmeticAssignment(:x, :y, :sub, :a, :mul, :b)
    s = BennettVM.IState(0,
        Dict(:y => Int64(50), :a => Int64(3), :b => Int64(4)),
        :running)
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr, s)
    @test s2.locals[:x] == Int64(38)
    @test !haskey(s2.locals, :y)
    s3 = BennettVM.inverse(instr, s2, nothing)
    @test s3 == s_before
end

@testset "ArithmeticAssignment constructor validation (M2.6)" begin
    # Bad modop — :mul is not in the RC3 ModificationOperator set.
    @test_throws ErrorException BennettVM.ArithmeticAssignment(
        :x, :y, :mul, :a, :add, :b)
    # Bad op — :fadd exists in FP_BINARY_OPERATORS but FP routes
    # through M_FP, not the integer ArithmeticAssignment surface.
    @test_throws ErrorException BennettVM.ArithmeticAssignment(
        :x, :y, :xor, :a, :fadd, :b)
    # Bad op — pure typo.
    @test_throws ErrorException BennettVM.ArithmeticAssignment(
        :x, :y, :xor, :a, :nonsense, :b)
end

@testset "ArithmeticAssignment with constant operands (M2.6)" begin
    # rhs is a literal Int64. a + 1 = 3; 7 XOR 3 = 4.
    instr = BennettVM.ArithmeticAssignment(:x, :y, :xor, :a, :add, Int64(1))
    s = BennettVM.IState(0,
        Dict(:y => Int64(7), :a => Int64(2)),
        :running)
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr, s)
    @test s2.locals[:x] == Int64(7) ⊻ (Int64(2) + Int64(1))
    @test s2.locals[:x] == Int64(4)
    @test !haskey(s2.locals, :y)
    s3 = BennettVM.inverse(instr, s2, nothing)
    @test s3 == s_before
end

@testset "dual_modop (M2.6)" begin
    @test BennettVM.dual_modop(:xor) === :xor
    @test BennettVM.dual_modop(:add) === :sub
    @test BennettVM.dual_modop(:sub) === :add
    @test_throws ErrorException BennettVM.dual_modop(:mul)
    @test_throws ErrorException BennettVM.dual_modop(:nonsense)
end
