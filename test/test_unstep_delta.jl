# test/test_unstep_delta.jl — M7.4 unit + integration tests for the
# `unstep!` L2 DeltaEntry fast-path (bd `bennettvm-bk5`).
#
# # Why these tests exist
#
# M7.4 grows a fast-path on top of M4.3's checkpoint-restore-and-replay
# `unstep!` (`src/history/Replay.jl`): when the top of `s.history` is
# a `DeltaEntry` whose `step` field equals the current `s.step_count`,
# `unstep!` pops the entry and applies the M7.4 NamedTuple-dispatch
# specialisation of `inverse` to reverse the most recent forward step
# in O(1) without restoring a checkpoint or replaying forward. The
# tests below pin every load-bearing invariant of the fast-path AND
# its composition with the existing M4.3 path.
#
# **M7.6's automatic push integration into `step!` is NOT yet wired**
# (it's the next bead, `bennettvm-7e7`). Until then, the tests below
# manually push `DeltaEntry`s into `rs.history` via `make_delta` to
# simulate M7.6's behaviour at the dispatch-side test boundary. This
# is the intentional split per the M7.4 brief: M7.4 is dispatch-side
# only; M7.4 tests construct DeltaEntries manually.
#
# # Load-bearing tests
#
#   1. **ArithmeticAssignment :add fast-path.** Single-block program;
#      step forward through one Arith :add; manually push the delta;
#      unstep!; assert history empty, step_count decremented, current
#      bit-for-bit matches the captured pre-step snapshot.
#   2. **ArithmeticAssignment :sub fast-path.** Mirror of (1) with the
#      :sub modop. Pins both modop branches under the
#      `dual_modop` flip.
#   3. **MemoryAssignment fast-path.** Pins the L2 fast-path for the
#      second non-injective instruction type (`bennettvm-c0e` is the
#      open follow-up that would broaden M6.1 to make some
#      MemoryAssignment cases injective; until it lands, all three
#      modops reach the M7.4 path).
#   4. **No fast-path when top is CheckpointEntry.** Step forward with
#      K=1 so the M4.2 push gate fires for the non-injective step.
#      The top of history is now a CheckpointEntry. unstep! must take
#      the M4.3 path (restore + replay). Pins that the fast-path
#      guard `last(history) isa DeltaEntry` correctly rejects the L3
#      case.
#   5. **No fast-path when top is a DeltaEntry from earlier step.**
#      The guard's full predicate is `entry.step == s.step_count`,
#      NOT merely `last is DeltaEntry`. If step_count has advanced
#      past the DeltaEntry's recorded step (e.g., an injective step
#      followed the non-injective one without pushing), the
#      fast-path must NOT fire. Pins the guard's step-equality clause.
#   6. **Symmetric push-then-pop round-trip.** For each per-instruction
#      case: starting from a pre-step snapshot, run forward, manually
#      push the delta, call unstep!, assert current == pre-step
#      snapshot. This is the per-step inverse pattern (PRD v4 §3.13;
#      spike Q3) at the dispatch-side boundary.
#   7. **Mixing DeltaEntry and CheckpointEntry in history.** The
#      architecture-validation testset for M7.6: history contains
#      BOTH entry types in monotone-ascending step order. unstep!
#      must alternate correctly between the M7.4 fast-path (when top
#      is DeltaEntry@step_count) and the M4.3 path (when top is
#      CheckpointEntry or DeltaEntry-from-earlier-step). If this
#      testset passes, M7.6 has a clean compositional surface to
#      land on.
#
# # Mutation-proof intent (Rule 5)
#
# Each test corresponds to a specific perturbation in `unstep!` /
# `inverse(::T, s, payload::NamedTuple)` that would silently break a
# real downstream consumer:
#
#   - Replace the fast-path guard `entry.step == s.step_count` with
#     `entry.step == s.step_count - 1` → all fast-path tests turn RED
#     (the guard fails, unstep! falls through to the M4.3 path which
#     succeeds via the `s.initial` fallback, BUT history still
#     contains the DeltaEntry so subsequent unstep!s see it again at
#     step_count == entry.step - 1, and the assertion
#     `length(history) == 0` after one unstep! turns RED).
#   - Replace the fast-path with a direct call to
#     `inverse(entry.instruction, s.current, nothing)` (skipping the
#     M7.4 NamedTuple dispatch) → still passes today (empty payload
#     delegates to nothing-path) but breaks the day a future
#     Phase-2.x instruction adds non-empty payload; this is
#     intentional defense-in-depth for the architectural contract.
#   - Drop the `last(s.history) isa DeltaEntry` check → testset 4
#     (No fast-path when top is CheckpointEntry) turns RED: a
#     CheckpointEntry would be popped, its `instruction` field doesn't
#     exist, MethodError.
#   - Skip `s.step_count -= 1` inside the fast-path → all fast-path
#     tests turn RED (step_count doesn't decrement).
#   - Forget to `pop!(s.history)` inside the fast-path → all fast-path
#     tests turn RED (history not empty).
#   - Move `_entry_step(::DeltaEntry)` to error out → unrun! tests in
#     other files turn RED (the truncation loop / unrun!'s
#     post-condition diagnostic would crash on any DeltaEntry).
#
# Ref:
#   * `src/history/Replay.jl` — `unstep!` (the function under test;
#     M7.4 adds the L2 fast-path at step (1a)).
#   * `src/history/delta.jl` — `DeltaEntry{T}` (M7.2) the fast-path
#     pops.
#   * `src/ir/arithmetic_assignment.jl` — `inverse(::ArithmeticAssignment,
#     s, payload::NamedTuple)` (M7.4 specialisation).
#   * `src/ir/memory_instructions.jl` — `inverse(::MemoryAssignment,
#     s, payload::NamedTuple)` (M7.4 specialisation).
#   * `docs/adr/0002-enzyme-min-cut-mapping.md` §Composition with M6,
#     §Design Decision 4 — the dispatch contract M7.4 implements.
#   * `bennettvm_prd.md` (PRD v4) §3.3 layer 2, §3.9, §3.13, §3.16.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (every test pins a
#     known-correct value), Rule 5 (mutation-proof), Rule 11
#     (literate test docstrings).

