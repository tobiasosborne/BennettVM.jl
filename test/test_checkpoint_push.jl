# test/test_checkpoint_push.jl — M4.2 unit + integration tests for
# `step!`'s checkpoint-push behavior and `run!`'s `checkpoint_interval`
# forwarding (bd `bennettvm-n26`).
#
# # Why these tests exist
#
# M4.2 wires up the second concrete change in the PRD v4 §3.3 three-
# layer history scheme: `step!` now (a) maintains a persistent
# `step_count::Int` on `RState`, incremented once per successful
# forward step; (b) pushes a `CheckpointEntry` onto `s.history` every
# `checkpoint_interval` steps (default K=64); and (c) `run!` forwards
# the same kwarg to every `step!` call. Per CLAUDE.md Rule 4
# ("'Runs without errors' is not a passing test"), every `@test`
# below pins one specific structural fact against a known-correct
# value. The most load-bearing tests are:
#
#   - **Step-counter increment-only-on-success.** The brief pins this
#     invariant explicitly: `step_count` increments after a successful
#     forward + dispatch + halt-detection sequence on a `:running`
#     state, and on NO other path (early-return on non-:running;
#     exception thrown anywhere in the body). Future M4.3 `unstep!`
#     decrements the count on backward steps; the round-trip
#     invariant `step_count == 0 after unrun!` will break if the
#     forward-only invariant ever silently regresses.
#
#   - **Push fires at exactly multiples of K.** Off-by-one in the
#     periodicity check (`step_count % K == 0 && step_count > 0`)
#     would either push at step 0 (which M4.3's replay logic forbids
#     — step 0 is the initial-state baseline, not a checkpoint), or
#     push at K+1 (which would silently break M4.3's "find largest
#     checkpoint at step <= target" lookup). Both are silent failure
#     modes the round-trip test M4.5 will eventually surface, but
#     pinning the exact-multiples-of-K invariant HERE means M4.5 can
#     focus on the round-trip semantics rather than re-litigating
#     the push frequency.
#
#   - **Aliasing safety through the step! pipeline.** M4.1's
#     `CheckpointEntry` constructor deep-copies its `snapshot` arg,
#     but a faulty M4.2 `step!` could pre-empt that contract by
#     deep-copying nothing (the live `s.current` is what the
#     constructor receives), or — worse — by re-deep-copying outside
#     the constructor and then handing a stale alias to the
#     constructor. The aliasing test re-exercises the M4.1 contract
#     through the M4.2 call site, catching both regression shapes.
#
# # Mutation-proof intent (Rule 5)
#
# Each test below corresponds to a specific perturbation in
# `step!`/`run!` that would silently break a real downstream consumer:
#
#   - Remove the `s.step_count += 1` line → counter-increment tests
#     turn RED.
#   - Move the increment BEFORE the `forward` call → exception-path
#     test turns RED (the count would advance even when `forward`
#     throws).
#   - Move the increment BEFORE the early-return → halted-no-op test
#     turns RED.
#   - Change the periodicity check from `% K == 0 && > 0` to `% K == 0`
#     → step-0-not-checkpointed test turns RED.
#   - Drop the `checkpoint_interval > 0` validation → K-validation
#     tests turn RED (a K=0 would `DivideError` instead of raising
#     a descriptive Rule-1 message).
#   - Drop the K-forwarding in `run!` → forwarding-test turns RED.
#   - Re-deep-copy `s.current` inside `step!` before passing to
#     CheckpointEntry → no test turns RED (the redundant copy is
#     semantically correct, just wasteful); this is by design — we
#     pin the *outcome* (aliasing safety) not the *mechanism*
#     (whose deepcopy did the work).
#
# Ref:
#   * `src/interpreter/Interpreter.jl` — `step!` and `run!` (the
#     functions under test; M4.2 modifies both).
#   * `src/ir/RState.jl` — the `step_count::Int` field this milestone
#     adds.
#   * `src/history/CheckpointEntry.jl` (M4.1) — the entry type pushed.
#   * `bennettvm_prd.md` (PRD v4) §3.3 — three-layer history; K=64
#     placeholder.
#   * `spike/RETROSPECTIVE.md` Q2.2 — deepcopy + ordering rationale
#     this milestone exercises through the M4.1 constructor's
#     contract.
#   * `docs/impl-plan/phase2-impl-plan.md` M4.2 (lines 216-217).
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (every test pins a
#     known-correct value), Rule 11 (literate test docstrings).

using Test
using BennettVM

# The M3.8 hand-built `build_countdown_vm` factory is exactly the
# right shape for these tests (multi-block program with predictable
# step count per N). It is defined as a top-level function in
# `test_forward_interpreter.jl`, which `runtests.jl` includes BEFORE
# this file — so the symbol is already in scope. We deliberately do
# NOT `include(test_forward_interpreter.jl)` here: that would re-run
# the M3.8 testsets twice in the same suite, inflating the pass
# count without adding coverage.

# ---------------------------------------------------------------------
# Small fixture helpers.
# ---------------------------------------------------------------------

# A minimal one-block program: Begin -> (no body) -> End. Total flat-
# stream count = 2; full forward run from initial_state takes 2 steps.
function _empty_main_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, Symbol[]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:m, Symbol[]))
    return VMProgram([bb], BennettVM.LabelTable([bb]), :m, Int[], Int[])
