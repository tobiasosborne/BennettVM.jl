# test/test_unrun.jl — M4.4 unit + integration tests for `unrun!`,
# the full-reverse driver of the L3 checkpoint-replay history layer
# (bd `bennettvm-5jb`).
#
# # Why these tests exist
#
# M4.4 lands the loop-driver companion to M4.3's `unstep!`: keep
# calling `unstep!` until `s.step_count == 0`, then assert the
# structural exit invariant `isempty(s.history)`. The function is
# small (~20 LOC executable) but every line carries a Rule-1 / Rule-4
# obligation. Per CLAUDE.md Rule 4 ("'Runs without errors' is not a
# passing test"), every `@test` below pins one specific structural or
# semantic fact against a known-correct value. The most load-bearing
# tests are:
#
#   - **Full forward + full reverse** ("the load-bearing test"). Run a
#     program to halt with K=4 checkpoint pushes; capture the initial
#     state; `unrun!`; assert `s.current == captured_initial`,
#     `s.step_count == 0`, `isempty(history)`. This is the round-trip
#     test in miniature; M4.5 will do this exhaustively but M4.4 must
#     already support it via its own contract.
#
#   - **Reverse from halted state**. The path that exercises M4.3's
#     halt-boundary handling. Forward to halt; assert `is_halted`;
#     `unrun!`; assert `!is_halted` (status flipped back to `:running`
#     by the first iteration's unstep! restoring a pre-halt snapshot);
#     `current == initial`.
#
#   - **Multiple checkpoint boundaries reversed correctly**. K=2, 10
#     forward steps so history has 5 checkpoints (steps 2/4/6/8/10).
#     `unrun!` must drain all of them. This pins that the loop iterates
#     enough times to walk past every checkpoint, not just the
#     most recent one.
#
#   - **Max-iterations guard fires**. Pass `max_unsteps=2` on a 10-step
#     program. Must raise an ErrorException with "max_unsteps" and
#     "exceeded" in the message. The RState must be left mid-reverse —
#     `step_count > 0` after the catch (NOT rolled back).
#
#   - **Structural post-condition assertion fires**. The load-bearing
#     fail-loud test. Construct a scenario where after the unstep!
#     loop terminates (step_count == 0), `s.history` is non-empty.
#     This cannot arise from correct unstep! behaviour — it requires
#     manual corruption (push a step-0 CheckpointEntry directly into
#     the history vector). `unrun!` must raise.
#
#   - **NO manual status reset**. Construct a degenerate RState whose
#     `initial.status === :error` (the 4-arg RState constructor
#     accepts this; `initial_state` would never produce it). Step
#     forward; `unrun!`. Assert `s.current.status === :error` after
#     `unrun!`. This pins that the post-state of `unrun!` is
#     determined by `s.initial`, not by a manual `:running` reset
#     hidden inside `unrun!`. If a future "fix" silently resets to
#     `:running`, this test turns RED.
#
#   - **All three exit invariants together**. After a full `unrun!`,
#     EACH of `step_count == 0`, `isempty(history)`, and
#     `current == initial` must hold. The full canonical "fully
#     reversed" predicate.
#
# # Mutation-proof intent (Rule 5)
#
# Each test corresponds to a specific perturbation in `unrun!` /
# `unstep!` / `RState` that would silently break a real downstream
# consumer:
#
#   - Change loop predicate from `step_count > 0` to
#     `!isempty(history)` → "Single-step reversal" turns RED (K=64 + 1
#     step → empty history → loop never runs → step_count remains 1 →
#     either the post-condition fires or the assertion on
#     step_count == 0 turns RED).
#   - Drop the structural post-condition assertion →
#     "Structural post-condition assertion fires" turns RED (silent
#     pass instead of throw).
#   - Add `s.current = deepcopy(s.initial)` (or any manual status
#     reset) at end of `unrun!` → "NO manual status reset" turns RED.
#   - Drop the `max_unsteps` guard → "Max-iterations guard fires"
#     turns RED (silent infinite loop or silent pass instead of
#     throw).
#   - Off-by-one in guard (`n > max_unsteps` instead of `n >=`) →
#     "Max-iterations guard fires" remains GREEN at boundary but
#     RED at the precise threshold: pass `max_unsteps=0` and observe
#     it allows one unstep! (which would fire if guard is wrong).
#     The test `max_unsteps=2 on 10-step program` exercises the
#     guard fires AFTER 2 unsteps regardless.
#   - Roll back the RState on guard fire (e.g., wrap the loop in a
#     try/catch that restores) → "Max-iterations guard fires" turns
#     RED on the "RState left mid-reverse" assertion.
#   - Replace `_entry_step(e)` in the post-condition error with a
#     direct field access (e.g., `e.step`) → silent pass for
#     M6/M7-style entry types, no direct RED today; the comment in
#     `unrun!` documents the M6/M7 forward-compat reason. Out of
#     M4.4 scope to test.
#
# Ref:
#   * `src/history/Replay.jl` — `unrun!` (the function under test) and
#     `unstep!` (the per-iteration primitive M4.4 builds on).
#   * `src/ir/RState.jl` — the `initial::IState` field whose
#     correct restoration `unrun!`'s exit invariants depend on.
#   * `bennettvm_prd.md` (PRD v4) §3.3 (L3 layer), §3.9 (`unrun!`
#     signature), §3.16 (descriptive raise on guard fire).
#   * `references/foundational/bennett-1973-logical-reversibility.pdf`
#     §"Discussion" p. 529 col. 1 — Stage-3 retrace ancestor.
#   * `references/reverse-debugging/ocallahan-2017-rr-deployability.pdf`
#     §2.1 — the rr architecture this layer is the BennettVM
#     specialisation of.
#   * `docs/impl-plan/phase2-impl-plan.md` M4.4 (lines 221-223).
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (every test pins a
#     known-correct value), Rule 5 (mutation-proof), Rule 11
#     (literate test docstrings).

using Test
using BennettVM

# The M3.8 hand-built `countdown_program` factory and its
# `countdown_ref` oracle live in `test/reference/countdown.jl`
# (M8.1 — bd `bennettvm-do7`). Include directly so this file stands
# alone (no transitive include-order dependency on runtests.jl).
include(joinpath(@__DIR__, "reference", "countdown.jl"))

function _ur_small_arith_program()
    # Local re-declaration (Rule 4: per-file fixture autonomy). The
    # countdown VM exercises full multi-block dispatch; this tiny
    # single-block fixture exercises the no-control-flow path and is
    # the right fixture for tests that don't care about loop body
    # arithmetic.
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:x, :n, :xor, :n, :xor, Int64(0)),
        ],
        BennettVM.EndInstruction(:m, [:x]))
    return VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