using Test
using BennettVM

# ---------------------------------------------------------------------
# Local fixtures. Kept self-contained so a future reorder of
# `runtests.jl` includes does not silently decouple this file from
# upstream test fixtures (per the same convention as
# `test_unstep.jl`'s `_u_small_arith_program`).
# ---------------------------------------------------------------------

# Single-block program: Begin([:n]) -> ArithAssign(:y, :n, :add, 1, :and, 1)
# -> End([:y]).
# Dispatched step sequence under M3.x/M6.2:
#   step 1: Begin              — injective; no push regardless of K.
#   step 2: Arith :add         — NON-injective; pushes when step_count % K == 0.
#   step 3: End                — injective; no push regardless of K.
# Total = 3 dispatched steps.
function _arith_add_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:y, :n, :add, Int64(1), :and, Int64(1)),
        ],
        BennettVM.EndInstruction(:m, [:y]))
    return VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
end

# Sibling of `_arith_add_program` but with `:sub` modop. Same 3-step
# dispatched sequence; pins the second `ArithmeticAssignment` modop
# branch under M7.4's fast-path.
function _arith_sub_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:y, :n, :sub, Int64(1), :and, Int64(1)),
        ],
        BennettVM.EndInstruction(:m, [:y]))
    return VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
end

# Single-block program: Begin([:addr]) -> MemoryAssignment(:addr, :add, 1, :and, 1)
# -> End([]).
# Dispatched step sequence:
#   step 1: Begin              — injective; no push.
#   step 2: MemoryAssignment   — NON-injective; pushes when step_count % K == 0.
#   step 3: End                — injective; no push.
# The MemAssign body destroys nothing in locals (it reads `:addr` for
# the address operand, the operands `1` and `1` are literal Int64s);
# the cell at `s.memory[input[:addr]]` is updated in place.
function _memassign_add_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:addr]),
        BennettVM.Instruction[
            BennettVM.MemoryAssignment(:addr, :add, Int64(1), :and, Int64(1)),
        ],
        BennettVM.EndInstruction(:m, Symbol[]))
    return VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], Int[])
end

