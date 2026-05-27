# test/test_delta_push.jl — M7.6 L2 delta push integration tests
# (bd `bennettvm-7e7`).
#
# # What M7.6 ships
#
# M7.6 wires the M7.5 `must_cache_set` and the M7.3 `make_delta`
# factories into `step!`'s push site (`src/interpreter/Interpreter.jl`).
# The composition rule is locked by ADR 0002 §"Composition with M6's
# injective gate":
#
#     s.step_count += 1
#     if replay_mode                                # M7.6
#         # nothing
#     elseif is_injective(instr)                    # L1 (M6.2)
#         # nothing
#     elseif must_cache(must_cache_set, blk, i)     # L2 (M7.6)
#         push!(s.history, make_delta(instr, ...))
#     elseif s.step_count % K == 0                  # L3 (M4.2)
#         push!(s.history, CheckpointEntry(...))
#     end
#
# The `must_cache_set` is passed as a kwarg (not a VMProgram field —
# M7.6 design decision A; see the `step!` docstring §"must_cache_set
# — kwarg, NOT a VMProgram field"). The `replay_mode::Bool=false`
# kwarg (M7.6 design decision C) lets M4.3's `unstep!` replay loop
# suppress ALL pushes uniformly.
#
# # Load-bearing tests
#
#   1. **L2 push on single non-injective step.** 3-instruction program
#      (Begin + ArithAssign(:add) + End); pass populated must_cache_set;
#      assert history has exactly ONE DeltaEntry at step==2, no
#      CheckpointEntry.
#   2. **L2 push on every non-injective step (countdown(3)).** All six
#      non-inj body steps push DeltaEntries when must_cache_set is
#      populated. No CheckpointEntries appear.
#   3. **L2 + L3 mutual exclusivity (countdown(5) at K=4).** When
#      must_cache_set is populated, the L2 branch fires for every
#      non-inj step and the L3 branch is starved. All entries are
#      DeltaEntry; none are CheckpointEntry.
#   4. **L2 suppressed in replay (unstep! roundtrip).** Full run! +
#      unrun! cycle on countdown(3) with must_cache_set populated;
#      assert history empty at end, step_count == 0, and rs.current
#      == rs.initial. Confirms replay_mode=true correctly suppresses
#      L2 pushes during the M4.3 replay phase.
#   5. **L2 + L3 composition under K=2 with a partial must_cache_set.**
#      Hand-construct a set that EXCLUDES one non-inj position; that
#      position falls through to the L3 branch (push when K-multiple,
#      else no push). Pins the trichotomy at the push site.
#   6. **Backward-compat: default empty must_cache_set.** countdown(3)
#      at K=2 with NO must_cache_set kwarg → behaviour matches
#      pre-M7.6 M4.2/M6.2 baseline (CheckpointEntry at K-multiples,
#      no DeltaEntries).
#
# # Mutation-proof intent (Rule 5)
#
# Each test corresponds to a perturbation in the M7.6 push site that
# would silently break a downstream consumer:
#
#   - Replace `must_cache(must_cache_set, label, idx)` with `true` →
#     test 6 (Backward-compat) turns RED because the empty-set
#     default would suddenly push deltas everywhere.
#   - Replace `must_cache(must_cache_set, label, idx)` with `false` →
#     tests 1, 2, 3 turn RED (the L2 branch never fires).
#   - Drop the `replay_mode` early-return → test 4 turns RED because
#     the replay loop would re-push L2 DeltaEntries.
#   - Swap the L2 and L3 branches' order (L3 first, L2 second) →
#     test 3 turns RED because L3 would fire at K-multiple non-inj
#     steps even though the must_cache_set includes them.
#   - Replace `_block_index_at(prog, pc_before)` with the post-step
#     pc → tests 1 and 2 turn RED because the (label, idx) lookup
#     would be off-by-one (or in the destination block for cross-
#     block exits).
#
# Ref:
#   * `src/interpreter/Interpreter.jl` (M7.6) — `step!` push site with
#     the three-way decision; `_block_index_at` helper.
#   * `src/history/Replay.jl` (M7.6) — `unstep!` replay loop passing
#     `replay_mode=true`.
#   * `src/analysis/liveness.jl` (M7.5) — `compute_must_cache` and
#     `must_cache` predicates this test populates the set from.
#   * `src/history/delta.jl` (M7.2), `src/ir/arithmetic_assignment.jl`
#     and `src/ir/memory_instructions.jl` (M7.3) — DeltaEntry type
#     and per-instruction `make_delta` methods.
#   * `docs/adr/0002-enzyme-min-cut-mapping.md` §"Composition with
#     M6's injective gate", §"DeltaEntry payload schema",
#     §"Design decisions that ripple to M7.2–M7.7" decision 5.
#   * `bennettvm_prd.md` (PRD v4) §3.3 layer 2.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (every test pins a
#     known-correct value), Rule 5 (mutation-proof), Rule 11
#     (literate test docstrings).

