# test/test_softcall.jl — M_FP.2 op-level unit tests for `SoftCall`
# (bead `bennettvm-8ox`, ADR 0011 §D1, ADR 0012 §D1 template).
#
# # What this file pins
#
# `src/ir/softcall_instruction.jl` defines `SoftCall`, the SoftFloat-
# dispatch SSA-create `dest := soft_f*(args...)` over integer bit-patterns
# — the lowering target for LLVM `IRCall` to a registered `soft_f*` callee,
# whose args are READ but never destroyed. Like `Define` / `CastInstruction`
# it is a non-destructive create; unlike them it calls a host SoftFloat
# primitive resolved through the `_SOFT_DISPATCH` registry/allowlist. The
# tests below pin (Rule 4 — every @test asserts a known-correct value,
# hand-computed against native IEEE-754 f64 and the bit-exact SoftFloat
# contract of ADR 0011 D1):
#
#   1. **Forward — arithmetic.** soft_fmul(2.0, 3.0) bits == bits of 6.0;
#      soft_fadd(2.0, 3.0) bits == bits of 5.0; soft_fsub bits == bits of
#      the difference. Asserted bit-for-bit AND via the decoded Float64.
#   2. **Forward — negative bit-pattern carrier.** A double with its sign
#      bit set (e.g. -2.5) is a NEGATIVE Int64 in locals; the mask-and-
#      reinterpret path must still feed the correct UInt64 to the soft
#      function: soft_fadd(-2.5, 1.0) bits == bits of -1.5.
#   3. **Forward — fma (ternary arity).** soft_fma(a,b,c) bits == bits of
#      fma(a,b,c) — proving the variadic arity ArithmeticAssignment cannot
#      express.
#   4. **Forward — literal operand.** A literal Int64 bit-pattern operand
#      resolves directly (no locals lookup).
#   5. **Args survive.** After forward, every arg symbol is still in locals
#      unchanged — the non-destructive create property (contrast
#      ArithmeticAssignment, which deletes its source).
#   6. **Overwrite at the forward level.** Two forwards with the same dest
#      update locals[dest] with no error — the cross-iteration loop case.
#   7. **Constructor validation** (Rule 1): rejects an unknown callee_name
#      (the allowlist boundary), dest ∈ args (SSA single-assignment), an
#      args/arg_widths length mismatch, and a width ∉ {32,64}.
#   8. **`is_injective(SoftCall) == false`** — load-bearing: FP ops are not
#      locally invertible and a loop re-def overwrites → conservatively
#      non-injective → L3 checkpoints.
#   9. **`is_l2_capable(SoftCall) == false`** — no make_delta, no
#      predelta_payload, so compute_must_cache never selects it; reversed
#      L3-only.
#  10. **`inverse` raises the deferral error** — the reverse is the L3
#      checkpoint-replay path, never a per-instruction inverse. Pin the
#      descriptive message via `occursin`.
#
# # Mutation-proof (Rule 5) — performed manually, reverted, NOT in tree
#
# Perturbing `_from_soft_unsigned` (`src/ir/softcall_instruction.jl`) to
# return `Int64(0)` always makes testset (1) go RED (the result bit-pattern
# no longer matches the oracle). Swapping the `soft_fmul`/`soft_fadd` keys
# in the dispatch registry would make (1) RED too. Confirmed RED-then-GREEN;
# see the orchestration report.
#
# Ref: src/ir/softcall_instruction.jl (the implementation; full forward bit-
#      reinterpret semantics + Bennett.jl soft_f* cross-reference in its
#      top-of-module docstring).
# Ref: docs/adr/0011-fp-inheritance.md §D1 (inherit SoftFloat wholesale).
# Ref: test/test_cast_instruction.jl — the sibling SSA-create unit-test
#      layout this file mirrors.
# Ref: CLAUDE.md Rule 1 (constructor validates), Rule 4 (every @test pins a
#      value), Rule 5 (mutation-proof).

using Test
using BennettVM
import Bennett

const _BVSC = BennettVM

# Bit-pattern of a Float64, as the Int64 locals carrier.
_b(x::Float64) = reinterpret(Int64, x)

