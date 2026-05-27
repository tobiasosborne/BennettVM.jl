# test/test_unstep.jl — M4.3 unit + integration tests for `unstep!`,
# the backward primitive of the L3 checkpoint-replay history layer
# (bd `bennettvm-3do`).
#
# # Why these tests exist
#
# M4.3 lands the consumer of M4.2's periodic-checkpoint pushes: a single-
# step backward primitive that finds the nearest `CheckpointEntry` at-or-
# before the target step, deepcopies its snapshot into `s.current`,
# truncates "future" entries off `s.history`, and replays `step!`
# forward (with `checkpoint_interval = typemax(Int)`) to reach the
# target. Per CLAUDE.md Rule 4 ("'Runs without errors' is not a passing
# test"), every `@test` below pins one specific structural fact against
# a known-correct value. The most load-bearing tests are:
#
#   - **Single-step revert after one forward step.** The simplest
#     non-trivial reversal: step once with K=64 (no push fires), unstep
#     once, assert `s.current == s.initial` and `s.step_count == 0`.
#     Pins the fallback-to-`s.initial` code path because no checkpoint
#     exists.
#
#   - **Restore-side deepcopy invariant.** The defense-in-depth Q2.2
#     mirror of M4.1's constructor-side deepcopy. After unstepping
#     across a checkpoint, mutating `s.current` MUST NOT corrupt the
#     checkpoint snapshot in `s.history`. Without the deepcopy at
#     restore, every subsequent `step!` during replay would mutate the
#     checkpoint snapshot via the Dict-aliasing path; the next unstep!
#     targeting the same checkpoint would then see a silently corrupted
#     snapshot. This test would catch that.
#
#   - **History truncation correctness.** Step 6 times with K=2 (push
#     at 2/4/6, history length 3), unstep! once → target=5 → no
#     checkpoint exactly at 5; nearest <= 5 is step 4. Restore step-4,
#     replay 1 step. History must be `[step-2, step-4]` (step-6 popped;
#     step-4 retained because it is <= target).
#
#   - **No-spurious-push during replay.** Replay calls `step!(...;
#     checkpoint_interval=typemax(Int))`. M4.2's push gate is `step_count
#     % K == 0 && > 0`; with K=typemax(Int) for any step_count in
#     `[1, typemax-1]` this is `step_count != 0`, so no push fires. Test
#     pins history length to exactly len_before - n_popped.
#
#   - **Multiple unstep!s all the way back.** A loose simulation of
#     M4.4's `unrun!`: loop unstep! until step_count == 0, then assert
#     `s.current == s.initial`, `isempty(s.history)`, `s.step_count == 0`.
#     Pins the round-trip invariant M4.4 will formalise.
#
# # Mutation-proof intent (Rule 5)
#
# Each test corresponds to a specific perturbation in `unstep!` /
# `RState` / `initial_state` that would silently break a real downstream
# consumer:
#
#   - Remove the deepcopy at restore (step 4) → restore-side deepcopy
#     invariant test turns RED. The next replay step!'s mutation of
#     s.current corrupts the source snapshot.
#   - Move the truncation BEFORE the restore → no easy direct RED, but
#     the "history truncation across checkpoint boundary" test still
#     catches a wrong target/start_step pairing because the wrong
#     checkpoint would be popped before the lookup.
#   - Pop entries with `step >= target` (instead of `> target`) →
#     "history truncation across checkpoint boundary" test turns RED:
#     the step-4 entry would be popped instead of retained.
#   - Use the constructor-default K=64 in the replay loop (instead of
#     `typemax(Int)`) → "no spurious push during replay" test turns RED
#     in a corner case where target lands on a multiple of 64; for the
#     small N used in this file, this would not directly RED but the
#     "history truncation" + "multiple unstep!s" tests would surface
#     the bug at long-running tests.
#   - Replay from `start_step` to `target - 1` (off-by-one) instead of
#     `target` → "single unstep! after K steps recovers state at step
#     K-1" turns RED, because s.current would be one step further back
#     than expected.
#   - Drop the `s.step_count > 0` precondition raise → "unstep! at
#     step_count=0 raises descriptively" turns RED (silent no-op
#     instead of error).
#   - Drop the 4-arg RState constructor → "RState backwards-compat
#     constructors work" turns RED (or a compile error).
#   - Drop `initial` from RState `==` → "Equality with different
#     initial distinguishes RStates" turns RED.
#   - Drop the deepcopy in the 2-arg / 3-arg RState constructors →
#     "RState's new initial field is populated correctly" test catches
#     the alias by stepping the rs and confirming initial is untouched.
#   - Drop the deepcopy in initial_state (the explicit 4-arg call) → no
#     easy direct RED (the 2-arg-default deepcopy still defends), but
#     this is BY DESIGN — defense-in-depth means losing one defense
#     leaves the other.
#
# Ref:
#   * `src/history/Replay.jl` — `unstep!` (the function under test).
#   * `src/ir/RState.jl` — the `initial::IState` field this milestone
#     adds and the 4-arg constructor it uses.
#   * `src/interpreter/Interpreter.jl` — `step!` (replay primitive,
#     called with `checkpoint_interval=typemax(Int)`).
#   * `bennettvm_prd.md` (PRD v4) §3.3 (L3 layer), §3.9 (`unstep!`
#     signature), §3.16 (descriptive raise on step_count = 0).
#   * `references/reverse-debugging/ocallahan-2017-rr-deployability.pdf`
#     §2.1 — the rr architecture this layer is the BennettVM
#     specialisation of.
#   * `spike/RETROSPECTIVE.md` Q2.2 — the deepcopy / Dict-aliasing
#     lesson this milestone applies at the restore site.
#   * `docs/impl-plan/phase2-impl-plan.md` M4.3 (lines 218-220).
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (every test pins a
#     known-correct value), Rule 5 (mutation-proof), Rule 11
#     (literate test docstrings).

using Test
using BennettVM

# The M3.8 hand-built `build_countdown_vm` factory is defined as a top-
# level function in `test_forward_interpreter.jl`, which `runtests.jl`
# includes BEFORE this file. The `_small_arith_program` and
# `_empty_main_program` fixtures from `test_checkpoint_push.jl` are
# similarly in scope.

# Re-declare these tiny fixtures (Julia symbol re-binding in
# top-level test scope is permitted; they're identical to the
# `test_checkpoint_push.jl` versions). Keeping a local copy means a
# future reorder of include() lines in runtests.jl doesn't silently
# decouple this file from its fixture dependencies.

function _u_small_arith_program()
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

@testset "RState's new `initial` field is populated correctly (M4.3)" begin
    # The 2-arg back-compat constructor must default `initial =
    # deepcopy(current)`. Pinning the four-tuple `pc / locals / status /
    # ==-to-current-at-construction` is the bottom-of-stack guarantee
    # every downstream M4.3 test (and M4.4 / M4.5) relies on.
    vm = build_countdown_vm(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))

    # Fields are populated.
    @test rs.initial isa BennettVM.IState
    @test rs.initial == rs.current
    # But they are NOT the same object — the deepcopy at construction
    # (initial_state's 4-arg call + RState's 2-arg-default deepcopy)
    # has produced a distinct IState. This is the load-bearing
    # invariant: without it, subsequent step! mutations would corrupt
    # rs.initial via the Dict-aliasing path.
    @test rs.initial !== rs.current
    @test rs.initial.locals !== rs.current.locals

    # The initial reflects step-0 state per PRD v4 §3.9: pc =
    # entry-block fwd_address, locals == input dict, status :running.
    @test rs.initial.pc == vm.label_table[vm.entry_label].fwd_address
    @test rs.initial.locals == Dict(:n0 => Int64(3), :steps0 => Int64(0))
    @test rs.initial.status === :running

    # Step forward; initial MUST remain frozen at step-0 state
    # (defense-in-depth: this confirms the deepcopy in both
    # initial_state AND the RState 2-arg constructor took effect).
    initial_locals_snapshot = copy(rs.initial.locals)
    initial_pc_snapshot = rs.initial.pc
    initial_status_snapshot = rs.initial.status
    for _ in 1:5
        step!(rs, vm; checkpoint_interval=64)
    end
    @test rs.initial.pc == initial_pc_snapshot
    @test rs.initial.locals == initial_locals_snapshot
    @test rs.initial.status === initial_status_snapshot
    # And the rs.current HAS moved.
    @test rs.current != rs.initial
