# test/test_zero_history_roundtrip.jl — M6.4 capstone (bd `bennettvm-moa`).
#
# # What this milestone integration-tests
#
# M6.1 (`src/history/Injective.jl`, commit `6b59824`) classifies the
# nine type-level injective `Instruction` subtypes (SwapInstruction,
# all six `ControlInstruction` subtypes, MemoryInterchange, MemorySwap)
# plus the value-level `ArithmeticAssignment(modop=:xor)` case as
# *injective* under PRD v4 §3.2's "Injective primitives" — i.e.,
# `forward` is information-preserving on `IState`, so the inverse is
# recoverable from current state alone (Vieri Pendulum §4.2.1
# Exchange-as-injective; Mogensen 2016 §3 paired entry/exit; PRD v4
# §3.2 lines 413-446).
#
# M6.2 (`src/interpreter/Interpreter.jl` lines 744-763, commit
# `e9eb994`) AND-gates `step!`'s L3 push site with `!is_injective(instr)`
# so injective instructions never push a `CheckpointEntry`. PRD v4 §3.3
# layer 1 "No log" (lines 448-479).
#
# M6.3 (`test/test_injective_inverse.jl`, commit `44dfdca`) pins —
# at the per-instruction level — that `inverse(i, deepcopy(forward(i,
# deepcopy(s_pre))), nothing) == s_pre` holds for every M6.1-injective
# instruction. That property is what makes M6.2's L1 gate sound: a
# missing history entry is recoverable from current state.
#
# **M6.4 (this file) is the integration capstone**: build VM programs
# composed *entirely* of injective instructions, exercise the full
# `step!` / `run!` / `unstep!` / `unrun!` machinery on them, and pin
# the load-bearing zero-history invariants —
#
#   1. `run!` halts with the correct (golden-master-reference)
#      result.
#   2. `isempty(rs.history)` holds at EVERY step (not just at start /
#      end). The L3 push gate is K-insensitive on all-injective
#      programs: under K=1 the gate is most aggressive, under
#      K=typemax(Int) the gate is most permissive; both must produce
#      identical zero-history behavior.
#   3. `unrun!` succeeds — `step_count == 0`, `isempty(history)`,
#      `rs.current == rs.initial`. Backward reversal works via
#      `unstep!`'s `s.initial` fallback path (Replay.jl step (3))
#      because no checkpoint was ever pushed.
#   4. Per-step inverse pattern (PRD v4 §3.13): for any non-trivial
#      forward slice `step!` × N, the paired `unstep!` × N restores
#      the pre-slice state bit-for-bit. This is the spike Q3
#      lesson re-applied at the all-injective layer.
#   5. Mid-run `unrun!` (forward N < halt; then `unrun!`) lands at
#      `rs.initial` regardless of halt status.
#
# Each of the five helper programs below exercises a different
# combination of injective instructions: arithmetic-xor chain, swap
# chain, two-block cross-block with xor bodies, memory swap with
# delete-on-zero, and a mixed swap+xor+interchange single block.
#
# # Golden-master discipline (PRD v4 §3.14)
#
# Each helper has a paired irreversible Julia reference function that
# computes the same final locals/memory from the same input. The forward
# integration tests assert `result(rs)` (and the surviving memory dict)
# equals the reference function's output. This pins forward correctness
# independently of the round-trip — a buggy `forward` that happened to
# be its own inverse would pass round-trip tests but fail golden-master.
#
# # The load-bearing zero-history-throughout assertion (Rule 4)
#
# `_assert_zero_history_per_step!(rs, vm, K)` loops `step!` and
# asserts `isempty(rs.history)` after EVERY step, not just at start /
# end. A naive "check empty at the end" would silently miss a
# transient push-then-pop bug. The per-step assertion catches a
# regression of M6.2's `!is_injective(instr) &&` gate (e.g., gate
# accidentally dropped → on a K-multiple step the push fires, then
# subsequent steps don't push, but the lingering entry stays — caught
# at step K).
#
# # Mutation matrix (Rule 5)
#
# Each testset below documents one specific mutation in M6.1/M6.2/M6.3
# production code that would turn its asserts RED, with file:line. Six
# canonical mutations are exercised:
#
#  (a) Drop `!is_injective(instr) &&` from `step!`'s `should_checkpoint`
#      clause (`src/interpreter/Interpreter.jl:757`):
#        → zero-history-throughout RED at first K-multiple step.
#  (b) SwapInstruction.inverse target↔source transposition
#      (`src/ir/swap_instruction.jl:184`):
#        → round-trip RED on locals after `unrun!`.
#  (c) Drop `s.initial` fallback in Replay.jl
#      (`src/history/Replay.jl:259-265`):
#        → `unstep!` would error "no checkpoint at step 0" on the first
#          backward step for a zero-history program.
#  (d) Drop the `is_injective(SwapInstruction) = true` specialisation
#      (`src/history/Injective.jl:269`):
#        → Swap-program zero-history-throughout RED at every K-multiple.
#  (e) `is_injective(::Type{<:Instruction})::Bool = true` default flip
#      (`src/history/Injective.jl:248`):
#        → would actually pass these tests, BUT would break
#          `test_injective.jl` and `test_roundtrip.jl` test 9 (which
#          pins non-zero history on non-injective programs); cross-file
#          mutation-proof.
#  (f) Drop the `inverse(MemoryInterchange).delete-on-zero` rule
#      (`src/ir/memory_instructions.jl:428`):
#        → memory-program round-trip RED on memory dict equality.
#
# # Cross-block dispatch caveat (no `_handle_backward_cross_block_dispatch!`)
#
# M6.3's audit surfaced a gap: there is no
# `_handle_backward_cross_block_dispatch!` analogue. The backward path
# in `unstep!` (Replay.jl) handles cross-block transitions via the
# checkpoint+forward-replay strategy: when no checkpoint is available
# (the all-injective regime), `unstep!` falls back to `s.initial` at
# step 0 and replays *forward*, which uses the existing forward cross-
# block dispatch. So all-injective + cross-block round-trip is sound
# THROUGH THE REPLAY PATH even though no direct backward cross-block
# dispatch exists. The bennettvm-xtb bead tracking that gap remains
# correctly characterised as P3 (forward-replay-path performance
# optimization, not correctness).
#
# # Ref
#
#   * `bennettvm_prd.md` (PRD v4) §3.2 (lines 413-446) — injective
#     primitives.
#   * `bennettvm_prd.md` (PRD v4) §3.3 (lines 448-479) — three-layer
#     history; L1 "No log".
#   * `bennettvm_prd.md` (PRD v4) §3.13 — per-step inverse / round-trip
#     invariant.
#   * `bennettvm_prd.md` (PRD v4) §3.15 — property-test discipline.
#   * `src/history/Injective.jl` (M6.1, commit `6b59824`).
#   * `src/interpreter/Interpreter.jl` (M6.2 gate at line 757, commit
#     `e9eb994`).
#   * `test/test_injective_inverse.jl` (M6.3 unit tests, commit `44dfdca`).
#   * `src/history/Replay.jl` (M4.3/M4.4 `unstep!`/`unrun!`; `s.initial`
#     fallback at line 259-265).
#   * `test/test_roundtrip.jl` (M4.5 capstone) — analogue at the L3
#     layer; M6.4 here is the analogue at the L1 layer.
#   * `spike/RETROSPECTIVE.md` Q3 — per-step inverse pattern's origin.
#   * CLAUDE.md Rule 4 (every test asserts a known-correct value);
#     Rule 5 (mutation-proof); Rule 11 (literate docstring).