@testset "SoftCall forward — arithmetic (M_FP.2)" begin
    # soft_fmul(2.0, 3.0) → 6.0
    mul = _BVSC.SoftCall(:p, :soft_fmul,
                         Union{Symbol,Int64}[:a, :b], [64, 64], 64)
    s = _BVSC.IState(0, Dict(:a => _b(2.0), :b => _b(3.0)), :running)
    s2 = _BVSC.forward(mul, s)
    @test s2.locals[:p] == _b(6.0)                       # bit-for-bit
    @test reinterpret(Float64, s2.locals[:p]) == 6.0     # decoded
    @test s2.pc == 1
    @test s2.status === :running

    # soft_fadd(2.0, 3.0) → 5.0
    add = _BVSC.SoftCall(:p, :soft_fadd,
                         Union{Symbol,Int64}[:a, :b], [64, 64], 64)
    s = _BVSC.IState(0, Dict(:a => _b(2.0), :b => _b(3.0)), :running)
    @test _BVSC.forward(add, s).locals[:p] == _b(5.0)

    # soft_fsub(3.0, 2.0) → 1.0
    sub = _BVSC.SoftCall(:p, :soft_fsub,
                         Union{Symbol,Int64}[:a, :b], [64, 64], 64)
    s = _BVSC.IState(0, Dict(:a => _b(3.0), :b => _b(2.0)), :running)
    @test _BVSC.forward(sub, s).locals[:p] == _b(1.0)
end

@testset "SoftCall forward — negative bit-pattern carrier (M_FP.2)" begin
    # -2.5 has its sign bit set → a NEGATIVE Int64 carrier. The mask-and-
    # reinterpret path must feed the correct UInt64 to soft_fadd.
    add = _BVSC.SoftCall(:p, :soft_fadd,
                         Union{Symbol,Int64}[:a, :b], [64, 64], 64)
    @test _b(-2.5) < 0                                    # sign bit set
    s = _BVSC.IState(0, Dict(:a => _b(-2.5), :b => _b(1.0)), :running)
    @test _BVSC.forward(add, s).locals[:p] == _b(-1.5)
    @test reinterpret(Float64, _BVSC.forward(add,
        _BVSC.IState(0, Dict(:a => _b(-2.5), :b => _b(1.0)), :running)).locals[:p]) == -1.5
end

@testset "SoftCall forward — fma ternary arity (M_FP.2)" begin
    # soft_fma(a,b,c) = a*b + c, the 3-operand form ArithmeticAssignment
    # (binary) cannot express.
    fma_i = _BVSC.SoftCall(:p, :soft_fma,
                           Union{Symbol,Int64}[:a, :b, :c], [64, 64, 64], 64)
    s = _BVSC.IState(0, Dict(:a => _b(2.0), :b => _b(3.0), :c => _b(4.0)),
                     :running)
    @test reinterpret(Float64, _BVSC.forward(fma_i, s).locals[:p]) ==
          fma(2.0, 3.0, 4.0)
end

@testset "SoftCall forward — literal operand (M_FP.2)" begin
    # A literal Int64 bit-pattern operand resolves directly (no locals).
    mul = _BVSC.SoftCall(:p, :soft_fmul,
                         Union{Symbol,Int64}[:a, _b(3.0)], [64, 64], 64)
    s = _BVSC.IState(0, Dict(:a => _b(2.0)), :running)
    @test reinterpret(Float64, _BVSC.forward(mul, s).locals[:p]) == 6.0
end

@testset "SoftCall args survive forward (M_FP.2)" begin
    # Non-destructive create: every arg symbol remains in locals unchanged.
    mul = _BVSC.SoftCall(:p, :soft_fmul,
                         Union{Symbol,Int64}[:a, :b], [64, 64], 64)
    s = _BVSC.IState(0, Dict(:a => _b(2.0), :b => _b(3.0)), :running)
    s2 = _BVSC.forward(mul, s)
    @test haskey(s2.locals, :a) && s2.locals[:a] == _b(2.0)
    @test haskey(s2.locals, :b) && s2.locals[:b] == _b(3.0)
end

@testset "SoftCall overwrite at forward level (M_FP.2)" begin
    # The cross-iteration loop case: the same dest is recomputed with fresh
    # operand values; forward OVERWRITES locals[dest] with no error.
    mul = _BVSC.SoftCall(:p, :soft_fmul,
                         Union{Symbol,Int64}[:a, :b], [64, 64], 64)
    s = _BVSC.IState(0, Dict(:a => _b(2.0), :b => _b(3.0)), :running)
    _BVSC.forward(mul, s)
    @test s.locals[:p] == _b(6.0)
    s.locals[:a] = _b(4.0)
    _BVSC.forward(mul, s)
    @test s.locals[:p] == _b(12.0)                       # overwritten, no error
    @test s.pc == 2
end

