# test/test_fp_f32_reject.jl — Float32-rejection enforcement at the BennettVM
# ingest boundary (M_FP.5; bead `bennettvm-h0t`; ADR 0011 §D2, Bennett-3rph).
#
# # Why this file exists
#
# ADR 0011 §D2 mandates that Float32 be REJECTED at the BennettVM boundary: f32
# arithmetic in mixed-precision IR is routed `soft_fpext → f64-op →
# soft_fptrunc`, which DOUBLE-ROUNDS (rounds once at the f64 op, again at the
# f32 mantissa boundary) and is therefore NOT bit-exact against hardware f32
# (`../Bennett.jl/src/softfloat/fpconv.jl:1-37`; Bennett-3rph; CLAUDE.md
# rule 13). The bit-exact contract extends only to Float64. Before this bead the
# rejection was documented-but-UNENFORCED on the BennettVM side; M_FP.5 turns it
# into a sound, local, enforced guard in the `IRCall` arm of `_lower_body_inst`
# (`src/ir/ingest.jl`) plus the two tests below.
#
# The guard predicate (the precise, non-over-rejecting one): a soft op "touches
# f32" iff `inst.ret_width == 32 || any(==(32), inst.arg_widths)`. This catches
# `soft_fptrunc` (f64→f32, ret 32), `soft_fpext` (f32→f64, arg 32), and any
# f32-OPERAND soft op. It does NOT catch any legitimate pure-Float64 op (all
# widths 64), NOR a legal f64→intN conversion: `fptosi`/`fptoui` to a narrow
# width is emitted upstream as an `IRCall` with `ret_width = 64` PLUS a separate
# `IRCast(:trunc, 64→32)` (`../Bennett.jl/src/extract/instructions.jl:2322-2345`),
# so the SoftCall keeps `ret_width = 64` and `arg_widths = [64]` — never a
# 32-width soft op.
#
# # The two halves (Rule 4 — each asserts a known-correct invariant)
#
#   * **Witness (the key empirical claim).** Drive the SC10 gate
#     `reversible_compile(x -> x*x + 3x + 1, Float64; target=:reversible_vm)`
#     (ADR 0011 §D4; mirrors `test_fp_roundtrip.jl`'s end-to-end testset) and
#     assert the lowered `VMProgram` contains ZERO f32-touching SoftCalls. This
#     proves the SC10 path NEVER exercises the double-rounding path — the guard
#     is unreachable-by-construction on accepted Float64 IR (the SoftFloat
#     wrapper yields integer-only f64 IR over 64-bit bit-patterns).
#
#   * **Defensive (the guard actually fires).** Hand-build a `Bennett.IRCall`
#     to `soft_fptrunc` (ret_width = 32) and one to `soft_fpext`
#     (arg_widths = [32]), feed each through the REAL `lower_vm`, and assert it
#     rejects each with an `ErrorException` whose message NAMES the cause
#     ("Float32" / "double-round" / "f32") — Rule 4: assert the cause, not bare
#     "threw". This is the belt-and-suspenders catch for a mixed-precision `.ll`
#     reaching ingest.
#
# # Mutation-proof (Rule 5) — performed manually, reverted, NOT in tree;
# # captured in the orchestration report
#
# Removing the f32-touching guard from `src/ir/ingest.jl`'s `IRCall` arm makes
# the defensive testset go RED: the hand-built f32 `IRCall` then flows to the
# `SoftCall` constructor, which accepts the f32 widths (it must — see
# `test_softcall.jl`), so `lower_vm` SUCCEEDS and `_faillow_f32_raise` returns
# `nothing` instead of an `ErrorException` (the `e isa ErrorException` /
# `occursin` assertions fail). Confirmed RED-then-GREEN; see the report.
#
# # Ref
#
#   * `docs/adr/0011-fp-inheritance.md` §D2 (Float32 rejection; the M_FP.5
#     boundary-guard update note), §D4 (the SC10 gate program).
#   * `src/ir/ingest.jl` — the `IRCall`-arm f32-touching guard (the impl).
#   * `src/ir/softcall_instruction.jl` §"Float32" — why the SoftCall DATA TYPE
#     still supports f32 widths (the constructor unit-tests) while the ingest
#     BOUNDARY rejects them.
#   * `../Bennett.jl/src/extract/instructions.jl:2322-2345` — the f64→intN
#     conversion emission (ret_width 64 + separate IRCast trunc) that proves no
#     over-rejection.
#   * `../Bennett.jl/src/ir_types.jl:281-293` — the `IRCall` constructor
#     (`dest`, `callee::Function`, `args`, `arg_widths`, `ret_width`) field order.
#   * `test/test_fp_roundtrip.jl` — the SC10 end-to-end fixture this witness
#     mirrors. `test/test_fail_loud_completeness.jl` — the hand-built-ParsedIR
#     `_faillow_raise` idiom this file reuses (Law 2).
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (message names the cause), Rule 5
#     (mutation-proof), Rule 11 (literate).

using Test
using BennettVM
import Bennett

const _F32R = BennettVM

# ---------------------------------------------------------------------
# Local helper (Law 2: the same idiom as test_fail_loud_completeness.jl's
# `_faillow_raise`). Lower a single-block fragment of `insts` (terminating in
# `term`) through the REAL `lower_vm` and capture the raised exception (or
# `nothing` if it did not raise).
# ---------------------------------------------------------------------
function _faillow_f32_raise(insts, term; args=[(:__x, 64)], ret=[64])
    blk = Bennett.IRBasicBlock(:entry, Bennett.IRInst[insts...], term)
    parsed = Bennett.ParsedIR(64, args, [blk], ret)
    try
        lower_vm(parsed; opts=:fail_loud)
        return nothing
    catch e
        return e
    end
