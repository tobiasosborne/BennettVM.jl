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

# -----------------------------------------------------------------------------
# M2.9 — UnconditionalEntry / UnconditionalExit  (bd `bennettvm-08q`)
# -----------------------------------------------------------------------------
#
# These tests pin (Rule 4):
#
#   1. **`UnconditionalEntry` pc-only semantics** — forward bumps
#      `pc` from 3 to 4, leaves `locals` untouched, leaves
#      `status` `:running`; inverse restores the pre-forward state
#      exactly under the content-comparing `Base.==` from M2.2.
#   2. **`UnconditionalExit` pc-only semantics** — same shape at a
#      different starting pc (5 → 6 → 5).
#   3. **Constructor validation** — duplicate symbols in `params`
#      / `args` raise `ErrorException` (Rule 1); empty vectors are
#      accepted.
#   4. **Type hierarchy** — both classes extend
#      `ControlInstruction` (introduced at M2.4).
#
# The "bead-vs-ADR reconciliation" — that `UnconditionalEntry`
# does NOT carry a predecessor-label field — is enforced
# structurally by the field definitions in
# `src/ir/control_instructions.jl`. No separate test is needed:
# the struct's accessible fields are `label` and `params` only,
# and Julia will throw on any attempted access to a non-existent
# `predecessor` field. The reconciliation note lives in the
# source docstring (per the task brief).

@testset "UnconditionalEntry (M2.9)" begin
    instr = BennettVM.UnconditionalEntry(:L1, [:x, :y])
    s = BennettVM.IState(3, Dict(:x => Int64(7), :y => Int64(9)), :running)
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr, s)
    @test s2.pc == 4
    @test s2.locals == s_before.locals
    @test s2.status === :running
    s3 = BennettVM.inverse(instr, s2, nothing)
    @test s3 == s_before
end

@testset "UnconditionalExit (M2.9)" begin
    instr = BennettVM.UnconditionalExit(:L_next, [:a, :b])
    s = BennettVM.IState(5, Dict(:a => Int64(1), :b => Int64(2)), :running)
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr, s)
    @test s2.pc == 6
    @test s2.locals == s_before.locals
    @test s2.status === :running
    s3 = BennettVM.inverse(instr, s2, nothing)
    @test s3 == s_before
end

@testset "Uncond constructor validation (M2.9)" begin
    # Duplicate symbols rejected (Rule 1):
    @test_throws ErrorException BennettVM.UnconditionalEntry(:L, [:x, :x])
    @test_throws ErrorException BennettVM.UnconditionalExit(:L, [:a, :a])
    # Empty lists OK (control-flow-only blocks are well-formed):
    @test BennettVM.UnconditionalEntry(:L0, Symbol[]) isa
        BennettVM.UnconditionalEntry
    @test BennettVM.UnconditionalExit(:L_end, Symbol[]) isa
        BennettVM.UnconditionalExit
    # Singletons OK:
    @test BennettVM.UnconditionalEntry(:L1, [:x]) isa
        BennettVM.UnconditionalEntry
    @test BennettVM.UnconditionalExit(:L1, [:a]) isa
        BennettVM.UnconditionalExit
end

@testset "Uncond type hierarchy (M2.9)" begin
    @test BennettVM.UnconditionalEntry <: BennettVM.ControlInstruction
    @test BennettVM.UnconditionalEntry <: BennettVM.Instruction
    @test BennettVM.UnconditionalExit <: BennettVM.ControlInstruction
    @test BennettVM.UnconditionalExit <: BennettVM.Instruction
end