end

# A minimal one-block program: Begin([:n]) -> single ArithAssign -> End.
# Total flat-stream count = 3; full forward run takes 3 steps.
function _small_arith_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:x, :n, :xor, :n, :xor, Int64(0)),
        ],
        BennettVM.EndInstruction(:m, [:x]))
    return VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
end

# Trampoline used to exercise the exception path in `step!`. An
# `_UnknownStepInstr` Instruction subtype has no concrete `forward`
# method, so the M2.4 generic fallback raises an `ErrorException`
# from inside `forward(...)`. The test below installs one as the
# body of an otherwise-valid one-block program and asserts step_count
# / history are unchanged after the throw.
struct _UnknownStepInstr <: BennettVM.Instruction end

function _program_with_unknown_body()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, Symbol[]),
        BennettVM.Instruction[_UnknownStepInstr()],
        BennettVM.EndInstruction(:m, Symbol[]))
    return VMProgram([bb], BennettVM.LabelTable([bb]), :m, Int[], Int[])
end

# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------

@testset "step_count starts at 0 (M4.2)" begin
    # `initial_state` constructs an RState via the 2-arg back-compat
    # constructor — `step_count` defaults to 0. This pins the
    # starting-condition invariant the rest of the suite assumes.
    vm = _empty_main_program()
    rs = initial_state(vm, Dict{Symbol,Int64}())
    @test rs.step_count == 0
end

@testset "step_count increments on each successful step (M4.2)" begin
    # Use the M3.8 countdown(3) fixture (defined in
    # test_forward_interpreter.jl, included from runtests.jl above).
    # Total successful forward step count for countdown(3) is 12.
    #
    # Layout: b_start (Begin + UncondExit = 2 dispatched steps;
    # the UncondExit is a cross-block dispatch landing PAST the
    # destination's entry marker, so b_step1's UncondEntry is
    # *skipped*) + b_step{1..3} (each = 2 Arith + UncondExit =
    # 3 dispatched steps; the entry marker of each is skipped by
    # the predecessor's cross-block dispatch) + b_done (End =
    # 1 dispatched step; its UncondEntry is also skipped).
    # = 2 + 3 + 3 + 3 + 1 = 12.
    #
    # The general formula for countdown(N >= 1) is 3N + 3.
    vm = build_countdown_vm(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))

    # Step the program one instruction at a time with a huge K so no
    # checkpoint push fires; this isolates the counter behavior.
    for expected_count in 1:12
        step!(rs, vm; checkpoint_interval=10_000)
        @test rs.step_count == expected_count
    end
    @test is_halted(rs)
    # A defensive extra step!: now status is :halted, so the early
    # return fires — counter MUST stay at 12.
    step!(rs, vm; checkpoint_interval=10_000)
    @test rs.step_count == 12
end

@testset "step_count does NOT increment on early-return path (M4.2)" begin
    # The early-return path (status !== :running) is the brief's
    # increment-skip rule. Manually pre-set status to :halted and
    # confirm step! is a no-op on step_count.
    vm = _small_arith_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))
    rs.current.status = :halted
    @test rs.step_count == 0
    step!(rs, vm; checkpoint_interval=10_000)
    @test rs.step_count == 0   # unchanged
    @test rs.current.status === :halted   # unchanged

    # Same on the :error path — the brief's invariant covers any
    # non-:running status.
    rs.current.status = :error
    step!(rs, vm; checkpoint_interval=10_000)
    @test rs.step_count == 0
    @test rs.current.status === :error