end

@testset "Float32 rejection at the ingest boundary (bennettvm-h0t; M_FP.5; ADR 0011 §D2)" begin

    # =================================================================
    # WITNESS — the SC10 pure-Float64 lowering has ZERO f32-touching
    # SoftCalls. Proves the double-rounding path is never exercised on
    # the accepted Float64 gate (the guard is unreachable-by-construction).
    # =================================================================
    @testset "WITNESS: SC10 Float64 lowering has zero f32-touching SoftCalls" begin
        # The literal SC10 gate (ADR 0011 §D4), exactly as test_fp_roundtrip.jl
        # drives it: `using BennettVM` (top of file) has run `__init__`,
        # registering the `:reversible_vm` backend so the dispatch reaches
        # `lower_vm`. The SoftFloat wrapper carries f64 as UInt64 → integer-only
        # IR over 64-bit bit-patterns.
        sc10_f = x -> x * x + 3x + 1
        vm = Bennett.reversible_compile(sc10_f, Float64; target = :reversible_vm)
        @test vm isa VMProgram

        # Walk every SoftCall in the lowered program and confirm NONE touches
        # f32 (the exact guard predicate: ret 32 OR any arg 32). The four FP ops
        # (x*x, 3*x, +, +1) must ALL be 64-bit — the empirical claim.
        n_softcalls = 0
        n_f32_touching = 0
        for b in vm.blocks, i in b.instructions
            i isa _F32R.SoftCall || continue
            n_softcalls += 1
            if i.ret_width == 32 || any(==(32), i.arg_widths)
                n_f32_touching += 1
            end
        end
        @test n_softcalls == 4              # the SC10 polynomial's four FP ops
        @test n_f32_touching == 0           # KEY CLAIM: none touch f32
    end

    # =================================================================
    # DEFENSIVE — a hand-built f32-touching IRCall reaches a SPECIFIC
    # error naming the cause when lowered. Rule 4: assert the cause, not
    # bare "threw". This is the guard that the mixed-precision `.ll`
    # route would hit.
    # =================================================================
    @testset "DEFENSIVE: IRCall(soft_fptrunc, ret 32) → raises naming Float32" begin
        # soft_fptrunc is the f64→f32 NARROW: ret_width = 32 (the f32 OUTPUT,
        # the double-rounding case). arg is the 64-bit f64 input.
        e = _faillow_f32_raise(
            [Bennett.IRCall(:__d, Bennett.soft_fptrunc,
                            Bennett.IROperand[Bennett.SSAOperand(:__x)],
                            [64], 32)],
            Bennett.IRRet(Bennett.SSAOperand(:__d), 32);
            args=[(:__x, 64)], ret=[32])
        @test e isa ErrorException
        # The message NAMES the cause (Rule 4): f32 + the double-rounding reason.
        @test occursin("Float32", e.msg)
        @test occursin("double-round", e.msg) || occursin("DOUBLE-ROUND", e.msg)
        @test occursin("soft_fptrunc", e.msg)
        # And it is NOT the generic SoftCall-allowlist message (the guard fires
        # BEFORE the SoftCall constructor): proves the specific D2 diagnostic.
        @test !occursin("recognised SoftFloat", e.msg)
    end

    @testset "DEFENSIVE: IRCall(soft_fpext, arg 32) → raises naming Float32" begin
        # soft_fpext is the f32→f64 WIDEN: arg_widths = [32] (the f32 INPUT).
        # Catching the arg-side f32 proves the predicate's `any(==(32),
        # arg_widths)` half fires, not only the ret-side half.
        e = _faillow_f32_raise(
            [Bennett.IRCall(:__d, Bennett.soft_fpext,
                            Bennett.IROperand[Bennett.SSAOperand(:__x)],
                            [32], 64)],
            Bennett.IRRet(Bennett.SSAOperand(:__d), 64);
            args=[(:__x, 32)], ret=[64])
        @test e isa ErrorException
        @test occursin("Float32", e.msg)
        @test occursin("double-round", e.msg) || occursin("DOUBLE-ROUND", e.msg)
        @test occursin("soft_fpext", e.msg)
        @test !occursin("recognised SoftFloat", e.msg)
    end

    # =================================================================
    # NON-OVER-REJECTION — a legitimate pure-Float64 soft op (all widths
    # 64) is NOT rejected by the f32 guard. Pins that the guard fires ONLY
    # on a genuine f32 width, never on a legal f64 op.
    # =================================================================
    @testset "NON-OVER-REJECTION: IRCall(soft_fmul, all widths 64) lowers cleanly" begin
        # A pure-f64 soft op: ret 64, args [64, 64]. The f32 guard must NOT fire;
        # the op lowers to a SoftCall and `lower_vm` succeeds.
        e = _faillow_f32_raise(
            [Bennett.IRCall(:__d, Bennett.soft_fmul,
                            Bennett.IROperand[Bennett.SSAOperand(:__x),
                                              Bennett.SSAOperand(:__x)],
                            [64, 64], 64)],
            Bennett.IRRet(Bennett.SSAOperand(:__d), 64);
            args=[(:__x, 64)], ret=[64])
        @test e === nothing                 # NOT rejected — the f64 op is legal
    end
end
