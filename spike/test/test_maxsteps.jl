# test/test_maxsteps.jl — max_steps guard. PRD v3 §5.4.5.
#
# Tested-files: spike/src/Interpreter.jl (Q2.5 / Q2.6)
# Oracle: test/reference/countdown.jl
#
# Three properties:
#   (1) `run!` errors (ErrorException) when the budget is tripped
#       by a program that would need more steps.
#   (2) The error fires *before* the step that would exceed the
#       budget — i.e. exactly `max_steps` step! invocations have
#       occurred when the error is raised.
#   (3) History accumulated up to that point is retained and the
#       partial computation is `unrun!`-able back to the initial
#       state (Q2.6 — see test_history.jl for the round-trip check).

using Test
using BennettVMSpike

isdefined(@__MODULE__, :countdown) ||
    include(joinpath(@__DIR__, "reference", "countdown.jl"))

@testset "run! errors on max_steps trip" begin
    # countdown(1000) needs ≥ 1000 step!s; max_steps=10 trips early.
    prog = countdown(1000)
    s = initial_state(prog)
    @test_throws ErrorException run!(s, prog; max_steps=10)
    # The exception fires when 10 step!s have been executed (one per
    # loop iteration), so the history must have exactly 10 entries —
    # none of the first 10 steps of countdown(1000) is terminal, so
    # the discard-pop predicate never fires.
    @test length(s.history) == 10
    @test s.current.status === :running
end

@testset "max_steps message is informative (Rule 1: fail loud)" begin
    prog = countdown(50)
    s = initial_state(prog)
    err = nothing
    try
        run!(s, prog; max_steps=3)
    catch e
        err = e
    end
    @test isa(err, ErrorException)
    msg = sprint(showerror, err)
    @test occursin("max_steps", msg)
    @test occursin("3", msg)              # the budget value
    @test occursin("pc=", msg)            # the diagnostic pc
end

@testset "max_steps generous enough does not trip" begin
    # countdown(3) needs 20 step! calls (incl. terminal Halt) — see
    # test_history.jl. max_steps=200 is generous.
    prog = countdown(3)
    s = initial_state(prog)
    run!(s, prog; max_steps=200)          # no throw
    @test s.current.status === :halted
    @test result(s)[:n] == 0
end

@testset "max_steps == exact step count just fits" begin
    # countdown(0): 5 step! calls. max_steps=5 → no trip.
    prog = countdown(0)
    s = initial_state(prog)
    run!(s, prog; max_steps=5)
    @test s.current.status === :halted

    # countdown(0): max_steps=4 → trips (5 calls needed).
    prog2 = countdown(0)
    s2 = initial_state(prog2)
    @test_throws ErrorException run!(s2, prog2; max_steps=4)
end
