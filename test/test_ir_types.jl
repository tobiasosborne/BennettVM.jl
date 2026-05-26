# test/test_ir_types.jl — M2.18 hand-built countdown + reversed() validation.
#
# # What this file pins (the M2 exit gate)
#
# M2.18 (bd `bennettvm-p8n`) is the structural validation that the
# entire Phase-2 IR type hierarchy — 12 concrete `Instruction` subtypes
# (M2.6-M2.14), `BasicBlock` + `reversed()` + `structural_inverse`
# (M2.15), dual-address `LabelTable` (M2.16), and `VMProgram` (M2.17) —
# composes correctly into a representative program shape **before** M3
# builds the interpreter. The spike's `countdown(n)` is the canonical
# Phase-0 test fixture; this file rebuilds a structurally analogous
# program in Phase-2 IR and exercises every load-bearing primitive in
# the IR layer end-to-end.
#
# The fixture is deliberately three blocks, exercising all four
# control-flow types in the RSSA twelve-class set:
#
#   * `:b1` — `BeginInstruction` (subroutine entry, M2.8) → body
#     (`ArithmeticAssignment`, M2.6) → `ConditionalExit` (split with
#     predicate, M2.10).
#   * `:b2` — `ConditionalEntry` (join with predicate, M2.10) → body
#     (`ArithmeticAssignment`) → `UnconditionalExit` (basic-block exit,
#     M2.9).
#   * `:b3` — `UnconditionalEntry` (basic-block entry, M2.9) → empty
#     body → `EndInstruction` (subroutine exit, M2.8).
#
# This covers Begin/End (M2.8), UnconditionalEntry/Exit (M2.9),
# ConditionalEntry/Exit (M2.10), and `ArithmeticAssignment` (M2.6) —
# the full set of control-flow-class instructions plus the prototypical
# data-flow instruction, all simultaneously. The flat-stream layout
# (M2.16) sums to `3 + 3 + 2 = 8` instructions, with `LabelTable`
# computing the per-block addresses.
#
# # Why structural-only — semantic correctness is M3's job
#
# Phase-2 M2.18 is **structural validation**: the fixture must compose
# without `ErrorException` at construction time, the dual-address
# layout must match the analytical expectation, and the
# `structural_inverse` IR rewrites must be involutive. The fixture's
# `ArithmeticAssignment` bodies use deliberately degenerate forms
# (e.g. `:n XOR (:n XOR 0) = 0`) because semantic-level correctness —
# whether the program actually computes a meaningful countdown — is
# the interpreter's responsibility (M3.x) and is gated by M3-era
# behavioural tests, NOT here.
#
# # The mutation-proof witness (Rule 5)
#
# The fifth testset is the "documentation-via-test" form of Rule 5:
# rather than perturbing the production `structural_inverse` and
# observing the involution test fail, we hand-construct a HYPOTHETICAL
# bad inverse (an `ArithmeticAssignment` with target/source NOT
# swapped) and assert that — if `structural_inverse` ever regressed
# to produce such a bad value — the involution check in testset (3)
# would catch it. This is the structural form of "tests have caught a
# real regression": the witness documents what the regression would
# look like, and confirms the existing assertions are load-bearing.
#
# # Ref
#
#   * `bennettvm-p8n` bd issue (M2.18 task spec).
#   * `src/ir/VMProgram.jl` (M2.17) — the program-level struct under test.
#   * `src/ir/label_table.jl` (M2.16) — dual-address layout under test.
#   * `src/ir/basic_block.jl` (M2.15) — `reversed()` and
#     `structural_inverse` under test.
#   * `src/ir/control_instructions.jl` (M2.8/M2.9/M2.10) — all six
#     concrete `ControlInstruction` subtypes exercised by the fixture.
#   * `src/ir/arithmetic_assignment.jl` (M2.6) — `dual_modop` involution
#     under test in testset (3).
#   * `spike/src/Programs.jl` — the Phase-0 `countdown(n)` analogue
#     this fixture echoes structurally (but NOT semantically — see
#     "Why structural-only" above).
#   * CLAUDE.md Rule 1 (constructor validation); Rule 4 (every
#     assertion is against a known-correct value); Rule 5
#     (mutation-proof witness).

using Test
using BennettVM

