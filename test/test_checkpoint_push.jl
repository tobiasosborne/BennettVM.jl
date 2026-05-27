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
#
# Body modop is `:xor` — INJECTIVE under M6.1's trait. Under the M6.2
# gate, none of the three dispatched steps (Begin, Arith :xor, End)
# triggers a checkpoint push regardless of K. This fixture is the right
# shape for tests that probe the K-validation / increment-only / status-
# transition paths (which do NOT depend on the push firing); tests
# that need the push to fire at a specific step must use
# `_small_arith_nonxor_program` below.
function _small_arith_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:x, :n, :xor, :n, :xor, Int64(0)),
        ],
        BennettVM.EndInstruction(:m, [:x]))
    return VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
end

# Same shape as `_small_arith_program` but the body modop is `:sub`
# (NON-injective under M6.1). Dispatched steps:
#   step 1: Begin              — injective; no push regardless of K.
#   step 2: Arith :sub         — NON-injective; pushes when step_count % K == 0.
#   step 3: End                — injective; no push regardless of K.
# This is the right fixture for the M4.2 "push captures POST-step
# state" and "aliasing safety" tests post-M6.2: they need a push to
# actually fire so the captured snapshot is observable, and the only
# step in this 3-step program that pushes is step 2.
function _small_arith_nonxor_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:x, :n, :sub, Int64(1), :and, Int64(1)),
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

@testset "push fires at exactly K, 2K, 3K (M4.2 / M6.2)" begin
    # countdown(3) executes 12 successful steps (= 3N + 3 for N = 3;
    # see prior testset for the dispatched-step accounting). With
    # K=4, the M4.2-only push-gate fires at steps 4/8/12; M6.2's
    # `!is_injective(instr)` AND-in narrows that set to the steps
    # whose instruction is non-injective per M6.1. The countdown(3)
    # dispatched-step instruction sequence is:
    #
    #   step  1: Begin                 (injective; control marker)
    #   step  2: UncondExit b_start    (injective; control flow)
    #   step  3: Arith :sub (b_step1)  (NON-injective; modop=:sub)
    #   step  4: Arith :add (b_step1)  (NON-injective; modop=:add)
    #   step  5: UncondExit b_step1    (injective)
    #   step  6: Arith :sub (b_step2)  (NON-injective)
    #   step  7: Arith :add (b_step2)  (NON-injective)
    #   step  8: UncondExit b_step2    (injective)
    #   step  9: Arith :sub (b_step3)  (NON-injective)
    #   step 10: Arith :add (b_step3)  (NON-injective)
    #   step 11: UncondExit b_step3    (injective)
    #   step 12: End                   (injective)
    #
    # Pre-M6.2 expected pushes at K=4: steps {4, 8, 12} → length 3.
    # Post-M6.2 push set: {4, 8, 12} ∩ non-injective = {4}.
    # Step 8 is UncondExit (injective; no push). Step 12 is End
    # (injective; no push). Only step 4 pushes.
    vm = build_countdown_vm(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    run!(rs, vm; checkpoint_interval=4)
    @test is_halted(rs)
    # M6.2: pushes only at non-injective K-multiples; only step 4 qualifies.
    @test length(rs.history) == 1
    # M6.2: the surviving entry is the step-4 push (Arith :add, non-injective).
    @test rs.history[1] isa BennettVM.CheckpointEntry
    @test rs.history[1].step == 4
    # Final step count is exactly the total successful-step count.
    @test rs.step_count == 12
    # M6.2: the step-4 snapshot is mid-run (:running), not halted —
    # the previous "3rd checkpoint at step 12 is halted" assertion is
    # gone because step 12's End is injective and no longer pushes.
    @test rs.history[1].snapshot.status === :running
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
    #
    # M6.2 — the fixture below uses `_small_arith_nonxor_program` so
    # the first dispatched step (Begin) is followed by a NON-injective
    # Arith :sub. Wait — actually the first step IS Begin (injective),
    # which under M6.2 doesn't push regardless of the `> 0` guard. So
    # using a fixture whose FIRST step is non-injective is what makes
    # this test continue to mutation-prove the `step_count > 0` guard.
    # We can't construct such a fixture cheaply (every BasicBlock starts
    # with a ControlInstruction, all of which are injective at M6.1).
    # We therefore pre-step the fixture forward to land on a non-
    # injective step BEFORE manufacturing the step_count=-1 state: this
    # way the next step! call dispatches on a non-injective instruction
    # (Arith :sub) and would push if the `> 0` guard were dropped.
    vm = _small_arith_nonxor_program()
    base = initial_state(vm, Dict(:n => Int64(7)))
    # Step 1: Begin (injective, no push). Now pc points at the body
    # ArithAssign (the next dispatch will be the non-injective Arith :sub).
    step!(base, vm; checkpoint_interval=10_000)
    @test base.current.status === :running
    # Manufacture an RState with step_count = -1 via the 3-arg
    # constructor (M4.2 `src/ir/RState.jl:221-223`), preserving the
    # post-step-1 IState so the next step! lands on Arith :sub (non-
    # injective). The history is empty.
    rs = BennettVM.RState(base.current,
                          BennettVM.AbstractHistoryEntry[],
                          -1)
    @test rs.step_count == -1
    @test isempty(rs.history)
    # One step with K=1, dispatching the non-injective Arith :sub.
    # Without the `&& > 0` guard, this would push a CheckpointEntry
    # at step 0 (the post-increment step_count). With the guard, no
    # push fires. M6.2's `!is_injective(instr)` AND-clause does NOT
    # cover for the guard here because the dispatched instruction
    # IS non-injective.
    step!(rs, vm; checkpoint_interval=1)
    @test rs.step_count == 0
    @test isempty(rs.history)
end

@testset "push captures POST-step state (M4.2 / M6.2)" begin
    # With K=1, the M4.2 push-gate would otherwise fire on every step
    # — but M6.2's `!is_injective(instr)` AND-clause skips the push on
    # injective steps even at K=1. `_small_arith_nonxor_program`'s
    # dispatched sequence is:
    #
    #   step 1: Begin         (injective; no push, even at K=1)
    #   step 2: Arith :sub    (NON-injective; pushes at K=1)
    #   step 3: End           (injective; no push)
    #
    # So with K=1 across the three steps, exactly one push fires
    # (step 2's Arith :sub). The post-step-state-capture invariant is
    # then re-exercised on that single push: the captured snapshot is
    # the post-step IState (pc bumped past Arith, :n destroyed, :x
    # created, status :running). The M4.1 `CheckpointEntry.==`
    # override (which delegates to the M2.2 `IState.==` override) is
    # what makes this content-equality rather than identity.
    vm = _small_arith_nonxor_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))

    # M6.2: step 1 is Begin (injective) → no push, history empty.
    step!(rs, vm; checkpoint_interval=1)
    @test isempty(rs.history)
    @test rs.step_count == 1   # counter increments regardless of push gate

    # M6.2: step 2 is Arith :sub (non-injective) → push at step_count=2.
    step!(rs, vm; checkpoint_interval=1)
    @test length(rs.history) == 1
    @test rs.history[end].step == 2
    @test rs.history[end].snapshot == rs.current
    # Belt-and-braces: snapshot is a DISTINCT IState from rs.current
    # (because CheckpointEntry's constructor deep-copied). This pins
    # the M4.1 deepcopy contract end-to-end through the M4.2 call site.
    @test rs.history[end].snapshot !== rs.current
    @test !haskey(rs.history[end].snapshot.locals, :n)
    # :sub with op=:and / lhs=1 / rhs=1 produces (7 - (1 & 1)) = 6.
    @test rs.history[end].snapshot.locals[:x] == Int64(6)
    @test rs.history[end].snapshot.status === :running

    # M6.2: step 3 is End (injective) → no push; history still length 1.
    step!(rs, vm; checkpoint_interval=1)
    @test length(rs.history) == 1
    @test rs.current.status === :halted
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
    # M6.2: countdown(3) at K=4 → step-4 (Arith :add, non-injective)
    # is the only K-multiple step whose instruction is non-injective.
    # Steps 8 and 12 are injective (UncondExit / End) so they no
    # longer push under M6.2 → length 1 (was length 3 pre-M6.2).
    @test length(rs_auto.history) == 1
    for i in eachindex(rs_manual.history)
        @test rs_manual.history[i] == rs_auto.history[i]
    end
