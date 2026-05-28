# test/test_operators.jl — M2.5 unit tests for the BinaryOperator
# symbol set (bd `bennettvm-msl`).
#
# # What this file pins
#
# `src/ir/operators.jl` defines four module-level names —
# `BINARY_OPERATORS`, `FP_BINARY_OPERATORS`, `ALL_BINARY_OPERATORS`,
# `is_binary_operator` — that downstream `ArithmeticAssignment` (M2.7)
# and the M_FP lowering pass rely on. The tests below pin:
#
#   1. **Membership.** Every integer opcode mirrored from Bennett.jl's
#      `_IR_BINOP_OPS` is present in `BINARY_OPERATORS`. Every FP op
#      (`:fadd` / `:fsub` / `:fmul` / `:fdiv`) is present in
#      `FP_BINARY_OPERATORS` and is **absent** from `BINARY_OPERATORS`
#      — the IRCall-vs-IRBinOp distinction made explicit by test.
#   2. **Union shape.** `length(ALL_BINARY_OPERATORS) ==
#      length(BINARY_OPERATORS) + length(FP_BINARY_OPERATORS)` — no
#      accidental concatenation duplicates.
#   3. **Typo guard (Rule 1).** `is_binary_operator(:addd)` is false;
#      `is_binary_operator(:floor)` is false; `is_binary_operator(:mod)`
#      is false (Julia `mod` is not an LLVM hardware op, and accepting
#      it here would silently mis-dispatch).
#   4. **Exact counts (regression anchor).** Hard-coded length
#      assertions (13 / 4 / 17). If Bennett.jl ever adds a 14th
#      `IRBinOp` opcode this test goes RED and forces a conscious
#      mirror update in `src/ir/operators.jl`. This is the upstream-
#      drift detector Law 2 ("reuse before reinvention") demands when
#      mirroring a published / external table.
#
# # Why a separate file (vs. appending to test_dispatch.jl)
#
# `test_dispatch.jl` (M2.4) pins the *abstract* dispatch skeleton
# (`Instruction` / `ControlInstruction` / `RValue` plus generic
# `forward` / `inverse` fallbacks). The operator table is a separate
# concern — it carries no abstract-type machinery, no fallback
# methods, no `IState` interaction — and lives in its own file for
# the same reason `instructions.jl` and `operators.jl` are separate
# in `src/ir/`: orthogonal concerns, separately reviewable.
#
# Ref: `src/ir/operators.jl` (top-of-module docstring; the IRCall-vs-
#      IRBinOp distinction and the `:xor` injectivity callout).
# Ref: `/home/tobias/Projects/Bennett.jl/src/ir_types.jl` lines 5-7
#      (`const _IR_BINOP_OPS`) — the upstream table our integer set
#      mirrors; the length-13 assertion below guards the mirror.
# Ref: `references/PRD-v4.md` §3.6 — FP inheritance via SoftFloat
#      dispatch; explains why `:fadd` etc. are in their own tuple.
# Ref: CLAUDE.md Rule 1 — "assertions, not silent returns"; the typo
#      guard tests verify the fail-fast constructor contract.

@testset "BinaryOperator set (M2.5)" begin
    # All expected integer ops present
    for op in (:add, :sub, :mul, :and, :or, :xor,
               :shl, :lshr, :ashr,
               :udiv, :sdiv, :urem, :srem)
        @test op in BennettVM.BINARY_OPERATORS
        @test BennettVM.is_binary_operator(op)
    end

    # All expected FP ops present
    for op in (:fadd, :fsub, :fmul, :fdiv)
        @test op in BennettVM.FP_BINARY_OPERATORS
        @test BennettVM.is_binary_operator(op)
        # FP ops MUST NOT be in the integer set (they arrive as IRCall)
        @test !(op in BennettVM.BINARY_OPERATORS)
    end

    # ALL_BINARY_OPERATORS is the union
    @test length(BennettVM.ALL_BINARY_OPERATORS) ==
          length(BennettVM.BINARY_OPERATORS) + length(BennettVM.FP_BINARY_OPERATORS)

    # Typo guard (Rule 1)
    @test !BennettVM.is_binary_operator(:addd)
    @test !BennettVM.is_binary_operator(:floor)
    @test !BennettVM.is_binary_operator(:mod)   # Julia mod isn't a HW op

    # Exact counts (regression anchor — if Bennett.jl IRBinOp gains
    # an opcode, this test goes RED and forces a conscious update)
    @test length(BennettVM.BINARY_OPERATORS) == 13
    @test length(BennettVM.FP_BINARY_OPERATORS) == 4
    @test length(BennettVM.ALL_BINARY_OPERATORS) == 17