end

@testset "RState backwards-compat constructors work (M4.3)" begin
    # 2-arg: step_count defaults to 0, initial defaults to deepcopy(current).
    istate = BennettVM.IState(1, Dict(:n => Int64(5)), :running)
    rs2 = BennettVM.RState(istate, BennettVM.AbstractHistoryEntry[])
    @test rs2.step_count == 0
    @test rs2.initial == rs2.current
    @test rs2.initial !== rs2.current  # deepcopy made distinct objects

    # 3-arg: explicit step_count, initial defaults to deepcopy(current).
    istate3 = BennettVM.IState(1, Dict(:n => Int64(5)), :running)
    rs3 = BennettVM.RState(istate3, BennettVM.AbstractHistoryEntry[], 7)
    @test rs3.step_count == 7
    @test rs3.initial == rs3.current
    @test rs3.initial !== rs3.current

    # 4-arg: explicit initial. The honest constructor.
    cur = BennettVM.IState(2, Dict(:x => Int64(99)), :running)
    init = BennettVM.IState(1, Dict(:x => Int64(0)), :running)
    rs4 = BennettVM.RState(cur, BennettVM.AbstractHistoryEntry[], 1, init)
    @test rs4.step_count == 1
    @test rs4.initial === init   # 4-arg form does NOT deepcopy (caller's opt-in)
    @test rs4.current === cur
    @test rs4.initial != rs4.current
