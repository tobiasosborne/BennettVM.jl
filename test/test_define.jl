# test/test_define.jl — M_UNBOUNDED unit tests for the `Define`
# instruction (bd `bennettvm-d3p`, ADR 0012 §D1).
#
# # What this file pins
#
# `src/ir/define_instruction.jl` defines `Define`, the reversible
# SSA-create `target := lhs op rhs` — the lowering target for LLVM
# `IRBinOp` / `IRICmp` (e.g. `__v4 = mul(value_phi6, 3)`), whose operands
# are READ but never destroyed. Unlike `ArithmeticAssignment` (a
# destructive transform that `delete!`s its `source`), `Define` is the
# non-destructive create. The tests below pin (Rule 4 — every @test
# asserts a known-correct value):
#
#   1. **Forward — arithmetic op.** `Define(:t, :a, :mul, 3)` with `a=4`
#      → `t == 12`. Proves the arithmetic family flows through
#      `_apply_binop`.
#   2. **Forward — comparison op.** `Define(:t, :a, :slt, 2)` with `a=1`
#      → `t == 1` (true); with `a=5` → `t == 0` (false). Proves `Define`
#      carries the comparison family (ADR 0012 §D2) and uses the
#      "nonzero = true" i1→Int64 convention.
#   3. **Operands survive.** After `forward`, the `lhs`/`rhs` symbols are
#      still in `locals` with unchanged values — the non-destructive
#      property (contrast `ArithmeticAssignment`, which deletes `source`).
#   4. **Overwrite at the forward level.** Two `forward`s with the same
#      target and different operand values update `locals[target]` with
#      no error — the cross-iteration loop case (ADR 0012 §"crux").
#   5. **Constructor rejects `target ∈ {lhs, rhs}`** (Rule 1 — SSA
#      single-assignment) and rejects an out-of-domain `op`.
#   6. **`is_injective(Define) == false`** — load-bearing per ADR 0012:
#      the static trait can't see runtime freshness, so it is
#      conservatively non-injective → L3 checkpoints.
#   7. **`inverse` raises the deferral error** — `Define`'s reverse is
#      the L3 checkpoint-replay path, never a per-instruction inverse.
#   8. **End-to-end `run!`** — a two-block VMProgram with a `Define` in
#      the body runs forward to halt; the result reflects the defined
#      value. Proves `Define` integrates with the M3.x interpreter
#      dispatch and the cross-block `LabelTable` machinery.
#
# # Why a fresh `IState` per testset
#
# `IState` is mutable and `forward` mutates in place. Each testset builds
# its own `IState`; `deepcopy` snapshots the pre-state where a before/
# after comparison is needed, matching `test_swap_instruction.jl` /
# `test_arithmetic_assignment.jl`.
#
# Ref: src/ir/define_instruction.jl (the implementation; full rationale
#      in its top-of-module docstring).
# Ref: docs/adr/0012-collatz-lowering.md §D1 + §"cross-iteration crux".
# Ref: test/reference/countdown.jl — the BasicBlock/VMProgram/
#      initial_state/run!/result idiom the end-to-end test reuses.
# Ref: CLAUDE.md Rule 1 (constructor validates), Rule 4 (every @test
#      pins a value).

@testset "Define forward — arithmetic op (M_UNBOUNDED)" begin
    instr = BennettVM.Define(:t, :a, :mul, Int64(3))
    s = BennettVM.IState(0, Dict(:a => Int64(4)), :running)
    s2 = BennettVM.forward(instr, s)
    @test BennettVM.active_locals(s2)[:t] == Int64(12)
    @test s2.pc == 1
    @test s2.status === :running
end

@testset "Define forward — comparison op (M_UNBOUNDED)" begin
    # slt(1, 2) == true → Int64(1); slt(5, 2) == false → Int64(0).
    # Proves Define carries the comparison family (ADR 0012 §D2) and the
    # "nonzero = true" i1→Int64 convention.
    instr = BennettVM.Define(:t, :a, :slt, Int64(2))

    s_true = BennettVM.IState(0, Dict(:a => Int64(1)), :running)
    @test BennettVM.active_locals(BennettVM.forward(instr, s_true))[:t] == Int64(1)

    s_false = BennettVM.IState(0, Dict(:a => Int64(5)), :running)
    @test BennettVM.active_locals(BennettVM.forward(instr, s_false))[:t] == Int64(0)
end

@testset "Define operands survive forward (M_UNBOUNDED)" begin
    # The non-destructive create property: both symbolic operands remain
    # in `locals` with unchanged values after `forward`. This is the
    # load-bearing contrast with ArithmeticAssignment (which deletes its
    # `source`). Use a symbolic lhs AND a symbolic rhs to pin both.
    instr = BennettVM.Define(:t, :a, :add, :b)
    s = BennettVM.IState(0, Dict(:a => Int64(7), :b => Int64(5)), :running)
    s2 = BennettVM.forward(instr, s)
    @test BennettVM.active_locals(s2)[:t] == Int64(12)       # 7 + 5
    @test haskey(BennettVM.active_locals(s2), :a)            # operand a NOT deleted
    @test haskey(BennettVM.active_locals(s2), :b)            # operand b NOT deleted
    @test BennettVM.active_locals(s2)[:a] == Int64(7)        # ...and unchanged
    @test BennettVM.active_locals(s2)[:b] == Int64(5)