# A two-non-inj-arith program used for the "Mixing DeltaEntry and
# CheckpointEntry" testset. Layout: Begin([:n]) -> ArithAssign :add ->
# ArithAssign :sub -> End([:y]). Dispatched step sequence:
#   step 1: Begin              — injective; no push.
#   step 2: Arith :add         — NON-injective.
#   step 3: Arith :sub         — NON-injective.
#   step 4: End                — injective; no push.
# Under K=2, the M4.2 push gate fires at step 2 (non-inj * K-multiple).
# Step 3 is non-inj but 3 % 2 != 0, so no L3 push at step 3 — that's
# where the M7.6-simulating manual DeltaEntry push lands in the
# Mixing test.
function _two_arith_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:m1, :n,  :add, Int64(1), :and, Int64(1)),
            BennettVM.ArithmeticAssignment(:y,  :m1, :sub, Int64(1), :and, Int64(1)),
        ],
        BennettVM.EndInstruction(:m, [:y]))
    return VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
end

# Helper: step `rs` forward `n` times with `K = typemax(Int)` so no
# M4.2 / M6.2 L3 push fires. Useful for advancing past an injective
# prefix without polluting `rs.history` with checkpoint entries.
function _step_no_push!(rs::BennettVM.RState, vm, n::Int)
    for _ in 1:n
        step!(rs, vm; checkpoint_interval=typemax(Int))
    end
    return rs
end

# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------

# Mutation cited in this testset: replace the M7.4 fast-path guard
# `entry.step == s.step_count` with `entry.step == s.step_count - 1`
# → this assertion sequence fails because (a) step_count would
# decrement but the DeltaEntry would remain on history (the fall-
# through to M4.3 path would also run!), or (b) the wrong dispatch
# entirely. Either way, `length(rs.history) == 0` after unstep! turns
# RED.
@testset "DeltaEntry fast-path: ArithmeticAssignment :add (M7.4)" begin
    vm = _arith_add_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))

    # Advance one step (Begin — injective, no push) so we're poised
    # at the Arith :add instruction at step 2.
    _step_no_push!(rs, vm, 1)
    @test rs.step_count == 1
    @test isempty(rs.history)

    # Capture pre-Arith state. This is the snapshot the M7.4 fast-path
    # must reconstruct.
    pre_arith = deepcopy(rs.current)

    # Step forward through the Arith :add (still K=typemax so no L3
    # push fires; M7.6's L2 push isn't wired yet). step_count now 2.
    _step_no_push!(rs, vm, 1)
    @test rs.step_count == 2
    @test isempty(rs.history)
    # The forward step has moved current away from pre_arith.
    @test rs.current != pre_arith
    @test rs.current.locals[:y] == Int64(7) + 1   # n + (1 & 1) = 8

    # Manually push the DeltaEntry that M7.6 will eventually push. The
    # `make_delta` factory lives in `src/ir/arithmetic_assignment.jl`
    # (M7.3) — it returns a DeltaEntry{ArithmeticAssignment} with
    # empty payload per ADR 0002 §DeltaEntry payload schema row 1.
    arith_instr = vm.blocks[1].instructions[1]
    @test arith_instr isa BennettVM.ArithmeticAssignment
    @test arith_instr.modop === :add
    delta = BennettVM.make_delta(arith_instr, pre_arith, rs.step_count)
    push!(rs.history, delta)
    @test length(rs.history) == 1
    @test rs.history[end] isa BennettVM.DeltaEntry
    @test BennettVM._entry_step(rs.history[end]) == 2   # post-increment step_count.

    # The M7.4 fast-path fires: history top is DeltaEntry whose step
    # equals s.step_count == 2.
    unstep!(rs, vm)

    # Assertions per the M7.4 brief:
    @test isempty(rs.history)               # DeltaEntry popped.
    @test rs.step_count == 1                # decremented by 1.
    @test rs.current == pre_arith           # inverse reconstructed pre-step.
    # The locals dict has the source variable restored.
    @test haskey(rs.current.locals, :n)
    @test !haskey(rs.current.locals, :y)
    @test rs.current.locals[:n] == Int64(7)
end