end

@testset "Equality with different `initial` distinguishes RStates (M4.3)" begin
    # Same current, same history, same step_count, but different initial.
    # The two RStates MUST NOT be ==.
    cur1 = BennettVM.IState(1, Dict(:n => Int64(0)), :running)
    cur2 = BennettVM.IState(1, Dict(:n => Int64(0)), :running)
    init_a = BennettVM.IState(1, Dict(:n => Int64(5)), :running)
    init_b = BennettVM.IState(1, Dict(:n => Int64(7)), :running)
    rs_a = BennettVM.RState(cur1, BennettVM.AbstractHistoryEntry[], 0, init_a)
    rs_b = BennettVM.RState(cur2, BennettVM.AbstractHistoryEntry[], 0, init_b)
    @test rs_a.current == rs_b.current
    @test rs_a.history == rs_b.history
    @test rs_a.step_count == rs_b.step_count
    @test rs_a.initial != rs_b.initial
    @test rs_a != rs_b
end

@testset "unstep! at step_count=0 raises descriptively (M4.3)" begin
    # PRD v4 §3.16 + Rule 1: unstep! on step_count == 0 MUST raise
    # an ErrorException with a message naming step_count. Silent no-op
    # is banned.
    vm = _u_small_arith_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))
    @test rs.step_count == 0
    err = try
        unstep!(rs, vm)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("step_count", err.msg)
    @test occursin("0", err.msg)
    @test occursin("§3.16", err.msg) || occursin("3.16", err.msg)
end

@testset "Single unstep! after one step recovers initial state (M4.3)" begin
    # countdown(3) with K=64: step 1 forward; no checkpoint pushes at
    # step 1 (1 % 64 != 0). unstep! → target=0 → no checkpoint at <= 0
    # → fall back to s.initial → restore + replay 0 steps. The result
    # MUST equal the freshly-constructed initial state.
    vm = build_countdown_vm(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    expected_initial = deepcopy(rs.current)  # snapshot for comparison
    @test isempty(rs.history)

    step!(rs, vm; checkpoint_interval=64)
    @test rs.step_count == 1
    @test isempty(rs.history)  # K=64 + 1 step → no push
    # The forward step has advanced rs.current away from initial.
    @test rs.current != expected_initial

    unstep!(rs, vm)
    @test rs.step_count == 0
    @test rs.current == expected_initial
    @test rs.current == rs.initial
    @test isempty(rs.history)  # nothing was popped because nothing was pushed
end

@testset "Single unstep! after K steps recovers state at step K-1 (M4.3)" begin
    # countdown(3) with K=4: step 4 forward; push fires at step 4.
    # unstep! → target=3 → no checkpoint at <= 3 (the only entry is
    # step 4 > 3) → fall back to s.initial → restore + replay 3 steps.
    # Result MUST match a fresh run stepped 3 times.
    vm = build_countdown_vm(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))

    # Construct the expected step-3 state via a separate fresh run.
    rs_ref = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    for _ in 1:3
        step!(rs_ref, vm; checkpoint_interval=10_000)  # no pushes
    end
    expected_step3_current = deepcopy(rs_ref.current)

    # Now the actual test run: 4 forward steps with K=4 (push at 4),
    # then unstep!.
    for _ in 1:4
        step!(rs, vm; checkpoint_interval=4)
    end
    @test rs.step_count == 4
    @test length(rs.history) == 1
    @test rs.history[1].step == 4

    unstep!(rs, vm)
    @test rs.step_count == 3
    @test rs.current == expected_step3_current
    # The checkpoint at step 4 is popped (4 > target=3).
    @test isempty(rs.history)