end

# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------

@testset "unrun! is a no-op on a freshly-constructed RState (M4.4)" begin
    # Fresh from initial_state: step_count == 0, isempty(history).
    # The while-loop predicate (step_count > 0) is immediately false,
    # so the loop body never runs. The post-condition assertion
    # (isempty(history)) is trivially satisfied. unrun! must return
    # the RState unchanged.
    vm = countdown_program(2)
    rs = initial_state(vm, Dict(:n0 => Int64(2), :steps0 => Int64(0)))
    @test rs.step_count == 0
    @test isempty(rs.history)

    # Capture pre-unrun! state for equality comparison.
    pre_current = deepcopy(rs.current)
    pre_initial = deepcopy(rs.initial)

    returned = unrun!(rs, vm)
    @test returned === rs        # in-place mutation, same object returned
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current == pre_current
    @test rs.initial == pre_initial
end

@testset "unrun! after a single forward step recovers initial state (M4.4)" begin
    # Step 1 forward with K=64 (no push at step 1); unrun! once. The
    # loop predicate runs the body exactly once → one unstep! call →
    # step_count goes 1 → 0, loop exits. Post-condition: history
    # empty (was empty all along). current == initial.
    vm = countdown_program(2)
    rs = initial_state(vm, Dict(:n0 => Int64(2), :steps0 => Int64(0)))
    captured_initial = deepcopy(rs.current)

    step!(rs, vm; checkpoint_interval=64)
    @test rs.step_count == 1
    @test rs.current != captured_initial   # advanced

    unrun!(rs, vm)
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current == captured_initial
    @test rs.current == rs.initial
end