using Test
using BennettVM

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

"""
    _assert_zero_history_per_step!(rs, vm, K) -> Int

Loop `step!(rs, vm; checkpoint_interval=K)` until `is_halted(rs)`,
asserting `isempty(rs.history)` after EVERY step. Returns the final
`rs.step_count`. The load-bearing assertion is per-step, not just at
end — see file docstring "The load-bearing zero-history-throughout
assertion".
"""
function _assert_zero_history_per_step!(rs, vm, K::Int)
    n = 0
    while !is_halted(rs)
        step!(rs, vm; checkpoint_interval=K)
        n += 1
        @test isempty(rs.history)
        n > 10_000 && error("_assert_zero_history_per_step!: max iters exceeded")
    end
    return n
end

# ---------------------------------------------------------------------
# (a) Single-block xor program — all-injective (Begin + N xor + End).
# ---------------------------------------------------------------------

"""
    _single_block_xor_program() -> (VMProgram, Dict{Symbol,Int64}, Dict{Symbol,Int64})

Single-block program: `Begin(:m, [:x0]) + 3 × ArithAssign(modop=:xor) +
End(:m, [:x3])`. All five flat-stream instructions are injective.

Each ArithAssign does `x_{i+1} := x_i ⊻ (lhs op rhs)` for fixed literal
constants — the constant pattern `op=:and, lhs=C, rhs=M` produces
`(C & M)` reproducibly. The chain materialises three distinct SSA
names (:x1, :x2, :x3) and destroys two (:x0, :x1, :x2). Returns the
VMProgram, the input dict, and the expected output dict (golden master,
computed in Julia).
"""
function _single_block_xor_program()
    # Constants chosen to make each step's effect distinct.
    # step 2: :x1 := :x0 ⊻ (0b1111 & 0b1010) = :x0 ⊻ 0b1010
    # step 3: :x2 := :x1 ⊻ (0b0011 & 0b0011) = :x1 ⊻ 0b0011
    # step 4: :x3 := :x2 ⊻ (0b1100 & 0b0101) = :x2 ⊻ 0b0100
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:x0]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:x1, :x0, :xor,
                Int64(0b1111), :and, Int64(0b1010)),
            BennettVM.ArithmeticAssignment(:x2, :x1, :xor,
                Int64(0b0011), :and, Int64(0b0011)),
            BennettVM.ArithmeticAssignment(:x3, :x2, :xor,
                Int64(0b1100), :and, Int64(0b0101)),
        ],
        BennettVM.EndInstruction(:m, [:x3]))
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
    input = Dict(:x0 => Int64(0b0110))   # 6
    # Golden master (Julia reference computation):
    expected_x3 = Int64(0b0110) ⊻ (Int64(0b1111) & Int64(0b1010))
    expected_x3 = expected_x3 ⊻ (Int64(0b0011) & Int64(0b0011))
    expected_x3 = expected_x3 ⊻ (Int64(0b1100) & Int64(0b0101))
    expected = Dict(:x3 => expected_x3)
    return vm, input, expected