end

# test/test_operators.jl — ComparisonOperator set + `_apply_binop`
# evaluation (ADR 0012 §D2, bd `bennettvm-3vj`).
#
# # What this testset pins
#
#   1. **Membership + mirror.** Every LLVM `icmp` predicate from
#      Bennett.jl's `_IR_ICMP_PREDS` is in `COMPARISON_OPERATORS`, and
#      `is_comparison_operator` agrees. A length-regression test pins
#      `length(COMPARISON_OPERATORS) == length(Bennett._IR_ICMP_PREDS)`
#      so an upstream predicate-set drift goes RED (Law 2), mirroring
#      the `BINARY_OPERATORS` regression above.
#   2. **Disjointness / membership decision.** Comparison predicates
#      are NOT in `BINARY_OPERATORS`, `FP_BINARY_OPERATORS`, nor
#      `ALL_BINARY_OPERATORS` (the union the `ArithmeticAssignment`
#      constructor validates against) — and `is_binary_operator`
#      rejects them. This is the membership decision (ADR 0012 §D2):
#      comparisons share `_apply_binop` evaluation but NOT the
#      arithmetic construction-time op-domain. The `ArithmeticAssignment`
#      constructor must still reject a comparison op (Rule 1).
#   3. **`_apply_binop` returns exact `Int64(0)`/`(1)`** for a
#      representative true AND false case of EACH predicate (Rule 4 —
#      pin the value, not "didn't throw").
#   4. **Signed-vs-unsigned discrimination.** `_apply_binop(:slt,-1,0)
#      == 1` (signed: -1 < 0) but `_apply_binop(:ult,-1,0) == 0`
#      (unsigned: -1 reinterprets to 0xFFFF…FFFF, the largest UInt64).
#      This is the load-bearing distinction (ADR 0012 §D2 / R1 width
#      note) and the case a naive shared `<` would get wrong.
#
# # Mutation-prove (Rule 5, port-and-verify)
#
# Confirmed manually during development that the tests catch a
# regression: temporarily editing `_apply_binop`'s `:slt` arm from
# `Int64(a < b)` to `Int64(a > b)` makes the `_apply_binop(:slt,
# Int64(-1), Int64(0)) == 1` assertion below go RED (it returns 0),
# and editing the `:ult` arm to drop the `reinterpret(UInt64, ·)` (so
# it compares signed) makes `_apply_binop(:ult, Int64(-1), Int64(0))
# == 0` go RED (it returns 1). Both mutations were reverted; the
# perturbations are NOT left in the source. This proves the
# signed/unsigned discriminating asserts are load-bearing.
#
# Ref: docs/adr/0012-collatz-lowering.md §D2 — comparison operators,
#      i1→Int64 "nonzero = true" convention.
# Ref: /home/tobias/Projects/Bennett.jl/src/ir_types.jl lines 8-10
#      (`const _IR_ICMP_PREDS`, pin `877341e`) — the mirrored table.
# Ref: src/ir/operators.jl (COMPARISON_OPERATORS docstring — membership
#      decision) and src/ir/arithmetic_assignment.jl (`_apply_binop`).
import Bennett