using Test
using BennettVM

include(joinpath(@__DIR__, "reference", "countdown.jl"))

# ---------------------------------------------------------------------
# Local fixtures.
#
# `_arith_add_program` is a single-non-inj-step program; the simplest
# possible M7.6 push-site exercise. `countdown_program` (from
# `test/reference/countdown.jl`, M8.1 / bd `bennettvm-do7`) is the
# multi-block fixture that exercises L2 across cross-block dispatch
# boundaries; included directly below so this file stands alone.
# ---------------------------------------------------------------------

# Single-block program with one non-injective body step:
#   Begin :n → ArithAssign(:y, :n, :add, 1, :and, 1) → End :y
# Dispatched step sequence:
#   step 1: Begin              — injective; no push regardless of mode.
#   step 2: Arith :add         — NON-injective; (block_label, body_idx)
#                                = (:m, 1). L2 fires iff (:m, 1) in
#                                must_cache_set.
#   step 3: End                — injective; no push regardless of mode.
function _m7_arith_add_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:y, :n, :add, Int64(1), :and, Int64(1)),
        ],
        BennettVM.EndInstruction(:m, [:y]))
    return VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
end

# Two-non-inj single-block program (mirrors test_unstep_delta.jl's
# `_two_arith_program` but with distinct fixture name to avoid
# cross-file coupling). Layout: Begin :n → ArithAssign :add → ArithAssign
# :sub → End :y. Dispatched step sequence:
#   step 1: Begin              — inj; no push
#   step 2: Arith :add (m1)    — NON-inj; (:m, 1)
#   step 3: Arith :sub (y)     — NON-inj; (:m, 2)
#   step 4: End                — inj; no push
function _m7_two_arith_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:m1, :n,  :add, Int64(1), :and, Int64(1)),
            BennettVM.ArithmeticAssignment(:y,  :m1, :sub, Int64(1), :and, Int64(1)),
        ],
        BennettVM.EndInstruction(:m, [:y]))
    return VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
end

# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------

# Mutation cited: replace `must_cache(must_cache_set, label, idx)` with
# `false` → this test goes RED (no DeltaEntry pushed). Replace it with
# `true` → backward-compat test (6) goes RED (would push delta in the
# empty-set default case).
@testset "M7.6 L2 push on single non-injective step" begin
    vm = _m7_arith_add_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))

    # Populate the must_cache_set via the M7.5 stub analysis. For
    # `_m7_arith_add_program`, the only non-injective body slot is
    # (block_label=:m, body_idx=1) — the ArithAssign :add.
    set = BennettVM.compute_must_cache(vm)
    @test set == Set([(:m, 1)])

    # Run forward with the populated set.
    run!(rs, vm; must_cache_set=set)

    @test is_halted(rs)
    @test rs.step_count == 3
    @test rs.current.locals[:y] == Int64(8)   # 7 + (1 & 1) = 8.

    # M7.6: exactly ONE DeltaEntry at step==2 (the post-increment
    # count when the L2 branch fired on the Arith :add). No
    # CheckpointEntry — the L2 branch fires before the L3 branch.
    @test length(rs.history) == 1
    @test rs.history[1] isa BennettVM.DeltaEntry
    @test BennettVM._entry_step(rs.history[1]) == 2
    # The instruction reference in the DeltaEntry matches the program's
    # body instruction (DeltaEntry{ArithmeticAssignment}).
    @test rs.history[1].instruction === vm.blocks[1].instructions[1]
    # Empty payload per ADR 0002 §"DeltaEntry payload schema" row 1.
    @test rs.history[1].payload === NamedTuple()
end