end

# ---------------------------------------------------------------------
# (b) Swap-chain program — all-injective (Begin + 3 swaps + End).
# ---------------------------------------------------------------------

"""
    _swap_chain_program() -> (VMProgram, Dict{Symbol,Int64}, Dict{Symbol,Int64})

Single-block: Begin(:m, [:a, :b, :c, :d]) + 3 × SwapInstruction + End.
Each SwapInstruction renames `(s1, s2) → (t1, t2)` positionally
(target1 receives source1's value).

Step trace:
  step 1: Begin           — pc++
  step 2: Swap (:p,:q,:a,:b)   — :a,:b destroyed; :p,:q created
  step 3: Swap (:r,:s,:c,:d)   — :c,:d destroyed; :r,:s created
  step 4: Swap (:w,:x,:p,:r)   — :p,:r destroyed; :w,:x created
  step 5: End

After step 4: locals = {:w => initial_a, :x => initial_c, :q => initial_b, :s => initial_d}.
"""
function _swap_chain_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:a, :b, :c, :d]),
        BennettVM.Instruction[
            BennettVM.SwapInstruction(:p, :q, :a, :b),
            BennettVM.SwapInstruction(:r, :s, :c, :d),
            BennettVM.SwapInstruction(:w, :x, :p, :r),
        ],
        BennettVM.EndInstruction(:m, [:w, :x, :q, :s]))
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64, 64, 64, 64], [64, 64, 64, 64])
    input = Dict(:a => Int64(11), :b => Int64(22),
                 :c => Int64(33), :d => Int64(44))
    expected = Dict(:w => Int64(11), :x => Int64(33),
                    :q => Int64(22), :s => Int64(44))
    return vm, input, expected
end

# ---------------------------------------------------------------------
# (c) Two-block uncond-cross + xor bodies — all-injective.
# ---------------------------------------------------------------------

"""
    _two_block_uncond_program() -> (VMProgram, Dict{Symbol,Int64}, Dict{Symbol,Int64})

Two blocks chained by `UnconditionalExit` / `UnconditionalEntry`,
bodies of all-injective ArithmeticAssignment(:xor).

  Block :b_a: Begin([:n0]) + Xor(:n1, :n0, mask=0b1010) + UncondExit(:b_b, [:n1])
  Block :b_b: UncondEntry([:n2])              # identity rename n1->n2
              + Xor(:n3, :n2, mask=0b0101) + End([:n3])

Wait — args→params is positional, so we exit with [:n1] and re-receive
as [:n2]. The cross-block dispatch will rename `:n1 → :n2` inside the
locals dict.

Forward step trace (8 steps total):
  step 1: BeginInstruction          (block :b_a entry)
  step 2: ArithAssign(:xor)         (n1 := n0 ⊻ 10)
  step 3: UnconditionalExit         (cross-block to :b_b; rename n1->n2)
  step 4: UnconditionalEntry        (block :b_b entry marker, skipped via pc+1 in dispatch — but actually pc is set to fwd_address+1 in _dispatch_to_block!, so step 3 effectively lands pc one PAST :b_b's entry. The entry marker is NOT counted as a step from the dispatch perspective; control flows directly into the body.)

Actually let me re-check: looking at `_dispatch_to_block!`, after
`UnconditionalExit`'s forward, the dispatch sets pc to
`target_entry.fwd_address + 1` — one past the entry marker. So the
entry marker is skipped from the dispatch's perspective. Hmm wait —
that means the entry marker is never `step!`-dispatched in the
forward direction.

But step_count counts successful `step!` calls. So the entry marker
contributes nothing to step_count in forward direction. Let me revise:

Forward (counted via step!):
  step 1: BeginInstruction          (block :b_a entry)
  step 2: ArithAssign(:xor)
  step 3: UnconditionalExit         (this step skips past the entry of :b_b)
  step 4: ArithAssign(:xor)
  step 5: EndInstruction

→ 5 steps; all injective; zero history at every step regardless of K.
"""
function _two_block_uncond_program()
    bb_a = BennettVM.BasicBlock(:b_a,
        BennettVM.BeginInstruction(:m, [:n0]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:n1, :n0, :xor,
                Int64(0b1010), :and, Int64(0b1111)),    # mask = 0b1010
        ],
        BennettVM.UnconditionalExit(:b_b, [:n1]))
    bb_b = BennettVM.BasicBlock(:b_b,
        BennettVM.UnconditionalEntry(:b_b, [:n2]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:n3, :n2, :xor,
                Int64(0b0101), :and, Int64(0b1111)),    # mask = 0b0101
        ],
        BennettVM.EndInstruction(:m, [:n3]))
    blocks = [bb_a, bb_b]
    vm = VMProgram(blocks, BennettVM.LabelTable(blocks), :b_a, [64], [64])
    input = Dict(:n0 => Int64(0b1100))   # 12
    # Golden master — mirror the instructions' semantics exactly:
    # `ArithmeticAssignment(target, source, :xor, lhs, op, rhs)` is
    # `target := source ⊻ (lhs op rhs)`. The instruction-level mask is
    # `lhs & rhs` (lhs=0b1010 or 0b0101, rhs=0b1111). Computing the
    # mask explicitly here (rather than simplifying to a literal) so
    # a future edit to `lhs` or `rhs` cannot silently desynchronise
    # the golden master from the instruction semantics.
    mask_a = Int64(0b1010) & Int64(0b1111)
    mask_b = Int64(0b0101) & Int64(0b1111)
    n1 = Int64(0b1100) ⊻ mask_a
    n3 = n1 ⊻ mask_b
    expected = Dict(:n3 => n3)
    return vm, input, expected
