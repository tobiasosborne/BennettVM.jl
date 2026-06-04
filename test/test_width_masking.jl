# test/test_width_masking.jl — width-aware `_apply_binop` golden-master +
# round-trip gate (bead `bennettvm-bgc`, ADR 0012 R1).
#
# # What this gate is, and why it exists
#
# ADR 0012 Risk R1: `IState.locals` are `Int64`, but a narrow-width source
# program (collatz is i8) has values of LLVM type i`w` living in the low
# `w` bits. The original ingest DROPPED the `IRBinOp.width` / `IRICmp.width`
# at the lowering call site and `_apply_binop` computed at FULL Int64 width,
# so a create that OVERFLOWED its width diverged from a native i`w` oracle.
# The fix (this bead) threads `inst.width` into the `Define` and makes
# `_apply_binop` WIDTH-AWARE: extract the low-`w` bits of each operand,
# re-extend per the op's OWN signedness, do the op, mask the result to low
# `w` bits.
#
# # The load-bearing RED→GREEN witness (Rule 5 mutation-proof anchor)
#
# `f(x::Int8) = (Int8(3) * x) ÷ Int8(2)` lowers to `Define(:__v1, x, :mul,
# 3, width=8)` + `Define(:__v2, :__v1, :sdiv, 2, width=8)`. For `x=Int8(50)`:
# `50*3 = 150` OVERFLOWS i8 → `Int8(-106)`; `-106 ÷ 2 = -53`. The native
# oracle is `Int8(-53)`, stored in the VM's low-8-bit representation as
# `-53 & 0xFF == 203`. PRE-fix the VM computed `150 ÷ 2 == 75` (full-width,
# DISAGREE); POST-fix it computes `203` (agree). `x=Int8(20)` does NOT
# overflow (`60 ÷ 2 == 30`) and agreed both before and after — it pins that
# the fix did not regress the in-range case.
#
# Mutation-proof evidence (manually performed, then reverted; NOT left in
# the tree): reverting ONLY the width-threading at the ingest site (passing
# `64` instead of `inst.width` to the `Define` constructor) turned the x=50
# golden-master RED — the VM gave `75` again — while x=20 stayed GREEN.
# Restoring `inst.width` returned it to GREEN. This proves the test catches
# the exact regression the bead fixes (Rule 5: "tests have caught a real
# regression").
#
# # Why these assertions (Rule 4 — known-correct oracle, not "didn't throw")
#
#   1. **Signed golden-master (`÷` → `:sdiv`).** Overflowing x=50 → 203 and
#      non-overflowing x=20 → 30, each `== Int64(f(Int8(x))) & 0xFF` (the
#      native oracle in the VM's low-8-bit representation). This is THE R1
#      witness.
#   2. **Signed remainder corroboration (`%` → `:srem`).** `g(x::Int8) =
#      (Int8(3) * x) % Int8(5)` on an OVERFLOWING input (x=50: `150` wraps
#      to `-106`; `-106 % 5 == -1`; low-8 = 255). A second signed op so the
#      witness is not single-op.
#   3. **Unsigned golden-master (`÷` → `:udiv`).** `h(x::UInt8) = x ÷
#      UInt8(3)` exercises the udiv `& mask` (zero-extend) path at w<64,
#      where the WRONG full-64-bit reinterpret would have used high bits.
#      x=200 (0xC8, high bit set): unsigned `200 ÷ 3 == 66`; a signed read
#      would give `-56 ÷ 3 == -18` (≠), so this discriminates the unsigned
#      arm.
#   4. **Round-trip on the overflow input (P0.6).** `unrun!(run!(…))` →
#      `rs.current == rs.initial`, empty history, step_count 0. Reversibility
#      is width-independent (masking is part of the deterministic forward,
#      so the L3 checkpoint-replay reverses it unchanged) — this must stay
#      GREEN on the SAME overflowing input the golden-master uses.
#   5. **Width-64 is a verified NO-OP.** `_apply_binop(op, a, b)` (default
#      64) `== _apply_binop(op, a, b, 64)` for every op, across signed /
#      unsigned / comparison families — so every pre-existing full-width
#      `Define` (synthetic φ-incoming constants, hand-built unit tests) is
#      byte-identical. Also the signed/unsigned comparison split at w=8
#      (`slt(-1,0)==1` vs `ult(-1,0)==0`) is pinned directly.
#
# # Why NO change to IState / Cast / Select / input-binding
#
# The model RE-EXTRACTS each operand inside `_apply_binop` per the op's own
# signedness, so the stored Int64 representation's high bits never matter —
# the change is self-contained to the op kernel plus the `Define.width`
# field. `CastInstruction` already gets width right (it is the one place
# that must, ADR 0013); `SelectInstruction` only copies a chosen arm
# verbatim; input-binding stores the raw Int64. None needed touching.
#
# # Ref
#
#   * docs/adr/0012-collatz-lowering.md R1 (the width risk this resolves),
#     §D2 (comparison signed/unsigned split).
#   * src/ir/arithmetic_assignment.jl — the width-aware `_apply_binop` +
#     its per-op classification docstring.
#   * src/ir/define_instruction.jl — the `Define.width` field (default 64).
#   * src/ir/ingest.jl — the `_lower_body_inst` IRBinOp / IRICmp arms that
#     thread `inst.width`.
#   * src/ir/cast_instruction.jl — `_low_mask` / `_apply_cast(:sext, …)`,
#     reused by `_apply_binop` (Law 2).
#   * test/test_collatz_roundtrip.jl / test_fp_roundtrip.jl — the e2e
#     `reversible_compile`/`run!`/`unrun!` forward-run idiom this mirrors.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known-correct oracle), Rule 5
#     (mutation-proof), Rule 11 (literate).