end

@testset "step_count does NOT increment when forward throws (M4.2)" begin
    # The exception path: `forward(_UnknownStepInstr(), ...)` raises
    # via the M2.4 generic fallback (test_dispatch.jl M2.4 pins the
    # raise). step! propagates the exception WITHOUT incrementing
    # step_count and WITHOUT pushing to history. This is the brief's
    # "no increment on exception" rule, and the round-trip-pinning
    # invariant for M4.5: a partial step that throws must leave the
    # counter/history pair internally consistent with what the
    # M4.3 `unstep!` will see.
    vm = _program_with_unknown_body()
    rs = initial_state(vm, Dict{Symbol,Int64}())
    # First step is Begin (succeeds).
    step!(rs, vm; checkpoint_interval=10_000)
    @test rs.step_count == 1
    history_before = copy(rs.history)
    # Second step is the unknown body — forward throws.
    @test_throws ErrorException step!(rs, vm; checkpoint_interval=10_000)
    @test rs.step_count == 1   # unchanged
    @test rs.history == history_before   # unchanged
end

@testset "push fires at exactly K, 2K, 3K (M4.2)" begin
    # countdown(3) executes 12 successful steps (= 3N + 3 for N = 3;
    # see prior testset for the dispatched-step accounting). With
    # K=4, push must fire at step 4, 8, 12 — three entries — and NOT
    # at steps 1, 2, 3, 5, 6, 7, 9, 10, 11. Step 12 is the final
    # End-step that flips status to :halted; per the brief's pinned
    # design (7), the push at step K=12 still fires AFTER halt
    # detection (status becomes :halted, then increment+push), and
    # the captured snapshot is the halted state.
    vm = build_countdown_vm(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    run!(rs, vm; checkpoint_interval=4)
    @test is_halted(rs)
    @test length(rs.history) == 3
    @test rs.history[1] isa BennettVM.CheckpointEntry
    @test rs.history[2] isa BennettVM.CheckpointEntry
    @test rs.history[3] isa BennettVM.CheckpointEntry
    @test rs.history[1].step == 4
    @test rs.history[2].step == 8
    @test rs.history[3].step == 12
    # Final step count is exactly the total successful-step count.
    @test rs.step_count == 12
    # And the 3rd checkpoint's snapshot reflects the halted state
    # (brief design point 7: halt + checkpoint interaction — the
    # snapshot is harmless-but-halted, not a bug).
    @test rs.history[3].snapshot.status === :halted
end

@testset "step_count=0 post-increment does NOT trigger push (D2 sentinel) (M4.2)" begin
    # D2 sentinel test (M4.2 hostile-review fix). The mutation-proof
    # comment at the top of this file states: "Change the periodicity
    # check from `% K == 0 && > 0` to `% K == 0` → step-0-not-
    # checkpointed test turns RED." This is THAT test.
    #
    # Why this matters: M4.3's `unstep!` will use the 3-arg
    # `RState(current, history, step_count)` constructor to manufacture
    # replay state whose `step_count` is the just-decremented value.
    # Without the `&& s.step_count > 0` guard in step!'s checkpoint
    # gate, a step_count value that lands on 0 post-increment (the
    # case constructed here via step_count=-1 + one successful step)
    # would push a spurious CheckpointEntry at step_count=0. Then
    # M4.3's "find nearest checkpoint at or before current step"
    # lookup would return that step-0 checkpoint instead of falling
    # through to a from-scratch initial_state replay, silently breaking
    # the round-trip invariant M4.5 is supposed to catch.
    #
    # The test manufactures the dangerous case directly: start with
    # step_count=-1 (a value only the 3-arg constructor can produce),
    # take one successful step with K=1 (which would otherwise fire on
    # every step), and assert the push did NOT happen and that
    # step_count post-increment is exactly 0.
    vm = _small_arith_program()
    base = initial_state(vm, Dict(:n => Int64(7)))
    # Manufacture an RState with step_count = -1 via the 3-arg
    # constructor (M4.2 `src/ir/RState.jl:221-223`). The history is
    # empty and the IState is the same starting snapshot.
    rs = BennettVM.RState(base.current,
                          BennettVM.AbstractHistoryEntry[],
                          -1)
    @test rs.step_count == -1
    @test isempty(rs.history)
    # One step with K=1. Without the `&& > 0` guard, this would push
    # a CheckpointEntry at step 0. With the guard, no push fires.
    step!(rs, vm; checkpoint_interval=1)
    @test rs.step_count == 0
    @test isempty(rs.history)
end

@testset "push captures POST-step state (M4.2)" begin
    # With K=1, every step pushes. After each step, the just-pushed
    # entry's snapshot must equal `s.current` at the moment of push
    # — i.e., the post-step state. We check this by capturing
    # `s.current` immediately after each `step!` call and comparing.
    # The M4.1 `CheckpointEntry.==` override (which delegates to the
    # M2.2 `IState.==` override) is what makes this comparison
    # content-equality rather than identity.
    vm = _small_arith_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))

    # Step 1: Begin. Post-state has pc=2 (bumped past entry), locals
    # unchanged, status :running. The push captures THAT state.
    step!(rs, vm; checkpoint_interval=1)
    @test length(rs.history) == 1
    @test rs.history[end].step == 1
    @test rs.history[end].snapshot == rs.current
    # Belt-and-braces: snapshot is a DISTINCT IState from rs.current
    # (because CheckpointEntry's constructor deep-copied). This pins
    # the M4.1 deepcopy contract end-to-end through the M4.2 call site.
    @test rs.history[end].snapshot !== rs.current

    # Step 2: ArithAssign. Post-state has pc=3, :n destroyed, :x
    # created, status :running.
    step!(rs, vm; checkpoint_interval=1)
    @test length(rs.history) == 2
    @test rs.history[end].step == 2
    @test rs.history[end].snapshot == rs.current
    @test !haskey(rs.history[end].snapshot.locals, :n)
    @test rs.history[end].snapshot.locals[:x] == 7 ⊻ (7 ⊻ 0)

    # Step 3: End. Post-state has status :halted.
    step!(rs, vm; checkpoint_interval=1)
    @test length(rs.history) == 3
    @test rs.history[end].step == 3
    @test rs.history[end].snapshot == rs.current
    @test rs.history[end].snapshot.status === :halted
