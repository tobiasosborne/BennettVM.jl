# test/test_select.jl — M_UNBOUNDED unit tests for the
# `SelectInstruction` instruction (bd `bennettvm-8wj`, ADR 0012 §D3).
#
# # What this file pins
#
# `src/ir/select_instruction.jl` defines `SelectInstruction`, the
# reversible 2-to-1 multiplexer
# `target := (cond != 0) ? val_true : val_false` — the lowering target
# for LLVM `IRSelect` (e.g. `value_phi4 = .not ? __v6 : __v5` and
# `or.cond = __v8 ? Const(-1) : __v9` in collatz), whose predicate and
# arms are READ but never destroyed. It is the structural sibling of
# `Define` (the SSA-create, §D1); LLVM `select` has no RC3 analogue
# (documented Law-2 exception). The tests below pin (Rule 4 — every
# @test asserts a known-correct value):
#
#   1. **Forward — arm selection.** With `cond != 0` the true arm is
#      chosen, with `cond == 0` the false arm, with `cond` any nonzero
#      value (7) the true arm — pinning the "nonzero = true" i1→Int64
#      convention.
#   2. **Literal operand.** `SelectInstruction(:t, :c, Int64(-1), :b)`
#      with `c=1` → `t == -1` — the `or.cond` shape with a literal
#      `Const(-1)` true-arm.
#   3. **Operands + cond survive.** After `forward`, `cond` and both
#      symbolic arms are still in `locals` with unchanged values — the
#      non-destructive property (contrast `ArithmeticAssignment`, which
#      deletes `source`).
#   4. **Overwrite at the forward level.** Two `forward`s with the same
#      target and a flipped cond update `locals[target]` with no error —
#      the cross-iteration loop case (ADR 0012 §"crux").
#   5. **Constructor rejects `target ∈ {cond, val_true, val_false}`**
#      (Rule 1 — SSA single-assignment).
#   6. **`is_injective(SelectInstruction) == false`** — load-bearing per
#      ADR 0012: a 2-to-1 MUX discards the unselected arm and the static
#      trait can't see runtime freshness, so it is conservatively
#      non-injective → L3 checkpoints.
#   7. **`inverse` raises the deferral error** — the select's reverse is
#      the L3 checkpoint-replay path, never a per-instruction inverse.
#   8. **End-to-end `run!`** — a single-block VMProgram with a `Define`
#      (to make a cond) + a `SelectInstruction` runs forward to halt; the
#      result reflects the selected value. Proves `SelectInstruction`
#      integrates with the M3.x interpreter dispatch.
#
# # Why a fresh `IState` per testset
#
# `IState` is mutable and `forward` mutates in place. Each testset builds
# its own `IState`, matching `test_define.jl` /
# `test_arithmetic_assignment.jl`.
#
# Ref: src/ir/select_instruction.jl (the implementation; full rationale
#      in its top-of-module docstring).
# Ref: docs/adr/0012-collatz-lowering.md §D3 + §"cross-iteration crux".
# Ref: test/test_define.jl — the sibling unit-test template.
# Ref: test/reference/countdown.jl — the BasicBlock/VMProgram/
#      initial_state/run!/result idiom the end-to-end test reuses.
# Ref: CLAUDE.md Rule 1 (constructor validates), Rule 4 (every @test
#      pins a value).

@testset "SelectInstruction forward — arm selection (M_UNBOUNDED)" begin
    # cond != 0 → true arm; cond == 0 → false arm; any nonzero → true arm.
    instr = BennettVM.SelectInstruction(:t, :c, :a, :b)

    s_true = BennettVM.IState(0,
        Dict(:c => Int64(1), :a => Int64(10), :b => Int64(20)), :running)
    s2t = BennettVM.forward(instr, s_true)
    @test s2t.locals[:t] == Int64(10)       # cond=1 → val_true
    @test s2t.pc == 1
    @test s2t.status === :running

    s_false = BennettVM.IState(0,
        Dict(:c => Int64(0), :a => Int64(10), :b => Int64(20)), :running)
    @test BennettVM.forward(instr, s_false).locals[:t] == Int64(20)  # cond=0 → val_false

    s_nz = BennettVM.IState(0,
        Dict(:c => Int64(7), :a => Int64(10), :b => Int64(20)), :running)
    @test BennettVM.forward(instr, s_nz).locals[:t] == Int64(10)     # cond=7 (nonzero=true) → val_true
end

@testset "SelectInstruction forward — literal operand (M_UNBOUNDED)" begin
    # The `or.cond` shape: a literal `Const(-1)` true-arm. With cond=1 the
    # literal is selected verbatim through `_resolve`.
    instr = BennettVM.SelectInstruction(:t, :c, Int64(-1), :b)
    s = BennettVM.IState(0, Dict(:c => Int64(1), :b => Int64(99)), :running)
    @test BennettVM.forward(instr, s).locals[:t] == Int64(-1)
end