end

@testset "Unstep! from a halted state (M4.3 / M6.2)" begin
    # countdown(2) terminates with status :halted at step 9
    # (3N + 3 = 9 for N=2). Run to halt; unstep! once. Status must
    # flip back to :running, step_count -> 8, history truncation
    # correct.
    vm = build_countdown_vm(2)
    rs = initial_state(vm, Dict(:n0 => Int64(2), :steps0 => Int64(0)))
    run!(rs, vm; checkpoint_interval=4)
    @test is_halted(rs)
    @test rs.step_count == 9
    # countdown(2) dispatched-step sequence (M6.2 injectivity in []):
    #   1 Begin [inj], 2 UncondExit [inj],
    #   3 Arith :sub [non-inj], 4 Arith :add [non-inj],
    #   5 UncondExit [inj],
    #   6 Arith :sub [non-inj], 7 Arith :add [non-inj],
    #   8 UncondExit [inj],
    #   9 End [inj].
    # K=4 candidates: steps 4 and 8. Of these, step 4 is non-injective
    # (Arith :add), step 8 is injective (UncondExit). M6.2 → only step
    # 4 pushes. Pre-M6.2 this was length 2 ([4, 8]); post-M6.2 length 1.
    @test length(rs.history) == 1
    @test rs.history[1].step == 4

    unstep!(rs, vm)
    @test rs.step_count == 8
    @test rs.current.status === :running
    # target=8, nearest checkpoint with step <= 8 is the step-4 entry
    # (the only one). Restore step 4, replay forward 4 steps to reach
    # step 8. Truncation: pop entries with step > 8 — none. The step-4
    # checkpoint is RETAINED (4 is not > 8). M6.2 introduces no new
    # pushes during replay (the replay loop uses checkpoint_interval=
    # typemax(Int) so the gate never fires, M6.2 gate or otherwise).
    @test length(rs.history) == 1
    @test rs.history[end].step == 4
end

