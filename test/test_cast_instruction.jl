# test/test_cast_instruction.jl — M_OPCODE unit tests for the
# `CastInstruction` (bd `bennettvm-hek`, ADR 0013 §D-5 step 1, ADR 0012
# §D1 template).
#
# # What this file pins
#
# `src/ir/cast_instruction.jl` defines `CastInstruction`, the reversible
# width-cast SSA-create `target := cast(op, operand)` — the lowering
# target for LLVM `IRCast` (`sext` / `zext` / `trunc`), whose single
# operand is READ but never destroyed. Like `Define` it is a
# non-destructive create; unlike `Define` it is unary and width-aware
# (its `op` domain is the three-element `{:sext,:zext,:trunc}` set, not
# `BINARY_OPERATORS`). The tests below pin (Rule 4 — every @test asserts
# a known-correct value, hand-computed against LLVM cast semantics):
#
#   1. **Forward — :zext.** Zero-extend = unsigned value of the low
#      `from_width` bits. zext(200, i8→i9) == 200 (200 fits the low 8 bits,
#      stays nonnegative even though i8-200 has its high bit set);
#      zext(-1, i8→i9) == 255 (low 8 bits of -1 are all ones). Edge case:
#      a value with the high bit set in `from_width` extends to a
#      NONNEGATIVE result (no sign propagation).
#   2. **Forward — :sext.** Sign-extend = signed value of the low
#      `from_width` bits. sext(200, i8→i64) == -56 (i8-200 == -56 signed —
#      a NEGATIVE from_width value sign-extends to a negative Int64);
#      sext(127, i8→i16) == 127 (no sign bit, unchanged); sext(511, i9→i16)
#      == -1 (i9 all-ones == -1).
#   3. **Forward — :trunc.** Truncate = low `to_width` bits, LOSSY.
#      trunc(511, i16→i8) == 255 (drops the high bit 0x100); trunc(256,
#      i9→i8) == 0 (the only set bit 0x100 is dropped). Edge case: trunc
#      DROPS high bits — the lossy property.
#   4. **Operand survives.** After `forward`, the operand symbol is still
#      in `locals` with its unchanged value — the non-destructive create
#      property (contrast `ArithmeticAssignment`, which deletes `source`).
#   5. **Overwrite at the forward level.** Two `forward`s with the same
#      target update `locals[target]` with no error — the cross-iteration
#      loop case (ADR 0013 / ADR 0012 §"crux").
#   6. **Literal operand.** `CastInstruction(:t, :sext, Int64(200), 8, 64)`
#      sign-extends the literal directly (no locals lookup needed).
#   7. **Constructor validation** (Rule 1): rejects `target === operand`
#      (SSA single-assignment), an out-of-domain op, and out-of-range
#      widths; accepts a literal operand and in-range widths.
#   8. **`is_injective(CastInstruction) == false`** — load-bearing: the
#      static trait can't see runtime freshness AND :trunc is lossy, so it
#      is conservatively non-injective → L3 checkpoints.
#   9. **`inverse` raises the deferral error** — the reverse is the L3
#      checkpoint-replay path, never a per-instruction inverse. Pin the
#      descriptive message via `occursin`.
#
# # Mutation-proof (Rule 5) — performed manually, reverted, NOT in tree
#
# Perturbing the `:trunc` mask in `_apply_cast` from `_low_mask(to_width)`
# to `_low_mask(from_width)` (so trunc keeps the FROM width instead of the
# TO width) makes testset (3) go RED: trunc(511, i16→i8) would return 511
# (low 16 bits) instead of 255 (low 8 bits). Confirmed RED, then restored.
# See the orchestration report for the captured RED evidence.
#
# Ref: src/ir/cast_instruction.jl (the implementation; full per-op LLVM
#      semantics + Bennett.jl gate cross-reference in its top-of-module
#      docstring).
# Ref: docs/adr/0013-reversible-memory-architecture.md §D-5 step 1;
#      docs/adr/0012-collatz-lowering.md §D1 + §"cross-iteration crux".
# Ref: ../Bennett.jl/src/lowering/arith.jl:536-566 (lower_cast! — the
#      gate-level reference for the bit semantics).
# Ref: test/test_define.jl — the sibling SSA-create unit-test layout this
#      file mirrors.
# Ref: CLAUDE.md Rule 1 (constructor validates), Rule 4 (every @test pins
#      a value), Rule 5 (mutation-proof).

