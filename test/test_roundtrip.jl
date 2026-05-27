# test/test_roundtrip.jl — M4.5 capstone: round-trip property test for
# the L3 checkpoint-replay history layer (bd `bennettvm-n2g`).
#
# # What this test exercises
#
# This is the integrated end-to-end exercise of the full M4 milestone:
# M4.1's `CheckpointEntry`, M4.2's periodic push policy inside `step!`,
# M4.3's `unstep!` (find-nearest-checkpoint + truncate + replay), and
# M4.4's `unrun!` loop driver. Each of M4.1-M4.4 has its own per-bead
# unit-test file (test_checkpoint_entry.jl, test_checkpoint_push.jl,
# test_unstep.jl, test_unrun.jl) which together comprise 849 passing
# assertions at the baseline. None of them, however, drives the full
# `countdown(5)` program end-to-end with K=4 and verifies that every
# pre-step IState captured during the forward sweep is recovered
# byte-for-byte by `unstep!` on the way back.
#
# # Why countdown(5) with K=4 is the right capstone shape
#
# `countdown(5)` takes exactly 18 forward steps to halt (3N + 3 for
# N=5, as M3.8's countdown formula and `test_unstep.jl`'s "Unstep!
# from a halted state" test confirm). With K=4, M4.2's push gate
# (`step_count % K == 0 && step_count > 0`) fires at steps 4, 8, 12,
# and 16 — four checkpoints, one mid-run replay distance of 1-3 steps
# between any checkpoint and the next, and one fall-through-to-initial
# region for the first 3 backward steps. This is the smallest
# countdown shape that exercises:
#
#   - multiple checkpoint boundaries (so M4.3's truncate-the-tail
#     logic runs more than once),
#   - non-trivial replay distances (1 or 2 forward replay-steps per
#     unstep! across a K-boundary),
#   - the fall-through-to-`s.initial` path (for the final 3
#     backward steps after the step-4 checkpoint is popped),
#   - cross-block dispatch on every forward and (by replay) backward
#     transition (so M3.6's `_handle_cross_block_dispatch!` is in the
#     loop the entire time), and
#   - the halt boundary (the program does halt; `is_halted` flips
#     `:running` → `:halted`, and unstep! must back out of it).
#
# countdown(0) skips the decrement chain entirely and would not
# exercise replay; countdown(2) does not have enough K-boundaries
# (only step-4 and step-8 push fires before halt at step 9 with K=4).
# countdown(5) is the smallest member of the family that hits all
# the structural cases simultaneously while still being small enough
# to enumerate every per-step IState explicitly for the per-step
# inverse pattern (test 4 below) — 18 snapshots are small enough to
# log and inspect by hand if something goes wrong.
#
# # The per-step inverse pattern (THE load-bearing test, test 4)
#
# The aggregate round-trip test (test 2) is necessary but
# insufficient. Per `spike/RETROSPECTIVE.md` Q3 §"Unexpectedly hard":
#
#   "a single-pass aggregate round-trip can mask mid-sequence
#    inversion bugs because a correct inverse later in the sequence
#    overwrites a corrupted intermediate state. Pass 3 added a
#    per-step inverse test ... that exercises `unstep!` immediately
#    after each `step!`."
#
# The spike's analogue lives at `spike/test/test_roundtrip.jl:80-135`.
# M4.5 adapts that pattern for the L3 layer: rather than asserting
# `unstep!` immediately after each `step!` (the spike's per-step
# discipline, valid because the spike pushed every step), here we
# capture a deepcopy snapshot of `s.current` after each forward
# step (indexed by `s.step_count`) and assert during the backward
# sweep that each `unstep!` lands `s.current` equal to the captured
# forward snapshot at the new `step_count`. This catches a
# middle-step inverse bug that the aggregate round-trip cannot see,
# because a corrupted intermediate snapshot during the backward
# walk is immediately visible at the per-step level even though the
# final step (which restores `s.initial`) would overwrite the
# corruption.
#
# # Mutation-proof matrix (Rule 5)
#
# Below is the mapping from a specific mutation in M4.1-M4.4
# production code to the test number in this file that turns RED.
# This is the load-bearing column: a test that does not catch a
# real-world buggy mutation is not pulling its weight (CLAUDE.md
# Rule 5).
#
#   - Drop the deepcopy at restore in `unstep!` step (4)
#     (src/history/Replay.jl line `s.current = deepcopy(restore_snap)`):
#       → test 4 (per-step inverse) turns RED at the boundary between
#         the unstep! that restores a checkpoint and the next unstep!
#         that mutates s.current during replay. The next unstep!
#         finds the checkpoint silently corrupted.
#
#   - Change unstep!'s truncation rule from `> target` to `>= target`
#     (src/history/Replay.jl line `_entry_step(s.history[end]) > target`):
#       → test 4 + test 9 RED. The retained-at-target checkpoint
#         gets popped one unstep! too early, so the next backward
#         step lands at the wrong snapshot.
#
#   - Forget the typemax kwarg in unstep!'s replay loop (use K=64
#     accidentally instead of typemax) (src/history/Replay.jl line
#     `step!(s, prog; checkpoint_interval=typemax(Int))`):
#       → test 9 (history length exactly 4) turns RED — replays
#         create spurious extra checkpoint entries, so the post-run
#         history is longer than expected. Test 6 (run!+unrun!
#         identity) also catches it indirectly through the RState
#         equality (`history` field).
#
#   - Drop the `isempty(history)` post-condition assertion in
#     `unrun!` (src/history/Replay.jl):
#       → does not directly RED any test here (silent pass on
#         post-condition would still leave a non-empty history),
#         BUT test 6 / test 9 catch the contamination via the
#         RState == check and the history-length assertion.
#
#   - Off-by-one in unstep!'s replay loop predicate (e.g., replay
#     from start_step to target - 1 instead of target):
#       → test 4 (per-step inverse) turns RED immediately: every
#         backward step lands one step further back than expected,
#         so the captured-forward-snapshot equality check fails on
#         the very first replay-crossing unstep!.
#
#   - Forgetting to pop the step-> target entries (truncation
#     omitted entirely):
#       → test 6 (run!+unrun! identity) RED (history not drained);
#         test 9 RED (post-forward history has wrong content);
#         test 4 RED (the next unstep! finds the wrong checkpoint).
#
#   - Manual status reset to :running added at end of unrun!:
#       → not directly tested here (test_unrun.jl has the dedicated
#         M4.4 test for this), but test 2's status-equality
#         assertion (which pins :running) and test 6/7 (which pin
#         RState ==, including initial.status) catch any divergence.
#
#   - Replace s.initial fallback with default IState() inside
#     unstep!:
#       → test 2 RED (current.pc != initial.pc; current.locals
#         missing :n0 / :steps0 inputs).
#
#   - K=1 degenerate (every step pushes):
#       → test 5 with K=1 forces M4.2's push policy to push every
#         step. Tests M4.3's nearest-checkpoint search and
#         "checkpoint exactly at target" retention.
#
#   - K=typemax(Int) (never push):
#       → test 5 with K=typemax forces M4.3's fall-through-to-
#         s.initial path for every unstep!. Tests RState.initial
#         is correctly populated and deepcopied.
#
# Ref:
#   * CLAUDE.md Rule 4 — every test asserts a known-correct value.
#   * CLAUDE.md Rule 5 — mutation-proof discipline.
#   * CLAUDE.md Rule 11 — literate test files; the docstring above
#     is the file-level chapter.
#   * `spike/RETROSPECTIVE.md` Q3 §"Unexpectedly hard" — the
#     per-step inverse pattern's origin lesson.
#   * `spike/test/test_roundtrip.jl` lines 80-135 — the spike's
#     per-step inverse pattern that this M4.5 file adapts for L3.
#   * `bennettvm_prd.md` (PRD v4) §3.3 (three-layer history; L3),
#     §3.9 (`run!` / `unrun!` signatures), §3.13 (round-trip
#     invariant).
#   * `docs/impl-plan/phase2-impl-plan.md` M4.5 (lines 224-226).
#   * `test/reference/countdown.jl` — `countdown_program` factory
#     AND `countdown_ref` golden master (M8.1, bd `bennettvm-do7`).
#   * `test/test_unstep.jl`, `test/test_unrun.jl` — per-bead M4.3 /
#     M4.4 tests this file builds on.

