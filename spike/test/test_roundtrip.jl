# test/test_roundtrip.jl — round-trip property tests.
# PRD v3 §5.4.2; CLAUDE.md P0.6 (round-trip is the load-bearing
# Phase-0 invariant); Rule 5 (port-and-verify, mutation-proof
# discipline — see RETROSPECTIVE Q2 for the perturbation transcript).
#
# Tested-files: spike/src/Interpreter.jl, spike/src/Instructions.jl
# Oracles: test/reference/countdown.jl,
#          test/reference/property_programs.jl
#
# Two layers:
#   (a) Countdown(n) for n ∈ {0,1,2,3,5,10}: deterministic golden
#       check on a known interesting program.
#   (b) 100 bounded random programs with explicit seed
#       MersenneTwister(0xBE171973). Bounded length (≤20) and
#       max_steps=200 so a malformed program cannot hang the suite.

using Test
using Random
using BennettVMSpike

# Helpers come from reference/{countdown,property_programs}.jl,
# included once at the top of runtests.jl. Guarded so this file
# also runs standalone.
isdefined(@__MODULE__, :countdown) ||
    include(joinpath(@__DIR__, "reference", "countdown.jl"))
isdefined(@__MODULE__, :random_bounded_program) ||
    include(joinpath(@__DIR__, "reference", "property_programs.jl"))

@testset "countdown(n) round-trip restores initial state" for n in (0, 1, 2, 3, 5, 10)
    prog = countdown(n)
    s = initial_state(prog)
    s0 = deepcopy(s.current)               # snapshot the IState
    run!(s, prog)
    @test s.current.status === :halted     # forward terminated
    @test !isempty(s.history)              # every countdown(n), including n==0,
    # has non-empty history before unrun! because the 4 non-terminal
    # Const/BinaryOp/JumpIf steps are retained (only the terminal Halt
    # is discard-popped per Q2.4)
    unrun!(s, prog)
    @test s.current == s0                  # IState == is structural (Q2.1)
    @test isempty(s.history)               # P0.6 load-bearing invariant
    @test s.current.status === :running    # initial state was :running
    @test s.current.pc == 1
end

@testset "round-trip on 100 bounded random programs (seed 0xBE171973)" begin
    rng = MersenneTwister(0xBE171973)
    successful_trials = 0
    forward_agreements = 0
    for trial in 1:100
        prog = random_bounded_program(rng; max_len=20, max_vars=3)
        s = initial_state(prog)
        s0 = deepcopy(s.current)
        # Forward must terminate within max_steps; straight-line
        # programs have at most length(prog) instructions, so a
        # max_steps=200 budget can never be the natural terminator.
        run!(s, prog; max_steps=200)
        @test s.current.status === :halted

        # Golden-master cross-check: VM result must equal the reference
        # irreversible Julia executor's result (Rule 4 / P0.5).
        ref = program_reference(prog)
        @test result(s) == ref
        forward_agreements += (result(s) == ref) ? 1 : 0

        # Round-trip: undo back to the initial state.
        unrun!(s, prog)
        @test s.current == s0
        @test isempty(s.history)
        @test s.current.status === :running
        successful_trials += (s.current == s0 && isempty(s.history)) ? 1 : 0
    end
    # Sanity: every trial must have passed both invariants. If even
    # one regressed silently (e.g. due to a future inverse change),
    # this top-level assertion makes the failure unambiguous.
    @test successful_trials == 100
    @test forward_agreements == 100
end