end

@testset "Define overwrite at forward level (M_UNBOUNDED)" begin
    # The cross-iteration loop case (ADR 0012 §"crux"): the same SSA name
    # is re-defined with a fresh operand value. The forward semantics
    # OVERWRITE `locals[target]` with no error — reversibility of the
    # overwrite is the L3 checkpoint-replay layer's job, not the forward
    # step's.
    instr = BennettVM.Define(:t, :a, :mul, Int64(3))
    s = BennettVM.IState(0, Dict(:a => Int64(4)), :running)
    BennettVM.forward(instr, s)
    @test BennettVM.active_locals(s)[:t] == Int64(12)
    # Re-enter the "loop body": change the operand and define again.
    BennettVM.active_locals(s)[:a] = Int64(10)
    BennettVM.forward(instr, s)
    @test BennettVM.active_locals(s)[:t] == Int64(30)        # overwritten, no error
    @test s.pc == 2                        # two forward steps
end

@testset "Define constructor validation (M_UNBOUNDED)" begin
    # target === lhs — SSA single-assignment violation.
    @test_throws ErrorException BennettVM.Define(:t, :t, :add, Int64(1))
    # target === rhs — SSA single-assignment violation.
    @test_throws ErrorException BennettVM.Define(:t, :a, :add, :t)
    # out-of-domain op (not in BINARY_OPERATORS ∪ COMPARISON_OPERATORS).
    @test_throws ErrorException BennettVM.Define(:t, :a, :not_an_op, Int64(1))
    # A literal Int64 operand can never collide with the Symbol target,
    # and a comparison op is in-domain — these construct successfully.
    @test BennettVM.Define(:t, :a, :slt, Int64(2)) isa BennettVM.Define
    @test BennettVM.Define(:t, Int64(0), :add, Int64(0)) isa BennettVM.Define
end

@testset "Define is_injective == false (M_UNBOUNDED)" begin
    # Load-bearing per ADR 0012 §"cross-iteration crux": the static trait
    # can't see runtime freshness, so Define is conservatively
    # non-injective → the M6.2/M7.6 push gate emits L3 checkpoints. Pin
    # BOTH the type-level and value-level answers.
    @test BennettVM.is_injective(BennettVM.Define) == false
    instr = BennettVM.Define(:t, :a, :mul, Int64(3))
    @test BennettVM.is_injective(instr) == false
end

@testset "Define inverse raises (deferred L1/L2) (M_UNBOUNDED)" begin
    # Define's reverse is via the L3 checkpoint-replay path, which never
    # calls per-instruction inverse(). Reaching this method is a bug;
    # Rule 1 demands a loud raise, not a silent no-op.
    instr = BennettVM.Define(:t, :a, :mul, Int64(3))
    s = BennettVM.IState(1, Dict(:a => Int64(4), :t => Int64(12)), :running)
    @test_throws ErrorException BennettVM.inverse(instr, s, nothing)
end

@testset "Define end-to-end run! (M_UNBOUNDED)" begin
    # A tiny well-formed two-block routine proving Define integrates with
    # the interpreter dispatch + cross-block LabelTable. Layout mirrors
    # the countdown idiom (test/reference/countdown.jl):
    #
    #   :b_start — BeginInstruction(:f, [:a]) → body: Define(:t, :a, :mul, 3)
    #              → UnconditionalExit(:b_done, [:a, :t])
    #   :b_done  — UnconditionalEntry(:b_done, [:a, :t]) → empty body
    #              → EndInstruction(:f, [:t])
    #
    # The Define's operand `:a` survives the create (carried as an exit
    # arg alongside the freshly defined `:t`), so the done block's params
    # reconcile. With a=4, the result must hold :t == 12.
    start_block = BennettVM.BasicBlock(
        :b_start,
        BennettVM.BeginInstruction(:f, [:a]),
        BennettVM.Instruction[
            BennettVM.Define(:t, :a, :mul, Int64(3)),
        ],
        BennettVM.UnconditionalExit(:b_done, [:a, :t]),
    )
    done_block = BennettVM.BasicBlock(
        :b_done,
        BennettVM.UnconditionalEntry(:b_done, [:a, :t]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:f, [:t]),
    )
    blocks = BennettVM.BasicBlock[start_block, done_block]
    vm = VMProgram(blocks, BennettVM.LabelTable(blocks), :b_start,
                   [64], [64])

    rs = initial_state(vm, Dict(:a => Int64(4)))
    run!(rs, vm)
    @test is_halted(rs)
    r = result(rs)
    @test r[:t] == Int64(12)               # 4 * 3 — the Define result
    @test r[:a] == Int64(4)                # operand survived end-to-end
end