# -----------------------------------------------------------------------------
# M2.10 — ConditionalEntry / ConditionalExit  (bd `bennettvm-du4`)
# -----------------------------------------------------------------------------
#
# These tests pin (Rule 4):
#
#   1. **`ConditionalEntry` pc-only semantics** — forward bumps `pc`
#      from 0 to 1, leaves `locals` (including the predicate `c`)
#      untouched, leaves `status` `:running`; inverse restores the
#      pre-forward state exactly under the content-comparing
#      `Base.==` from M2.2.
#   2. **`ConditionalExit` pc-only semantics** — same shape at a
#      different starting pc (3 → 4 → 3) with a false-valued
#      predicate to confirm the dispatch-layer behaviour is
#      *predicate-independent* (the predicate-driven dispatch is
#      M3.x's job; this file's forward/inverse must not branch on
#      `c`'s value).
#   3. **Constructor validation (Rule 1)** — six rejection cases:
#      duplicate symbols in params/args; collapsed predecessor/
#      target pair (degenerate-Uncond); predicate symbol shadowing
#      a param/arg.
#   4. **Type hierarchy** — both classes extend
#      `ControlInstruction` (introduced at M2.4).
#   5. **Field-order + paired-symbol narrative** — true-branch
#      symbols sit at field positions matching the RC3 source form;
#      the predicate symbol is the same on the paired Entry/Exit
#      (here just confirmed positionally — the cross-block invariant
#      lands at M2.15's `BasicBlock` validation pass).
#
# The "φ-on-splits-AND-joins" narrative is documented at the file /
# section level in `src/ir/control_instructions.jl`'s M2.10 block
# docstring (per the task brief — this is the most hallucination-
# prone bead in the M2.x sequence). The tests below pin the
# *structural* consequences of that narrative.

@testset "ConditionalEntry (M2.10)" begin
    instr = BennettVM.ConditionalEntry(:Lj, [:x], :Lt, :Lf, :c)
    s = BennettVM.IState(0, Dict(:x => Int64(5), :c => Int64(1)), :running)
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr, s)
    @test s2.pc == 1
    @test s2.locals == s_before.locals
    @test s2.status === :running
    s3 = BennettVM.inverse(instr, s2, nothing)
    @test s3 == s_before
end

@testset "ConditionalExit (M2.10)" begin
    instr = BennettVM.ConditionalExit(:c, :Lt, :Lf, [:y])
    s = BennettVM.IState(3, Dict(:y => Int64(42), :c => Int64(0)), :running)
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr, s)
    @test s2.pc == 4
    @test s2.locals == s_before.locals
    @test s2.status === :running
    s3 = BennettVM.inverse(instr, s2, nothing)
    @test s3 == s_before
end

@testset "Cond constructor validation (M2.10)" begin
    # Duplicate params/args rejected:
    @test_throws ErrorException BennettVM.ConditionalEntry(:L, [:x, :x], :Lt, :Lf, :c)
    @test_throws ErrorException BennettVM.ConditionalExit(:c, :Lt, :Lf, [:y, :y])
    # Collapsed branches (would be Uncond) rejected:
    @test_throws ErrorException BennettVM.ConditionalEntry(:L, [:x], :L_same, :L_same, :c)
    @test_throws ErrorException BennettVM.ConditionalExit(:c, :L_same, :L_same, [:y])
    # Predicate shadowing a param/arg rejected:
    @test_throws ErrorException BennettVM.ConditionalEntry(:L, [:c], :Lt, :Lf, :c)
    @test_throws ErrorException BennettVM.ConditionalExit(:c, :Lt, :Lf, [:c])
end

@testset "Cond type hierarchy + φ-on-splits-AND-joins narrative (M2.10)" begin
    @test BennettVM.ConditionalEntry <: BennettVM.ControlInstruction
    @test BennettVM.ConditionalEntry <: BennettVM.Instruction
    @test BennettVM.ConditionalExit <: BennettVM.ControlInstruction
    @test BennettVM.ConditionalExit <: BennettVM.Instruction

    # Structural pairing assertion: any ConditionalExit can be
    # "reversed" by swapping the target/predecessor pair (this is
    # what M2.15's BasicBlock.reversed() will exploit; here we just
    # confirm the field-positional symmetry — true-branch on the
    # left in both Entry and Exit, mirroring the RC3 source form).
    exit_ = BennettVM.ConditionalExit(:cond, :T1, :T2, [:a, :b])
    @test exit_.target_true === :T1
    @test exit_.target_false === :T2

    entry = BennettVM.ConditionalEntry(:L, [:a, :b], :P1, :P2, :cond)
    @test entry.predecessor_true === :P1
    @test entry.predecessor_false === :P2

    # The cross-bead invariant: the predicate symbol must agree
    # between paired Entry and Exit (verifiable only at IR-graph
    # validation time, M2.15). Here, just confirm we kept the
    # convention.
    @test entry.condition === :cond
    @test exit_.condition === :cond
end