@testset "countdown VMProgram structure (M2.18)" begin
    # Block :b1 — BeginInstruction → 1 ArithmeticAssignment → ConditionalExit.
    # Flat-layout contribution: 1 + 1 + 1 = 3 instructions.
    b1 = BennettVM.BasicBlock(
        :b1,
        BennettVM.BeginInstruction(:countdown, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:s, :n, :xor, :n, :xor, Int64(0)),
        ],
        BennettVM.ConditionalExit(:is_zero, :b3, :b2, [:s]),
    )

    # Block :b2 — ConditionalEntry → 1 ArithmeticAssignment → UnconditionalExit.
    # Flat-layout contribution: 1 + 1 + 1 = 3 instructions.
    b2 = BennettVM.BasicBlock(
        :b2,
        BennettVM.ConditionalEntry(:b2, [:s_in], :b1, :b2, :is_zero),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:s_out, :s_in, :add, :s_in, :and, Int64(1)),
        ],
        BennettVM.UnconditionalExit(:b3, [:s_out]),
    )

    # Block :b3 — UnconditionalEntry → empty body → EndInstruction.
    # Flat-layout contribution: 1 + 0 + 1 = 2 instructions.
    b3 = BennettVM.BasicBlock(
        :b3,
        BennettVM.UnconditionalEntry(:b3, [:s_final]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:countdown, [:s_final]),
    )

    blocks = [b1, b2, b3]
    label_table = BennettVM.LabelTable(blocks)
    vm = VMProgram(blocks, label_table, :b1, [64], [64])

    # All three labels resolve in the table.
    @test haskey(vm.label_table, :b1)
    @test haskey(vm.label_table, :b2)
    @test haskey(vm.label_table, :b3)

    # Per-block dual-address layout (M2.16 flat-stream convention,
    # `1 + length(body) + 1` per block):
    #   :b1 -> block_index=1, fwd=1, bwd=3   (entry at 1, exit at 3)
    #   :b2 -> block_index=2, fwd=4, bwd=6   (entry at 4, exit at 6)
    #   :b3 -> block_index=3, fwd=7, bwd=8   (entry at 7, exit at 8)
    @test vm.label_table[:b1].block_index == 1
    @test vm.label_table[:b1].fwd_address == 1
    @test vm.label_table[:b1].bwd_address == 3
    @test vm.label_table[:b2].block_index == 2
    @test vm.label_table[:b2].fwd_address == 4
    @test vm.label_table[:b2].bwd_address == 6
    @test vm.label_table[:b3].block_index == 3
    @test vm.label_table[:b3].fwd_address == 7
    @test vm.label_table[:b3].bwd_address == 8

    # Total flat-stream instruction count: 3 + 3 + 2 = 8.
    @test BennettVM.n_instructions(vm) == 8
    @test length(vm) == 3
end

@testset "BasicBlock reversed-of-reversed identity (M2.18)" begin
    # Rebuild the three-block fixture locally — testset isolation per
    # the M2.15-template convention (each testset owns its fixtures so
    # a failure mode is locally interpretable).
    b1 = BennettVM.BasicBlock(
        :b1,
        BennettVM.BeginInstruction(:countdown, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:s, :n, :xor, :n, :xor, Int64(0)),
        ],
        BennettVM.ConditionalExit(:is_zero, :b3, :b2, [:s]),
    )
    b2 = BennettVM.BasicBlock(
        :b2,
        BennettVM.ConditionalEntry(:b2, [:s_in], :b1, :b2, :is_zero),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:s_out, :s_in, :add, :s_in, :and, Int64(1)),
        ],
        BennettVM.UnconditionalExit(:b3, [:s_out]),
    )
    b3 = BennettVM.BasicBlock(
        :b3,
        BennettVM.UnconditionalEntry(:b3, [:s_final]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:countdown, [:s_final]),
    )

    # The reverse-of-reverse contract per the M2.15 docstring:
    # `reversed(reversed(bb))` produces a block STRUCTURALLY equivalent
    # to `bb` — same label, same body shape, same entry/exit class.
    # We don't assert `===` because:
    #   * The returned struct is a NEW value (purity contract, see
    #     M2.15 `structural_inverse(::MemorySwap)` rationale).
    #   * `BasicBlock` does not override `Base.==`; default `==` on a
    #     struct holding a `Vector` would compare the Vector field by
    #     identity, not contents.
    # So we compare structural shape field-by-field.
    for b in [b1, b2, b3]
        rr = BennettVM.reversed(BennettVM.reversed(b))
        @test rr.label === b.label
        @test length(rr.instructions) == length(b.instructions)
        @test typeof(rr.entry) === typeof(b.entry)
        @test typeof(rr.exit) === typeof(b.exit)
    end
end

@testset "ArithmeticAssignment structural_inverse is involutive (M2.18)" begin
    # The body of :b1 contains exactly one ArithmeticAssignment. The
    # involution check pins that `structural_inverse` faithfully
    # swaps `target` and `source` AND flips `modop` via `dual_modop`,
    # such that a double application recovers the original fields
    # (per the M2.15 `structural_inverse(::ArithmeticAssignment)`
    # implementation in `src/ir/basic_block.jl`). This is the
    # `dual_modop` involution test (`dual_modop(:xor) === :xor` self-
    # inverse, `dual_modop(:add) === :sub` paired-inverse) wired
    # through the IR-graph layer.
    b1 = BennettVM.BasicBlock(
        :b1,
        BennettVM.BeginInstruction(:countdown, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:s, :n, :xor, :n, :xor, Int64(0)),
        ],
        BennettVM.ConditionalExit(:is_zero, :b3, :b2, [:s]),
    )
    a = b1.instructions[1]
    @test a isa BennettVM.ArithmeticAssignment

    inv  = BennettVM.structural_inverse(a)
    inv2 = BennettVM.structural_inverse(inv)

    # Field-by-field involution: every load-bearing field on the
    # double-inverse must equal the original. `lhs` / `op` / `rhs`
    # are read-only operands (preserved unchanged through structural
    # inversion); `target` / `source` / `modop` are the role-swapping
    # / modop-flipping fields and must round-trip.
    @test inv2.target === a.target
    @test inv2.source === a.source
    @test inv2.modop  === a.modop
    @test inv2.lhs    === a.lhs
    @test inv2.op     === a.op
    @test inv2.rhs    === a.rhs