@testset "ComparisonOperator set + _apply_binop (ADR 0012 D2)" begin
    # 1. Membership + mirror against Bennett._IR_ICMP_PREDS.
    for pred in (:eq, :ne, :ult, :ule, :ugt, :uge, :slt, :sle, :sgt, :sge)
        @test pred in BennettVM.COMPARISON_OPERATORS
        @test BennettVM.is_comparison_operator(pred)
        @test pred in Bennett._IR_ICMP_PREDS   # confirms the mirror holds
    end
    # Length-regression anchor: pins the mirror to the upstream tuple.
    @test length(BennettVM.COMPARISON_OPERATORS) ==
          length(Bennett._IR_ICMP_PREDS)
    @test length(BennettVM.COMPARISON_OPERATORS) == 10   # exact count

    # 2. Disjointness / membership decision: comparisons are NOT
    #    arithmetic ops and the ArithmeticAssignment op-domain rejects
    #    them.
    for pred in BennettVM.COMPARISON_OPERATORS
        @test !(pred in BennettVM.BINARY_OPERATORS)
        @test !(pred in BennettVM.FP_BINARY_OPERATORS)
        @test !(pred in BennettVM.ALL_BINARY_OPERATORS)
        @test !BennettVM.is_binary_operator(pred)
    end
    # Conversely, arithmetic ops are not comparison predicates.
    @test !BennettVM.is_comparison_operator(:add)
    @test !BennettVM.is_comparison_operator(:fadd)
    @test !BennettVM.is_comparison_operator(:lt)   # not an icmp name

    # The ArithmeticAssignment constructor must STILL reject a
    # comparison op (Rule 1, fail fast) — the membership decision in
    # action: _apply_binop accepts :slt, but the AA constructor does
    # not.
    @test_throws ErrorException BennettVM.ArithmeticAssignment(
        :x, :y, :xor, :a, :slt, :b)

    # 3. `_apply_binop` returns exact Int64(0)/Int64(1) for a true AND
    #    a false case of EACH predicate.
    # Equality (signedness-agnostic):
    @test BennettVM._apply_binop(:eq, Int64(3), Int64(3)) == Int64(1)
    @test BennettVM._apply_binop(:eq, Int64(3), Int64(4)) == Int64(0)
    @test BennettVM._apply_binop(:ne, Int64(3), Int64(4)) == Int64(1)
    @test BennettVM._apply_binop(:ne, Int64(3), Int64(3)) == Int64(0)
    # Signed:
    @test BennettVM._apply_binop(:slt, Int64(-2), Int64(3)) == Int64(1)
    @test BennettVM._apply_binop(:slt, Int64(3), Int64(-2)) == Int64(0)
    @test BennettVM._apply_binop(:sle, Int64(3), Int64(3))  == Int64(1)
    @test BennettVM._apply_binop(:sle, Int64(4), Int64(3))  == Int64(0)
    @test BennettVM._apply_binop(:sgt, Int64(3), Int64(-2)) == Int64(1)
    @test BennettVM._apply_binop(:sgt, Int64(-2), Int64(3)) == Int64(0)
    @test BennettVM._apply_binop(:sge, Int64(3), Int64(3))  == Int64(1)
    @test BennettVM._apply_binop(:sge, Int64(2), Int64(3))  == Int64(0)
    # Unsigned (reinterpret to UInt64). Use small non-negative values
    # for the ordinary cases; the negative-operand discriminators are
    # in part 4.
    @test BennettVM._apply_binop(:ult, Int64(2), Int64(3)) == Int64(1)
    @test BennettVM._apply_binop(:ult, Int64(3), Int64(2)) == Int64(0)
    @test BennettVM._apply_binop(:ule, Int64(3), Int64(3)) == Int64(1)
    @test BennettVM._apply_binop(:ule, Int64(4), Int64(3)) == Int64(0)
    @test BennettVM._apply_binop(:ugt, Int64(3), Int64(2)) == Int64(1)
    @test BennettVM._apply_binop(:ugt, Int64(2), Int64(3)) == Int64(0)
    @test BennettVM._apply_binop(:uge, Int64(3), Int64(3)) == Int64(1)
    @test BennettVM._apply_binop(:uge, Int64(2), Int64(3)) == Int64(0)

    # 4. Signed-vs-unsigned DISCRIMINATING case (the load-bearing
    #    distinction). -1 < 0 signed (slt = 1), but reinterpret(UInt64,
    #    -1) == 0xFFFFFFFFFFFFFFFF > 0 unsigned (ult = 0).
    @test BennettVM._apply_binop(:slt, Int64(-1), Int64(0)) == Int64(1)
    @test BennettVM._apply_binop(:ult, Int64(-1), Int64(0)) == Int64(0)
    # The symmetric ugt/sgt discriminator: -1 sorts ABOVE 0 unsigned
    # (ugt = 1) but BELOW 0 signed (sgt = 0).
    @test BennettVM._apply_binop(:ugt, Int64(-1), Int64(0)) == Int64(1)
    @test BennettVM._apply_binop(:sgt, Int64(-1), Int64(0)) == Int64(0)
    # eq is unaffected by signedness — sanity that -1 == -1 either way.
    @test BennettVM._apply_binop(:eq, Int64(-1), Int64(-1)) == Int64(1)
end
