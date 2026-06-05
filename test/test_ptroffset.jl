# test/test_ptroffset.jl — cell-addressed STATIC GEP ingest (`IRPtrOffset`)
# round-trip gate (bead `bennettvm-b5x`; Bennett.jl field `Bennett-xv0u`;
# ADR 0009 Decision 2b).
#
# # What this file pins, and why it is load-bearing
#
# `IRPtrOffset(dest, base, offset_bytes, elem_width)` is Bennett.jl's
# CONSTANT-offset pointer create — the static-index analogue of `IRVarGEP`
# (the runtime-index create already covered by `test_array_floor.jl`). Until
# this bead it was the sole remaining GAP `IRInst` subtype, falling through
# `_lower_body_inst`'s shared fail-loud `else`. The cell-addressed VM
# (`IState.memory` is `Dict{Int64,Int64}` — ONE Int64 per cell, NOT a byte
# array) reserves one cell per ELEMENT (VarGEP stride 1; `test_array_floor.jl`
# "Addressing convention"). So the cell offset is the ELEMENT INDEX, not the
# byte offset.
#
# Bennett.jl stores the offset in BYTES (`offset_bytes`, the circuit-backend
# unit) plus the source element bit width (`elem_width`, the additive
# `Bennett-xv0u` field the circuit backend ignores). The element index is
# therefore `offset_bytes ÷ (elem_width ÷ 8)` — and WITHOUT `elem_width` a
# non-i64 array's byte offset would be mis-divided (a latent silent
# miscompile: an i32 array's `offset_bytes=8` is element 2, not 8). This file
# is the executable proof the recovery is correct AND that the sub-element /
# non-SSA-base cases fail loud rather than misaddress (Rule 1, Rule 2).
#
# # The program (hand-built ParsedIR; oracle = a known value, Rule 4)
#
#   alloca i32 [N=4]; arr[2] = 99 (via IRPtrOffset off=8 bytes, ew=32 →
#   element index 2); r = load arr[2]; ret r          oracle: f(x) = 99
#
# `offset_bytes=8, elem_width=32` is the b5x trap in miniature: a hardcoded
# `÷8` would yield element 1 (wrong cell); a no-division byte-addressed VM
# would index cell 8 (out of the 4 reserved). The correct cell is `base + 2`.
#
# # The fail-loud gates (Rule 1 — every reject NAMES the cause)
#
#   * off=3, ew=32 — 3 not divisible by 4 (element byte width) → a sub-element
#     / struct offset, out of scope (BG3 / U16). Must raise naming the scope.
#   * a non-SSAOperand base (ConstOperand) → a malformed GEP shape. Must raise
#     naming the base type.
#   * ew=0 / sub-byte ew — not a whole positive byte count → cannot recover an
#     index. Must raise (defensive; mem=:vm never emits it, but the ingest
#     guard is the firewall).
#
# # Ref
#   * `src/ir/ingest.jl` — the `IRPtrOffset` arm of `_lower_body_inst` (the
#     code under test), mirroring the `IRVarGEP` arm (stride-1 cell address).
#   * `src/ir/define_instruction.jl` — `Define(dest, base, :add, k)` is
#     `locals[dest] = locals[base] + k` (the lowered form here).
#   * `../Bennett.jl/src/ir_types.jl:144` — the `IRPtrOffset` struct (4 fields).
#   * `test/test_array_floor.jl` — the IRVarGEP round-trip idiom reused here.
#   * `docs/coverage-matrix.md` — IRPtrOffset row (now COVERED).
#   * CLAUDE.md Rule 1 (fail loud), Rule 2 (root-cause, no bandaid), Rule 4
#     (known value / specific error), Rule 11 (literate), P0.6 (round-trip to
#     empty history).

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# Lower a single-block fragment and capture the raised exception (or `nothing`
# if it did not raise). Same idiom as test_opcode_coverage.jl's `_coverage_raise`.
function _ptroff_raise(insts, term; args=[(:__x, 32)], ret=[32])
    blk = Bennett.IRBasicBlock(:entry, Bennett.IRInst[insts...], term)
    parsed = Bennett.ParsedIR(32, args, [blk], ret)
    try
        lower_vm(parsed; opts=:ptroffset)
        return nothing
    catch e
        return e
    end
end

