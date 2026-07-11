# BennettVM bennettvm-416r.16 — consumed-sret value-ABI bridge, CROSS-BLOCK.
#
# The Bennett front-end (extract/sret.jl) reconciles `setindex!`'s consumed
# sret-out box call into the VALUE ABI: a `{i64,i8}`-returning callee called by
# value (ret_width = 72 = sum([64,8])) whose result fields are read by
# `IRExtractValue`. The Bennett side pins the REWRITE; this test pins the BVM
# INGEST + runtime of the resulting shape, with the field reads spread ACROSS
# BLOCKS (field 0 read in TWO different blocks, field 1 in a later block) — the
# cross-block slot-family liveness the real setindex! body exercises (its box
# field-0 loads land in blocks `top`, `L8`, `L24`; the field-1 read in a later
# block). Full run!/unrun! round-trip vs a known-correct oracle (Rule 4).
#
# Ref: ../Bennett.jl/src/extract/sret.jl (the reconciliation);
#      src/ir/ingest.jl (IRExtractValue slot-copy + agg_dests);
#      test/test_x3t0_multikey_return.jl (the value-ABI idiom mirrored).

using Test
using BennettVM
import Bennett
const _BV = BennettVM
const _B = Bennett

# Callee whose `nameof` is the guard-5 callee identity in the hand-built set.
function bridge_pair end

# Callee `bridge_pair(x)`: builds {i64,i8} = (2x, x+1) via a ZERO_AGG-rooted
# ascending IRInsertBits chain, returns it BY VALUE (ret_width 72 = sum([64,8])).
# Asymmetric fields so a slot mis-order changes the observable result.
function _bridge_pair_ir()
    blk = _B.IRBasicBlock(:top,
        _B.IRInst[
            _B.IRBinOp(:f0, :mul, _B.SSAOperand(:x), _B.ConstOperand(2), 64),
            _B.IRBinOp(:f1, :add, _B.SSAOperand(:x), _B.ConstOperand(1), 64),
            _B.IRInsertBits(:agg0, _B.ZERO_AGG, _B.SSAOperand(:f0), 0, 64, 72),
            _B.IRInsertBits(:agg1, _B.SSAOperand(:agg0), _B.SSAOperand(:f1), 64, 8, 72)],
        _B.IRRet(_B.SSAOperand(:agg1), 72))
    return _B.ParsedIR(72, Tuple{Symbol,Int}[(:x, 64)], [blk], Int[64, 8])
end

# Caller `usebridge(n)`: value-ABI call to bridge_pair in block `top`, then read
# the aggregate slots ACROSS THREE BLOCKS:
#   * `top`: e0a := extractvalue(v, 0)          (field 0, block 1)
#   * `mid`: e0b := extractvalue(v, 0)          (field 0 AGAIN, block 2)
#   * `fin`: e1  := extractvalue(v, 1)          (field 1, block 3)
#            s := e0a + e0b + 100*e1
# Straight-line unconditional branches (no φ) — the cross-block reads exercise
# the aggregate slot family's liveness across the CallEnter's landing block into
# its successors. Oracle: e0a = e0b = 2n, e1 = n+1 ⇒ s = 4n + 100(n+1) = 104n+100.
function _bridge_use_module()
    b_top = _B.IRBasicBlock(:top,
        _B.IRInst[
            _B.IRCall(:v, bridge_pair, _B.IROperand[_B.SSAOperand(:n)], Int[64], 72),
            _B.IRExtractValue(:e0a, _B.SSAOperand(:v), 0, 0, 2, Int[64, 8])],
        _B.IRBranch(nothing, :mid, nothing))
    b_mid = _B.IRBasicBlock(:mid,
        _B.IRInst[
            _B.IRExtractValue(:e0b, _B.SSAOperand(:v), 0, 0, 2, Int[64, 8])],
        _B.IRBranch(nothing, :fin, nothing))
    b_fin = _B.IRBasicBlock(:fin,
        _B.IRInst[
            _B.IRExtractValue(:e1, _B.SSAOperand(:v), 1, 0, 2, Int[64, 8]),
            _B.IRBinOp(:e1s, :mul, _B.SSAOperand(:e1), _B.ConstOperand(100), 64),
            _B.IRBinOp(:t, :add, _B.SSAOperand(:e0a), _B.SSAOperand(:e0b), 64),
            _B.IRBinOp(:s, :add, _B.SSAOperand(:t), _B.SSAOperand(:e1s), 64)],
        _B.IRRet(_B.SSAOperand(:s), 64))
    use_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:n, 64)], [b_top, b_mid, b_fin], Int[64])
    return _BV.lower_vm(Pair{Symbol,_B.ParsedIR}[:usebridge => use_ir,
                                                 :bridge_pair => _bridge_pair_ir()];
                        entry = :usebridge)
end
_bridge_oracle(n) = 4n + 100 * (n + 1)

_bfind_block(prog, lbl) = prog.blocks[findfirst(b -> b.label === lbl, prog.blocks)]

@testset "bennettvm-416r.16 consumed-sret value-ABI bridge (cross-block)" begin
    prog = _bridge_use_module()
    @test prog isa _BV.VMProgram

    # Structural: the call dest `:v` is a value-ABI multi-return token, so the
    # CallEnter lands its 2-slot family and the cross-block IRExtractValues read
    # from that same family in `top`, `mid`, and `fin`.
    top_blk = _bfind_block(prog, Symbol("usebridge#top"))
    ce = top_blk.instructions[findfirst(i -> i isa _BV.CallEnter, top_blk.instructions)]
    @test ce.targets == Symbol[_BV._agg_slot_name(:v, 0), _BV._agg_slot_name(:v, 1)]
    # bridge_pair's End returns its terminal aggregate's 2-slot family.
    bp_blk = _bfind_block(prog, Symbol("bridge_pair#top"))
    @test bp_blk.exit isa _BV.EndInstruction
    @test bp_blk.exit.returns ==
          Symbol[_BV._agg_slot_name(:agg1, 0), _BV._agg_slot_name(:agg1, 1)]

    # Runtime round-trip vs oracle (Rule 4): forward run to halt, then unrun to
    # empty history + single frame + the exact initial state.
    mc = _BV.compute_must_cache(prog)
    for n in Int64[0, 1, 5, 42, -3]
        rs = _BV.initial_state(prog, Dict(:n => n))
        init = deepcopy(rs.current)
        _BV.run!(rs, prog; max_steps = 100_000, checkpoint_interval = typemax(Int),
                 must_cache_set = mc)
        @test _BV.is_halted(rs)
        @test _BV.result(rs)[:s] == _bridge_oracle(n)   # pins slot ORDER + x-block liveness
        _BV.unrun!(rs, prog; max_unsteps = 100_000)
        @test isempty(rs.history)
        @test length(rs.current.frames) == 1
        @test rs.current == init
    end
end