@testset "unrun! after full forward run to halt — countdown(3), K=4 (M4.4 / M6.2)" begin
    # THE LOAD-BEARING TEST. Run countdown(3) to halt with K=4. M3.8
    # established that countdown(N) takes 3N + 3 forward steps to
    # halt; for N=3 that is 12 steps. K=4 over 12 steps would push at
    # 4/8/12 in the M4.2-only world (pre-M6.2), but M6.2's
    # `!is_injective(instr)` AND-clause narrows the push set to
    # K-multiples whose instruction is non-injective. For countdown(3):
    #   step 4: Arith :add b_step1 — NON-injective → PUSH
    #   step 8: UncondExit b_step2 — injective → no push
    #   step 12: End b_done        — injective → no push
    # M6.2 → history length 1 (was 3 pre-M6.2).
    #
    # unrun! must walk all 12 steps back, draining history along the
    # way, and land at the captured initial state.
    vm = countdown_program(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    captured_initial = deepcopy(rs.current)

    run!(rs, vm; checkpoint_interval=4)
    @test is_halted(rs)
    @test rs.step_count == 12           # 3 * 3 + 3
    # M6.2: only step 4 pushes (Arith :add, non-injective).
    @test length(rs.history) == 1

    unrun!(rs, vm)
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current == captured_initial
    @test rs.current == rs.initial
end

@testset "unrun! from halted state flips status back to :running (M4.4)" begin
    # countdown(2) terminates at step 9 (3*2 + 3) with status
    # :halted. The first iteration of unrun!'s loop calls unstep!,
    # which restores a pre-halt snapshot (the step-8 state, with
    # status :running). After the full loop, status MUST remain
    # :running because s.initial.status === :running.
    vm = countdown_program(2)
    rs = initial_state(vm, Dict(:n0 => Int64(2), :steps0 => Int64(0)))
    run!(rs, vm; checkpoint_interval=4)
    @test is_halted(rs)
    @test rs.current.status === :halted

    unrun!(rs, vm)
    @test !is_halted(rs)
    @test rs.current.status === :running
    @test rs.step_count == 0
    @test rs.current == rs.initial
end

@testset "unrun! drains all surviving checkpoints — K=2 over 10 steps (M4.4 / M6.2)" begin
    # K=2 over 10 forward steps on countdown(3). countdown(3) dispatched
    # injectivity (M6.2):
    #   step 2: UncondExit       — injective → no push
    #   step 4: Arith :add b_step1 — NON-injective → PUSH
    #   step 6: Arith :sub b_step2 — NON-injective → PUSH
    #   step 8: UncondExit       — injective → no push
    #   step 10: Arith :add b_step3 — NON-injective → PUSH
    # M6.2 → 3 pushes at [4, 6, 10] (pre-M6.2 was 5 at [2,4,6,8,10]).
    # 10 < 12 → still :running (no halt yet); we partial-reverse a
    # partial-forward run, which is the most stressful exercise of
    # multi-checkpoint truncation.
    vm = countdown_program(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    captured_initial = deepcopy(rs.current)

    for _ in 1:10
        step!(rs, vm; checkpoint_interval=2)
    end
    @test rs.step_count == 10
    # M6.2: 3 surviving pushes (non-injective K-multiples 4, 6, 10).
    @test length(rs.history) == 3
    @test rs.history[1].step == 4
    @test rs.history[2].step == 6
    @test rs.history[3].step == 10
    @test !is_halted(rs)   # still mid-run

    unrun!(rs, vm)
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current == captured_initial
    @test rs.current == rs.initial
end

@testset "unrun! max_unsteps guard fires descriptively (M4.4)" begin
    # 10 forward steps with K=2 → step_count=10. Call unrun! with
    # max_unsteps=2; the guard MUST fire on iteration 3 (n >= 2 with
    # n having been incremented twice). The error message must name
    # "max_unsteps" and "exceeded". The RState is left mid-reverse:
    # step_count > 0 (NOT rolled back).
    vm = countdown_program(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    for _ in 1:10
        step!(rs, vm; checkpoint_interval=2)
    end
    @test rs.step_count == 10
    pre_step_count = rs.step_count

    err = try
        unrun!(rs, vm; max_unsteps=2)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("max_unsteps", err.msg)
    @test occursin("exceeded", err.msg)
    @test occursin("mid-reverse", err.msg)

    # RState left mid-reverse (NOT rolled back). Two unstep!s ran
    # before the guard fired, so step_count == pre - 2 == 8.
    @test rs.step_count == pre_step_count - 2
    @test rs.step_count > 0
end

@testset "unrun! post-condition assertion fires on corrupted history (M4.4)" begin
    # The load-bearing structural assertion test. Construct a
    # scenario where after the unstep! loop terminates
    # (step_count == 0), s.history is non-empty.
    #
    # This cannot arise from correct unstep! behaviour because:
    #   - M4.3's truncation rule is `pop while step > target`.
    #   - The final loop iteration sets target = 0 and pops entries
    #     with step > 0.
    #   - M4.2's push policy carves out step 0 (guarded by
    #     `step_count > 0`), so no step-0 entries appear naturally.
    #
    # We manually push a step-0 CheckpointEntry into the history
    # vector. The unstep! truncation rule (step > target=0) won't
    # remove it on the final iteration (0 is not > 0). After the
    # loop, step_count == 0 but history is non-empty → unrun! must
    # raise its structural post-condition error.
    vm = _ur_small_arith_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))
    step!(rs, vm; checkpoint_interval=64)
    @test rs.step_count == 1
    @test isempty(rs.history)

    # Inject a step-0 CheckpointEntry (manual corruption). This
    # entry has step==0, which violates M4.2's carve-out but does
    # NOT violate `unstep!`'s preconditions — `unstep!` will simply
    # leave it alone on the final iteration's truncation pass
    # (target=0; step=0 is NOT > 0; entry retained).
    bogus_snapshot = deepcopy(rs.current)
    bogus_entry = BennettVM.CheckpointEntry(bogus_snapshot, 0)
    pushfirst!(rs.history, bogus_entry)   # at front so it stays as the unstep! truncates from the back
    @test length(rs.history) == 1

    err = try
        unrun!(rs, vm)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("post-condition", err.msg)
    @test occursin("non-empty", err.msg) || occursin("history", err.msg)
end

@testset "unrun! does NOT manually reset status (M4.4)" begin
    # Construct a degenerate RState whose `initial.status === :error`
    # (initial_state would never produce this; the 4-arg RState
    # constructor does NOT enforce a :running check on initial). Run
    # a forward step (this requires current.status === :running, so
    # we set current separately from initial); then unrun!. The
    # post-state status MUST be :error — emerges from s.initial, NOT
    # from a manual :running reset hidden inside unrun!.
    #
    # If a future "fix" adds `s.current.status = :running` at the
    # end of unrun!, this test turns RED.
    vm = _ur_small_arith_program()

    # Build current via initial_state (so the program is well-formed
    # for step!), but then override initial.status to :error.
    rs = initial_state(vm, Dict(:n => Int64(7)))
    rs.initial = BennettVM.IState(rs.initial.pc,
                                  deepcopy(BennettVM.active_locals(rs.initial)),
                                  :error)
    @test rs.initial.status === :error
    @test rs.current.status === :running    # current came from initial_state

    # Forward step (current is :running, so step! is allowed).
    step!(rs, vm; checkpoint_interval=64)
    @test rs.step_count == 1

    # unrun! → loop body runs once → unstep! falls back to s.initial
    # (no checkpoint pushed at K=64 / 1 step) → s.current becomes
    # deepcopy(s.initial), inheriting status :error.
    unrun!(rs, vm)
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current.status === :error
    @test rs.current == rs.initial
end

@testset "unrun! exit invariants — all three together (M4.4)" begin
    # After a full unrun!, the canonical "fully reversed" predicate
    # is the conjunction of:
    #   (a) step_count == 0
    #   (b) isempty(history)
    #   (c) current == initial
    # All three must hold. M4.5 will rest its round-trip property on
    # all three; M4.4 must pin all three from the inside-out
    # perspective of unrun!'s exit guarantees.
    vm = countdown_program(2)
    rs = initial_state(vm, Dict(:n0 => Int64(2), :steps0 => Int64(0)))
    captured_initial = deepcopy(rs.current)

    run!(rs, vm; checkpoint_interval=3)   # different K from earlier tests for variety
    @test is_halted(rs)

    unrun!(rs, vm)
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current == captured_initial
    @test rs.current == rs.initial
    # Bonus structural: returned RState's status is :running
    # (inherited from initial), not :halted.
    @test rs.current.status === :running
    @test !is_halted(rs)
end

@testset "unrun! returns the same RState (chainable, M4.4)" begin
    # The signature is `::RState` and the implementation mutates
    # in place. Returning the same object means callers can chain
    # `unrun!(run!(initial_state(...), prog), prog)` exactly the
    # way the spike PRD v3 §5.4 and PRD v4 §3.9 specify.
    vm = countdown_program(1)
    rs = initial_state(vm, Dict(:n0 => Int64(1), :steps0 => Int64(0)))
    run!(rs, vm; checkpoint_interval=2)
    returned = unrun!(rs, vm)
    @test returned === rs    # identity, not equality
end
