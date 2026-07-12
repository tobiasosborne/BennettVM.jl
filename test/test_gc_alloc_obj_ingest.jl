# test/test_gc_alloc_obj_ingest.jl — Julia typed-GC arena ingest
# (CW-D3 Lever 3; Bennett-iwo9 consensus decision 5; ADR 0021 D3 floor;
# bead `bennettvm-416r.12` gc_alloc_obj PART).
#
# # What this file pins (Rule 4 — invariants, not "didn't throw")
#
# Bennett.jl (CW-D3 Lever 2) emits, for `julia.gc_alloc_obj`, the Symbol-callee
# `IRCall(:obj, :gc_alloc_obj, [size_op, tag_op], [64, 64], 64)` (the `task`
# arg dropped). BennettVM ingests that IRCall as a deterministic arena
# bump-allocation, mirroring `IntrinsicMalloc` exactly, while the TYPE TAG is
# IGNORED (ADR 0021 D3 floor): the tag is carried as metadata but is
# STRUCTURALLY UNREAD by any state transition (`forward` / `inverse` read only
# `dest` / `nbytes_operand`). No JIT type-tag address ever influences VM state.
#
#   1. Ingest shape: `_lower_intrinsic_call` of the gc_alloc_obj IRCall yields
#      an `IntrinsicGCAlloc(:obj, 64, <tag>)` (size+tag both lowered as values).
#   2. forward: from a fresh IState, binds `:obj == ARENA_BASE + 0` and bumps
#      `arena_top` by 64 BYTE-cells. (CW-D4 / bead `bennettvm-9n3y`: was
#      `64 ÷ 8 = 8` word-cells — defect D-b. Julia boxed-struct fields are
#      BYTE-offset `i8` GEPs (a 64-byte Dict addresses cells +0..+56), so the
#      reservation must cover `nbytes` cells or the next allocation lands
#      INSIDE the struct's field footprint — the fdict header clobber.)
#   3. inverse round-trip: `inverse` restores `arena_top → 0`, removes `:obj`
#      from active_locals, and the IState equals the pre-forward state.
#   4. tag-invariance (THE soundness witness): the SAME alloc run with THREE
#      different tag values (0, 1, 99 as const, plus an SSA-bound tag) yields a
#      BIT-IDENTICAL IState in all cases — the tag never affects state. This is
#      the ADR 0021 D3 floor expressed as a test: a type tag is metadata only.
#
# # Ref
#   * `../Bennett.jl/docs/design/Bennett-iwo9-CW-D3-typetag-consensus.md`
#     decision 5 — the BennettVM ingest contract (tag IGNORED).
#   * `src/ir/intrinsics.jl` — `IntrinsicGCAlloc` (the instruction under test;
#     mirror of `IntrinsicMalloc`).
#   * `src/ir/ingest_call.jl` — the `:gc_alloc_obj` `_HEAP_DISPATCH` arm.
#   * `test/test_arena_roundtrip.jl` — the IntrinsicMalloc forward/inverse idiom
#     this file mirrors.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known values), Rule 11 (literate).

using Test
using BennettVM
import Bennett

const _BVg = BennettVM
const _ABg = BennettVM.ARENA_BASE
const _Bg  = Bennett

