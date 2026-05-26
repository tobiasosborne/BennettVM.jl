# test/test_dispatch.jl — M2.4 unit tests for the dispatch skeleton
# (bd `bennettvm-qkd`).
#
# # What this file pins
#
# `src/ir/instructions.jl` defines three abstract types
# (`Instruction`, `ControlInstruction <: Instruction`, `RValue`) and
# two generic-fallback methods (`forward`, `inverse`) whose job is to
# raise a context-bearing `ErrorException` when an instruction with no
# concrete implementation reaches the dispatcher. Rule 1 ("fail fast,
# fail loud") makes the *contents* of that error message
# load-bearing: a future M2.x agent who defines a new instruction
# type but forgets to write its `forward` method must see a message
# that names the offending type AND the machine state at the point of
# failure, not the bare Julia `MethodError`. Each `@test` below pins
# one structural fact about that contract:
#
#   - Existence + abstractness of the three supertypes.
#   - `ControlInstruction <: Instruction` (the intermediate is in
#     place ahead of M2.13/M2.14 where the six control-flow concretes
#     will hang off it).
#   - The fallback `forward` and `inverse` raise `ErrorException`
#     (not `MethodError`), and the error text contains the offending
#     type name AND the `pc=` context fragment — that latter check
#     is the Rule 1 evidence.
#
# # Why a test-local `_UnknownInstr`
#
# We need an `Instruction` subtype that has *no* concrete `forward` /
# `inverse` method, in order to exercise the fallback. Declaring it
# inside the testset (which expands to a `let` block) scopes it to
# the testset's surrounding module — Main here — without polluting
# `BennettVM`'s namespace. It exists solely as a trampoline.
#
# Ref: src/ir/instructions.jl (the dispatch skeleton; full rationale
#      in its top-of-module docstring).
# Ref: CLAUDE.md Rule 1 (fail fast, fail loud: error messages must
#      carry context).
# Ref: docs/adr/0001-rc3-rvm-smoke.md §Observations (the 12-subclass
#      taxonomy that concrete subtypes will populate at M2.7-M2.14).

@testset "dispatch skeleton (M2.4)" begin
    # Abstract types exist + abstractness
    @test BennettVM.Instruction isa Type
    @test isabstracttype(BennettVM.Instruction)
    @test BennettVM.ControlInstruction isa Type
    @test isabstracttype(BennettVM.ControlInstruction)
    @test BennettVM.ControlInstruction <: BennettVM.Instruction
    @test BennettVM.RValue isa Type
    @test isabstracttype(BennettVM.RValue)

    # Generic forward stub fires on a fake unknown subtype.
    # `struct` inside a `@testset` is lifted to the enclosing module
    # (here `Main`, via `runtests.jl`); the testset itself is a `let`
    # block, but `struct` declarations are top-level forms and hoist
    # past the `let`. This keeps `BennettVM` untouched and the
    # trampoline scoped to the test harness only.
    struct _UnknownInstr <: BennettVM.Instruction end
    s = BennettVM.IState(0, Dict(:x => Int64(1)), :running)
    err = try
        BennettVM.forward(_UnknownInstr(), s)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("no `forward` method", err.msg)
    @test occursin("_UnknownInstr", err.msg)   # type included
    @test occursin("pc=", err.msg)             # state context

    # Generic inverse stub fires similarly
    err = try
        BennettVM.inverse(_UnknownInstr(), s, nothing)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("no `inverse` method", err.msg)
    @test occursin("_UnknownInstr", err.msg)
end