@testset "CastInstruction forward — :zext (M_OPCODE)" begin
    # Zero-extend: unsigned value of the low from_width bits, zero-filled.
    instr = BennettVM.CastInstruction(:t, :zext, :a, 8, 9)

    # 200 fits the low 8 bits (its i8 high bit is set, but zext does NOT
    # sign-propagate) → stays the nonnegative 200.
    s200 = BennettVM.IState(0, Dict(:a => Int64(200)), :running)
    s2 = BennettVM.forward(instr, s200)
    @test s2.locals[:t] == Int64(200)
    @test s2.pc == 1
    @test s2.status === :running

    # -1 as an i8 has all 8 low bits set → zext to 255 (unsigned).
    sneg = BennettVM.IState(0, Dict(:a => Int64(-1)), :running)
    @test BennettVM.forward(instr, sneg).locals[:t] == Int64(255)
end

@testset "CastInstruction forward — :sext (M_OPCODE)" begin
    # Sign-extend: signed value of the low from_width bits.
    # i8 200 == -56 signed (high bit set) → sext to Int64 -56.
    sext_8_64 = BennettVM.CastInstruction(:t, :sext, :a, 8, 64)
    s = BennettVM.IState(0, Dict(:a => Int64(200)), :running)
    @test BennettVM.forward(sext_8_64, s).locals[:t] == Int64(-56)

    # i8 127 has no sign bit → unchanged.
    sext_8_16 = BennettVM.CastInstruction(:t, :sext, :a, 8, 16)
    s127 = BennettVM.IState(0, Dict(:a => Int64(127)), :running)
    @test BennettVM.forward(sext_8_16, s127).locals[:t] == Int64(127)

    # i9 511 == 0x1FF == all 9 bits set == -1 signed → sext to -1.
    sext_9_16 = BennettVM.CastInstruction(:t, :sext, :a, 9, 16)
    s511 = BennettVM.IState(0, Dict(:a => Int64(511)), :running)
    @test BennettVM.forward(sext_9_16, s511).locals[:t] == Int64(-1)
end

@testset "CastInstruction forward — :trunc (M_OPCODE)" begin
    # Truncate: keep the low to_width bits (LOSSY — drops the high bits).
    trunc_16_8 = BennettVM.CastInstruction(:t, :trunc, :a, 16, 8)
    # 511 == 0x1FF → low 8 bits == 0xFF == 255 (the 0x100 bit is dropped).
    s511 = BennettVM.IState(0, Dict(:a => Int64(511)), :running)
    s2 = BennettVM.forward(trunc_16_8, s511)
    @test s2.locals[:t] == Int64(255)
    @test s2.pc == 1

    # 256 == 0x100 → low 8 bits == 0 (the only set bit is dropped).
    trunc_9_8 = BennettVM.CastInstruction(:t, :trunc, :a, 9, 8)
    s256 = BennettVM.IState(0, Dict(:a => Int64(256)), :running)
    @test BennettVM.forward(trunc_9_8, s256).locals[:t] == Int64(0)
end

@testset "CastInstruction operand survives forward (M_OPCODE)" begin
    # The non-destructive create property: the operand symbol remains in
    # `locals` with its unchanged value after `forward` (contrast
    # ArithmeticAssignment, which deletes its `source`).
    instr = BennettVM.CastInstruction(:t, :zext, :a, 8, 9)
    s = BennettVM.IState(0, Dict(:a => Int64(42)), :running)
    s2 = BennettVM.forward(instr, s)
    @test s2.locals[:t] == Int64(42)       # zext(42, i8→i9)
    @test haskey(s2.locals, :a)            # operand NOT deleted
    @test s2.locals[:a] == Int64(42)       # ...and unchanged