end

# ---------------------------------------------------------------------
# (d) Memory-swap program — MemoryInterchange + MemorySwap.
# ---------------------------------------------------------------------

"""
    _memory_swap_program() -> (VMProgram, Dict, Dict, Dict, Dict)

Single-block: Begin([:z0]) + MemoryInterchange(:x1, 100, :z0) +
MemorySwap(100, 200) + End([:x1]).

Pre-state: locals[:z0] = 0 (triggers MemoryInterchange's
delete-on-zero edge case inside the *inverse* on the way back —
during forward, M[100] := 0; during inverse, the delete-on-zero
rule fires when restoring). memory[100] = 0 (absent); memory[200] = 999.

Step trace:
  step 1: Begin                              — injective
  step 2: MemoryInterchange(:x1, 100, :z0)   — injective; M[100] := z0=0,
                                               :x1 := old M[100] = 0,
                                               :z0 destroyed.
  step 3: MemorySwap(100, 200)               — injective; swap M[100] <-> M[200].
                                               M[100] was 0 (just written), M[200] was 999.
                                               After swap: M[100] := 999, M[200] deleted (was 0).
  step 4: End

Returns (vm, locals_input, memory_input, expected_locals, expected_memory).
"""
function _memory_swap_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:z0]),
        BennettVM.Instruction[
            BennettVM.MemoryInterchange(:x1, Int64(100), :z0),
            BennettVM.MemorySwap(Int64(100), Int64(200)),
        ],
        BennettVM.EndInstruction(:m, [:x1]))
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
    input_locals = Dict(:z0 => Int64(0))
    input_memory = Dict{Int64,Int64}(Int64(200) => Int64(999))
    # Golden master walk:
    #   forward MemoryInterchange: read M[100]=0 (zero-init); M[100]:=z0=0; :x1:=0; del :z0.
    #     locals = {:x1=>0}; memory = {100=>0, 200=>999}.
    #   forward MemorySwap(100,200): va = M[100]=0, vb = M[200]=999.
    #     write M[100] := vb=999; va==0 → delete M[200].
    #     memory = {100=>999}.
    expected_locals = Dict(:x1 => Int64(0))
    expected_memory = Dict{Int64,Int64}(Int64(100) => Int64(999))
    return vm, input_locals, input_memory, expected_locals, expected_memory
end

# ---------------------------------------------------------------------
# (e) Mixed-injective single-block — Swap + xor + MemoryInterchange.
# ---------------------------------------------------------------------