using Test
using BennettVM

# `countdown_program` and `countdown_ref` live in
# `test/reference/countdown.jl` (M8.1 — bd `bennettvm-do7`). Include
# directly so this file stands alone (no transitive include-order
# dependency on runtests.jl).
include(joinpath(@__DIR__, "reference", "countdown.jl"))

# Hand-built single-block 3-instruction arithmetic program for test 8.
# A 1-block program with NO cross-block dispatch — exercises the L3
# layer in the degenerate "no _handle_cross_block_dispatch! call ever
# fires" regime that the countdown family always exercises. If a
# future regression breaks L3 only for single-block programs (e.g., a
# subtle interaction between the truncation pop loop and the
# cross-block dispatch's pc-rewrite that masks the bug for multi-block
# programs), test 8 catches it.
#
# Flat-stream count: Begin + 3 ArithAssign + End = 5 steps. With K=2,
# pushes at step 2 and step 4 → 2 history entries.
function _rt_threeop_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:n]),
        BennettVM.Instruction[
            # a := n xor (1 and 1)        — produces :a, destroys :n
            BennettVM.ArithmeticAssignment(:a, :n, :xor, Int64(1), :and, Int64(1)),
            # b := a add (1 and 1)        — produces :b, destroys :a
            BennettVM.ArithmeticAssignment(:b, :a, :add, Int64(1), :and, Int64(1)),
            # c := b sub (1 and 1)        — produces :c, destroys :b
            BennettVM.ArithmeticAssignment(:c, :b, :sub, Int64(1), :and, Int64(1)),
        ],
        BennettVM.EndInstruction(:m, [:c]))
    return VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
