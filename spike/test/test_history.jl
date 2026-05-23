# test/test_history.jl — history-tape invariants. PRD v3 §5.4.3
# (length(history) == steps_taken) and §5.4.4 (history empty after
# unrun!).
#
# Tested-files: spike/src/Interpreter.jl
# Oracle: test/reference/countdown.jl (for countdown(n))
#
# ───────────────────────────────────────────────────────────────────
# History-length convention (Pass-3 design choice; equivalent of
# convention (c) in the Pass-3 brief):
#
# The interpreter's `step!` pushes a pre-step snapshot, then
# *discard-pops* iff the post-step transition is a pure status
# flip — i.e. the post-state's status is terminal AND the pc and
# locals are unchanged from the pre-state (Interpreter.jl Q2.3 / Q2.4).
# Concretely for `countdown(n>=1)`: 19 nontrivial steps (snapshots
# retained) plus 1 idempotent Halt step (snapshot popped) = 20 calls
# to `step!`, history length 19 at termination.
#
# To phrase the §5.4.3 invariant *precisely* without depending on
# knowing the "real-work step count" ahead of time, we test it
# step-by-step:
#
#   1. Before each step that transitions `:running -> :running` we
#      assert `length(history) == n - 1` (where n is the number of
#      step! calls executed so far). I.e. the pre-step snapshot of
#      the *just-completed* step is retained.
#   2. After the terminal step, we assert
#      `length(history) == terminal_steps_retained`
#      where `terminal_steps_retained ∈ {n - 1, n}` depending on
#      whether the Halt step was a pure status flip.
#
# This is the precise reading of the PRD §5.4.3 invariant for the
# Phase-0 interpreter: a "step taken" that mutates IState beyond
# status pushes a history entry; an idempotent status-flip step
# does not. The same statement holds modulo the discard-pop
# predicate even if Pass 2 adds non-idempotent Halt variants.
# ───────────────────────────────────────────────────────────────────

using Test
using BennettVMSpike

isdefined(@__MODULE__, :countdown) ||
    include(joinpath(@__DIR__, "reference", "countdown.jl"))

@testset "history-length tracks non-terminal step count" begin
    prog = countdown(10)
    s = initial_state(prog)
    @test isempty(s.history)                 # P0.4 initial condition

    n_calls = 0
    pre_terminal_history = -1
    while s.current.status === :running
        prev_status = s.current.status
        step!(s, prog)
        n_calls += 1
        if s.current.status === :running
            # Non-terminal step: every step push is retained.
            @test length(s.history) == n_calls
        else
            # Terminal step: discard-pop iff pure status flip.
            # We record the post-terminal history length so we can
            # cross-check it below; do not assert a single fixed
            # value here because Pass-2 chose Halt to be the
            # pure-status-flip kind (so the discard-pop fires).
            pre_terminal_history = length(s.history)
        end
    end
    @test s.current.status === :halted
    # For the spike's Halt (pure status flip), discard-pop fires:
    @test pre_terminal_history == n_calls - 1
    # Cross-check against the empirically-verified canonical count for
    # countdown(10). Decomposition: prelude (Const :n, Const :zero) = 2
    # steps; per loop iteration (gt, JumpIf-take, Const :one, sub, Jump)
    # = 5 steps; final loop-exit (gt, JumpIf-fall) = 2 steps; idempotent
    # Halt = 1 call (popped). For n=10: 2 + 10*5 + 2 + 1 = 55 calls,
    # of which 54 snapshots are retained.
    @test length(s.history) == 54
    @test n_calls == 55
end

@testset "history-length on small fixed cases" begin
    # Empirically-verified counts (see test above for the decomposition
    # formula). All are: total step! calls; history length is calls - 1
    # because the spike's Halt is an idempotent status flip.
    #   n   calls   history
    #   0     5       4
    #   1    10       9
    #   2    15      14
    #   3    20      19
    let expected = ((0, 5, 4), (1, 10, 9), (2, 15, 14), (3, 20, 19))
        for (n, calls_expect, hist_expect) in expected
            prog = countdown(n)
            s = initial_state(prog)
            n_calls = 0
            while s.current.status === :running
                step!(s, prog)
                n_calls += 1
            end
            @test n_calls == calls_expect
            @test length(s.history) == hist_expect
            @test s.current.status === :halted
        end
    end
end

@testset "history empty after unrun!" for n in (0, 1, 2, 3, 5, 10)
    prog = countdown(n)
    s = initial_state(prog)
    run!(s, prog)
    # Pre-unrun!, history is non-empty for every n (including n==0): the
    # 4 non-terminal Const/BinaryOp/JumpIf steps are retained, while only
    # the terminal Halt is discard-popped (Q2.4). Post-unrun!, history
    # must be empty — that is the load-bearing invariant here.
    unrun!(s, prog)
    @test isempty(s.history)               # PRD §5.4.4
    @test s.current.status === :running
    @test s.current.pc == 1
end

@testset "unstep! errors on empty history" begin
    prog = countdown(0)
    s = initial_state(prog)
    @test_throws ErrorException unstep!(s, prog)   # nothing to undo
end

@testset "history retained on max_steps trip" begin
    # If run! aborts via max_steps, the partial history must still be
    # valid (i.e. unrun!-able). Verifies Interpreter.jl Q2.6.
    prog = countdown(100)
    s = initial_state(prog)
    s0 = deepcopy(s.current)
    try
        run!(s, prog; max_steps=5)
    catch err
        @test isa(err, ErrorException)
    end
    @test s.current.status === :running    # mid-execution
    @test length(s.history) == 5           # 5 step!s, all non-terminal
    unrun!(s, prog)
    @test s.current == s0
    @test isempty(s.history)
end