"""
    _mixed_injective_program() -> (VMProgram, Dict, Dict, Dict, Dict)

Single-block exercise of three injective instruction *kinds* in one
program: SwapInstruction, ArithmeticAssignment(:xor), MemoryInterchange.

  Begin([:a, :b, :z])
  Swap(:p, :q, :a, :b)                  — :a,:b -> :p,:q
  ArithAssign(:t, :p, :xor, 0b11, :and, 0b11)   — :p destroyed, :t created (t := p ⊻ 3)
  MemoryInterchange(:m, 50, :z)         — :z destroyed, :m := M[50]; M[50] := old z
  End([:t, :q, :m])

Step trace (6 steps; all injective):
  step 1: Begin
  step 2: Swap
  step 3: Xor
  step 4: MemoryInterchange
  step 5: End
"""
function _mixed_injective_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:a, :b, :z]),
        BennettVM.Instruction[
            BennettVM.SwapInstruction(:p, :q, :a, :b),
            BennettVM.ArithmeticAssignment(:t, :p, :xor,
                Int64(0b11), :and, Int64(0b11)),
            BennettVM.MemoryInterchange(:m_out, Int64(50), :z),
        ],
        BennettVM.EndInstruction(:m, [:t, :q, :m_out]))
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64, 64, 64], [64, 64, 64])
    input_locals = Dict(:a => Int64(7), :b => Int64(20), :z => Int64(77))
    input_memory = Dict{Int64,Int64}(Int64(50) => Int64(5))
    # Golden master walk:
    #   Swap: p:=a=7, q:=b=20; del a,b. locals = {p=>7,q=>20,z=>77}.
    #   Xor:  e = 3 & 3 = 3; t := p ⊻ 3 = 7 ⊻ 3 = 4; del p.
    #         locals = {t=>4, q=>20, z=>77}.
    #   MemInter: M[50] read = 5; M[50] := z=77; del z; m_out := 5.
    #         locals = {t=>4, q=>20, m_out=>5}; memory = {50=>77}.
    expected_locals = Dict(:t => Int64(4), :q => Int64(20), :m_out => Int64(5))
    expected_memory = Dict{Int64,Int64}(Int64(50) => Int64(77))
    return vm, input_locals, input_memory, expected_locals, expected_memory
end

# Helper to build an RState with a pre-populated memory dict.
function _initial_state_with_memory(vm, locals_input, memory_input)
    rs = initial_state(vm, locals_input)
    for (k, v) in memory_input
        rs.current.memory[k] = v
        rs.initial.memory[k] = v   # match initial anchor for round-trip
    end
    return rs
end

# K values we exercise across the testsets. K=1 is the most aggressive
# push regime under M4.2 alone; the L1 gate must still keep history
# empty. K=typemax(Int) suppresses pushes entirely (regardless of
# injectivity). K=4 is the canonical M4.5 sweep value.
const _K_VALUES = (1, 4, 64, typemax(Int))

# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------

@testset "M6.4 — single-block xor program (forward + zero-history-throughout)" begin
    # Mutation target: drop `!is_injective(instr) &&` from the
    # should_checkpoint clause at `src/interpreter/Interpreter.jl:757`.
    # Under that mutation, at K=1 the very first ArithAssign step
    # (step 2) would push a CheckpointEntry, breaking the
    # `isempty(rs.history)` per-step assertion below.
    #
    # Also exercises forward golden-master correctness (test 1 of the
    # M6.4 spec).
    for K in _K_VALUES
        vm, input, expected = _single_block_xor_program()
        rs = initial_state(vm, input)
        @test isempty(rs.history)                    # start state: clean.

        steps = _assert_zero_history_per_step!(rs, vm, K)

        @test is_halted(rs)
        @test rs.step_count == 5                     # Begin + 3 xor + End
        @test steps == 5
        @test isempty(rs.history)                    # end state: still clean
        @test result(rs)[:x3] == expected[:x3]       # golden master agreement
    end
end

@testset "M6.4 — single-block xor program (run!-then-unrun! round-trip)" begin
    # Mutation target: drop `s.initial` fallback at
    # `src/history/Replay.jl:259-265`. Without it, the first
    # `unstep!` call would error "no checkpoint at step 0" because
    # `nearest_idx === nothing` and there's no fallback snapshot.
    # All four K values must pass — the L1 gate produces identical
    # zero-history runs across K.
    for K in _K_VALUES
        vm, input, _ = _single_block_xor_program()
        rs = initial_state(vm, input)
        initial_current = deepcopy(rs.current)

        run!(rs, vm; checkpoint_interval=K)
        @test is_halted(rs)
        @test isempty(rs.history)                    # M6.4 invariant 2.

        unrun!(rs, vm)
        @test rs.step_count == 0
        @test isempty(rs.history)
        @test rs.current == initial_current
        @test rs.current == rs.initial
        @test rs.current.status === :running         # NOT :halted post-unrun!
    end
end

@testset "M6.4 — single-block xor program (per-step inverse pattern, PRD §3.13)" begin
    # Mutation target: a hypothetical regression in
    # `src/history/Replay.jl`'s replay loop (line 301-303) that
    # off-by-ones the target — e.g., `s.step_count < target - 1`
    # instead of `< target` — would leave the post-unstep! state at
    # one step further back than expected, breaking the per-step
    # snapshot equality. Catches an aggregate-round-trip-masking bug
    # per spike Q3.
    vm, input, _ = _single_block_xor_program()
    rs = initial_state(vm, input)
    initial_current = deepcopy(rs.current)

    # Forward: capture deepcopy after each step.
    forward_snapshots = BennettVM.IState[]
    while !is_halted(rs)
        step!(rs, vm; checkpoint_interval=4)
        push!(forward_snapshots, deepcopy(rs.current))
        @test isempty(rs.history)                   # per-step zero-history
    end
    @test length(forward_snapshots) == 5

    # Backward: unstep! one at a time; pin each intermediate.
    while rs.step_count > 0
        prev_count = rs.step_count
        unstep!(rs, vm)
        @test rs.step_count == prev_count - 1
        @test isempty(rs.history)                   # still empty after unstep!
        if rs.step_count > 0
            @test rs.current == forward_snapshots[rs.step_count]
        else
            @test rs.current == initial_current
            @test rs.current == rs.initial
        end
    end