end

@testset "K=large suppresses pushes (M4.2)" begin
    # countdown(1) executes 6 successful steps (= 3*1 + 3): Begin +
    # UncondExit at b_start (2; b_step1's UncondEntry is skipped by
    # the dispatch) + 2 Arith + UncondExit at b_step1 (3; b_done's
    # UncondEntry is skipped by the dispatch) + End at b_done (1).
    # With K=100, no push fires.
    vm = build_countdown_vm(1)
    rs = initial_state(vm, Dict(:n0 => Int64(1), :steps0 => Int64(0)))
    run!(rs, vm; checkpoint_interval=100)
    @test is_halted(rs)
    @test isempty(rs.history)
    @test rs.step_count == 6
end

@testset "K validation: K=0 raises (M4.2)" begin
    # Rule 1 / fail-loud: K=0 would `DivideError` at `step_count % K`,
    # which is a Julia-internal failure that doesn't name the offending
    # caller. step!'s early validation replaces that with a descriptive
    # ErrorException naming `checkpoint_interval` and the offending value.
    vm = _small_arith_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))
    err = try
        step!(rs, vm; checkpoint_interval=0)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("checkpoint_interval", err.msg)
    @test occursin("0", err.msg)
end

@testset "K validation: negative K raises (M4.2)" begin
    # K<0 is the more insidious bug — Julia's `%` on a negative
    # divisor is well-defined but produces results the caller cannot
    # reason about. The same Rule-1 raise covers it.
    vm = _small_arith_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))
    @test_throws ErrorException step!(rs, vm; checkpoint_interval=-1)
    @test_throws ErrorException step!(rs, vm; checkpoint_interval=-64)
end

