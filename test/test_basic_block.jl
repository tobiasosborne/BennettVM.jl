# test/test_basic_block.jl — M2.15 unit tests for `BasicBlock` and
# `reversed(::BasicBlock)` (bd `bennettvm-jvh`).
#
# # What this file pins
#
# `src/ir/basic_block.jl` defines the unit of RSSA program structure
# (PRD v4 §3.1) — a single straight-line code segment bracketed by
# exactly one control-flow entry marker and exactly one control-flow
# exit marker — and the block-level structural inverse
# `reversed(::BasicBlock)` consumed by the M9 pebble-game compute /
# uncompute pass (PRD v4 §3.4). The tests below pin:
#
#   1. **Struct shape + field access** — `label`, `entry`,
#      `instructions`, `exit` all carry the constructor's arguments
#      verbatim.
#   2. **Constructor validation (Rule 1)** — three categories of
#      malformed input raise `ErrorException`: a `ControlInstruction`
#      in the body vector, an exit-direction marker in the `entry`
#      slot, an entry-direction marker in the `exit` slot. Validation
#      uses `isa` against the concrete subtypes (not a string-name
#      match).
#   3. **`structural_inverse(::Instruction)` for the six non-control
#      subtypes** — the IR-graph-level instruction inverse (distinct
#      from the dispatch-level `inverse(instr, s, prev)`). Each of
#      `ArithmeticAssignment`, `SwapInstruction`, `MemoryAssignment`,
#      `MemoryInterchange`, `MemorySwap`, `CallInstruction` has a
#      module-level method that returns a new `Instruction` with the
#      role-swapped / modop-flipped fields per ADR 0001 §Observations
#      rows 1-6 and the M2.15 task spec.
#   4. **`reversed(::BasicBlock)` round-trip** — the body is reversed
#      in order AND each element is replaced by its structural
#      inverse; entry/exit are swapped AND each is structurally
#      inverted (with the block label injected where needed for
#      Uncond/Cond exits); label is preserved. The reverse-of-reverse
#      property recovers an equivalent block.
#   5. **`structural_inverse` coverage** across all twelve concrete
#      `Instruction` subtypes — no `MethodError` for any of them when
#      reached via `reversed(::BasicBlock)`. The six non-control
#      subtypes have module-level methods; the six control-flow
#      subtypes are handled by the entry/exit helpers
#      `_reverse_entry_to_exit` / `_reverse_exit_to_entry`.
#
# # Why these tests over the alternative shape
#
# Rule 4 ("'Runs without errors' is not a passing test"): every test
# below asserts against a known-correct field value, not merely that
# the call succeeded. Constructor validation tests use `@test_throws
# ErrorException` per the M2.7-M2.14 testset template.

@testset "BasicBlock structure (M2.15)" begin
    entry = BennettVM.UnconditionalEntry(:B1, [:x])
    exit_ = BennettVM.UnconditionalExit(:B2, [:y])
    body = BennettVM.Instruction[
        BennettVM.ArithmeticAssignment(:y, :x, :xor, :a, :and, :b),
    ]
    bb = BennettVM.BasicBlock(:B1, entry, body, exit_)
    @test bb.label === :B1
    @test bb.entry === entry
    @test bb.exit === exit_
    @test length(bb.instructions) == 1
end

@testset "BasicBlock constructor validation (M2.15)" begin
    entry = BennettVM.UnconditionalEntry(:B, [:x])
    exit_ = BennettVM.UnconditionalExit(:C, [:y])
    arith = BennettVM.ArithmeticAssignment(:y, :x, :xor, :a, :and, :b)
    uncond = BennettVM.UnconditionalExit(:D, [:z])

    # Body must not contain ControlInstruction.
    @test_throws ErrorException BennettVM.BasicBlock(:B, entry,
        BennettVM.Instruction[arith, uncond], exit_)
    # entry must be an entry-type ControlInstruction.
    @test_throws ErrorException BennettVM.BasicBlock(:B,
        BennettVM.UnconditionalExit(:X, Symbol[]),
        BennettVM.Instruction[arith], exit_)
    # exit must be an exit-type ControlInstruction.
    @test_throws ErrorException BennettVM.BasicBlock(:B, entry,
        BennettVM.Instruction[arith],
        BennettVM.UnconditionalEntry(:X, Symbol[]))
