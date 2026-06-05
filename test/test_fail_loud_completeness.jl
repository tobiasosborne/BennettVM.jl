# test/test_fail_loud_completeness.jl — the clean-fail-loud completeness gate
# (bead `bennettvm-0kl`, OPCODE F1/F2; epic `bennettvm-x49`; PRD v4 §3.6.1
# maximum-opcode-coverage north-star, the "fail loud cleanly" half).
#
# # Why this file exists
#
# The opcode-coverage north-star has two halves: every *reversibly possible*
# LLVM opcode flows Julia → Bennett.jl extract → `ParsedIR` → BennettVM ingest
# → `run!`/`unrun!` (the DONE rows, asserted in `test_opcode_coverage.jl`);
# and the *genuinely-impossible / nondeterministic* set must **fail loud
# cleanly** — reach a clear Rule-1 `ErrorException` whose message NAMES the
# cause, never a silent miscompile and never a *misleadingly generic* error.
# This file is the executable proof of that second half (bead `bennettvm-0kl`,
# F1 nondeterminism + F2 impossible-CFG/memory).
#
# # The boundary: most impossible constructs are rejected UPSTREAM
#
# Bennett.jl's `extract` already refuses the genuinely-impossible set at the
# LLVM-source boundary, so they never reach a `ParsedIR` and can never be
# constructed as an `IRInst` to feed `lower_vm`:
#
#   * **atomics / volatile** — U14 (cmpxchg / atomicrmw rejected in extract;
#     concurrency / memory-ordering is not a pure deterministic forward).
#   * **inline-asm / opaque external call** — U15 (callbr and asm-call
#     rejected; an opaque body is not visible to replay).
#   * **indirectbr** (computed goto) — U4eu (the target set is not statically
#     a CFG successor list, so it cannot be lowered to paired Entry/Exit
#     blocks).
#
# (docs/opcode-coverage-plan.md "Genuinely impossible — must stay fail-loud":
# "Inherited from Bennett.jl … Already rejected + tested on the Bennett.jl
# side (U14 atomic/volatile, U15 inline-asm/opaque-call, U4eu indirectbr,
# cmpxchg/atomicrmw/callbr).") Because there is NO `IRInst` subtype for any of
# these — Bennett.jl never emits one — they are UNREPRESENTABLE at the
# `ParsedIR` interface BennettVM consumes (Rule 14: BennettVM stands alone via
# that interface and does not reach into Bennett.jl internals). We therefore
# do NOT fake a `lower_vm` test for an unrepresentable construct; we DOCUMENT
# the boundary honestly here (Rule 1) and assert the belt-and-suspenders
# floor: the BennettVM-side shared `else` GAP in `_lower_body_inst` is what
# catches ANY unclassifiable `IRInst` if one ever did arrive (a malformed
# handoff or a frontend regression), so it fails loud rather than silently
# miscompiling.
#
# # What this file CAN and DOES assert (Rule 4 — message names the cause)
#
#   * **F1 nondeterminism (the new guard, bead 0kl).** An `IRCall` to a
#     nondeterministic callee (`rand`, `objectid`) is REPRESENTABLE — it is a
#     well-typed `IRCall` with a Julia `Function` callee — and `lower_vm` must
#     reject it with a SPECIFIC message containing "nondeterministic", NOT the
#     generic "unknown SoftFloat callee" the SoftCall allowlist would produce.
#     This is the `_NONDETERMINISTIC_CALLEES` guard in `ingest.jl`'s IRCall arm.
#   * **F2 impossible-CFG/memory belt-and-suspenders** (each already in place;
#     this file PINS them as the defensive mirror):
#       - `IRPtrOffset` now LOWERS (bead `bennettvm-b5x`; the cell-addressed
#         STATIC GEP) but carries its own Rule-1 reject for a sub-element /
#         struct byte offset (non-whole-element multiple, BG3 / U16 out of
#         scope) — pinned here from the fail-loud angle;
#       - a RETURNED aggregate (`IRInsertValue` / `IRExtractValue` now LOWER for
#         ArrayType — bead `bennettvm-acq` — but a returned `[N x iW]` aggregate
#         is still DEFERRED) hits the ingest IRRet aggregate-return guard;
#       - an `IRSwitch` arriving as a terminator hits `_successors`' reject;
#       - a non-SSA-operand `IRStore` / `IRLoad` ptr hits the memory-floor
#         reject (a pointer must be an `SSAOperand` naming an alloca dest).
#
# This file deliberately OVERLAPS `test_opcode_coverage.jl`'s GAP / N/A rows
# in spirit but frames them from the fail-loud-completeness angle and adds the
# new F1 nondeterminism guard the coverage file does not (it predates 0kl).
#
# # Ref
#
#   * `docs/opcode-coverage-plan.md` — "Genuinely impossible — must stay
#     fail-loud" section (Nondeterminism row; U14/U15/U4eu upstream rejects)
#     and the P6 "clean-fail-loud" phase row (bead `0kl`).
#   * `src/ir/ingest.jl` — `_NONDETERMINISTIC_CALLEES` + the IRCall-arm guard
#     (F1); `_lower_body_inst` shared `else` (now a structural firewall — the
#     GAP group is empty; IRPtrOffset lowers at bead `bennettvm-b5x`); the
#     IRRet aggregate-return guard (the deferred surface of
#     the now-lowering IRInsertValue / IRExtractValue, bead `bennettvm-acq`);
#     the IRStore / IRLoad SSA-ptr rejects (the memory floor); `_successors`
#     IRSwitch reject (F2).
#   * `Bennett.jl/src/ir_types.jl` — the `IRInst` subtype constructors
#     (read-only; Rule 14): IRCall:281, IRPtrOffset:144, IRExtractValue:273,
#     IRInsertValue:115, IRStore:172, IRLoad:157, IRSwitch:320.
#   * `test/test_opcode_coverage.jl` — the GAP-assertion idiom mirrored here.
#   * CLAUDE.md Rule 1 (fail loud), Rule 3 (skepticism), Rule 4 (message names
#     the cause, never bare "threw"), Rule 11 (literate), Rule 14 (stands alone
#     via the ParsedIR interface).