@testset "SelectInstruction operands + cond survive forward (M_UNBOUNDED)" begin
    # The non-destructive property: the predicate and both symbolic arms
    # remain in `locals` with unchanged values after `forward`. This is
    # the load-bearing contrast with ArithmeticAssignment (which deletes
    # its `source`).
    instr = BennettVM.SelectInstruction(:t, :c, :a, :b)
    s = BennettVM.IState(0,
        Dict(:c => Int64(1), :a => Int64(10), :b => Int64(20)), :running)
    s2 = BennettVM.forward(instr, s)
    @test s2.locals[:t] == Int64(10)        # 1 → val_true
    @test haskey(s2.locals, :c)             # predicate NOT deleted
    @test haskey(s2.locals, :a)             # val_true operand NOT deleted
    @test haskey(s2.locals, :b)             # val_false operand NOT deleted
    @test s2.locals[:c] == Int64(1)         # ...and unchanged
    @test s2.locals[:a] == Int64(10)
    @test s2.locals[:b] == Int64(20)
end

@testset "SelectInstruction overwrite at forward level (M_UNBOUNDED)" begin
    # The cross-iteration loop case (ADR 0012 §"crux"): the same SSA name
    # is re-defined with the cond flipped. The forward semantics OVERWRITE
    # `locals[target]` with no error — reversibility of the overwrite is
    # the L3 checkpoint-replay layer's job, not the forward step's.
    instr = BennettVM.SelectInstruction(:t, :c, :a, :b)
    s = BennettVM.IState(0,
        Dict(:c => Int64(1), :a => Int64(10), :b => Int64(20)), :running)
    BennettVM.forward(instr, s)
    @test s.locals[:t] == Int64(10)         # cond=1 → val_true
    # Re-enter the "loop body": flip the predicate and select again.
    s.locals[:c] = Int64(0)
    BennettVM.forward(instr, s)
    @test s.locals[:t] == Int64(20)         # overwritten with val_false, no error
    @test s.pc == 2                         # two forward steps
end

@testset "SelectInstruction constructor validation (M_UNBOUNDED)" begin
    # target === cond — SSA single-assignment violation.
    @test_throws ErrorException BennettVM.SelectInstruction(:t, :t, :a, :b)
    # target === val_true — SSA single-assignment violation.
    @test_throws ErrorException BennettVM.SelectInstruction(:t, :c, :t, :b)
    # target === val_false — SSA single-assignment violation.
    @test_throws ErrorException BennettVM.SelectInstruction(:t, :c, :a, :t)
    # A literal Int64 arm can never collide with the Symbol target — this
    # constructs successfully (the `or.cond` literal-true-arm shape).
    @test BennettVM.SelectInstruction(:t, :c, Int64(-1), :b) isa
        BennettVM.SelectInstruction
    # Both arms symbolic, distinct from target — constructs successfully.
    @test BennettVM.SelectInstruction(:t, :c, :a, :b) isa
        BennettVM.SelectInstruction
end

@testset "SelectInstruction is_injective == false (M_UNBOUNDED)" begin
    # Load-bearing per ADR 0012 §"cross-iteration crux": a 2-to-1 MUX
    # discards the unselected arm and the static trait can't see runtime
    # freshness, so SelectInstruction is conservatively non-injective →
    # the M6.2/M7.6 push gate emits L3 checkpoints. Pin BOTH the
    # type-level and value-level answers.
    @test BennettVM.is_injective(BennettVM.SelectInstruction) == false
    instr = BennettVM.SelectInstruction(:t, :c, :a, :b)
    @test BennettVM.is_injective(instr) == false
end

@testset "SelectInstruction inverse raises (deferred L1/L2) (M_UNBOUNDED)" begin
    # The select's reverse is via the L3 checkpoint-replay path, which
    # never calls per-instruction inverse(). Reaching this method is a
    # bug; Rule 1 demands a loud raise, not a silent no-op.
    instr = BennettVM.SelectInstruction(:t, :c, :a, :b)
    s = BennettVM.IState(1,
        Dict(:c => Int64(1), :a => Int64(10), :b => Int64(20),
             :t => Int64(10)), :running)
    @test_throws ErrorException BennettVM.inverse(instr, s, nothing)
end

@testset "SelectInstruction end-to-end run! (M_UNBOUNDED)" begin
    # A tiny well-formed single-block routine proving SelectInstruction
    # integrates with the interpreter dispatch. A `Define` first builds
    # the predicate `:c = slt(:x, 2)` (the collatz top-block icmp shape),
    # then a `SelectInstruction` picks between two surviving operands on
    # it. Layout mirrors the countdown idiom (test/reference/countdown.jl):
    #
    #   :b_start — BeginInstruction(:f, [:x, :a, :b])
    #              → body: Define(:c, :x, :slt, 2); SelectInstruction(:t, :c, :a, :b)
    #              → EndInstruction(:f, [:t, :c])
    #
    # With x=1 (< 2 → c=1 → true arm) the result must hold :t == a == 100.
    start_block = BennettVM.BasicBlock(
        :b_start,
        BennettVM.BeginInstruction(:f, [:x, :a, :b]),
        BennettVM.Instruction[
            BennettVM.Define(:c, :x, :slt, Int64(2)),
            BennettVM.SelectInstruction(:t, :c, :a, :b),
        ],
        BennettVM.EndInstruction(:f, [:t, :c]),
    )
    blocks = BennettVM.BasicBlock[start_block]
    vm = VMProgram(blocks, BennettVM.LabelTable(blocks), :b_start,
                   [64], [64])

    rs = initial_state(vm,
        Dict(:x => Int64(1), :a => Int64(100), :b => Int64(200)))
    run!(rs, vm)
    @test is_halted(rs)
    r = result(rs)
    @test r[:c] == Int64(1)                 # slt(1, 2) → true
    @test r[:t] == Int64(100)               # cond=1 → val_true (:a) selected
end