end

@testset "M6.4 — single-block xor program (mid-run unrun! before halt)" begin
    # Step forward 3 of the 5 steps (NOT to halt), then unrun! all
    # the way back. step_count: 0→3, then 3→0. Status remains
    # :running throughout — no halt boundary.
    #
    # Mutation target: a hypothetical `unrun!` regression that
    # checked `is_halted(s)` before entering the loop (analogue of
    # test_roundtrip.jl test 10's mid-run case) would silently no-op
    # on the non-halted state, leaving step_count at 3.
    vm, input, _ = _single_block_xor_program()
    rs = initial_state(vm, input)
    initial_current = deepcopy(rs.current)

    for _ in 1:3
        step!(rs, vm; checkpoint_interval=4)
        @test isempty(rs.history)
    end
    @test rs.step_count == 3
    @test !is_halted(rs)
    @test rs.current.status === :running

    unrun!(rs, vm)
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current == initial_current
    @test rs.current == rs.initial
    @test rs.current.status === :running
end

@testset "M6.4 — swap-chain program (forward + zero-history-throughout)" begin
    # Mutation target: drop `is_injective(::Type{SwapInstruction}) =
    # true` at `src/history/Injective.jl:269`. Then at K=1, steps 2,
    # 3, 4 (the three SwapInstructions) would each push a checkpoint,
    # and `isempty(rs.history)` would RED at step 2.
    for K in _K_VALUES
        vm, input, expected = _swap_chain_program()
        rs = initial_state(vm, input)
        @test isempty(rs.history)

        steps = _assert_zero_history_per_step!(rs, vm, K)

        @test is_halted(rs)
        @test rs.step_count == 5                     # Begin + 3 swaps + End
        @test steps == 5
        @test isempty(rs.history)
        # Golden master: full permutation result.
        res = result(rs)
        @test res[:w] == expected[:w]                # initial :a (11)
        @test res[:x] == expected[:x]                # initial :c (33)
        @test res[:q] == expected[:q]                # initial :b (22)
        @test res[:s] == expected[:s]                # initial :d (44)
    end
end

@testset "M6.4 — swap-chain program (run!-then-unrun! round-trip)" begin
    # Mutation target: SwapInstruction.inverse target↔source
    # transposition at `src/ir/swap_instruction.jl:184`. Specifically
    # if line 184 reads `BennettVM.active_locals(s)[instr.source2] = v1` instead of
    # `BennettVM.active_locals(s)[instr.source1] = v1`, the unrun! result would have
    # swapped names (initial :a's value would land at :b's slot etc.),
    # breaking the rs.current == initial_current assertion.
    for K in _K_VALUES
        vm, input, _ = _swap_chain_program()
        rs = initial_state(vm, input)
        initial_current = deepcopy(rs.current)

        run!(rs, vm; checkpoint_interval=K)
        @test is_halted(rs)
        @test isempty(rs.history)

        unrun!(rs, vm)
        @test rs.step_count == 0
        @test isempty(rs.history)
        @test rs.current == initial_current
        @test rs.current == rs.initial
        @test BennettVM.active_locals(rs.current)[:a] == Int64(11)     # original input pinned
        @test BennettVM.active_locals(rs.current)[:b] == Int64(22)
        @test BennettVM.active_locals(rs.current)[:c] == Int64(33)
        @test BennettVM.active_locals(rs.current)[:d] == Int64(44)
        @test rs.current.status === :running
    end
end

@testset "M6.4 — two-block uncond-cross program (forward + zero-history)" begin
    # The first cross-block exercise. Forward dispatch crosses block
    # boundary via `_handle_cross_block_dispatch!`
    # (src/interpreter/Interpreter.jl line 724). UnconditionalExit and
    # UnconditionalEntry are both M6.1-injective; no push at any step.
    #
    # Mutation target: drop `is_injective(::Type{UnconditionalExit}) =
    # true` at `src/history/Injective.jl:281`. Then at K=1, the cross-
    # block exit step (step 3) would push, breaking zero-history.
    for K in _K_VALUES
        vm, input, expected = _two_block_uncond_program()
        rs = initial_state(vm, input)
        @test isempty(rs.history)

        steps = _assert_zero_history_per_step!(rs, vm, K)

        @test is_halted(rs)
        @test rs.step_count == 5                # Begin + xor + UncondExit + xor + End
        @test steps == 5
        @test isempty(rs.history)
        @test result(rs)[:n3] == expected[:n3]       # golden master
    end