using Test
using BennettVM
import Bennett

# The three golden-master source functions. Co-located with the tests
# (PRD v4 §3.14 golden-master co-location): each native Julia function IS
# the irreversible oracle the lowered VM must agree with bit-for-bit (in
# the VM's low-`w`-bit representation).
_wm_f(x::Int8)  = (Int8(3) * x) ÷ Int8(2)   # :mul (w8) + :sdiv (w8)
_wm_g(x::Int8)  = (Int8(3) * x) % Int8(5)   # :mul (w8) + :srem (w8)
_wm_h(x::UInt8) = x ÷ UInt8(3)              # :udiv (w8)

# Lower a single-arg function to a VMProgram and recover its Begin-param
# arg name + End-return name (robust to extractor SSA renames; the same
# derive-from-the-lowered-program idiom test_fp_roundtrip.jl's e2e uses).
function _wm_lower(fn, ::Type{T}) where {T}
    parsed = Bennett.extract_parsed_ir(fn, Tuple{T})
    vm = lower_vm(parsed; opts = :width_masking)
    begin_inst = nothing
    end_inst = nothing
    for b in vm.blocks
        b.entry isa BennettVM.BeginInstruction && (begin_inst = b.entry)
        b.exit isa BennettVM.EndInstruction && (end_inst = b.exit)
    end
    @assert begin_inst !== nothing && length(begin_inst.params) == 1
    @assert end_inst !== nothing && length(end_inst.returns) == 1
    return (vm, begin_inst.params[1], end_inst.returns[1])
end

# Forward-run the lowered `vm` on a single Int64-carried input, returning
# the routine result (the End-return local).
function _wm_run(vm, arg::Symbol, ret::Symbol, xin::Int64)
    rs = initial_state(vm, Dict(arg => xin))
    run!(rs, vm; max_steps = 1000, checkpoint_interval = 4)
    @assert is_halted(rs)
    return result(rs)[ret]
end

