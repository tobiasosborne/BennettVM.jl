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