end

@testset "M6.4 — two-block uncond-cross program (round-trip via s.initial fallback)" begin
    # The backward cross-block dispatch case (M6.3 audit gap
    # `bennettvm-xtb`). Per Replay.jl, unstep! on a zero-history
    # program falls back to s.initial and replays forward from step 0
    # to target via existing forward `_handle_cross_block_dispatch!`.
    # The forward-replay path consumes the cross-block dispatch
    # transparently. If a future regression broke that replay path
    # (e.g., dropped the typemax(Int) kwarg in unstep!'s replay loop
    # `src/history/Replay.jl:302`), zero-history would degenerate
    # because the replay forward step would push checkpoints, and the
    # post-unrun! history would not be empty.
    for K in _K_VALUES
        vm, input, _ = _two_block_uncond_program()
        rs = initial_state(vm, input)
        initial_current = deepcopy(rs.current)

        run!(rs, vm; checkpoint_interval=K)
        @test is_halted(rs)
        @test isempty(rs.history)

        unrun!(rs, vm)
        @test rs.step_count == 0
        @test isempty(rs.history)
        @test rs.current == initial_current
        @test rs.current == rs.initial
        @test BennettVM.active_locals(rs.current)[:n0] == Int64(0b1100)
        @test rs.current.status === :running
    end
end

@testset "M6.4 — two-block uncond-cross program (per-step inverse)" begin
    # The per-step inverse pattern on a cross-block program. After
    # each unstep!, rs.current must == the corresponding forward
    # snapshot — this catches a bug where the backward path lands at
    # the right pc but wrong locals (e.g., a broken args→params
    # rename inverse).
    vm, input, _ = _two_block_uncond_program()
    rs = initial_state(vm, input)
    initial_current = deepcopy(rs.current)

    forward_snapshots = BennettVM.IState[]
    while !is_halted(rs)
        step!(rs, vm; checkpoint_interval=4)
        push!(forward_snapshots, deepcopy(rs.current))
        @test isempty(rs.history)
    end
    @test length(forward_snapshots) == 5

    while rs.step_count > 0
        prev_count = rs.step_count
        unstep!(rs, vm)
        @test rs.step_count == prev_count - 1
        @test isempty(rs.history)
        if rs.step_count > 0
            @test rs.current == forward_snapshots[rs.step_count]
        else
            @test rs.current == initial_current
            @test rs.current == rs.initial
        end
    end
end

@testset "M6.4 — memory-swap program (forward + zero-history)" begin
    # MemoryInterchange + MemorySwap are both M6.1-injective. The
    # delete-on-zero edge case is in the round-trip testset below,
    # not in this forward-correctness one.
    #
    # Mutation target: drop `is_injective(::Type{MemoryInterchange}) =
    # true` at `src/history/Injective.jl:295` or
    # `is_injective(::Type{MemorySwap}) = true` at line 300. Then at
    # K=1 the corresponding step pushes, breaking zero-history.
    for K in _K_VALUES
        vm, locs_in, mem_in, expected_locs, expected_mem = _memory_swap_program()
        rs = _initial_state_with_memory(vm, locs_in, mem_in)
        @test isempty(rs.history)

        steps = _assert_zero_history_per_step!(rs, vm, K)

        @test is_halted(rs)
        @test rs.step_count == 4                     # Begin + MI + MS + End
        @test steps == 4
        @test isempty(rs.history)
        @test result(rs)[:x1] == expected_locs[:x1]
        @test rs.current.memory == expected_mem      # golden master memory dict
    end
end

@testset "M6.4 — memory-swap program (round-trip including delete-on-zero)" begin
    # Mutation target: drop the delete-on-zero rule in
    # `src/ir/memory_instructions.jl:428` (MemoryInterchange.inverse).
    # The initial M[100] is absent. Forward writes M[100]=0 (z0=0).
    # Inverse must DELETE M[100] (not leave it as 0), otherwise
    # rs.current.memory would carry a phantom {100=>0} entry that
    # rs.initial.memory lacks, breaking rs.current == rs.initial.
    for K in _K_VALUES
        vm, locs_in, mem_in, _, _ = _memory_swap_program()
        rs = _initial_state_with_memory(vm, locs_in, mem_in)
        initial_current = deepcopy(rs.current)

        run!(rs, vm; checkpoint_interval=K)
        @test is_halted(rs)
        @test isempty(rs.history)

        unrun!(rs, vm)
        @test rs.step_count == 0
        @test isempty(rs.history)
        @test rs.current == initial_current
        @test rs.current == rs.initial
        # Specific delete-on-zero pin: M[100] absent post-unrun!
        # (was absent pre-forward, gained value 0 post-forward).
        @test !haskey(rs.current.memory, Int64(100))
        @test rs.current.memory[Int64(200)] == Int64(999)
        @test BennettVM.active_locals(rs.current)[:z0] == Int64(0)
        @test rs.current.status === :running
    end