end

# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------

@testset "M4.5 — countdown(5) forward correctness vs golden master (K=4)" begin
    # Test 1: pin that the forward pass remains bit-for-bit correct
    # under the L3 push-every-K policy. M3.8 established forward
    # correctness without history pushes (K never matters because
    # M3.8 predates M4.2); M4.5 must re-pin it specifically WITH the
    # checkpoint pushes firing during the run, because a buggy push
    # path (e.g., one that accidentally mutates s.current.locals via
    # CheckpointEntry's snapshot field due to a dropped deepcopy)
    # could corrupt the forward computation silently.
    vm = countdown_program(5)
    rs = initial_state(vm, Dict(:n0 => Int64(5), :steps0 => Int64(0)))
    run!(rs, vm; checkpoint_interval=4)

    @test is_halted(rs)                                # halt status
    @test result(rs)[:n5] == Int64(0)                  # final n value
    @test result(rs)[:steps5] == countdown_ref(Int64(5))  # golden master
    @test result(rs)[:steps5] == Int64(5)              # golden master value pinned
end

@testset "M4.5 — aggregate round-trip on countdown(5), K=4" begin
    # Test 2: the aggregate round-trip test. Capture initial state
    # BEFORE run!; run! then unrun!; assert all six post-conditions.
    #
    # Pin all six instead of just `rs.current == initial`: any single
    # one of them passing while another fails is a Rule-1 bug that a
    # one-line check would silently hide.
    vm = countdown_program(5)
    rs = initial_state(vm, Dict(:n0 => Int64(5), :steps0 => Int64(0)))
    initial_current = deepcopy(rs.current)
    initial_rstate_initial = deepcopy(rs.initial)

    run!(rs, vm; checkpoint_interval=4)
    @test is_halted(rs)                                # forward landed at halt
    @test rs.step_count == 18                          # 3N+3 for N=5

    unrun!(rs, vm)
    # All six post-conditions:
    @test rs.current == initial_current                # content equality (M2.2)
    @test rs.current == rs.initial                     # M4.3 anchor field
    @test rs.initial == initial_rstate_initial         # initial NEVER mutated
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current.status === :running               # NOT :halted post-unrun!
    # Specific value-pinning: the locals contain n0/steps0, the
    # original inputs. If a future regression somehow restored a mid-
    # run intermediate state (e.g., :n3 / :steps3) instead of the
    # initial-step locals, the content equality above would catch it
    # but this explicit pin makes the failure message readable.
    @test rs.current.pc == initial_current.pc
    @test rs.current.locals[:n0] == Int64(5)
    @test rs.current.locals[:steps0] == Int64(0)
end