@testset "SoftCall constructor validation (M_FP.2)" begin
    # Unknown callee_name — the allowlist boundary (Rule 1).
    @test_throws ErrorException _BVSC.SoftCall(:p, :not_a_soft_fn,
        Union{Symbol,Int64}[:a], [64], 64)
    # dest ∈ args — SSA single-assignment violation.
    @test_throws ErrorException _BVSC.SoftCall(:p, :soft_fadd,
        Union{Symbol,Int64}[:p, :b], [64, 64], 64)
    # args / arg_widths length mismatch.
    @test_throws ErrorException _BVSC.SoftCall(:p, :soft_fadd,
        Union{Symbol,Int64}[:a, :b], [64], 64)
    # width ∉ {32, 64}.
    @test_throws ErrorException _BVSC.SoftCall(:p, :soft_fadd,
        Union{Symbol,Int64}[:a, :b], [64, 17], 64)
    @test_throws ErrorException _BVSC.SoftCall(:p, :soft_fadd,
        Union{Symbol,Int64}[:a, :b], [64, 64], 17)
    # In-domain callee + widths construct successfully (f64 and the f32
    # conversion path).
    @test _BVSC.SoftCall(:p, :soft_fadd, Union{Symbol,Int64}[:a, :b],
                         [64, 64], 64) isa _BVSC.SoftCall
    @test _BVSC.SoftCall(:p, :soft_fpext, Union{Symbol,Int64}[:a],
                         [32], 64) isa _BVSC.SoftCall    # f32→f64 widen
    @test _BVSC.SoftCall(:p, :soft_fptrunc, Union{Symbol,Int64}[:a],
                         [64], 32) isa _BVSC.SoftCall    # f64→f32 narrow
end

@testset "SoftCall registry / allowlist (M_FP.2)" begin
    # The registry is built from Bennett.jl's FP callee groups (Law 2). Pin
    # representative members of each group are present, and a transcendental
    # (deliberately EXCLUDED at M_FP.2) is absent.
    @test haskey(_BVSC._SOFT_DISPATCH, :soft_fadd)      # _CALLEES_FP_BINARY
    @test haskey(_BVSC._SOFT_DISPATCH, :soft_fma)       # _CALLEES_FP_BINARY
    @test haskey(_BVSC._SOFT_DISPATCH, :soft_fneg)      # _CALLEES_FP_UNARY
    @test haskey(_BVSC._SOFT_DISPATCH, :soft_floor)     # _CALLEES_FP_ROUND
    @test haskey(_BVSC._SOFT_DISPATCH, :soft_fpext)     # _CALLEES_FP_CONV
    @test haskey(_BVSC._SOFT_DISPATCH, :soft_sitofp)    # _CALLEES_FP_CONV
    @test !haskey(_BVSC._SOFT_DISPATCH, :soft_exp)      # transcendental — excluded
    @test !haskey(_BVSC._SOFT_DISPATCH, :soft_fcmp_olt) # cmp — excluded
    # Every registry value is a Function whose nameof is the key.
    for (k, f) in _BVSC._SOFT_DISPATCH
        @test f isa Function
        @test nameof(f) === k
    end
end

@testset "SoftCall is_injective == false (M_FP.2)" begin
    # Load-bearing: FP ops are not locally invertible AND a loop re-def
    # overwrites, so SoftCall is conservatively non-injective → L3.
    @test _BVSC.is_injective(_BVSC.SoftCall) == false
    instr = _BVSC.SoftCall(:p, :soft_fmul,
                           Union{Symbol,Int64}[:a, :b], [64, 64], 64)
    @test _BVSC.is_injective(instr) == false
end

@testset "SoftCall is_l2_capable == false (M_FP.2)" begin
    # No make_delta, no predelta_payload → not L2-capable → compute_must_cache
    # never selects it; reversed L3-only.
    @test _BVSC.is_l2_capable(_BVSC.SoftCall) == false
    instr = _BVSC.SoftCall(:p, :soft_fmul,
                           Union{Symbol,Int64}[:a, :b], [64, 64], 64)
    @test _BVSC.predelta_payload(instr,
        _BVSC.IState(0, Dict(:a => _b(2.0), :b => _b(3.0)), :running)) === nothing
end

@testset "SoftCall inverse raises (deferred L1/L2) (M_FP.2)" begin
    # The reverse is via L3 checkpoint-replay, which never calls per-
    # instruction inverse(). Reaching this method is a bug; Rule 1 demands a
    # loud raise (FP ops are not locally invertible), not a silent no-op.
    instr = _BVSC.SoftCall(:p, :soft_fmul,
                           Union{Symbol,Int64}[:a, :b], [64, 64], 64)
    s = _BVSC.IState(1, Dict(:a => _b(2.0), :b => _b(3.0), :p => _b(6.0)),
                     :running)
    @test_throws ErrorException _BVSC.inverse(instr, s, nothing)
    err = try
        _BVSC.inverse(instr, s, nothing)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("SoftCall", err.msg)
    @test occursin("L3 checkpoint-replay", err.msg)
    @test occursin("deferred", err.msg)
end