end

@testset "M6.4 — mixed-injective program (forward + zero-history)" begin
    # Three injective KINDS in one program: SwapInstruction,
    # ArithAssign(:xor), MemoryInterchange. The dispatch cycles
    # through three different injective-trait paths in one program.
    #
    # Mutation target: change the value-level
    # `is_injective(x::ArithmeticAssignment) = x.modop === :xor` at
    # `src/history/Injective.jl:328` to always-false. Step 3
    # (ArithAssign(:xor)) would then push under K=1, breaking
    # zero-history.
    for K in _K_VALUES
        vm, locs_in, mem_in, expected_locs, expected_mem = _mixed_injective_program()
        rs = _initial_state_with_memory(vm, locs_in, mem_in)
        @test isempty(rs.history)

        steps = _assert_zero_history_per_step!(rs, vm, K)

        @test is_halted(rs)
        @test rs.step_count == 5                # Begin + Swap + Xor + MI + End
        @test steps == 5
        @test isempty(rs.history)

        res = result(rs)
        @test res[:t] == expected_locs[:t]
        @test res[:q] == expected_locs[:q]
        @test res[:m_out] == expected_locs[:m_out]
        @test rs.current.memory == expected_mem
    end
end

@testset "M6.4 — mixed-injective program (round-trip + per-step inverse)" begin
    # Combined run!+unrun! and per-step inverse. The most demanding
    # all-injective round-trip in the file: three instruction kinds
    # all sharing the same `s.initial` fallback path on the way back.
    vm, locs_in, mem_in, _, _ = _mixed_injective_program()
    rs = _initial_state_with_memory(vm, locs_in, mem_in)
    initial_current = deepcopy(rs.current)

    # Forward with per-step snapshot.
    forward_snapshots = BennettVM.IState[]
    while !is_halted(rs)
        step!(rs, vm; checkpoint_interval=4)
        push!(forward_snapshots, deepcopy(rs.current))
        @test isempty(rs.history)
    end
    @test length(forward_snapshots) == 5

    # Backward per-step.
    while rs.step_count > 0
        prev_count = rs.step_count
        unstep!(rs, vm)
        @test rs.step_count == prev_count - 1
        @test isempty(rs.history)
        if rs.step_count > 0
            @test rs.current == forward_snapshots[rs.step_count]
        else
            @test rs.current == initial_current
            @test rs.current == rs.initial
        end
    end

    @test BennettVM.active_locals(rs.current)[:a] == Int64(7)
    @test BennettVM.active_locals(rs.current)[:b] == Int64(20)
    @test BennettVM.active_locals(rs.current)[:z] == Int64(77)
    @test rs.current.memory[Int64(50)] == Int64(5)
    @test rs.current.status === :running
end

@testset "M6.4 — RState equality identity for all-injective programs" begin
    # The structural identity check on the M4.3 RState == override.
    # For every helper program, `deepcopy(rs0)` then run! + unrun!
    # the live one must produce `rs == rs0`. This is the all-fields
    # one-liner; any field (current, history, step_count, initial)
    # that fails to be undone by unrun! turns this RED.
    #
    # Mutation target: any of the M6.x mutations cited above would
    # surface here too via the RState == override. This is a
    # cross-cutting load-bearing canary.
    for K in _K_VALUES
        # Program (a)
        let
            vm, input, _ = _single_block_xor_program()
            rs0 = initial_state(vm, input)
            rs = deepcopy(rs0)
            run!(rs, vm; checkpoint_interval=K)
            unrun!(rs, vm)
            @test rs == rs0
        end
        # Program (b)
        let
            vm, input, _ = _swap_chain_program()
            rs0 = initial_state(vm, input)
            rs = deepcopy(rs0)
            run!(rs, vm; checkpoint_interval=K)
            unrun!(rs, vm)
            @test rs == rs0
        end
        # Program (c)
        let
            vm, input, _ = _two_block_uncond_program()
            rs0 = initial_state(vm, input)
            rs = deepcopy(rs0)
            run!(rs, vm; checkpoint_interval=K)
            unrun!(rs, vm)
            @test rs == rs0
        end
        # Program (d)
        let
            vm, locs_in, mem_in, _, _ = _memory_swap_program()
            rs0 = _initial_state_with_memory(vm, locs_in, mem_in)
            rs = deepcopy(rs0)
            run!(rs, vm; checkpoint_interval=K)
            unrun!(rs, vm)
            @test rs == rs0
        end
        # Program (e)
        let
            vm, locs_in, mem_in, _, _ = _mixed_injective_program()
            rs0 = _initial_state_with_memory(vm, locs_in, mem_in)
            rs = deepcopy(rs0)
            run!(rs, vm; checkpoint_interval=K)
            unrun!(rs, vm)
            @test rs == rs0
        end
    end
end
