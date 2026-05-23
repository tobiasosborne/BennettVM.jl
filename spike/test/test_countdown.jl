# test/test_countdown.jl — countdown forward-execution golden-master.
# PRD v3 §5.4.1; CLAUDE.md P0.5 (golden master required); Rule 4
# (every test asserts against a known-correct value).
#
# Tested-files: spike/src/Interpreter.jl, spike/src/Instructions.jl,
#               spike/src/Types.jl
# Reference oracle: test/reference/countdown.jl
#
# The bytecode program is the canonical Pass-2R-accepted countdown
# loop: 8 instructions, halts at pc=5 with locals[:n] == 0.

using Test
using BennettVMSpike

# countdown(n) and countdown_reference(n) come from reference/countdown.jl,
# included once at the top of runtests.jl. Guarded so this file also
# runs standalone via `julia --project=. test/test_countdown.jl`.
isdefined(@__MODULE__, :countdown_reference) ||
    include(joinpath(@__DIR__, "reference", "countdown.jl"))

@testset "countdown forward halts at expected pc and status" begin
    for n in (0, 1, 2, 3, 5, 10)
        prog = countdown(n)
        s = initial_state(prog)
        run!(s, prog)
        @test s.current.status === :halted
        @test is_halted(s)
        @test s.current.pc == 5            # Halt instruction position
        @test result(s)[:n] == 0           # countdown reaches zero
    end
end

@testset "countdown golden-master vs reference Julia (n=$n)" for n in (0, 1, 2, 3, 5, 10)
    prog = countdown(n)
    s = initial_state(prog)
    run!(s, prog)
    expected = countdown_reference(n)
    @test result(s) == expected            # full Dict equality
    # spot-check load-bearing keys explicitly so the failure mode
    # is informative if the dict equality regresses.
    @test result(s)[:n]    == expected[:n]
    @test result(s)[:zero] == expected[:zero]
    @test result(s)[:cond] == expected[:cond]
    if n >= 1
        @test result(s)[:one] == 1
    else
        @test !haskey(result(s), :one)
    end
end

@testset "countdown result errors when not halted" begin
    prog = countdown(3)
    s = initial_state(prog)
    @test_throws ErrorException result(s)  # still :running
end