# Mutation cited: drop the L2 branch entirely → this test goes RED
# (no DeltaEntries, would fall through to L3 with default K=64 and
# 16 steps → still 0 entries, but length(history) == 0 instead of 6).
@testset "M7.6 L2 push on every non-injective step (countdown(3))" begin
    vm = countdown_program(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))

    set = BennettVM.compute_must_cache(vm)
    # countdown(3) has 3 decrement blocks (b_step1, b_step2, b_step3),
    # each with 2 non-inj body steps (sub at idx 1, add at idx 2).
    # The entry block (b_start) and the done block (b_done) have empty
    # body slots.
    @test set == Set([
        (:b_step1, 1), (:b_step1, 2),
        (:b_step2, 1), (:b_step2, 2),
        (:b_step3, 1), (:b_step3, 2),
    ])

    run!(rs, vm; must_cache_set=set)

    @test is_halted(rs)
    @test result(rs)[:steps3] == Int64(3)
    # Total dispatched steps for countdown(3): 12. Cross-block
    # dispatch (M3.6) skips the destination block's entry marker by
    # setting pc to `fwd_address + 1` after the rename — so each
    # decrement block contributes 3 dispatched steps (sub + add +
    # exit), not 4. The ADR 0002 worked example counted entry markers
    # separately; the actual dispatched-step trace per
    # `src/interpreter/Interpreter.jl` `_dispatch_to_block!` is:
    #   step 1: Begin (b_start.entry)
    #   step 2: UncondExit (b_start.exit) → b_step1, skipping entry
    #   step 3: Arith :sub (b_step1, body 1)   ← non-inj, DeltaEntry@3
    #   step 4: Arith :add (b_step1, body 2)   ← non-inj, DeltaEntry@4
    #   step 5: UncondExit (b_step1.exit) → b_step2
    #   step 6: Arith :sub (b_step2, body 1)   ← non-inj, DeltaEntry@6
    #   step 7: Arith :add (b_step2, body 2)   ← non-inj, DeltaEntry@7
    #   step 8: UncondExit (b_step2.exit) → b_step3
    #   step 9: Arith :sub (b_step3, body 1)   ← non-inj, DeltaEntry@9
    #   step 10: Arith :add (b_step3, body 2)  ← non-inj, DeltaEntry@10
    #   step 11: UncondExit (b_step3.exit) → b_done
    #   step 12: End (b_done.exit; entry skipped by cross-block jump)
    @test rs.step_count == 12

    # Exactly six DeltaEntries — one per non-inj body step. No
    # CheckpointEntries (the L2 branch supersedes L3 under the
    # current K=64 default, and 6 < 64 so L3 wouldn't have fired
    # anyway — but the assertion is independent of K).
    @test length(rs.history) == 6
    @test all(e -> e isa BennettVM.DeltaEntry, rs.history)
    @test all(e -> !(e isa BennettVM.CheckpointEntry), rs.history)
    # Per-entry step counts: the non-inj steps in countdown(3) are at
    # dispatched-step indices 3, 4, 6, 7, 9, 10 — see the trace above.
    @test [BennettVM._entry_step(e) for e in rs.history] ==
          [3, 4, 6, 7, 9, 10]
    # All payloads are empty NamedTuples (ADR 0002 finding).
    @test all(e -> e.payload === NamedTuple(), rs.history)
end

# Mutation cited: swap the L2 and L3 branches' order (L3 first) → this
# test goes RED because L3 would fire at non-inj K-multiple steps,
# pushing CheckpointEntries instead of (or alongside) DeltaEntries.
@testset "M7.6 L2 + L3 mutual exclusivity (countdown(5) at K=4)" begin
    vm = countdown_program(5)
    rs = initial_state(vm, Dict(:n0 => Int64(5), :steps0 => Int64(0)))

    set = BennettVM.compute_must_cache(vm)
    # Run with must_cache_set populated AND K=4 (which under pre-M7.6
    # M4.2 alone would have pushed CheckpointEntries at non-inj
    # K-multiple steps).
    run!(rs, vm; checkpoint_interval=4, must_cache_set=set)

    @test is_halted(rs)
    @test result(rs)[:steps5] == Int64(5)
    # countdown(5) total dispatched steps: 2 (b_start) + 5*3 (each
    # decrement contributes sub+add+exit; entry skipped by cross-block
    # dispatch) + 1 (b_done's End; b_done's entry also skipped) = 18.
    @test rs.step_count == 18

    # M7.6 guarantee: with must_cache_set populated, the L2 branch
    # always fires first on non-inj steps. Every entry is a
    # DeltaEntry; no CheckpointEntry appears even though K=4 and
    # non-inj K-multiple steps (4) would normally trigger an L3 push
    # under M4.2 alone.
    @test all(e -> e isa BennettVM.DeltaEntry, rs.history)
    @test !any(e -> e isa BennettVM.CheckpointEntry, rs.history)
    # 10 non-inj steps for countdown(5) (5 blocks * 2 non-inj steps).
    @test length(rs.history) == 10
end