@testset "M4.5 — per-step forward snapshot capture (countdown(5), K=4)" begin
    # Test 3: forward-loop snapshot capture. Step through countdown(5)
    # one step at a time, capturing a deepcopy of rs.current after
    # EACH step into forward_snapshots[step_count]. Used by test 4
    # (the per-step inverse test) as the source-of-truth for what
    # rs.current should be after each backward unstep!.
    #
    # We exercise step!() directly (not run!) so we can inspect each
    # intermediate state — the load-bearing capture is then keyed by
    # step_count, which is the same index unstep! reduces by 1 on each
    # call. Total expected: 18 snapshots, indexed 1..18.
    vm = countdown_program(5)
    rs = initial_state(vm, Dict(:n0 => Int64(5), :steps0 => Int64(0)))

    forward_snapshots = BennettVM.IState[]
    # Forward sweep — record post-step IState by step_count.
    while !is_halted(rs)
        step!(rs, vm; checkpoint_interval=4)
        push!(forward_snapshots, deepcopy(rs.current))
    end

    # The exact count is M3.8's countdown(N) = 3N + 3 formula for
    # N=5: 18 steps. Pin it. This is also the index used by test 4.
    @test length(forward_snapshots) == 18
    @test rs.step_count == 18
    @test is_halted(rs)
    @test forward_snapshots[end].status === :halted     # the final snapshot IS the halt state
    @test forward_snapshots[end] == rs.current          # equivalent: last snapshot is rs.current
    # The pre-halt snapshot is :running (the previous step left
    # status :running; the End-instruction step flipped it to halted
    # at the very last step).
    @test forward_snapshots[end-1].status === :running
end

@testset "M4.5 — per-step backward verification (countdown(5), K=4)" begin
    # Test 4: THE LOAD-BEARING PER-STEP INVERSE TEST.
    #
    # Re-run the forward sweep to recapture snapshots, then unstep!
    # one at a time and verify rs.current == forward_snapshots[
    # rs.step_count] after EACH unstep!. This catches a mid-step
    # inverse bug that the aggregate round-trip (test 2) would
    # silently mask: if e.g. unstep! lands on the wrong intermediate
    # snapshot during one of the replay segments, but happens to
    # restore to rs.initial correctly on the final unstep!, the
    # aggregate test passes while the per-step assertion fails.
    #
    # This is the spike Q3 lesson applied to the L3 layer:
    # `spike/test/test_roundtrip.jl` lines 80-135 + RETROSPECTIVE Q3
    # §"Unexpectedly hard".
    vm = countdown_program(5)
    rs = initial_state(vm, Dict(:n0 => Int64(5), :steps0 => Int64(0)))
    initial_current = deepcopy(rs.current)

    # Forward: capture post-step snapshots indexed by step_count.
    # forward_snapshots[i] = the IState immediately after step i was
    # taken. Index range: 1..18.
    forward_snapshots = BennettVM.IState[]
    while !is_halted(rs)
        step!(rs, vm; checkpoint_interval=4)
        push!(forward_snapshots, deepcopy(rs.current))
    end
    @test length(forward_snapshots) == 18

    # Backward: unstep! one at a time. After each unstep!, rs.step_count
    # has decreased by 1. The new step_count value `k` (1 ≤ k ≤ 17)
    # means the interpreter is at "state after step k was taken",
    # which must == forward_snapshots[k]. When step_count reaches 0,
    # the state must == initial_current (the initial state).
    while rs.step_count > 0
        prev_count = rs.step_count
        unstep!(rs, vm)
        @test rs.step_count == prev_count - 1
        if rs.step_count > 0
            # Mid-sweep: rs.current must match the forward snapshot
            # at the new step_count.
            @test rs.current == forward_snapshots[rs.step_count]
        else
            # Bottom of sweep: rs.current must match the initial.
            @test rs.current == initial_current
            @test rs.current == rs.initial
        end
    end

    # Final structural invariants after the whole sweep:
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current == initial_current
end

@testset "M4.5 — aggregate round-trip across multiple K values" begin
    # Test 5: repeat the aggregate round-trip across a range of K
    # values, including the degenerate endpoints K=1 (push every
    # step) and K=typemax(Int) (never push; force the fall-through-
    # to-initial path for every unstep!).
    #
    # K=1     — every step pushes; M4.3's nearest-checkpoint search
    #           always finds the checkpoint exactly at target.
    # K=2     — alternating pushes; M4.3 sometimes finds at-target,
    #           sometimes one-step-behind.
    # K=4     — the canonical M4.5 K. 4 pushes at 4,8,12,16.
    # K=7     — pushes at 7 and 14 (countdown(5) is 18 steps). Non-
    #           K boundary at step 18 (since 18 % 7 != 0). Two
    #           pushes; the unstep! replay distance varies.
    # K=16    — single push at step 16. Most unstep!s fall through
    #           to the K=16 checkpoint or to s.initial.
    # K=64    — never pushes (countdown(5) is only 18 < 64 steps).
    #           Equivalent to K=typemax for this program but the
    #           kwarg is the documented default; pin it explicitly.
    # K=typemax(Int) — never pushes; M4.3 ALWAYS falls through to
    #           s.initial. The most adversarial K for the L3
    #           fallback path.
    for K in (1, 2, 4, 7, 16, 64, typemax(Int))
        vm = countdown_program(5)
        rs = initial_state(vm, Dict(:n0 => Int64(5), :steps0 => Int64(0)))
        initial_current = deepcopy(rs.current)

        run!(rs, vm; checkpoint_interval=K)
        @test is_halted(rs)
        @test rs.step_count == 18

        unrun!(rs, vm)
        @test rs.step_count == 0
        @test isempty(rs.history)
        @test rs.current == initial_current
        @test rs.current == rs.initial
        @test rs.current.status === :running
    end
