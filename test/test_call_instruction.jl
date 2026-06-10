# test/test_call_instruction.jl — M2.14 unit tests for the
# `CallInstruction` instruction (bd `bennettvm-dp1`).
#
# # What this file pins
#
# `src/ir/call_instruction.jl` defines the sixth concrete `Instruction`
# subtype in BennettVM's twelve-class RSSA taxonomy (row 6 in
# `docs/adr/0001-rc3-rvm-smoke.md` §Observations) — RC3's
# `(x,...) := call/uncall l(y,...)` procedure-call form, unified
# across the `:call` / `:uncall` source-level directions under one
# struct with a `direction::Symbol` field (ADR 0001 §Observations
# Structural-Pattern point 4 / decision-table row "Call/Uncall
# unification"). The tests below pin:
#
#   1. **Struct field access** — `targets`, `callee`, `args`,
#      `direction` are exposed and carry the constructor's arguments
#      verbatim. Both the `:call` and `:uncall` direction variants
#      construct successfully.
#   2. **pc-only forward / inverse semantics** at the IState dispatch
#      layer (the M2.14 scoping decision: actual arg/return transfer
#      and recursive sub-execution land at M3.x — see the source
#      file's top-of-module docstring for the rationale). `forward`
#      bumps `pc` by 1 and leaves `locals` untouched; `inverse`
#      decrements `pc` by 1 and round-trips the IState content-
#      equality.
#   3. **Constructor validation** (Rule 1): six degenerate cases
#      raise `ErrorException` — invalid direction symbol, duplicate
#      targets, duplicate args, symbol overlapping targets and args,
#      callee shadowing a target, callee shadowing an arg. Empty
#      `targets` / `args` are explicitly accepted (no-arg / no-return
#      subroutine legal under RSSA, mirroring M2.9
#      `UnconditionalEntry` / `UnconditionalExit` empty-list
#      acceptance).
#   4. **`effective_call_direction` truth table** — the four
#      `(instr.direction, vm_direction)` combinations produce the
#      XOR-of-directions composition documented in the source
#      file's helper docstring. An invalid `vm_direction` symbol
#      raises (Rule 1: do not silently default).
#
# # Why a fresh `IState` per testset
#
# `IState` is mutable and `forward`/`inverse` mutate in place. Each
# testset constructs its own `IState` and uses `deepcopy` to
# snapshot the initial image for the round-trip check, matching the
# convention established in `test_swap_instruction.jl` and
# `test_control_instructions.jl`.
#
# Ref: src/ir/call_instruction.jl (the implementation; full
#      rationale in its top-of-module docstring, including the
#      M2.14-vs-M3.x scoping decision).
# Ref: docs/adr/0001-rc3-rvm-smoke.md §Observations row 6 — the RC3
#      `CallInstruction` table entry and the
#      one-class-with-Direction-field decision.
# Ref: CLAUDE.md Rule 1 (constructor validates inputs), Rule 4
#      (every @test pins a specific value).

@testset "CallInstruction structure (M2.14)" begin
    instr = BennettVM.CallInstruction([:x, :y], :foo, [:a, :b], :call)
    @test instr.targets == [:x, :y]
    @test instr.callee === :foo
    @test instr.args == [:a, :b]
    @test instr.direction === :call

    # uncall variant — the unification under one class is the
    # load-bearing M2.14 design choice (ADR 0001 §Observations
    # Structural-Pattern point 4).
    instr2 = BennettVM.CallInstruction([:r], :bar, [:p], :uncall)
    @test instr2.direction === :uncall
    @test instr2.targets == [:r]
    @test instr2.callee === :bar
    @test instr2.args == [:p]

    # Empty targets / args legal (no-arg / no-return subroutine).
    empty_instr = BennettVM.CallInstruction(Symbol[], :main, Symbol[], :call)
    @test empty_instr.targets == Symbol[]
    @test empty_instr.args == Symbol[]
    @test empty_instr.callee === :main
end

@testset "CallInstruction forward/inverse pc-only (M2.14)" begin
    instr = BennettVM.CallInstruction([:x], :foo, [:y], :call)
    s = BennettVM.IState(0, Dict(:y => Int64(1)), :running)
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr, s)
    @test s2.pc == 1
    @test BennettVM.active_locals(s2) == BennettVM.active_locals(s_before)    # locals UNCHANGED at this layer
    @test s2.status === :running
    # (real arg/return transfer is M3.x — see the source docstring's
    # scoping section; this layer is pc-only.)
    s3 = BennettVM.inverse(instr, s2, nothing)
    @test s3 == s_before
    @test s3.pc == 0
end

@testset "CallInstruction forward/inverse pc-only uncall (M2.14)" begin
    # The :uncall variant must behave the same as :call at the IState
    # dispatch layer (pc bump only). The XOR-of-directions semantics
    # live in `effective_call_direction`, NOT here.
    instr = BennettVM.CallInstruction([:x], :foo, [:y], :uncall)
    s = BennettVM.IState(5, Dict(:y => Int64(42)), :running)
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr, s)
    @test s2.pc == 6
    @test BennettVM.active_locals(s2) == BennettVM.active_locals(s_before)
    s3 = BennettVM.inverse(instr, s2, nothing)
    @test s3 == s_before
end

@testset "CallInstruction constructor validation (M2.14)" begin
    # Invalid direction symbol — typo / stale spike-style tag.
    @test_throws ErrorException BennettVM.CallInstruction(
        [:x], :foo, [:y], :something_else)
    # Duplicate target — SSA single-assignment-within-receiver violation.
    @test_throws ErrorException BennettVM.CallInstruction(
        [:x, :x], :foo, [:y], :call)
    # Duplicate arg — SSA single-assignment-within-sender violation.
    @test_throws ErrorException BennettVM.CallInstruction(
        [:x], :foo, [:y, :y], :call)
    # Symbol in both targets AND args — cannot simultaneously create
    # and destroy one SSA name.
    @test_throws ErrorException BennettVM.CallInstruction(
        [:x, :y], :foo, [:y, :z], :call)
    # callee shadows a target — dispatch ambiguity.
    @test_throws ErrorException BennettVM.CallInstruction(
        [:foo], :foo, [:y], :call)
    # callee shadows an arg — dispatch ambiguity.
    @test_throws ErrorException BennettVM.CallInstruction(
        [:x], :foo, [:foo], :call)
    # Empty arg/target lists are LEGAL — no-arg / no-return subroutine.
    @test BennettVM.CallInstruction(Symbol[], :foo, Symbol[], :call) isa
        BennettVM.CallInstruction
end

@testset "effective_call_direction (M2.14)" begin
    # Truth table from the helper's docstring — pins the XOR-of-
    # directions semantics that M3.x will consume.
    call   = BennettVM.CallInstruction([:x], :foo, [:y], :call)
    uncall = BennettVM.CallInstruction([:x], :foo, [:y], :uncall)
    @test BennettVM.effective_call_direction(call,   :forward)  === :forward
    @test BennettVM.effective_call_direction(call,   :backward) === :backward
    @test BennettVM.effective_call_direction(uncall, :forward)  === :backward
    @test BennettVM.effective_call_direction(uncall, :backward) === :forward
    # Invalid vm_direction — Rule 1: fail loud, do not silently default.
    @test_throws ErrorException BennettVM.effective_call_direction(
        call, :sideways)
    @test_throws ErrorException BennettVM.effective_call_direction(
        uncall, :running)   # common typo: confusing vm_direction
                            # with IState.status.
end