@testset "per-step inverse: unstep! immediately after step! restores state" begin
    # The *strong* mutation-proof invariant. Without this, a buggy
    # inverse for a single instruction kind can slip past the outer
    # round-trip test because later correct inverses overwrite the
    # corrupted current-state field on the next `unstep!`. We exercise
    # every instruction kind individually plus the canonical countdown.
    #
    # Strategy: walk forward one step at a time, save the pre-step
    # snapshot in `pre_states`, then unstep! once if (and only if)
    # the step actually pushed to history. Assert each pre-step
    # snapshot is recovered byte-for-byte. This is the per-instruction
    # mutation-proof contract.
    progs = (
        Program(AbstractInstruction[Const(:x, 7), Halt()]),
        Program(AbstractInstruction[Const(:x, 5), Const(:y, 3),
                                    Move(:z, :x), Halt()]),
        Program(AbstractInstruction[Const(:x, 5), UnaryOp(:neg, :y, :x), Halt()]),
        Program(AbstractInstruction[Const(:x, 5), UnaryOp(:not, :y, :x), Halt()]),
        Program(AbstractInstruction[Const(:a, 7), Const(:b, 3),
                                    BinaryOp(:add, :c, :a, :b), Halt()]),
        Program(AbstractInstruction[Const(:a, 7), Const(:b, 3),
                                    BinaryOp(:sub, :c, :a, :b), Halt()]),
        Program(AbstractInstruction[Const(:a, 7), Const(:b, 3),
                                    BinaryOp(:mul, :c, :a, :b), Halt()]),
        Program(AbstractInstruction[Const(:cond, 1), Jump(3), Halt()]),
        Program(AbstractInstruction[Const(:cond, 1), JumpIf(:cond, 3), Halt()]),
        Program(AbstractInstruction[Const(:cond, 0), JumpIf(:cond, 4),
                                    Const(:x, 1), Halt()]),
        countdown(2),
        countdown(5),
    )
    for prog in progs
        s = initial_state(prog)
        # Forward sweep: at each step, record (pre, history-grew?).
        # If history grew, the inverse will fire on `unstep!`; if not
        # (terminal status flip), `unstep!` would underflow.
        pre_states = IState[]
        retained   = Bool[]
        while s.current.status === :running
            pre = deepcopy(s.current)
            h_before = length(s.history)
            step!(s, prog)
            grew = length(s.history) > h_before
            push!(pre_states, pre)
            push!(retained, grew)
        end
        # Reverse sweep: undo each step that was retained.
        for i in length(pre_states):-1:1
            if retained[i]
                unstep!(s, prog)
                @test s.current == pre_states[i]   # the load-bearing inverse check
            end
        end
        @test isempty(s.history)
    end
end

@testset "round-trip on hand-crafted edge-case programs" begin
    # Edge case: a single Halt. The Halt's pre-step snapshot is
    # discard-popped (Interpreter.jl Q2.4) because the transition
    # is a pure status flip. Consequence: there is nothing to
    # unrun, and the post-run :halted status cannot be recovered
    # back to :running. The round-trip-to-initial invariant is
    # therefore vacuous for this degenerate program; what we *can*
    # assert is that the history is empty (and stays empty), and
    # that the forward state's pc and locals match the initial.
    prog = Program(AbstractInstruction[Halt()])
    s = initial_state(prog)
    s0_pc     = s.current.pc
    s0_locals = deepcopy(s.current.locals)
    run!(s, prog)
    @test s.current.status === :halted
    @test isempty(s.history)                # discard-popped Halt
    @test s.current.pc == s0_pc             # idempotent on pc
    @test s.current.locals == s0_locals     # idempotent on locals
    unrun!(s, prog)                         # no-op (history empty)
    @test isempty(s.history)
    @test s.current.status === :halted      # nothing to revert

    # Return is semantically Halt in the spike (Instructions.jl §7/8);
    # because it follows a non-idempotent Const, the history *does*
    # retain the Const's snapshot, and the round-trip to initial holds.
    prog2 = Program(AbstractInstruction[Const(:x, 42), Return()])
    s2 = initial_state(prog2)
    s2_0 = deepcopy(s2.current)
    run!(s2, prog2)
    @test s2.current.status === :halted
    @test result(s2)[:x] == 42
    @test length(s2.history) == 1           # Const retained; Return popped
    unrun!(s2, prog2)
    @test s2.current == s2_0
    @test isempty(s2.history)
end