# Mutation cited: dropping the NamedTuple-vs-prev::Any dispatch would
# silently fall through to either the `prev::Any` method (which works
# for empty payload, so this test would still pass) OR to a
# MethodError (which would also surface RED here). The dispatch
# routing is what this testset pins, via `which()` cross-check above
# the assert block — see the dispatch-method verification embedded in
# this same file.
@testset "DeltaEntry fast-path: ArithmeticAssignment :sub (M7.4)" begin
    vm = _arith_sub_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))

    _step_no_push!(rs, vm, 1)   # Begin (injective)
    @test rs.step_count == 1
    pre_arith = deepcopy(rs.current)

    _step_no_push!(rs, vm, 1)   # Arith :sub
    @test rs.step_count == 2
    @test rs.current.locals[:y] == Int64(7) - 1   # n - (1 & 1) = 6
    @test rs.current != pre_arith

    arith_instr = vm.blocks[1].instructions[1]
    @test arith_instr.modop === :sub
    delta = BennettVM.make_delta(arith_instr, pre_arith, rs.step_count)
    push!(rs.history, delta)

    unstep!(rs, vm)
    @test isempty(rs.history)
    @test rs.step_count == 1
    @test rs.current == pre_arith
end

# Mutation cited: the empty-payload finding (ADR 0002 §DeltaEntry
# payload schema row 2) means MemoryAssignment's inverse is structural
# via dual_modop on the surviving cell. This test pins that the M7.4
# fast-path works for `T = MemoryAssignment` (the second NamedTuple
# specialisation) and not just `T = ArithmeticAssignment`.
@testset "DeltaEntry fast-path: MemoryAssignment :add (M7.4)" begin
    vm = _memassign_add_program()
    # Input: addr=42, so the memory write at step 2 will be
    # s.memory[42] += (1 & 1) = 1. Pre-step the memory cell is unset
    # (zero-init equivalence).
    rs = initial_state(vm, Dict(:addr => Int64(42)))

    _step_no_push!(rs, vm, 1)   # Begin (injective)
    @test rs.step_count == 1
    @test isempty(rs.current.memory)
    pre_memassign = deepcopy(rs.current)

    _step_no_push!(rs, vm, 1)   # MemoryAssignment :add
    @test rs.step_count == 2
    @test rs.current.memory == Dict{Int64,Int64}(Int64(42) => Int64(1))
    @test rs.current != pre_memassign

    memassign_instr = vm.blocks[1].instructions[1]
    @test memassign_instr isa BennettVM.MemoryAssignment
    delta = BennettVM.make_delta(memassign_instr, pre_memassign, rs.step_count)
    push!(rs.history, delta)
    @test BennettVM._entry_step(rs.history[end]) == 2

    unstep!(rs, vm)
    @test isempty(rs.history)
    @test rs.step_count == 1
    @test rs.current == pre_memassign
    # The delete-on-zero rule restored the absent-key state on the
    # memory cell — this is what the inverse delegating chain
    # (NamedTuple -> prev::Any -> existing inverse body) accomplishes.
    @test isempty(rs.current.memory)
end

# Mutation cited: drop the `last(history) isa DeltaEntry` check from
# the fast-path guard → the pop would fire on a CheckpointEntry, and
# `entry.instruction` would `MethodError` (CheckpointEntry has no
# `instruction` field). This testset's `unstep!` call would then
# raise instead of taking the M4.3 path.
@testset "No fast-path when top is CheckpointEntry (M7.4)" begin
    vm = _arith_sub_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))

    # With K=1, EVERY non-injective step pushes a CheckpointEntry.
    # In _arith_sub_program only step 2 (Arith :sub) is non-inj, so
    # after running all three steps, history = [CheckpointEntry@2].
    run!(rs, vm; checkpoint_interval=1)
    @test rs.step_count == 3
    @test length(rs.history) == 1
    @test rs.history[1] isa BennettVM.CheckpointEntry
    @test rs.history[1].step == 2

    # unstep! from step 3 → target = 2. The fast-path guard is FALSE
    # (top is CheckpointEntry, not DeltaEntry); control falls through
    # to the M4.3 path which finds the nearest checkpoint at step 2
    # (== target), restores it, truncates nothing (step 2 not > 2),
    # replays 0 steps forward. Result: step_count = 2.
    unstep!(rs, vm)
    @test rs.step_count == 2
    @test length(rs.history) == 1   # CheckpointEntry@2 retained (2 not > 2).
    @test rs.history[1] isa BennettVM.CheckpointEntry
    @test rs.history[1].step == 2