@testset "gc_alloc_obj → IntrinsicGCAlloc arena ingest (CW-D3 Lever 3; ADR 0021 D3)" begin

    # ------------------------------------------------------------------
    # (1) Ingest shape: the gc_alloc_obj IRCall lowers to IntrinsicGCAlloc.
    # ------------------------------------------------------------------
    @testset "ingest: IRCall(:gc_alloc_obj, [64, tag]) → IntrinsicGCAlloc(:obj, 64, tag)" begin
        # The Lever-2 shape: size=64 (const), tag=99 (const). task arg dropped.
        call = _Bg.IRCall(:obj, :gc_alloc_obj,
                          _Bg.IROperand[_Bg.iconst(64), _Bg.iconst(99)], [64, 64], 64)
        instr = _BVg._lower_intrinsic_call(call, :gc_alloc_obj)
        @test instr isa _BVg.IntrinsicGCAlloc
        @test instr.dest === :obj
        @test instr.nbytes_operand == Int64(64)
        @test instr.type_tag == Int64(99)
        # gc_alloc_obj IS in the heap dispatch whitelist (so the IRCall arm routes it).
        @test :gc_alloc_obj in _BVg._HEAP_DISPATCH
    end

    @testset "ingest: SSA-bound tag operand carried as a Symbol (still unread)" begin
        call = _Bg.IRCall(:obj, :gc_alloc_obj,
                          _Bg.IROperand[_Bg.iconst(64), _Bg.ssa(:tagref)], [64, 64], 64)
        instr = _BVg._lower_intrinsic_call(call, :gc_alloc_obj)
        @test instr isa _BVg.IntrinsicGCAlloc
        @test instr.nbytes_operand == Int64(64)
        @test instr.type_tag === :tagref       # SSA ref preserved as metadata
    end

    @testset "ingest: wrong arity fails loud (Rule 1)" begin
        # 3 args (the task-included shape, or any non-2 arity) → _need(2) raises.
        bad = _Bg.IRCall(:obj, :gc_alloc_obj,
                         _Bg.IROperand[_Bg.iconst(64)], [64], 64)
        @test_throws ErrorException _BVg._lower_intrinsic_call(bad, :gc_alloc_obj)
    end

    # ------------------------------------------------------------------
    # (2) forward: binds :obj == ARENA_BASE + 0, bumps arena_top by 64
    #     BYTE-cells (CW-D4 byte-granular Julia tier; was ÷8 = 8).
    # ------------------------------------------------------------------
    @testset "forward: binds ARENA_BASE, bumps arena_top by 64 byte-cells" begin
        IS = _BVg.IState
        s = IS(1, Dict{Symbol,Int64}(), :running, Dict{Int64,Int64}())
        instr = _BVg.IntrinsicGCAlloc(:obj, Int64(64), Int64(99))
        _BVg.forward(instr, s)
        @test _BVg.active_locals(s)[:obj] == _ABg        # first alloc → ARENA_BASE + 0
        @test s.arena_top == 64                           # 64 bytes = 64 BYTE-cells (CW-D4)
        @test s.pc == 2                                   # pc bumped
        @test isempty(s.memory)                           # region stays absent (no zeroing)
    end

    # ------------------------------------------------------------------
    # (3) inverse round-trip: restores arena_top → 0, removes :obj.
    # ------------------------------------------------------------------
    @testset "inverse round-trip: arena_top → 0, :obj removed, IState restored" begin
        IS = _BVg.IState
        s = IS(1, Dict{Symbol,Int64}(), :running, Dict{Int64,Int64}())
        pre = deepcopy(s)
        instr = _BVg.IntrinsicGCAlloc(:obj, Int64(64), Int64(99))
        p = _BVg.predelta_payload(instr, s)               # PRE-forward L2 capture
        _BVg.forward(instr, s)
        _BVg.inverse(instr, s, p)
        @test s == pre                                    # bit-identical to pre-forward
        @test s.arena_top == 0
        @test !haskey(_BVg.active_locals(s), :obj)
        @test isempty(s.memory)                           # no phantom {addr=>0}
    end

    # ------------------------------------------------------------------
    # (4) tag-invariance — THE soundness witness (ADR 0021 D3 floor).
    #     The SAME alloc with DIFFERENT tags ⇒ bit-identical post-forward IState.
    # ------------------------------------------------------------------
    @testset "tag-invariance: tag never affects post-forward IState" begin
        IS = _BVg.IState
        # Build a fresh state, run an IntrinsicGCAlloc with the given tag, return
        # the resulting post-forward IState.
        function _forward_with_tag(tag)
            s = IS(1, Dict{Symbol,Int64}(), :running, Dict{Int64,Int64}())
            # For an SSA-bound tag, the tag SSA value lives in locals; binding a
            # WILDLY different value proves it is never consulted.
            if tag isa Symbol
                _BVg.active_locals(s)[tag] = Int64(123456789)
            end
            instr = _BVg.IntrinsicGCAlloc(:obj, Int64(64), tag)
            _BVg.forward(instr, s)
            return s
        end

        s0  = _forward_with_tag(Int64(0))
        s1  = _forward_with_tag(Int64(1))
        s99 = _forward_with_tag(Int64(99))

        # All three const-tag runs produce bit-identical IStates (uses BennettVM's
        # IState ==/hash override, which sees pc/locals/memory/arena_top).
        @test s0 == s1
        @test s1 == s99
        @test hash(s0) == hash(s1) == hash(s99)

        # An SSA-bound tag (with a junk value in locals UNDER the tag name) differs
        # from the const runs ONLY by the extra `:tagref` binding — strip it and
        # the alloc-relevant state (the :obj binding + arena_top) is identical.
        s_ssa = _forward_with_tag(:tagref)
        @test _BVg.active_locals(s_ssa)[:obj] == _ABg
        @test s_ssa.arena_top == s0.arena_top == 64   # byte-cells (CW-D4)
        # The tag's junk value never leaked into the arena or the :obj address.
        @test _BVg.active_locals(s_ssa)[:obj] == _BVg.active_locals(s0)[:obj]
    end
end
