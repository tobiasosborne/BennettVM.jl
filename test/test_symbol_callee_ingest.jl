# test/test_symbol_callee_ingest.jl — Symbol-callee IRCall ingest
# (CW-C2 chunk C, BVM ADR 0020 D5; bead `bennettvm-416r.9`; Bennett-nd45).
#
# # What this file pins (Rule 4 — invariants, not "didn't throw")
#
# Bennett.jl widened `IRCall.callee` from `Function` to
# `Union{Function,Symbol}` (Bennett-k3ej / BVM ADR 0020 D1): a C-track
# `.ll`-sourced callee arrives as a bare `Symbol` (name-only). The BVM IRCall
# arm dispatched on `nameof(inst.callee)` at 8 decision sites — and
# `nameof(::Symbol)` does NOT exist, so a Symbol-callee IRCall would
# MethodError before reaching any dispatch (the chunk-A precondition flagged in
# worklog 078/079). Chunk C replaces every site with `_callee_sym(inst.callee)`
# (`nameof` for a `Function`, identity for a `Symbol`).
#
# These tests assert a Symbol-callee IRCall resolves through BOTH closed-world
# routes the C-track relies on:
#   - `_HEAP_DISPATCH` (`:malloc`) → an `IntrinsicMalloc` (ADR 0018 §C).
#   - guard-5 function table (an in-module callee) → a `CallEnter` (ADR 0019 §2).
# Plus the Float32 / nondeterminism guards still fire on a Symbol callee (the
# dispatch is name-only, so the guards key off `_callee_sym` uniformly), and
# the `_callee_sym` helper itself collapses both callee shapes to a `Symbol`.

using Test
using BennettVM
import Bennett
const _BVc = BennettVM
const _Bc = Bennett

@testset "Symbol-callee IRCall ingest (CW-C2 chunk C / BVM ADR 0020 D5)" begin

    @testset "_callee_sym collapses both IRCall.callee shapes to a Symbol" begin
        # A Function callee names itself via nameof; a Symbol callee is identity.
        @test _BVc._callee_sym(:malloc) === :malloc
        @test _BVc._callee_sym(sin) === :sin
    end

    @testset "Symbol :malloc resolves through _HEAP_DISPATCH → IntrinsicMalloc" begin
        blk = _Bc.IRBasicBlock(:entry,
                _Bc.IRInst[_Bc.IRCall(:p, :malloc,
                                      _Bc.IROperand[_Bc.ConstOperand(32)], [64], 64)],
                _Bc.IRRet(_Bc.ssa(:p), 64))
        pir = _Bc.ParsedIR(64, Tuple{Symbol,Int}[], _Bc.IRBasicBlock[blk], [64])
        prog = _BVc.lower_vm(pir)
        insts = reduce(vcat, [b.instructions for b in prog.blocks];
                       init=_BVc.Instruction[])
        @test any(i -> i isa _BVc.IntrinsicMalloc, insts)
    end

    @testset "Symbol in-module callee resolves through guard-5 → CallEnter" begin
        callee_blk = _Bc.IRBasicBlock(:e,
                _Bc.IRInst[_Bc.IRBinOp(:r, :add, _Bc.ssa(:x), _Bc.ConstOperand(1), 64)],
                _Bc.IRRet(_Bc.ssa(:r), 64))
        callee_pir = _Bc.ParsedIR(64, Tuple{Symbol,Int}[(:x, 64)],
                                  _Bc.IRBasicBlock[callee_blk], [64])
        caller_blk = _Bc.IRBasicBlock(:e,
                _Bc.IRInst[_Bc.IRCall(:z, :inc, _Bc.IROperand[_Bc.ssa(:y)], [64], 64)],
                _Bc.IRRet(_Bc.ssa(:z), 64))
        caller_pir = _Bc.ParsedIR(64, Tuple{Symbol,Int}[(:y, 64)],
                                  _Bc.IRBasicBlock[caller_blk], [64])
        prog = _BVc.lower_vm(Pair{Symbol,_Bc.ParsedIR}[:inc => callee_pir,
                                                       :caller => caller_pir];
                             entry = :caller)
        insts = reduce(vcat, [b.instructions for b in prog.blocks];
                       init=_BVc.Instruction[])
        ces = filter(i -> i isa _BVc.CallEnter, insts)
        @test length(ces) == 1
        @test ces[1].callee === :inc          # _callee_sym carried the Symbol name
    end

    @testset "Symbol void in-module callee → CallEnter with EMPTY targets" begin
        # The C `ht_put` shape: a void callee (empty returns) → empty targets
        # (a `[dest]` target would mismatch the callee's `[]` returns).
        void_blk = _Bc.IRBasicBlock(:e,
                _Bc.IRInst[_Bc.IRStore(_Bc.ssa(:t), _Bc.ssa(:v), 64)],
                _Bc.IRRet())                 # the void IRRet form (ret_width 0)
        void_pir = _Bc.ParsedIR(0, Tuple{Symbol,Int}[(:t, 64), (:v, 64)],
                                _Bc.IRBasicBlock[void_blk], Int[])
        # caller allocates a cell, stores, then calls the void callee.
        caller_blk = _Bc.IRBasicBlock(:e,
                _Bc.IRInst[_Bc.IRAlloca(:c, 64, _Bc.iconst(1)),
                           _Bc.IRCall(:dead, :store_it,
                                      _Bc.IROperand[_Bc.ssa(:c), _Bc.ssa(:w)],
                                      [64, 64], 64)],
                _Bc.IRRet(_Bc.ssa(:w), 64))
        caller_pir = _Bc.ParsedIR(64, Tuple{Symbol,Int}[(:w, 64)],
                                  _Bc.IRBasicBlock[caller_blk], [64])
        prog = _BVc.lower_vm(Pair{Symbol,_Bc.ParsedIR}[:store_it => void_pir,
                                                       :caller => caller_pir];
                             entry = :caller)
        insts = reduce(vcat, [b.instructions for b in prog.blocks];
                       init=_BVc.Instruction[])
        ce = only(filter(i -> i isa _BVc.CallEnter, insts))
        @test ce.callee === :store_it
        @test isempty(ce.targets)             # void callee ⇒ empty targets
    end

    @testset "Symbol nondeterministic callee still fails loud" begin
        # The name-only dispatch routes a Symbol callee through the SAME
        # nondeterminism guard — `:rand` is rejected before SoftCall.
        blk = _Bc.IRBasicBlock(:entry,
                _Bc.IRInst[_Bc.IRCall(:r, :rand, _Bc.IROperand[], Int[], 64)],
                _Bc.IRRet(_Bc.ssa(:r), 64))
        pir = _Bc.ParsedIR(64, Tuple{Symbol,Int}[], _Bc.IRBasicBlock[blk], [64])
        @test_throws ErrorException _BVc.lower_vm(pir)
    end
end