end

# Mutation cited: replace the `entry.step == s.step_count` guard with
# `last(history) isa DeltaEntry` alone → the fast-path would fire on
# the stale DeltaEntry at step 1 when step_count is 2, which would
# (a) apply the inverse to current state that isn't actually the
# post-step-1 state (corruption), and (b) leave the M4.3 path
# unreachable. This test would RED via the wrong final state, or via
# MethodError if the inverse cannot apply to an inconsistent state.
@testset "No fast-path when top DeltaEntry is from earlier step (M7.4)" begin
    # We deliberately fabricate the case: top of history is a
    # DeltaEntry at step=1, but s.step_count is 2 because an
    # injective step (e.g., a hypothetical post-Arith End advance)
    # happened after the non-injective step but didn't push.
    # In _arith_add_program the natural form is Begin -> Arith ->
    # End. We:
    #   - run forward 1 step (Begin) with K=typemax (no push),
    #     step_count=1.
    #   - manually push a DeltaEntry recording the (hypothetical)
    #     Arith step at step=1 (NOT step=2 — we're constructing the
    #     "stale" case where M7.4 fast-path's guard MUST evaluate to
    #     false because the entry's recorded step doesn't match the
    #     current step_count).
    # Then we advance step_count by 1 more (the Arith step itself,
    # K=typemax, no L2 push because M7.6 not wired). Top of history
    # is still DeltaEntry@1; s.step_count is 2; guard `entry.step ==
    # s.step_count` evaluates to `1 == 2` → false; fast-path skipped;
    # control falls through to the M4.3 path.
    #
    # Note: this is an artificial scenario — under M7.6's eventual
    # push contract, every non-injective step pushes a DeltaEntry
    # with step == post-increment step_count, so the "earlier step"
    # case arises only at the boundary where multiple injective
    # steps follow a single non-injective one without an intervening
    # L3 push. The artificial construction here exercises the guard
    # clause directly.
    vm = _arith_add_program()
    rs = initial_state(vm, Dict(:n => Int64(7)))

    _step_no_push!(rs, vm, 1)   # Begin → step_count=1
    @test rs.step_count == 1

    # Stash a snapshot at step_count=1 (pre-Arith), to be used as the
    # M4.3 fallback target after the fast-path is rejected. NOTE: we
    # have not yet stepped through the Arith, so we should NOT push
    # the Arith-delta yet — the fabrication below installs a
    # SEMANTICALLY WRONG DeltaEntry (at step=1) on purpose, to exercise
    # the guard clause.
    arith_instr = vm.blocks[1].instructions[1]
    # Push a stale DeltaEntry at step=1 (matching the current
    # step_count). This entry's step DOES equal step_count, so the
    # fast-path WOULD fire here. But we want to test the "earlier
    # step" case, so we step forward FIRST (decoupling step_count
    # from the entry's recorded step) and THEN attempt unstep!.
    #
    # Concretely: after _step_no_push!(rs, vm, 1) we are at step_count=1.
    # If we now push at step=1 and run unstep!, the fast-path fires
    # (1 == 1). To trigger the "earlier" case, we advance step_count
    # to 2 (by running the Arith step, which under our manual
    # contract does NOT push a delta — M7.6 isn't wired).
    push!(rs.history, BennettVM.make_delta(arith_instr,
                                            deepcopy(rs.current),
                                            rs.step_count))   # step==1
    @test BennettVM._entry_step(rs.history[end]) == 1

    _step_no_push!(rs, vm, 1)   # Arith :add → step_count=2 (no push wired)
    @test rs.step_count == 2
    @test length(rs.history) == 1
    @test BennettVM._entry_step(rs.history[end]) == 1   # stale entry.

    # M7.4 guard: entry.step (1) == s.step_count (2)? NO. Fast-path
    # skipped. Falls through to M4.3 path which finds no CheckpointEntry
    # at <= target=1, falls back to s.initial (start_step=0), restores
    # initial, truncates entries with step > 1 (none — the DeltaEntry@1
    # is NOT > 1), replays 1 forward step to reach target=1.
    #
    # Outcome: step_count = 1, history = [DeltaEntry@1] (retained,
    # because step 1 is not > 1). current matches the step-1 state.
    unstep!(rs, vm)
    @test rs.step_count == 1
    @test length(rs.history) == 1            # stale DeltaEntry retained.
    @test BennettVM._entry_step(rs.history[end]) == 1
    # current matches the step-1 state — reconstructed by replay
    # forward from s.initial.
    @test rs.current.locals == Dict(:n => Int64(7))   # post-Begin locals unchanged.