end

@testset "M4.5 — run!+unrun! is RState-equality identity" begin
    # Test 6: deepcopy the freshly-constructed RState, run! and unrun!
    # the live one, then assert `rs == rs0` via the M4.3 RState ==
    # override (which compares current + history + step_count +
    # initial in lock-step). This is a one-line assertion but it
    # pins the FULL structural identity at the type level — any
    # mutation in any of the four fields that fails to be undone
    # by unrun! turns this RED.
    vm = countdown_program(5)
    rs0 = initial_state(vm, Dict(:n0 => Int64(5), :steps0 => Int64(0)))
    rs = deepcopy(rs0)

    run!(rs, vm; checkpoint_interval=4)
    unrun!(rs, vm)

    @test rs == rs0   # M4.3 RState == covers all four fields
end

@testset "M4.5 — run!+unrun!+run! produces bit-identical halt state" begin
    # Test 7: same as test 6, but with an EXTRA forward run after
    # unrun!. Assert the second run!'s result is bit-for-bit
    # identical to the first run!'s result. This exercises the
    # discipline that unrun! truly returns to initial state — if it
    # didn't, the second run! would start from a divergent state
    # and produce a divergent halt result.
    #
    # The second run!'s halt result must match the first run!'s
    # halt result. Any silent state corruption from unrun! that
    # didn't manifest in test 6's == check (e.g., a corruption in
    # an internal flag that == doesn't probe) would surface here.
    vm = countdown_program(5)
    rs = initial_state(vm, Dict(:n0 => Int64(5), :steps0 => Int64(0)))

    run!(rs, vm; checkpoint_interval=4)
    first_result = copy(result(rs))
    first_step_count = rs.step_count
    first_history_len = length(rs.history)
    first_history_steps = [e.step for e in rs.history]

    unrun!(rs, vm)
    run!(rs, vm; checkpoint_interval=4)

    @test result(rs) == first_result
    @test rs.step_count == first_step_count
    @test length(rs.history) == first_history_len
    @test [e.step for e in rs.history] == first_history_steps
end

@testset "M4.5 — round-trip on single-block 3-arith program (no cross-block)" begin
    # Test 8: a NON-countdown program shape. The single-block 3-arith
    # program has no UnconditionalExit / UnconditionalEntry cross-
    # block dispatch — M3.6's `_handle_cross_block_dispatch!` does
    # not fire on any transition. If a future L3 bug only manifests
    # in single-block programs (e.g., a subtle ordering between
    # truncation and replay that's masked when cross-block dispatch
    # is in the loop), test 8 catches it.
    #
    # Total flat-stream: Begin + 3 ArithAssign + End = 5 steps.
    # Under M6.2 the L1 "no log" gate (PRD v4 §3.3) skips the push
    # for injective instructions. Per-step injectivity (M6.1 trait):
    #   step 1: BeginInstruction          — injective → push skipped
    #   step 2: ArithAssign(modop=:xor)   — injective → push skipped
    #   step 3: ArithAssign(modop=:add)   — non-injective; 3%2=1 → no push
    #   step 4: ArithAssign(modop=:sub)   — non-injective; 4%2=0 → PUSH
    #   step 5: EndInstruction            — injective → push skipped
    # → 1 history entry at step 4 (the only non-injective K-multiple).
    vm = _rt_threeop_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))
    initial_current = deepcopy(rs.current)

    run!(rs, vm; checkpoint_interval=2)
    @test is_halted(rs)
    @test rs.step_count == 5
    @test length(rs.history) == 1
    @test [e.step for e in rs.history] == [4]

    unrun!(rs, vm)
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current == initial_current
    @test rs.current == rs.initial
    @test rs.current.status === :running
    @test rs.current.locals[:n] == Int64(7)   # original input preserved
end