@testset "width-aware _apply_binop (ADR 0012 R1, bgc)" begin
    # ------------------------------------------------------------------
    # (1) Signed golden-master: ÷ → :sdiv, the R1 witness.
    # ------------------------------------------------------------------
    # x=50 OVERFLOWS i8 (the case the bug miscompiled to 75); x=20 does
    # not. Each VM output must equal the native oracle in the VM's
    # low-8-bit representation (`Int64(oracle) & 0xFF`).
    @testset "signed sdiv golden-master (overflow + in-range)" begin
        vm, arg, ret = _wm_lower(_wm_f, Int8)
        # Overflow input — the load-bearing case (pre-fix this was 75).
        got50 = _wm_run(vm, arg, ret, Int64(50))
        @test got50 == (Int64(_wm_f(Int8(50))) & 0xFF)
        @test got50 == 203                 # explicit constant: -53 & 0xFF
        @test got50 != 75                  # the pre-fix full-width value
        # In-range input — no overflow, agreed before AND after.
        got20 = _wm_run(vm, arg, ret, Int64(20))
        @test got20 == (Int64(_wm_f(Int8(20))) & 0xFF)
        @test got20 == 30                  # explicit constant
    end

    # ------------------------------------------------------------------
    # (2) Signed remainder corroboration: % → :srem on an overflow input.
    # ------------------------------------------------------------------
    @testset "signed srem corroboration (overflow)" begin
        vm, arg, ret = _wm_lower(_wm_g, Int8)
        got50 = _wm_run(vm, arg, ret, Int64(50))
        @test got50 == (Int64(_wm_g(Int8(50))) & 0xFF)
        @test got50 == 255                 # -106 % 5 == -1; -1 & 0xFF
        # A second overflow input (x=100: 300 wraps to 44; 44 % 5 == 4).
        got100 = _wm_run(vm, arg, ret, Int64(100))
        @test got100 == (Int64(_wm_g(Int8(100))) & 0xFF)
        @test got100 == 4
    end

    # ------------------------------------------------------------------
    # (3) Unsigned golden-master: ÷ → :udiv, the `& mask` zero-extend path.
    # ------------------------------------------------------------------
    # x=200 has its i8 high bit set, so a SIGNED read (-56 ÷ 3 = -18) would
    # disagree with the UNSIGNED op (200 ÷ 3 = 66). This discriminates the
    # udiv arm and exercises masking at w<64 (the old full-64-bit
    # reinterpret would have used the high bits — wrong at w=8).
    @testset "unsigned udiv golden-master (w<64 mask path)" begin
        vm, arg, ret = _wm_lower(_wm_h, UInt8)
        for xin in (Int64(200), Int64(7), Int64(255))
            got = _wm_run(vm, arg, ret, xin)
            # Oracle: UInt8 result widened to its low-8-bit Int64 carrier.
            @test got == (Int64(_wm_h(UInt8(xin))) & 0xFF)
        end
        # Explicit discriminating constant (signed read would give 238).
        @test _wm_run(vm, arg, ret, Int64(200)) == 66
    end

    # ------------------------------------------------------------------
    # (4) Round-trip on the overflow input (P0.6) — must stay GREEN.
    # ------------------------------------------------------------------
    # Reversibility is width-independent: masking is part of the
    # deterministic forward function, so L3 checkpoint-replay reverses the
    # masked forward unchanged. Asserted on the SAME overflowing x=50 the
    # golden-master uses.
    @testset "round-trip on the overflow input (P0.6)" begin
        vm, arg, ret = _wm_lower(_wm_f, Int8)
        rs = initial_state(vm, Dict(arg => Int64(50)))
        initial_snap = deepcopy(rs.initial)
        run!(rs, vm; max_steps = 1000, checkpoint_interval = 4)
        @test is_halted(rs)
        @test result(rs)[ret] == 203                # forward still correct
        unrun!(rs, vm)
        @test rs.current == rs.initial              # reversed to start
        @test isempty(rs.history)                   # history drained
        @test rs.step_count == 0                    # step counter reset
        @test rs.initial == initial_snap            # rs.initial never mutated
    end

    # ------------------------------------------------------------------
    # (5) Width-64 is a verified NO-OP + the w=8 signed/unsigned split.
    # ------------------------------------------------------------------
    # Every existing full-width Define (synthetic φ-incoming constants,
    # hand-built unit tests) calls `_apply_binop(op, a, b)` (default 64);
    # it MUST be byte-identical to the explicit `…, 64` form across all
    # families — otherwise the fix would silently perturb pinned behavior.
    @testset "width-64 no-op (existing behavior byte-identical)" begin
        _ab = BennettVM._apply_binop
        # Sample values chosen to be sign-sensitive (negative dividends,
        # high-bit-set operands) so a mis-masking would surface.
        sample = (Int64(-7), Int64(3), Int64(-106), Int64(150),
                  Int64(-1), Int64(0), typemax(Int64), typemin(Int64))
        ops = (:add, :sub, :mul, :and, :or, :xor, :shl, :lshr, :ashr,
               :udiv, :sdiv, :urem, :srem,
               :eq, :ne, :ult, :ule, :ugt, :uge, :slt, :sle, :sgt, :sge)
        for op in ops
            for a in sample, b in sample
                # Skip divide/rem by zero (not a width concern; throws
                # identically in both calls — guard to keep the loop clean).
                (op in (:udiv, :sdiv, :urem, :srem) && b == 0) && continue
                # Skip the signed `typemin ÷ -1` / `typemin % -1` overflow
                # (Julia `DivideError`): it throws identically in BOTH calls
                # at w=64, so it is not a masking discrepancy — guarding it
                # keeps the no-op assertion (not the exception) under test.
                (op in (:sdiv, :srem) && a == typemin(Int64) && b == -1) &&
                    continue
                # Shifts by >= 64 are platform-defined but IDENTICAL between
                # the two calls at w=64 (bm == b in both); include them.
                @test _ab(op, a, b) == _ab(op, a, b, 64)
            end
        end
    end

    @testset "signed/unsigned comparison split at w=8" begin
        _ab = BennettVM._apply_binop
        # The load-bearing predicate split (ADR 0012 §D2): at w=8, the i8
        # value -1 is the low-8 pattern 0xFF (= 255 unsigned). A signed
        # `slt(-1, 0)` is TRUE (1); the unsigned `ult(-1, 0)` compares
        # 255 < 0, FALSE (0).
        @test _ab(:slt, Int64(-1), Int64(0), 8) == 1
        @test _ab(:ult, Int64(-1), Int64(0), 8) == 0
        # 200 (0xC8) as i8 is -56: slt(200,5)@8 = (-56 < 5) = 1;
        # ult(200,5)@8 = (200 < 5) = 0.
        @test _ab(:slt, Int64(200), Int64(5), 8) == 1
        @test _ab(:ult, Int64(200), Int64(5), 8) == 0
        # Equality is signedness-agnostic and width-masked: at w=8,
        # 256 ≡ 0 and 257 ≡ 1, so eq(256, 0)@8 = 1, eq(257, 1)@8 = 1.
        @test _ab(:eq, Int64(256), Int64(0), 8) == 1
        @test _ab(:eq, Int64(257), Int64(1), 8) == 1
        @test _ab(:ne, Int64(256), Int64(1), 8) == 1
    end
end