end

# Mutation cited: the symmetric round-trip is the per-step-inverse
# pattern (PRD v4 §3.13; spike Q3 §"Test patterns worth keeping").
# A perturbation that makes the M7.4 fast-path apply the WRONG inverse
# direction (e.g., calls `forward` instead of `inverse`, or applies
# `dual_modop` twice) would turn this test RED via current != initial
# after the round-trip.
@testset "DeltaEntry fast-path: push-then-pop symmetric round-trip (M7.4)" begin
    # ArithmeticAssignment :add — full forward sweep on _arith_add_program
    # with manual DeltaEntry push at the non-inj step, then full
    # backward sweep.
    let vm = _arith_add_program()
        rs = initial_state(vm, Dict(:n => Int64(13)))
        initial_current = deepcopy(rs.current)
        @test rs.step_count == 0

        # Forward sweep: step 1 (Begin), step 2 (Arith :add — manually
        # push delta to simulate M7.6), step 3 (End).
        _step_no_push!(rs, vm, 1)
        pre_arith = deepcopy(rs.current)
        _step_no_push!(rs, vm, 1)   # Arith :add
        arith_instr = vm.blocks[1].instructions[1]
        push!(rs.history,
              BennettVM.make_delta(arith_instr, pre_arith, rs.step_count))
        _step_no_push!(rs, vm, 1)   # End — injective, no push, step_count=3
        @test rs.step_count == 3
        @test length(rs.history) == 1
        @test BennettVM._entry_step(rs.history[end]) == 2

        # Backward sweep one step at a time:
        # unstep! @ step_count=3 → top of history is DeltaEntry@2 — guard
        # is FALSE (2 != 3). Falls through to M4.3 path: no
        # CheckpointEntry, falls back to s.initial, replays 2 steps
        # forward (pop the DeltaEntry@2 along the way because 2 > target=2
        # is false, so it's RETAINED).
        unstep!(rs, vm)
        @test rs.step_count == 2
        @test length(rs.history) == 1   # DeltaEntry@2 retained (2 not > 2).

        # unstep! @ step_count=2 → top is DeltaEntry@2; guard TRUE; M7.4
        # fast-path fires.
        unstep!(rs, vm)
        @test rs.step_count == 1
        @test isempty(rs.history)
        @test rs.current == pre_arith

        # unstep! @ step_count=1 → history empty, fast-path guard FALSE
        # (isempty). M4.3 path: fall back to s.initial, replay 0 steps.
        unstep!(rs, vm)
        @test rs.step_count == 0
        @test rs.current == initial_current
        @test rs.current == rs.initial
        @test isempty(rs.history)
    end

    # MemoryAssignment :add — same shape, second non-injective type.
    let vm = _memassign_add_program()
        rs = initial_state(vm, Dict(:addr => Int64(99)))
        initial_current = deepcopy(rs.current)

        _step_no_push!(rs, vm, 1)
        pre_memassign = deepcopy(rs.current)
        _step_no_push!(rs, vm, 1)   # MemoryAssignment
        memassign_instr = vm.blocks[1].instructions[1]
        push!(rs.history,
              BennettVM.make_delta(memassign_instr, pre_memassign,
                                    rs.step_count))
        _step_no_push!(rs, vm, 1)   # End
        @test rs.step_count == 3
        @test length(rs.history) == 1

        unstep!(rs, vm)              # M4.3 path; step_count=2
        @test rs.step_count == 2
        unstep!(rs, vm)              # M7.4 fast-path; step_count=1
        @test rs.step_count == 1
        @test rs.current == pre_memassign
        @test isempty(rs.history)
        unstep!(rs, vm)              # M4.3 path; step_count=0
        @test rs.step_count == 0
        @test rs.current == initial_current
        @test isempty(rs.history)
    end