@testset "M4.5 — history contains exactly the expected entries during run (K=4)" begin
    # Test 9: pin the M4.2 + M6.2 push pattern at the integration
    # level on the canonical countdown(5) / K=4 fixture.
    #
    # countdown(5) is 18 steps total. Under M4.2 alone, the push fires
    # at every step where `step_count % 4 == 0 && step_count > 0`:
    #   steps 4, 8, 12, 16 → 4 entries.
    # Under M6.2's L1 "no log" gate (PRD v4 §3.3 layer 1), the push is
    # additionally suppressed for injective instructions (M6.1 trait).
    # Walking the flat stream:
    #   step  1: BeginInstruction          — injective
    #   step  2: UnconditionalExit          — injective
    #   step  3: ArithAssign(:sub)          — non-injective; 3%4=3
    #   step  4: ArithAssign(:add)          — non-injective; 4%4=0 → PUSH
    #   step  5: UnconditionalExit          — injective
    #   step  6: ArithAssign(:sub)          — non-injective; 6%4=2
    #   step  7: ArithAssign(:add)          — non-injective; 7%4=3
    #   step  8: UnconditionalExit          — injective → push skipped
    #   step  9: ArithAssign(:sub)          — non-injective; 9%4=1
    #   step 10: ArithAssign(:add)          — non-injective; 10%4=2
    #   step 11: UnconditionalExit          — injective
    #   step 12: ArithAssign(:sub)          — non-injective; 12%4=0 → PUSH
    #   step 13: ArithAssign(:add)          — non-injective; 13%4=1
    #   step 14: UnconditionalExit          — injective
    #   step 15: ArithAssign(:sub)          — non-injective; 15%4=3
    #   step 16: ArithAssign(:add)          — non-injective; 16%4=0 → PUSH
    #   step 17: UnconditionalExit          — injective
    #   step 18: EndInstruction             — injective (halt)
    # → length 3, indices [4, 12, 16] (step 8 would have pushed
    # under M4.2 but is UnconditionalExit → injective → push skipped).
    #
    # (The cross-block dispatch in step!() jumps over UnconditionalEntry
    # instructions — they never appear in the executed flat stream
    # under the canonical forward flow; their bwd_address exists only
    # for backward traversal.)
    #
    # A common bug mode this test catches: the replay loop inside
    # unstep! using K=4 (the test's K) instead of typemax(Int).
    # That would cause spurious extra pushes during replays, and
    # the post-forward-run history (BEFORE any unstep!) would still
    # be correct, but the post-unrun! history check (and test 6's
    # RState == check) would catch the contamination.
    #
    # We pin BOTH the length AND the exact step indices (not just
    # length) — a regression that produces 3 entries at wrong steps
    # would fail the entries-by-step check but not the length-only
    # check.
    vm = countdown_program(5)
    rs = initial_state(vm, Dict(:n0 => Int64(5), :steps0 => Int64(0)))

    run!(rs, vm; checkpoint_interval=4)
    @test is_halted(rs)
    @test rs.step_count == 18
    @test length(rs.history) == 3
    @test [e.step for e in rs.history] == [4, 12, 16]
    # Each entry is a CheckpointEntry (not some other
    # AbstractHistoryEntry variant that doesn't exist yet at M4.5).
    @test all(e isa BennettVM.CheckpointEntry for e in rs.history)
end

@testset "M4.5 — round-trip after partial (non-halt) forward run" begin
    # Test 10: 7 forward steps on countdown(5) (which would normally
    # take 18 to halt), then unrun!. Status remains :running
    # throughout — no halt boundary in this trace. unrun! must drain
    # the partial history (one push at step 4 with K=4 → length 1)
    # and restore to initial.
    #
    # Catches unrun! bugs that depend on the forward pass having
    # reached halt (e.g., a hypothetical M4.4 regression that checks
    # `is_halted(s)` before entering the unstep! loop and silently
    # no-ops on non-halted states).
    vm = countdown_program(5)
    rs = initial_state(vm, Dict(:n0 => Int64(5), :steps0 => Int64(0)))
    initial_current = deepcopy(rs.current)

    for _ in 1:7
        step!(rs, vm; checkpoint_interval=4)
    end
    @test rs.step_count == 7
    @test !is_halted(rs)
    @test rs.current.status === :running
    @test length(rs.history) == 1               # K=4 → push at step 4 only
    @test rs.history[1].step == 4

    unrun!(rs, vm)
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current == initial_current
    @test rs.current == rs.initial
    @test rs.current.status === :running
end