@testset "Unstep! across a checkpoint boundary (retained-at-target) (M4.3)" begin
    # K=4, step 5 times. Push fires at step 4 only (5 % 4 != 0).
    # step_count = 5, history = [step-4-entry].
    # unstep! → target=4 → nearest checkpoint is step 4 (== target) →
    # restore checkpoint, replay 0 steps.
    # Truncation rule: pop while step > target. step-4 is NOT > 4, so
    # it is retained.
    vm = build_countdown_vm(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    for _ in 1:5
        step!(rs, vm; checkpoint_interval=4)
    end
    @test rs.step_count == 5
    @test length(rs.history) == 1

    # Capture the snapshot at the moment of unstep! call; the restored
    # s.current must equal this captured snapshot (content-equal, but
    # NOT the same object — deepcopy at restore).
    captured_step4_snapshot = deepcopy(rs.history[1].snapshot)

    unstep!(rs, vm)
    @test rs.step_count == 4
    # The retained checkpoint at step 4 IS still on history.
    @test length(rs.history) == 1
    @test rs.history[1].step == 4
    # s.current matches the step-4 snapshot (content equality).
    @test rs.current == captured_step4_snapshot
    # And it is a DISTINCT object — restore deepcopied.
    @test rs.current !== rs.history[1].snapshot
end

@testset "Unstep! across a back-to-checkpoint boundary (fall-through) (M4.3)" begin
    # K=4, step 4 times. Push fires at step 4. step_count = 4,
    # history = [step-4-entry].
    # unstep! → target=3 → no checkpoint at <= 3 (the only entry is
    # step 4 > 3) → fall through to s.initial → replay 3 forward steps.
    # Truncation: step-4 entry is > 3, so it gets popped.
    vm = build_countdown_vm(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    for _ in 1:4
        step!(rs, vm; checkpoint_interval=4)
    end
    @test rs.step_count == 4
    @test length(rs.history) == 1

    # Expected step-3 state by independent fresh run.
    rs_ref = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    for _ in 1:3
        step!(rs_ref, vm; checkpoint_interval=10_000)
    end
    expected_step3 = deepcopy(rs_ref.current)

    unstep!(rs, vm)
    @test rs.step_count == 3
    @test rs.current == expected_step3
    # The step-4 entry got truncated (it was > target=3).
    @test isempty(rs.history)
end

@testset "Multiple unstep!s all the way back (M4.3 / M6.2)" begin
    # K=2, countdown(2) → 9 steps total. countdown(2) dispatched
    # injectivity (see "Unstep! from a halted state" testset):
    #   step 2: UncondExit       — injective; no push
    #   step 4: Arith :add       — NON-injective; PUSH at K=2
    #   step 6: Arith :sub b_step2 — NON-injective; PUSH at K=2
    #   step 8: UncondExit       — injective; no push
    # M6.2: history length 2 (steps [4, 6]); pre-M6.2 was 4.
    # Loop unstep! until step_count == 0 → full backward sweep.
    # M4.4's `unrun!` is essentially this loop; M4.3 must already
    # support it as a primitive sequence.
    vm = build_countdown_vm(2)
    rs = initial_state(vm, Dict(:n0 => Int64(2), :steps0 => Int64(0)))
    expected_initial = deepcopy(rs.current)
    run!(rs, vm; checkpoint_interval=2)
    @test is_halted(rs)
    @test rs.step_count == 9
    # M6.2: 2 non-injective steps at K-multiples (4, 6); pre-M6.2 was 4.
    @test length(rs.history) == 2

    # Loop unstep! until exhausted.
    while rs.step_count > 0
        unstep!(rs, vm)
    end
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current == expected_initial
    @test rs.current == rs.initial
end

@testset "History truncation correctness — mid-K target (M4.3 / M6.2)" begin
    # K=2, step 6 times on countdown(3). Dispatched injectivity
    # (countdown(3) is the canonical fixture; see test_checkpoint_push
    # "push fires at exactly K, 2K, 3K" testset for the full layout):
    #   step 2: UncondExit       — injective; no push
    #   step 4: Arith :add b_step1 — NON-injective; PUSH at K=2
    #   step 6: Arith :sub b_step2 — NON-injective; PUSH at K=2
    # M6.2: history=[step-4, step-6] (pre-M6.2 was [step-2, step-4,
    # step-6]).
    # unstep! once → target=5 → nearest checkpoint <= 5 is step 4.
    # Restore step-4, replay 1 step. Truncation: pop entries with step
    # > 5. step-6 > 5 → popped. step-4 not > 5 → retained.
    # Expected history after unstep!: [step-4].
    vm = build_countdown_vm(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    for _ in 1:6
        step!(rs, vm; checkpoint_interval=2)
    end
    @test rs.step_count == 6
    # M6.2: 2 non-injective K-multiples (4, 6); pre-M6.2 was 3.
    @test length(rs.history) == 2
    @test rs.history[1].step == 4
    @test rs.history[2].step == 6

    unstep!(rs, vm)
    @test rs.step_count == 5
    # M6.2: step-6 popped (6 > target=5); step-4 retained (4 not > 5).
    # Pre-M6.2 this was length 2 (retained [step-2, step-4]).
    @test length(rs.history) == 1
    @test rs.history[1].step == 4
end

@testset "Restore-side deepcopy invariant — checkpoint case (M4.3)" begin
    # Mutate s.current after a checkpoint-targeted unstep!. The
    # checkpoint snapshot in s.history MUST remain undisturbed.
    # Without the deepcopy at restore (step 4 of the algorithm),
    # s.current would alias the snapshot and the mutation would
    # corrupt the checkpoint for future unstep!s.
    vm = build_countdown_vm(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    for _ in 1:5
        step!(rs, vm; checkpoint_interval=4)
    end
    # history = [step-4-entry], step_count=5.
    unstep!(rs, vm)   # target=4 → restore step-4 checkpoint, retain it
    @test length(rs.history) == 1
    @test rs.history[1].step == 4

    # Capture the snapshot's state BEFORE the mutation.
    snap_pc_before = rs.history[1].snapshot.pc
    snap_locals_before = copy(rs.history[1].snapshot.locals)
    snap_status_before = rs.history[1].snapshot.status

    # Forcibly mutate rs.current. None of these MAY reach the
    # checkpoint snapshot.
    rs.current.pc = -42
    rs.current.status = :error
    for k in collect(keys(rs.current.locals))
        rs.current.locals[k] = Int64(-999)
    end

    # Snapshot unchanged.
    @test rs.history[1].snapshot.pc == snap_pc_before
    @test rs.history[1].snapshot.locals == snap_locals_before
    @test rs.history[1].snapshot.status === snap_status_before
    # And they are distinct Dict instances.
    @test rs.history[1].snapshot.locals !== rs.current.locals
end

@testset "Restore-side deepcopy invariant — initial fallback case (M4.3)" begin
    # The mirror of the previous test, but for the s.initial-fallback
    # restore path. After an unstep! that falls through to s.initial,
    # mutating s.current MUST NOT corrupt s.initial.
    vm = _u_small_arith_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))
    step!(rs, vm; checkpoint_interval=64)  # K=64, 1 step, no push
    @test rs.step_count == 1
    @test isempty(rs.history)

    unstep!(rs, vm)  # falls through to s.initial; replay 0 steps
    @test rs.step_count == 0
    @test rs.current == rs.initial

    initial_pc_before = rs.initial.pc
    initial_locals_before = copy(rs.initial.locals)
    initial_status_before = rs.initial.status

    # Mutate s.current. The initial anchor MUST remain untouched.
    rs.current.pc = -1
    rs.current.locals[:junk] = Int64(123)
    rs.current.status = :error

    @test rs.initial.pc == initial_pc_before
    @test rs.initial.locals == initial_locals_before
    @test rs.initial.status === initial_status_before
    @test rs.initial.locals !== rs.current.locals
end

@testset "No-spurious-push during replay (M4.3 / M6.2)" begin
    # K=2, step 6 times on countdown(3). Per the M6.2-aware accounting
    # in the prior testset, history is [step-4, step-6] (length 2).
    # unstep! once → target=5 → nearest <= 5 is step 4, restore +
    # replay 1 step. The replay's step!() call uses
    # checkpoint_interval=typemax(Int), so it must NOT push (this is
    # the load-bearing M4.3 invariant; M6.2 doesn't change it).
    # After unstep!, history length must be exactly 1 (step-6 popped;
    # step-4 retained; no new push from replay).
    vm = build_countdown_vm(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    for _ in 1:6
        step!(rs, vm; checkpoint_interval=2)
    end
    # M6.2: 2 non-injective K-multiples; pre-M6.2 was 3.
    @test length(rs.history) == 2

    unstep!(rs, vm)
    @test rs.step_count == 5
    # M6.2: step-6 popped (> target=5); step-4 retained. No new push
    # during replay (typemax(Int) suppresses the gate). Length 1
    # (pre-M6.2 was 2).
    @test length(rs.history) == 1
end

@testset "unstep! is a no-op equivalent on a sequence of step/unstep (M4.3)" begin
    # The semantics check: for any number of forward steps N where N
    # is small enough to not hit halt, step N times then unstep! N
    # times MUST return s to initial state. This is essentially the
    # M4.5 round-trip property test for the K-driven L3 layer.
    vm = build_countdown_vm(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    expected_initial = deepcopy(rs.current)

    # Step 7 (out of the 12 total countdown(3) takes).
    for _ in 1:7
        step!(rs, vm; checkpoint_interval=3)
    end
    @test rs.step_count == 7

    # Unstep all 7.
    for _ in 1:7
        unstep!(rs, vm)
    end
    @test rs.step_count == 0
    @test rs.current == expected_initial
    @test isempty(rs.history)
end