# Mutation cited: drop the `replay_mode` early-return → this test
# goes RED because the M4.3 replay loop would re-push L2 DeltaEntries
# at every non-inj step it crosses during replay, leaving history
# non-empty at the end of `unrun!` and breaking the M4.4
# `isempty(history)` post-condition (which would raise an error
# inside `unrun!` before this testset's final assert reached).
@testset "M7.6 L2 suppressed in replay (full unrun! roundtrip)" begin
    vm = countdown_program(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    initial_current = deepcopy(rs.current)

    set = BennettVM.compute_must_cache(vm)
    run!(rs, vm; must_cache_set=set)

    @test rs.step_count == 12
    @test length(rs.history) == 6

    # Drive unrun! — this calls unstep!() repeatedly, whose M4.3 replay
    # loop now uses replay_mode=true to suppress both L2 and L3 pushes
    # during forward replay. If replay_mode failed to suppress L2,
    # the M4.4 isempty(history) post-condition would error inside
    # unrun!() at the loop exit.
    unrun!(rs, vm)

    # Structural invariants per M4.4:
    @test rs.step_count == 0
    @test isempty(rs.history)
    # Semantic invariant per M4.5 (round-trip): current matches the
    # pre-run initial.
    @test rs.current == initial_current
    @test rs.current == rs.initial
end

# Mutation cited: remove the L2 branch entirely → this test goes RED.
# Specifically, the non-inj position (:m, 2) is excluded from the
# must_cache_set, so the M7.6 L2 branch does NOT fire there; control
# falls through to the L3 branch. At K=2 with step 3 non-inj-and-not-
# K-multiple, no push fires — the trichotomy gives an empty history
# for the excluded position. The included position (:m, 1) at step 2
# (non-inj K-multiple) fires L2.
@testset "M7.6 L2 + L3 composition under K=2 with partial set" begin
    vm = _m7_two_arith_program()
    rs = initial_state(vm, Dict(:n => Int64(11)))

    # Hand-construct a must_cache_set that EXCLUDES (:m, 2). The
    # included position (:m, 1) takes the L2 path; the excluded
    # position (:m, 2) falls through to L3 (push iff K-multiple).
    set = Set([(:m, 1)])
    run!(rs, vm; checkpoint_interval=2, must_cache_set=set)

    @test is_halted(rs)
    @test rs.step_count == 4
    @test rs.current.locals[:y] == Int64(11)   # +1 then -1 → 11

    # Trichotomy: step 2 (Arith :add, in set) → L2 push, DeltaEntry@2.
    #             step 3 (Arith :sub, NOT in set) → L3 gate: non-inj
    #                    AND step_count=3; 3 % 2 != 0 → NO push.
    #             step 1 (Begin), step 4 (End) → L1 (inj), no push.
    @test length(rs.history) == 1
    @test rs.history[1] isa BennettVM.DeltaEntry
    @test BennettVM._entry_step(rs.history[1]) == 2
    @test rs.history[1].instruction === vm.blocks[1].instructions[1]
end

# Mutation cited: replace `must_cache(must_cache_set, label, idx)`
# with `true` (always L2) → this test goes RED because the empty-set
# default would push DeltaEntries instead of the CheckpointEntry the
# M4.2 path produces.
@testset "M7.6 backward-compat: default empty must_cache_set" begin
    # countdown(3) at K=2 with NO must_cache_set kwarg passed. Per
    # M7.6's "backward compatibility" contract, this MUST reproduce
    # the pre-M7.6 M4.2/M6.2 behaviour bit-for-bit.
    vm = countdown_program(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))

    # No must_cache_set kwarg → default empty Set → L2 never fires.
    run!(rs, vm; checkpoint_interval=2)

    @test is_halted(rs)
    @test result(rs)[:steps3] == Int64(3)
    @test rs.step_count == 12

    # Pre-M7.6 baseline: L3 pushes at non-inj K-multiple steps.
    # Non-inj steps in countdown(3) are at dispatched-step indices
    # 3, 4, 6, 7, 9, 10 (see the trace in test 2). At K=2 the
    # K-multiple ones are 4, 6, 10. So we expect three
    # CheckpointEntries at steps 4, 6, 10.
    @test all(e -> e isa BennettVM.CheckpointEntry, rs.history)
    @test !any(e -> e isa BennettVM.DeltaEntry, rs.history)
    @test [BennettVM._entry_step(e) for e in rs.history] == [4, 6, 10]

    # Also confirm the full forward-then-backward round-trip works
    # in the backward-compat path (no must_cache_set involved).
    initial_current = deepcopy(rs.initial)
    unrun!(rs, vm)
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current == initial_current
end