end

@testset "aliasing safety re-confirmed through step! pipeline (M4.2 / M6.2)" begin
    # The M4.1 deep-copy contract, exercised through the M4.2 call
    # site. With K=1 on `_small_arith_nonxor_program`, exactly one
    # push fires (step 2, Arith :sub, non-injective per M6.1); see the
    # "push captures POST-step state" testset above for the dispatched-
    # step enumeration. After that single push, the captured snapshot
    # MUST be undisturbed by subsequent mutations to `s.current`.
    # M4.1's test_checkpoint_entry.jl pinned this at the constructor
    # level; this test pins it END-TO-END, catching any future M4.2
    # refactor that "optimises away" the deepcopy by handing a stale
    # alias to CheckpointEntry's constructor.
    vm = _small_arith_nonxor_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))

    # M6.2: step 1 is Begin (injective) → no push.
    step!(rs, vm; checkpoint_interval=1)
    @test isempty(rs.history)

    # M6.2: step 2 is Arith :sub (non-injective) → push fires at step
    # 2. Capture the entry for the aliasing checks below. The pushed
    # snapshot is the post-step-2 IState: pc bumped past Arith (= 3),
    # :n destroyed, :x = 7 - 1 = 6 (since `op=:and, lhs=1, rhs=1`
    # produces 1), status :running.
    step!(rs, vm; checkpoint_interval=1)
    @test length(rs.history) == 1
    captured_after_step2 = rs.history[end]
    @test captured_after_step2.step == 2
    @test captured_after_step2.snapshot.pc == 3
    @test !haskey(captured_after_step2.snapshot.locals, :n)
    @test captured_after_step2.snapshot.locals[:x] == Int64(6)
    @test captured_after_step2.snapshot.status === :running

    # Step 3 is End (injective; no push). The forward() of End bumps
    # pc and step! flips status to :halted. The captured step-2
    # snapshot must STILL show pc=3, status=:running.
    step!(rs, vm; checkpoint_interval=1)
    @test length(rs.history) == 1   # no new push (End is injective)
    @test rs.current.status === :halted
    @test captured_after_step2.snapshot.pc == 3
    @test captured_after_step2.snapshot.status === :running
    @test captured_after_step2.snapshot.locals[:x] == Int64(6)

    # Hand mutation: forcibly alter rs.current — none of this can
    # reach the captured step-2 snapshot if the deepcopy contract holds.
    rs.current.locals[:x] = Int64(-999)
    rs.current.pc = 0
    rs.current.status = :error
    @test captured_after_step2.snapshot.pc == 3
    @test captured_after_step2.snapshot.locals[:x] == Int64(6)
    @test captured_after_step2.snapshot.status === :running
    @test !haskey(captured_after_step2.snapshot.locals, :n)
    # And the Dict instances are distinct objects (the M4.1 mechanism
    # check, mirrored here for end-to-end coverage).
    @test captured_after_step2.snapshot.locals !== rs.current.locals
end