end

@testset "structural_inverse — non-control instructions (M2.15)" begin
    # ArithmeticAssignment :add → :sub with target/source swapped.
    a = BennettVM.ArithmeticAssignment(:x, :y, :add, :u, :mul, :v)
    inv = BennettVM.structural_inverse(a)
    @test inv isa BennettVM.ArithmeticAssignment
    @test inv.target === :y
    @test inv.source === :x
    @test inv.modop === :sub
    @test inv.lhs === :u
    @test inv.op === :mul
    @test inv.rhs === :v

    # Idempotency: applying inverse twice returns equivalent struct.
    inv2 = BennettVM.structural_inverse(inv)
    @test inv2.target === a.target
    @test inv2.modop === a.modop

    # SwapInstruction: positional target/source pair swap.
    sw = BennettVM.SwapInstruction(:a, :b, :c, :d)
    inv_sw = BennettVM.structural_inverse(sw)
    @test inv_sw.target1 === :c
    @test inv_sw.target2 === :d
    @test inv_sw.source1 === :a
    @test inv_sw.source2 === :b

    # MemorySwap is self-inverse (fresh instance, same field values).
    ms = BennettVM.MemorySwap(:p, :q)
    @test BennettVM.structural_inverse(ms).addr1 === :p
    @test BennettVM.structural_inverse(ms).addr2 === :q

    # CallInstruction: targets/args swap AND :call <-> :uncall.
    ci = BennettVM.CallInstruction([:r], :foo, [:s], :call)
    inv_ci = BennettVM.structural_inverse(ci)
    @test inv_ci.targets == [:s]
    @test inv_ci.args == [:r]
    @test inv_ci.direction === :uncall
    @test inv_ci.callee === :foo

    # MemoryAssignment: modop flip; addr/lhs/op/rhs preserved.
    ma = BennettVM.MemoryAssignment(:addr, :add, :u, :mul, :v)
    inv_ma = BennettVM.structural_inverse(ma)
    @test inv_ma isa BennettVM.MemoryAssignment
    @test inv_ma.addr === :addr
    @test inv_ma.modop === :sub
    @test inv_ma.lhs === :u
    @test inv_ma.op === :mul
    @test inv_ma.rhs === :v

    # MemoryInterchange: target ↔ source swap; addr preserved.
    mi = BennettVM.MemoryInterchange(:t, :addr, :s)
    inv_mi = BennettVM.structural_inverse(mi)
    @test inv_mi isa BennettVM.MemoryInterchange
    @test inv_mi.target === :s
    @test inv_mi.addr === :addr
    @test inv_mi.source === :t

    # :uncall ↔ :call (the other direction of CallInstruction).
    ci_u = BennettVM.CallInstruction([:r], :foo, [:s], :uncall)
    @test BennettVM.structural_inverse(ci_u).direction === :call
end

@testset "BasicBlock.reversed() round-trip (M2.15)" begin
    entry = BennettVM.UnconditionalEntry(:B, [:x])
    exit_ = BennettVM.UnconditionalExit(:C, [:y])
    body = BennettVM.Instruction[
        BennettVM.ArithmeticAssignment(:y, :x, :xor, :a, :and, :b),
    ]
    bb = BennettVM.BasicBlock(:B, entry, body, exit_)

    rev = BennettVM.reversed(bb)
    @test rev.label === :B
    # entry was UnconditionalEntry → now UnconditionalExit (out of THIS
    # block, going back to where forward came from — but we encode it
    # with this block's label since we don't know the predecessor here).
    @test rev.exit isa BennettVM.UnconditionalExit
    @test rev.exit.target === :B
    # exit was UnconditionalExit(:C) → now UnconditionalEntry(:C) —
    # entering this block from C on the forward direction of the
    # reversed traversal.
    @test rev.entry isa BennettVM.UnconditionalEntry
    @test rev.entry.label === :C

    # Body reversal: 1 instruction, inverted.
    @test length(rev.instructions) == 1
    rev_body_first = rev.instructions[1]
    @test rev_body_first isa BennettVM.ArithmeticAssignment
    @test rev_body_first.target === :x   # source becomes target
    @test rev_body_first.source === :y

    # Reverse-of-reverse property: structural double-inverse should give
    # back an equivalent block.
    bb2 = BennettVM.reversed(rev)
    @test bb2.label === bb.label
    @test length(bb2.instructions) == length(bb.instructions)
    @test bb2.instructions[1].target === bb.instructions[1].target