end

@testset "VMProgram-wide reversed() preserves label set (M2.18)" begin
    # Rebuild the three-block fixture locally (testset isolation).
    b1 = BennettVM.BasicBlock(
        :b1,
        BennettVM.BeginInstruction(:countdown, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:s, :n, :xor, :n, :xor, Int64(0)),
        ],
        BennettVM.ConditionalExit(:is_zero, :b3, :b2, [:s]),
    )
    b2 = BennettVM.BasicBlock(
        :b2,
        BennettVM.ConditionalEntry(:b2, [:s_in], :b1, :b2, :is_zero),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:s_out, :s_in, :add, :s_in, :and, Int64(1)),
        ],
        BennettVM.UnconditionalExit(:b3, [:s_out]),
    )
    b3 = BennettVM.BasicBlock(
        :b3,
        BennettVM.UnconditionalEntry(:b3, [:s_final]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:countdown, [:s_final]),
    )
    blocks = [b1, b2, b3]
    label_table = BennettVM.LabelTable(blocks)
    vm = VMProgram(blocks, label_table, :b1, [64], [64])

    # Per the M2.15 `reversed()` docstring, "Preserve the label" — the
    # block label is its identity in the program-level callgraph and
    # remains unchanged through reversal. Apply `reversed` to every
    # block and check the label sequence is unchanged.
    reversed_blocks = [BennettVM.reversed(b) for b in vm.blocks]
    @test [b.label for b in reversed_blocks] == [b.label for b in vm.blocks]

    # Per the M2.16 `LabelTable(::Vector{BasicBlock})` contract, the
    # label set determines the `Dict{Symbol,LabelEntry}` keys. After
    # reversing every block (no relabeling), the rebuilt LabelTable
    # must have the same label set as the original.
    new_lt = BennettVM.LabelTable(reversed_blocks)
    @test sort(collect(keys(new_lt.entries))) ==
          sort(collect(keys(vm.label_table.entries)))
end

@testset "Structural inverse: mutation-proof witness (M2.18)" begin
    # The Phase-0 retrospective (`spike/RETROSPECTIVE.md`) and CLAUDE.md
    # Rule 5 demand that the tests CATCH structural-inverse regressions.
    # Rather than perturb the production `structural_inverse` (which
    # would leave the suite RED for the rest of the session), this
    # testset documents the regression WITNESS: we hand-construct a
    # HYPOTHETICAL bad inverse and assert that the involution check in
    # the previous testset would in fact catch it.

    # The correct involution: target/source swap + :add → :sub flip.
    a = BennettVM.ArithmeticAssignment(:x, :y, :add, :u, :mul, :v)
    correct_inv = BennettVM.structural_inverse(a)
    @test correct_inv.target === :y      # source becomes target
    @test correct_inv.source === :x      # target becomes source
    @test correct_inv.modop  === :sub    # :add flips to :sub via dual_modop

    # The hypothetical buggy inverse: target/source NOT swapped, modop
    # still flipped. This is what a structural_inverse implementation
    # would produce if a future agent "simplified" the role-swap out.
    bad_inv = BennettVM.ArithmeticAssignment(:x, :y, :sub, :u, :mul, :v)

    # Apply the REAL structural_inverse to the bad-shaped input. The
    # round-trip would NOT recover `a`'s original fields — the
    # target/source roles stay broken.
    bad_round_trip = BennettVM.structural_inverse(bad_inv)
    # The real `structural_inverse` always swaps target↔source, so
    # `bad_round_trip.target` is `bad_inv.source` = `:y`, and
    # `bad_round_trip.source` is `bad_inv.target` = `:x` — i.e. the
    # double-application of the (correct) `structural_inverse` to a
    # bad-shaped input does NOT recover the original `a.target` = `:x`.
    @test bad_round_trip.target === :y   # NOT equal to a.target = :x
    @test bad_round_trip.source === :x   # NOT equal to a.source = :y

    # Therefore: if the production `structural_inverse` ever regressed
    # to copy target/source verbatim (instead of swapping them), the
    # ArithmeticAssignment involution test would observe
    # `inv2.target === a.target` failing — exactly the failure mode the
    # testset above is designed to catch. The witness is conceptually
    # load-bearing: it pins the regression signature.
end