using Test
using BennettVM
import Bennett

# ---------------------------------------------------------------------
# Local helper (Law 2: same idiom as test_opcode_coverage.jl's
# `_coverage_raise`). Lower a single-block fragment through the REAL
# `lower_vm` and capture the raised exception (or `nothing` if it did not
# raise). One formal arg `:__x` (i32) by default.
# ---------------------------------------------------------------------
function _faillow_raise(insts, term; args=[(:__x, 32)], ret=[32])
    blk = Bennett.IRBasicBlock(:entry, Bennett.IRInst[insts...], term)
    parsed = Bennett.ParsedIR(32, args, [blk], ret)
    try
        lower_vm(parsed; opts=:fail_loud)
        return nothing
    catch e
        return e
    end
end

_faillow_ret_x() = Bennett.IRRet(Bennett.SSAOperand(:__x), 32)

@testset "clean-fail-loud completeness (bennettvm-0kl; F1 nondeterminism + F2 impossible-CFG/memory)" begin

    # =================================================================
    # F1 — NONDETERMINISM GUARD (the new `_NONDETERMINISTIC_CALLEES`).
    # An IRCall to a nondeterministic callee must reach a SPECIFIC error
    # naming the cause ("nondeterministic"), NOT the generic SoftCall
    # allowlist message. This is the guard `bennettvm-0kl` adds.
    # =================================================================
    @testset "F1 IRCall(rand) → raises naming 'nondeterministic'" begin
        e = _faillow_raise(
            [Bennett.IRCall(:__d, rand,
                            Bennett.IROperand[], Int[], 64)],
            Bennett.IRRet(Bennett.SSAOperand(:__d), 64);
            args=[(:__x, 64)], ret=[64])
        @test e isa ErrorException
        # The message NAMES the cause (Rule 4) — not just "threw something".
        @test occursin("nondeterministic", e.msg)
        @test occursin("rand", e.msg)
        # And it is NOT the generic SoftFloat-allowlist message (the guard
        # fires BEFORE the SoftCall constructor): proves the diagnostic is the
        # specific F1 one, not the misleading one.
        @test !occursin("recognised SoftFloat", e.msg)
    end

    @testset "F1 IRCall(objectid) → raises naming 'nondeterministic'" begin
        # objectid is the CLAUDE.md identity-hashing hallucination callout:
        # a hash of the runtime allocation address, nondeterministic across
        # runs. The ingest-boundary catch for it arriving as a raw IRCall.
        e = _faillow_raise(
            [Bennett.IRCall(:__d, objectid,
                            Bennett.IROperand[Bennett.SSAOperand(:__x)],
                            [64], 64)],
            Bennett.IRRet(Bennett.SSAOperand(:__d), 64);
            args=[(:__x, 64)], ret=[64])
        @test e isa ErrorException
        @test occursin("nondeterministic", e.msg)
        @test occursin("objectid", e.msg)
        @test !occursin("recognised SoftFloat", e.msg)
    end

    # =================================================================
    # F2 — IMPOSSIBLE-CFG/MEMORY belt-and-suspenders (each already in
    # place; PINNED here as the defensive mirror). Rule 4: each asserts
    # the message NAMES the cause.
    # =================================================================

    # IRPtrOffset LOWERS now (bead `bennettvm-b5x`): the cell-addressed STATIC
    # GEP → `Define(dest, base, :add, element_index)` (ADR 0009 Decision 2b). It
    # is no longer a GAP — but it carries its OWN Rule-1 fail-loud surface: a
    # byte offset that is NOT a whole-element multiple is a sub-element / struct
    # offset, out of scope (BG3 / U16), and must reject rather than silently
    # misaddress. (The full COVERED round-trip lives in test_ptroffset.jl; here
    # we pin the fail-loud half from the completeness angle.) off=3, ew=32:
    # 3 % 4 != 0.
    @testset "F2 IRPtrOffset sub-element offset → rejects naming the scope" begin
        e = _faillow_raise(
            [Bennett.IRAlloca(:__a, 32, Bennett.ConstOperand(4)),
             Bennett.IRPtrOffset(:__d, Bennett.SSAOperand(:__x), 3, 32)],
            _faillow_ret_x())
        @test e isa ErrorException
        @test occursin("IRPtrOffset", e.msg)
        @test occursin("sub-element", e.msg)   # Rule 4 — names the cause
        @test occursin("out of scope", e.msg)
    end

    # IRExtractValue / IRInsertValue now LOWER (bead `bennettvm-acq`): a
    # scalar-CONSUMED build/read chain lowers cleanly. What stays DEFERRED is a
    # RETURNED aggregate — the decomposed per-slot family cannot dangle into the
    # symbol-only `EndInstruction.returns` (the multi-key return keyed off
    # `ret_elem_widths` is the follow-on bead). The ingest IRRet guard fails
    # loud on it (Rule 1) — this is the fail-loud-completeness surface that
    # replaces the old "extract/insert unsupported" GAP rows.
    @testset "F2 DEFERRED aggregate IRRet → ingest guard names the deferral" begin
        # Build a [2 x i32] aggregate, then RETURN it (the deferred shape).
        agg_block = Bennett.IRBasicBlock(
            :entry,
            Bennett.IRInst[
                Bennett.IRInsertValue(:__a0, Bennett.ZERO_AGG,
                                      Bennett.SSAOperand(:__x), 0, 32, 2),
                Bennett.IRInsertValue(:__a1, Bennett.SSAOperand(:__a0),
                                      Bennett.ConstOperand(7), 1, 32, 2),
            ],
            Bennett.IRRet(Bennett.SSAOperand(:__a1), 64),
        )
        parsed = Bennett.ParsedIR(64, [(:__x, 32)], [agg_block], [32, 32])
        e = try
            lower_vm(parsed; opts=:fail_loud_agg)
            nothing
        catch ex
            ex
        end
        @test e isa ErrorException
        @test occursin("aggregate", e.msg)         # Rule 4 — names the cause
        @test occursin("DEFERRED", e.msg)
        @test occursin("bennettvm-acq", e.msg)
    end

    # And the scalar-consumed chain itself does NOT raise (the positive half of
    # the lift — extract/insert are no longer a GAP). A `[2 x i32]` built, read
    # back into scalars, and a scalar returned lowers to a runnable VMProgram.
    @testset "F2 scalar-consumed extract/insert lowers (no longer a GAP)" begin
        ok_block = Bennett.IRBasicBlock(
            :entry,
            Bennett.IRInst[
                Bennett.IRInsertValue(:__a0, Bennett.ZERO_AGG,
                                      Bennett.SSAOperand(:__x), 0, 32, 2),
                Bennett.IRExtractValue(:__e0, Bennett.SSAOperand(:__a0), 0, 32, 2),
            ],
            Bennett.IRRet(Bennett.SSAOperand(:__e0), 32),
        )
        parsed = Bennett.ParsedIR(32, [(:__x, 32)], [ok_block], [32])
        @test lower_vm(parsed; opts=:fail_loud_ok) isa VMProgram
    end

    # An IRSwitch arriving as a block terminator hits `_successors`' reject.
    # (Switches are frontend-pre-expanded to IRICmp/IRBranch and never reach
    # `lower_vm` in practice — this is the belt-and-suspenders floor if a
    # malformed handoff ever did send one.)
    @testset "F2 IRSwitch terminator → _successors names IRSwitch" begin
        switch_term = Bennett.IRSwitch(
            Bennett.SSAOperand(:__x), 32, :entry,
            Tuple{Bennett.IROperand,Symbol}[(Bennett.ConstOperand(0), :entry)])
        e = _faillow_raise(Bennett.IRInst[], switch_term)
        @test e isa ErrorException
        @test occursin("IRSwitch", e.msg)
        @test occursin("unsupported terminator subtype", e.msg)
    end

    # A non-SSA-operand ptr on IRStore / IRLoad hits the memory-floor reject:
    # a pointer must be an SSAOperand naming an alloca dest (a pointer is an
    # Int64 address in `locals`); address arithmetic via a ConstOperand ptr
    # is the deferred / malformed-GEP shape (Rule 1).
    @testset "F2 IRStore non-SSA ptr → memory-floor reject names IRStore" begin
        e = _faillow_raise(
            [Bennett.IRStore(Bennett.ConstOperand(0),
                             Bennett.SSAOperand(:__x), 32)], _faillow_ret_x())
        @test e isa ErrorException
        @test occursin("IRStore ptr", e.msg)
        @test occursin("memory floor", e.msg)
    end

    @testset "F2 IRLoad non-SSA ptr → memory-floor reject names IRLoad" begin
        e = _faillow_raise(
            [Bennett.IRLoad(:__r, Bennett.ConstOperand(0), 32)],
            Bennett.IRRet(Bennett.SSAOperand(:__r), 32))
        @test e isa ErrorException
        @test occursin("IRLoad ptr", e.msg)
        @test occursin("memory floor", e.msg)
    end

end