@testset "K validation: pre-halted RState is exempt from K check (M4.2)" begin
    # The validation lives AFTER the early-return on non-:running,
    # so a halted RState whose status flips through `step!` without
    # consuming K is not gated on the kwarg being sensible. This
    # matches the docstring §"(2) Validate" rationale: a halted
    # state is a no-op regardless of K.
    vm = _empty_main_program()
    rs = initial_state(vm, Dict{Symbol,Int64}())
    rs.current.status = :halted
    # K=0 would normally raise, but on a halted state step! returns
    # early without reaching the validation. Pinning this here means a
    # future refactor that moves the validation BEFORE the early
    # return — which would change observable behavior on halted states
    # — would turn this test RED.
    step!(rs, vm; checkpoint_interval=0)
    @test rs.current.status === :halted
    @test rs.step_count == 0
end

@testset "default K=64 suppresses pushes for short programs (M4.2)" begin
    # Tight loop of step!() calls without the kwarg. For < 64 steps,
    # no push fires. This pins that the default K is what the brief
    # says (64), and protects against a silent default change.
    vm = build_countdown_vm(3)   # 12 successful steps total (3N + 3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    # Step 11 times — still under K=64, so no push.
    for _ in 1:11
        step!(rs, vm)
    end
    @test rs.step_count == 11
    @test isempty(rs.history)
    # 12th step completes (program halts). Still under K=64.
    step!(rs, vm)
    @test is_halted(rs)
    @test rs.step_count == 12
    @test isempty(rs.history)
end

@testset "run! forwards checkpoint_interval to step! (M4.2)" begin
    # Two runs of the same program: one driven manually with explicit
    # `step!(...; checkpoint_interval=4)`, the other via
    # `run!(...; checkpoint_interval=4)`. The resulting histories must
    # be content-equal entry-for-entry — pinning that run! forwards
    # the kwarg verbatim, neither dropping it nor substituting the
    # default.
    vm = build_countdown_vm(3)

    rs_manual = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    while !is_halted(rs_manual)
        step!(rs_manual, vm; checkpoint_interval=4)
    end

    rs_auto = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    run!(rs_auto, vm; checkpoint_interval=4)

    @test rs_manual.step_count == rs_auto.step_count
    @test length(rs_manual.history) == length(rs_auto.history)
    @test length(rs_auto.history) == 3   # K=4 over 12 steps -> 3 pushes
    for i in eachindex(rs_manual.history)
        @test rs_manual.history[i] == rs_auto.history[i]
    end
end

@testset "aliasing safety re-confirmed through step! pipeline (M4.2)" begin
    # The M4.1 deep-copy contract, exercised through the M4.2 call
    # site. With K=1, every step pushes a CheckpointEntry capturing
    # `s.current`. After the push, mutating `s.current` (via the next
    # step!) MUST NOT alter the captured snapshot. M4.1's
    # test_checkpoint_entry.jl pinned this at the constructor level;
    # this test pins it END-TO-END, catching any future M4.2 refactor
    # that "optimises away" the deepcopy by handing a stale alias to
    # CheckpointEntry's constructor.
    vm = _small_arith_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))

    # Step 1: Begin. Push captures pc=2, locals={:n => 7}, :running.
    step!(rs, vm; checkpoint_interval=1)
    captured_after_step1 = rs.history[end]
    @test captured_after_step1.snapshot.pc == 2
    @test captured_after_step1.snapshot.locals[:n] == 7
    @test captured_after_step1.snapshot.status === :running

    # Step 2: ArithAssign destroys :n, creates :x, pc -> 3. The
    # captured snapshot from step 1 must STILL show pc=2 and :n=>7,
    # not the post-step-2 state.
    step!(rs, vm; checkpoint_interval=1)
    @test captured_after_step1.snapshot.pc == 2
    @test captured_after_step1.snapshot.locals[:n] == 7
    @test !haskey(captured_after_step1.snapshot.locals, :x)
    @test captured_after_step1.snapshot.status === :running

    # Hand mutation: forcibly alter rs.current after step 2 — none of
    # this can reach the step-1 snapshot if the deepcopy contract holds.
    rs.current.locals[:x] = Int64(-999)
    rs.current.pc = 0
    rs.current.status = :error
    @test captured_after_step1.snapshot.pc == 2
    @test captured_after_step1.snapshot.locals[:n] == 7
    @test !haskey(captured_after_step1.snapshot.locals, :x)
    @test captured_after_step1.snapshot.status === :running
    # And the Dict instances are distinct objects (the M4.1 mechanism
    # check, mirrored here for end-to-end coverage).
    @test captured_after_step1.snapshot.locals !== rs.current.locals
end