@testset "IRPtrOffset cell-addressed static GEP (bennettvm-b5x / Bennett-xv0u)" begin

    # =================================================================
    # (1) Lowering shape — IRPtrOffset(off=8, ew=32) → Define(:add, 2).
    #     The element index 2 = 8 bytes ÷ (32÷8 bytes). NOT 8 (byte-
    #     addressed), NOT 1 (hardcoded ÷8). This is the b5x trap pinned.
    # =================================================================
    @testset "(1) lowers to Define(dest, base, :add, element_index)" begin
        blk = Bennett.IRBasicBlock(
            :entry,
            Bennett.IRInst[
                Bennett.IRAlloca(:__arr, 32, Bennett.ConstOperand(4)),
                # gep arr + 8 bytes, i32 elements → element index 2.
                Bennett.IRPtrOffset(:__gep, Bennett.SSAOperand(:__arr), 8, 32),
            ],
            Bennett.IRRet(Bennett.SSAOperand(:__gep), 32),
        )
        parsed = Bennett.ParsedIR(32, [(:__x, 32)], [blk], [32])
        vm = lower_vm(parsed; opts=:ptroffset)

        # Find the lowered IRPtrOffset → it must be Define(:__gep,:__arr,:add,2).
        defs = [i for i in first(vm.blocks).instructions
                if i isa BennettVM.Define && i.target == :__gep]
        @test length(defs) == 1
        d = defs[1]
        @test d.lhs == :__arr            # base
        @test d.op == :add
        @test d.rhs == Int64(2)          # ELEMENT INDEX (8 ÷ (32÷8)), the b5x fix
    end

    # =================================================================
    # (2) Forward semantics — locals[gep] == locals[arr] + 2 (element 2).
    #     The bump allocator gives arr base = 1, so gep = 3 (cell base+2).
    # =================================================================
    @testset "(2) forward — locals[gep] == locals[arr] + element_index" begin
        blk = Bennett.IRBasicBlock(
            :entry,
            Bennett.IRInst[
                Bennett.IRAlloca(:__arr, 32, Bennett.ConstOperand(4)),
                Bennett.IRPtrOffset(:__gep, Bennett.SSAOperand(:__arr), 8, 32),
            ],
            Bennett.IRRet(Bennett.SSAOperand(:__gep), 32),
        )
        parsed = Bennett.ParsedIR(32, [(:__x, 32)], [blk], [32])
        vm = lower_vm(parsed; opts=:ptroffset)
        rs = initial_state(vm, Dict(:__x => Int64(0)))
        run!(rs, vm; checkpoint_interval=4)
        r = result(rs)
        @test r[:__arr] == 1                 # alloca base (bump cursor start)
        @test r[:__gep] == r[:__arr] + 2     # base + element index 2 (cell base+2)
        @test r[:__gep] == 3
    end

    # =================================================================
    # (3) END-TO-END round-trip vs an irreversible oracle (P0.6).
    #     alloca i32[4]; arr[2] = 99 (IRPtrOffset off=8, ew=32); r = load
    #     arr[2]; ret r.  Oracle: f(x) = 99 for every input. Forward result
    #     bit-exact, then run!/unrun! drains to empty history.
    # =================================================================
    @testset "(3) write+read-back via IRPtrOffset round-trips (P0.6)" begin
        block = Bennett.IRBasicBlock(
            :entry,
            Bennett.IRInst[
                Bennett.IRAlloca(:__arr, 32, Bennett.ConstOperand(4)),
                # p = gep(arr, element 2) via byte offset 8, i32 elements.
                Bennett.IRPtrOffset(:__p, Bennett.SSAOperand(:__arr), 8, 32),
                # arr[2] = 99
                Bennett.IRStore(Bennett.SSAOperand(:__p),
                                Bennett.ConstOperand(99), 32),
                # q = gep(arr, element 2) AGAIN (distinct SSA name; same cell)
                Bennett.IRPtrOffset(:__q, Bennett.SSAOperand(:__arr), 8, 32),
                # r = load arr[2]  → reads back 99
                Bennett.IRLoad(:__r, Bennett.SSAOperand(:__q), 32),
            ],
            Bennett.IRRet(Bennett.SSAOperand(:__r), 32),
        )
        parsed = Bennett.ParsedIR(32, [(:__x, 32)], [block], [32])
        vm = lower_vm(parsed; opts=:ptroffset)

        # Irreversible oracle (Rule 4 — assert vs a known value, not "no throw").
        ptroff_oracle(_x) = 99

        for x in (Int64(0), Int64(1), Int64(-7), Int64(123))
            rs = initial_state(vm, Dict(:__x => x))
            run!(rs, vm; checkpoint_interval=4)
            @test is_halted(rs)
            @test result(rs)[:__r] == ptroff_oracle(x)   # 99, bit-exact
            @test result(rs)[:__p] == 3                   # arr[2] @ cell base+2
            @test result(rs)[:__q] == 3                   # same cell, distinct SSA

            unrun!(rs, vm)
            @test rs.current == rs.initial                # P0.6 — reversed to start
            @test isempty(rs.history)                     # P0.6 — history drained
            @test rs.step_count == 0                      # P0.6 — counter reset
        end

        # Per-step inverse (L3) at two checkpoint densities — catches a mid-
        # program reversal bug the aggregate round-trip can mask.
        for K in (1, 4)
            @test per_step_inverse_check(
                vm, Dict(:__x => Int64(5));
                checkpoint_interval = K,
                label = "ptroffset/K=$K") === nothing
        end
    end

    # =================================================================
    # (4) FAIL-LOUD: sub-element offset (off not divisible by element byte
    #     width) → out of scope (BG3 / U16). off=3, ew=32: 3 % 4 != 0.
    # =================================================================
    @testset "(4) sub-element offset rejects loud (BG3/U16)" begin
        e = _ptroff_raise(
            [Bennett.IRAlloca(:__arr, 32, Bennett.ConstOperand(4)),
             Bennett.IRPtrOffset(:__gep, Bennett.SSAOperand(:__arr), 3, 32)],
            Bennett.IRRet(Bennett.SSAOperand(:__arr), 32))
        @test e isa ErrorException
        # Rule 4 — the message NAMES the cause (sub-element / out of scope),
        # not a bare "threw something".
        @test occursin("sub-element", e.msg)
        @test occursin("out of scope", e.msg)
        @test occursin("IRPtrOffset", e.msg)
    end

    # =================================================================
    # (5) FAIL-LOUD: a non-SSAOperand base (a malformed GEP shape) → reject.
    # =================================================================
    @testset "(5) non-SSAOperand base rejects loud" begin
        e = _ptroff_raise(
            [Bennett.IRPtrOffset(:__gep, Bennett.ConstOperand(7), 8, 32)],
            Bennett.IRRet(Bennett.SSAOperand(:__x), 32))
        @test e isa ErrorException
        @test occursin("IRPtrOffset base", e.msg)
        @test occursin("SSAOperand", e.msg)
    end

    # =================================================================
    # (6) FAIL-LOUD: a non-whole-byte element width (defensive — mem=:vm
    #     never emits it, but the ingest guard is the firewall). ew=4 bits.
    # =================================================================
    @testset "(6) sub-byte elem_width rejects loud" begin
        e = _ptroff_raise(
            [Bennett.IRAlloca(:__arr, 32, Bennett.ConstOperand(4)),
             Bennett.IRPtrOffset(:__gep, Bennett.SSAOperand(:__arr), 8, 4)],
            Bennett.IRRet(Bennett.SSAOperand(:__arr), 32))
        @test e isa ErrorException
        @test occursin("elem_width", e.msg)
        @test occursin("whole positive byte count", e.msg)
    end

    # =================================================================
    # (7) FAIL-LOUD: a negative offset_bytes (defensive — no mem=:vm site
    #     emits one, but a GEP below the alloca base is malformed and must
    #     not silently misaddress; hostile-review nit, bead `bennettvm-b5x`).
    # =================================================================
    @testset "(7) negative offset_bytes rejects loud" begin
        e = _ptroff_raise(
            [Bennett.IRAlloca(:__arr, 32, Bennett.ConstOperand(4)),
             Bennett.IRPtrOffset(:__gep, Bennett.SSAOperand(:__arr), -8, 32)],
            Bennett.IRRet(Bennett.SSAOperand(:__arr), 32))
        @test e isa ErrorException
        @test occursin("negative", e.msg)
        @test occursin("IRPtrOffset", e.msg)
    end
end