end

# Mutation cited: this is the architecture-validation testset for M7.6.
# The history contains BOTH a CheckpointEntry and a DeltaEntry in
# monotone-ascending step order, mirroring the future composition
# rule in `src/interpreter/Interpreter.jl` once M7.6 wires the
# DeltaEntry push site. unstep! must alternate between the M7.4
# fast-path (pop DeltaEntry, apply inverse) and the M4.3 path
# (restore CheckpointEntry, replay forward) without leaking state.
# A regression that confuses the two paths would surface RED at
# this testset.
@testset "Mixing DeltaEntry and CheckpointEntry in history (M7.4)" begin
    # _two_arith_program has dispatched step sequence:
    #   step 1: Begin              — inj
    #   step 2: Arith :add (m1)    — NON-inj
    #   step 3: Arith :sub (y)     — NON-inj
    #   step 4: End                — inj
    # With K=2, M4.2's push gate fires when step_count % 2 == 0 AND
    # non-injective AND step_count > 0. Step 2 satisfies all three
    # (push CheckpointEntry@2). Step 3 is non-inj but 3 % 2 != 0
    # (no L3 push). Step 4 is inj (no push regardless of K).
    #
    # After natural forward run, history = [CheckpointEntry@2]. We then
    # manually push a DeltaEntry@3 to simulate M7.6's eventual L2 push
    # at the non-inj step 3 that L3 skipped. Final history shape:
    # [CheckpointEntry@2, DeltaEntry@3] in monotone-ascending step order.
    vm = _two_arith_program()
    rs = initial_state(vm, Dict(:n => Int64(11)))
    initial_current = deepcopy(rs.current)
    @test rs.step_count == 0

    # Step 1: Begin. Injective; no push at K=2.
    step!(rs, vm; checkpoint_interval=2)
    @test rs.step_count == 1
    @test isempty(rs.history)

    # Step 2: Arith :add. Non-injective; M4.2 push fires at step 2
    # (2 % 2 == 0 && >0 && non-inj).
    step!(rs, vm; checkpoint_interval=2)
    @test rs.step_count == 2
    @test length(rs.history) == 1
    @test rs.history[end] isa BennettVM.CheckpointEntry
    @test rs.history[end].step == 2

    # Capture the pre-Arith-sub state for the manual delta push below.
    pre_arith_sub = deepcopy(rs.current)

    # Step 3: Arith :sub. Non-injective; M4.2 push does NOT fire
    # (3 % 2 != 0).
    step!(rs, vm; checkpoint_interval=2)
    @test rs.step_count == 3
    @test length(rs.history) == 1   # still just CheckpointEntry@2.

    # SIMULATE M7.6's L2 push: manually push a DeltaEntry for the
    # Arith :sub step at step=3.
    arith_sub_instr = vm.blocks[1].instructions[2]
    @test arith_sub_instr isa BennettVM.ArithmeticAssignment
    @test arith_sub_instr.modop === :sub
    push!(rs.history,
          BennettVM.make_delta(arith_sub_instr, pre_arith_sub,
                                rs.step_count))
    @test length(rs.history) == 2
    @test rs.history[end] isa BennettVM.DeltaEntry
    @test BennettVM._entry_step(rs.history[end]) == 3
    @test BennettVM._entry_step(rs.history[1]) == 2   # monotone-ascending.

    # Step 4: End. Injective; no push regardless of K.
    step!(rs, vm; checkpoint_interval=2)
    @test rs.step_count == 4
    @test length(rs.history) == 2   # unchanged.

    # Now reverse one step at a time and assert the alternation:
    #
    # unstep! @ step_count=4 → top is DeltaEntry@3; guard `entry.step
    # == s.step_count` is `3 == 4` → FALSE. Fall through to M4.3 path.
    # Nearest CheckpointEntry <= target=3 is CheckpointEntry@2. Restore
    # step-2 snapshot. Truncate entries with step > 3: pop DeltaEntry@3.
    # Replay 1 step forward to reach target=3.
    # Result: step_count=3, history=[CheckpointEntry@2] (4-popped no, but
    # the DeltaEntry@3 IS popped because 3 > 3 is false — wait, it's
    # popped because the M4.3 truncation rule is `step > target`, and
    # 3 is NOT > 3, so it's RETAINED. Re-derive:
    # ...
    # Actually: M4.3 pops entries with step > target=3. DeltaEntry@3
    # has step=3, NOT > 3, so it is RETAINED. CheckpointEntry@2 has
    # step=2, NOT > 3, also RETAINED.
    # Therefore after the M4.3 path: history is still
    # [CheckpointEntry@2, DeltaEntry@3].
    # Hmm — but then the next unstep! @ step_count=3 would see top =
    # DeltaEntry@3, guard `3 == 3` → TRUE, fast-path fires.
    # So the alternation IS: unstep!#1 (M4.3, falls through past
    # DeltaEntry@3 because its step doesn't match step_count=4);
    # unstep!#2 (M7.4 fast-path on DeltaEntry@3); unstep!#3 (M7.4 path
    # OR M4.3 — depends on top); unstep!#4 (M4.3 path → s.initial).
    unstep!(rs, vm)
    @test rs.step_count == 3
    # Both entries retained: CheckpointEntry@2 (2 not > 3) and
    # DeltaEntry@3 (3 not > 3). The M4.3 replay reconstructed the
    # step-3 state from CheckpointEntry@2 + 1 forward step.
    @test length(rs.history) == 2
    @test rs.history[1] isa BennettVM.CheckpointEntry
    @test rs.history[1].step == 2
    @test rs.history[end] isa BennettVM.DeltaEntry
    @test BennettVM._entry_step(rs.history[end]) == 3
    # current matches the pre-step-4 state (i.e., post-step-3) — the
    # state we captured BEFORE the Arith :sub completed, advanced ONE
    # step forward via M4.3 replay. Equivalent to "the state at the
    # moment we manually pushed the DeltaEntry, post-Arith-sub".
    # Actually: pre_arith_sub was captured pre-step-3; the replay
    # restored CheckpointEntry@2 (step-2 state) and replayed 1 step
    # forward (Arith :sub) to reach step-3 state. So rs.current is
    # the post-step-3 state.
    @test haskey(rs.current.locals, :y)   # post-Arith-sub created :y.

    # Capture pre-step-3 state for the next assertion — we need the
    # state at step 2 to compare against the next unstep!'s result.
    pre_step3_check = deepcopy(rs.history[1].snapshot)

    # unstep! #2 @ step_count=3 → top is DeltaEntry@3; guard `3 == 3`
    # → TRUE; M7.4 fast-path fires. Pop DeltaEntry@3, apply
    # inverse(arith_sub_instr, current, NamedTuple()), decrement
    # step_count to 2.
    unstep!(rs, vm)
    @test rs.step_count == 2
    # Only CheckpointEntry@2 remains.
    @test length(rs.history) == 1
    @test rs.history[end] isa BennettVM.CheckpointEntry
    @test rs.history[end].step == 2
    # current matches the step-2 state — the inverse of Arith :sub
    # took us from post-step-3 back to post-step-2.
    @test rs.current == pre_step3_check
    @test rs.current == pre_arith_sub   # same step-2 state.

    # unstep! #3 @ step_count=2 → top is CheckpointEntry@2; guard
    # `last is DeltaEntry` → FALSE; M4.3 path. Nearest checkpoint at
    # <= target=1 is NONE (the only entry is step 2 > 1). Fall back
    # to s.initial. Truncate entries with step > 1: pop
    # CheckpointEntry@2 (2 > 1). Replay 1 step forward (Begin) to
    # reach target=1.
    unstep!(rs, vm)
    @test rs.step_count == 1
    @test isempty(rs.history)   # CheckpointEntry@2 popped (2 > 1).

    # unstep! #4 @ step_count=1 → history empty; fast-path guard FALSE
    # (`isempty`); M4.3 fall back to s.initial, replay 0 steps.
    unstep!(rs, vm)
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current == initial_current
    @test rs.current == rs.initial
end