end

@testset "ConditionalEntry/Exit structural_inverse (M2.15)" begin
    # Test the body-only case (without block label dependency):
    # ConditionalExit can be structurally inverted IF the block label
    # is known. Here we test the BasicBlock.reversed() path which
    # handles the label injection.
    entry = BennettVM.ConditionalEntry(:B, [:x], :L1, :L2, :c)
    exit_ = BennettVM.ConditionalExit(:c, :T1, :T2, [:y])
    body = BennettVM.Instruction[]
    bb = BennettVM.BasicBlock(:B, entry, body, exit_)
    rev = BennettVM.reversed(bb)
    @test rev.entry isa BennettVM.ConditionalEntry
    # The forward exit's target_true/target_false become the reversed
    # entry's predecessor_true/predecessor_false:
    @test rev.entry.predecessor_true === :T1
    @test rev.entry.predecessor_false === :T2
    @test rev.entry.condition === :c
    @test rev.exit isa BennettVM.ConditionalExit
    # The forward entry's predecessor_true/predecessor_false become the
    # reversed exit's target_true/target_false:
    @test rev.exit.target_true === :L1
    @test rev.exit.target_false === :L2
end

@testset "Begin/End structural_inverse via reversed() (M2.15)" begin
    # Begin/End coverage — both control-flow subtypes route through
    # `_reverse_entry_to_exit` / `_reverse_exit_to_entry`. Confirms no
    # MethodError for either subtype when reached via reversed().
    entry = BennettVM.BeginInstruction(:sub, [:p])
    exit_ = BennettVM.EndInstruction(:sub, [:r])
    bb = BennettVM.BasicBlock(:sub, entry, BennettVM.Instruction[], exit_)
    rev = BennettVM.reversed(bb)
    # Begin(:sub, [:p]) reversed → End(:sub, [:p]) in reversed exit slot.
    @test rev.exit isa BennettVM.EndInstruction
    @test rev.exit.label === :sub
    @test rev.exit.returns == [:p]
    # End(:sub, [:r]) reversed → Begin(:sub, [:r]) in reversed entry slot.
    @test rev.entry isa BennettVM.BeginInstruction
    @test rev.entry.label === :sub
    @test rev.entry.params == [:r]
end

@testset "reversed() body order + multi-instruction (M2.15)" begin
    # Body of 3 instructions: confirm order reversal AND per-element
    # structural inversion. Forward: [arith1, swap, arith2]. Reversed
    # body should be [inv(arith2), inv(swap), inv(arith1)].
    entry = BennettVM.UnconditionalEntry(:B, Symbol[])
    exit_ = BennettVM.UnconditionalExit(:C, Symbol[])
    arith1 = BennettVM.ArithmeticAssignment(:y, :x, :add, :a, :mul, :b)
    sw     = BennettVM.SwapInstruction(:p, :q, :r, :s)
    arith2 = BennettVM.ArithmeticAssignment(:w, :y, :xor, :p, :or, :q)
    body = BennettVM.Instruction[arith1, sw, arith2]
    bb = BennettVM.BasicBlock(:B, entry, body, exit_)
    rev = BennettVM.reversed(bb)
    @test length(rev.instructions) == 3
    # rev.instructions[1] = structural_inverse(arith2)
    @test rev.instructions[1] isa BennettVM.ArithmeticAssignment
    @test rev.instructions[1].target === :y
    @test rev.instructions[1].source === :w
    @test rev.instructions[1].modop === :xor  # self-inverse
    # rev.instructions[2] = structural_inverse(sw)
    @test rev.instructions[2] isa BennettVM.SwapInstruction
    @test rev.instructions[2].target1 === :r
    @test rev.instructions[2].source1 === :p
    # rev.instructions[3] = structural_inverse(arith1)
    @test rev.instructions[3] isa BennettVM.ArithmeticAssignment
    @test rev.instructions[3].target === :x
    @test rev.instructions[3].source === :y
    @test rev.instructions[3].modop === :sub  # was :add
end