end

@testset "CastInstruction overwrite at forward level (M_OPCODE)" begin
    # The cross-iteration loop case: the same SSA name is re-cast with a
    # fresh operand value. The forward semantics OVERWRITE `locals[target]`
    # with no error — reversibility of the overwrite (and of trunc's lost
    # bits) is the L3 checkpoint-replay layer's job.
    instr = BennettVM.CastInstruction(:t, :trunc, :a, 16, 8)
    s = BennettVM.IState(0, Dict(:a => Int64(511)), :running)
    BennettVM.forward(instr, s)
    @test s.locals[:t] == Int64(255)
    # Re-enter the "loop body": change the operand and cast again.
    s.locals[:a] = Int64(256)
    BennettVM.forward(instr, s)
    @test s.locals[:t] == Int64(0)         # overwritten, no error
    @test s.pc == 2                        # two forward steps
end

@testset "CastInstruction literal operand (M_OPCODE)" begin
    # A literal Int64 operand resolves directly (no locals lookup). i8 200
    # == -56 signed → sext to Int64 -56.
    instr = BennettVM.CastInstruction(:t, :sext, Int64(200), 8, 64)
    s = BennettVM.IState(0, Dict{Symbol,Int64}(), :running)
    @test BennettVM.forward(instr, s).locals[:t] == Int64(-56)
end

@testset "CastInstruction constructor validation (M_OPCODE)" begin
    # target === operand — SSA single-assignment violation.
    @test_throws ErrorException BennettVM.CastInstruction(:t, :zext, :t, 8, 9)
    # out-of-domain op (not in {:sext,:zext,:trunc}).
    @test_throws ErrorException BennettVM.CastInstruction(:t, :bitcast, :a, 8, 9)
    # widths out of the 1..64 range (IState.locals are Int64).
    @test_throws ErrorException BennettVM.CastInstruction(:t, :zext, :a, 0, 9)
    @test_throws ErrorException BennettVM.CastInstruction(:t, :zext, :a, 8, 65)
    @test_throws ErrorException BennettVM.CastInstruction(:t, :sext, :a, 65, 9)
    # A literal Int64 operand can never collide with the Symbol target,
    # and in-range widths construct successfully (incl. full 64-bit).
    @test BennettVM.CastInstruction(:t, :zext, Int64(0), 8, 9) isa BennettVM.CastInstruction
    @test BennettVM.CastInstruction(:t, :trunc, :a, 64, 64) isa BennettVM.CastInstruction
end

@testset "CastInstruction is_injective == false (M_OPCODE)" begin
    # Load-bearing: the static trait can't see runtime freshness AND
    # :trunc is intrinsically lossy, so CastInstruction is conservatively
    # non-injective → the M6.2/M7.6 push gate emits L3 checkpoints. Pin
    # BOTH the type-level and value-level answers, for all three ops.
    @test BennettVM.is_injective(BennettVM.CastInstruction) == false
    for op in (:sext, :zext, :trunc)
        instr = BennettVM.CastInstruction(:t, op, :a, 8, 9)
        @test BennettVM.is_injective(instr) == false
    end
end

@testset "CastInstruction inverse raises (deferred L1/L2) (M_OPCODE)" begin
    # The reverse is via the L3 checkpoint-replay path, which never calls
    # per-instruction inverse(). Reaching this method is a bug; Rule 1
    # demands a loud raise (trunc is lossy; a loop re-def loses the prior
    # target), not a silent no-op. Pin the descriptive message.
    instr = BennettVM.CastInstruction(:t, :trunc, :a, 16, 8)
    s = BennettVM.IState(1, Dict(:a => Int64(511), :t => Int64(255)), :running)
    @test_throws ErrorException BennettVM.inverse(instr, s, nothing)
    err = try
        BennettVM.inverse(instr, s, nothing)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("CastInstruction", err.msg)
    @test occursin("L3 checkpoint-replay", err.msg)
    @test occursin("deferred", err.msg)
end
