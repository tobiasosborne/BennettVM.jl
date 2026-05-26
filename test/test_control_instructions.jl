# test/test_control_instructions.jl — M2.8 unit tests for
# `BeginInstruction` and `EndInstruction` (bd `bennettvm-n3c`).
#
# # What this file pins
#
# `src/ir/control_instructions.jl` defines the first two concrete
# `ControlInstruction` subtypes (rows 7 and 8 of
# `docs/adr/0001-rc3-rvm-smoke.md` §Observations) — the RC3
# subroutine-entry / subroutine-exit markers. Per the scoping
# decision recorded in the source file's top-of-module docstring,
# the dispatch-level semantics are pc-only: forward bumps `pc` by
# 1, inverse decrements `pc` by 1, and `locals` / `status` are
# untouched. Parameter / return-value transfer lives at the call
# site (`CallInstruction`, M2.14) and is therefore NOT exercised
# by these tests.
#
# The tests below pin (Rule 4 — every @test pins a specific value):
#
#   1. **`BeginInstruction` pc-only semantics** — forward bumps
#      `pc` from 0 to 1, leaves `locals` untouched, leaves
#      `status` `:running`; inverse restores the pre-forward state
#      exactly under the content-comparing `Base.==` from M2.2.
#   2. **`EndInstruction` pc-only semantics** — same shape at a
#      different starting pc (5 → 6 → 5) to confirm the ±1
#      symmetry is value-independent.
#   3. **Type hierarchy** — both classes extend
#      `ControlInstruction` (introduced at M2.4), which itself
#      extends `Instruction`. This is the test that catches a
#      future agent accidentally redefining `ControlInstruction`
#      in this file (the bead wording invites that mistake; the
#      scoping note in the source docstring forestalls it).
#   4. **Empty parameter / return list legal** — a no-arg `main`
#      and a void-returning subroutine are both well-formed at
#      this layer, with the same pc-only behaviour.
#
# # Why a fresh `IState` per testset
#
# `IState` is mutable and `forward`/`inverse` mutate in place.
# Each testset constructs its own `IState` and uses `deepcopy` to
# snapshot the initial image for the round-trip check, matching
# the convention established in `test_arithmetic_assignment.jl`
# and `test_swap_instruction.jl`.
#
# Ref: src/ir/control_instructions.jl (the implementation; full
#      rationale in its top-of-module docstring — especially the
#      "Scoping: parameter / return-value transfer is NOT here"
#      and "Structural inverse vs. dispatch-level inverse"
#      sections).
# Ref: docs/adr/0001-rc3-rvm-smoke.md §Observations rows 7 and 8
#      — the RC3 `BeginInstruction` / `EndInstruction` table.
# Ref: CLAUDE.md Rule 4 (every @test pins a specific value).

@testset "BeginInstruction (M2.8)" begin
    begin_inst = BennettVM.BeginInstruction(:my_routine, [:p, :q])
    s = BennettVM.IState(0, Dict(:p => Int64(1), :q => Int64(2)), :running)
    s_before = deepcopy(s)
    s2 = BennettVM.forward(begin_inst, s)
    @test s2.pc == 1
    @test s2.locals == s_before.locals   # locals unchanged
    @test s2.status === :running
    s3 = BennettVM.inverse(begin_inst, s2, nothing)
    @test s3 == s_before
end

@testset "EndInstruction (M2.8)" begin
    end_inst = BennettVM.EndInstruction(:my_routine, [:r])
    s = BennettVM.IState(5, Dict(:r => Int64(42)), :running)
    s_before = deepcopy(s)
    s2 = BennettVM.forward(end_inst, s)
    @test s2.pc == 6
    @test s2.locals == s_before.locals
    s3 = BennettVM.inverse(end_inst, s2, nothing)
    @test s3 == s_before
end

@testset "Begin/End type hierarchy (M2.8)" begin
    @test BennettVM.BeginInstruction <: BennettVM.ControlInstruction
    @test BennettVM.BeginInstruction <: BennettVM.Instruction
    @test BennettVM.EndInstruction <: BennettVM.ControlInstruction
    @test BennettVM.EndInstruction <: BennettVM.Instruction
end

@testset "Empty param list legal (M2.8)" begin
    bi = BennettVM.BeginInstruction(:no_args, Symbol[])
    ei = BennettVM.EndInstruction(:no_returns, Symbol[])
    s = BennettVM.IState(0, Dict{Symbol,Int64}(), :running)
    s_before = deepcopy(s)
    s2 = BennettVM.forward(bi, s)
    s3 = BennettVM.inverse(bi, s2, nothing)
    @test s3 == s_before

    s4 = BennettVM.forward(ei, s_before)
    s5 = BennettVM.inverse(ei, s4, nothing)
    @test s5 == s_before
end
