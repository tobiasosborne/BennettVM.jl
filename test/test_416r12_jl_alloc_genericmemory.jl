# test/test_416r12_jl_alloc_genericmemory.jl — Julia Memory{T} backing-alloc
# ingest (CW-D2; bead `bennettvm-416r.12`).
#
# # What this file pins (Rule 4 — invariants, not "didn't throw")
#
# Bennett.jl (CW-D2) closes the fdict closed-world set by tolerating the modeled
# heap/runtime intrinsics its `rehash!` body reaches — among them
# `jl_alloc_genericmemory_unchecked`, the Julia `Memory{T}` backing allocation.
# Bennett emits it via the generic ptr_cells C-call arm as a bare Symbol-callee
# IRCall carrying `[ptls, nbytes, typ]` (3 args, ptls NOT dropped upstream).
#
# BennettVM ingests that IRCall as a deterministic arena bump-allocation,
# mirroring `IntrinsicGCAlloc` (⇐ `:gc_alloc_obj`) exactly: it DROPS a[1]=ptls
# (a TLS pointer with no VM meaning), takes size=a[2] (the lbot-fused smul
# product, bytes) and tag=a[3] (metadata, STRUCTURALLY UNREAD by any state
# transition — ADR 0021 D3 floor). It inherits the `_ArenaAlloc`
# forward/inverse/predelta machinery, so it reverses for free.
#
#   1. Ingest shape: `_lower_intrinsic_call` of the 3-arg IRCall yields
#      `IntrinsicGCAlloc(:m, <sz>, <typ>)` — ptls dropped, size+tag carried.
#   2. lower_vm end-to-end (single function): the Symbol-callee IRCall routes
#      through `_HEAP_DISPATCH` (NO SoftCall allowlist reject) to the same
#      `IntrinsicGCAlloc` inside the lowered block.
#   3. forward / inverse: arena cursor round-trips (the IntrinsicMalloc idiom).
#   4. Coupling: `Bennett._D1B_MODELED_HEAP_INTRINSICS == BennettVM._HEAP_DISPATCH`
#      — the durable tolerate-here ⟺ ingest-there invariant, machine-checked.
#
# # Ref
#   * `src/ir/ingest_call.jl` — the `:jl_alloc_genericmemory_unchecked` arm +
#     `_HEAP_DISPATCH` membership.
#   * `src/ir/intrinsics.jl` — `IntrinsicGCAlloc` (the shared arena instruction).
#   * `test/test_gc_alloc_obj_ingest.jl` — the sibling `:gc_alloc_obj` test this
#     file mirrors.
#   * `../Bennett.jl/src/extract/julia_set.jl` — `_D1B_MODELED_HEAP_INTRINSICS`.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known values), Rule 11 (literate).

using Test
using BennettVM
import Bennett

const _BVm = BennettVM
const _ABm = BennettVM.ARENA_BASE
const _Bm  = Bennett

@testset "jl_alloc_genericmemory_unchecked → IntrinsicGCAlloc arena ingest (CW-D2)" begin

    # ------------------------------------------------------------------
    # (1) Ingest shape: 3-arg IRCall [ptls, sz, typ] → IntrinsicGCAlloc,
    #     ptls DROPPED, size=a[2], tag=a[3].
    # ------------------------------------------------------------------
    @testset "ingest: IRCall([ptls, sz, typ]) → IntrinsicGCAlloc(:m, sz, typ) (ptls dropped)" begin
        # size=64 (const), tag=99 (const), ptls an SSA ref that MUST be dropped.
        call = _Bm.IRCall(:m, :jl_alloc_genericmemory_unchecked,
                          _Bm.IROperand[_Bm.ssa(:ptls), _Bm.iconst(64), _Bm.iconst(99)],
                          [64, 64, 64], 64)
        instr = _BVm._lower_intrinsic_call(call, :jl_alloc_genericmemory_unchecked)
        @test instr isa _BVm.IntrinsicGCAlloc
        @test instr.dest === :m
        @test instr.nbytes_operand == Int64(64)     # a[2], the byte size
        @test instr.type_tag == Int64(99)           # a[3], metadata only
        # ptls (a[1]) is dropped — it never becomes nbytes or tag.
        @test instr.nbytes_operand !== :ptls
        @test instr.type_tag !== :ptls
        # membership: it IS in the heap dispatch whitelist (so the arm routes it).
        @test :jl_alloc_genericmemory_unchecked in _BVm._HEAP_DISPATCH
    end

    @testset "ingest: SSA-bound size/tag carried as Symbols (tag still unread)" begin
        call = _Bm.IRCall(:m, :jl_alloc_genericmemory_unchecked,
                          _Bm.IROperand[_Bm.ssa(:ptls), _Bm.ssa(:sz), _Bm.ssa(:typ)],
                          [64, 64, 64], 64)
        instr = _BVm._lower_intrinsic_call(call, :jl_alloc_genericmemory_unchecked)
        @test instr isa _BVm.IntrinsicGCAlloc
        @test instr.nbytes_operand === :sz          # a[2] SSA ref preserved
        @test instr.type_tag === :typ               # a[3] SSA ref preserved (metadata)
    end

    @testset "ingest: wrong arity fails loud (Rule 1)" begin
        # 2 args (the gc_alloc_obj shape, or any non-3 arity) → _need(3) raises.
        bad = _Bm.IRCall(:m, :jl_alloc_genericmemory_unchecked,
                         _Bm.IROperand[_Bm.iconst(64), _Bm.iconst(99)], [64, 64], 64)
        @test_throws ErrorException _BVm._lower_intrinsic_call(
            bad, :jl_alloc_genericmemory_unchecked)
    end

    # ------------------------------------------------------------------
    # (2) lower_vm end-to-end (single function): the Symbol-callee IRCall
    #     routes through _HEAP_DISPATCH, NO SoftCall allowlist reject.
    # ------------------------------------------------------------------
    @testset "lower_vm: single-function Memory-alloc lowers to IntrinsicGCAlloc" begin
        # ptls / sz / typ are function params (defined at the boundary). The
        # entry block calls the allocator into :m, then returns :m.
        call = _Bm.IRCall(:m, :jl_alloc_genericmemory_unchecked,
                          _Bm.IROperand[_Bm.ssa(:ptls), _Bm.ssa(:sz), _Bm.ssa(:typ)],
                          [64, 64, 64], 64)
        blk = _Bm.IRBasicBlock(:entry, _Bm.IRInst[call],
                               _Bm.IRRet(_Bm.SSAOperand(:m), 64))
        parsed = _Bm.ParsedIR(64, [(:ptls, 64), (:sz, 64), (:typ, 64)], [blk], [64])

        prog = _BVm.lower_vm(parsed)                 # MUST NOT throw (no allowlist reject)
        # find the lowered IntrinsicGCAlloc for :m among the merged blocks.
        allocs = _BVm.IntrinsicGCAlloc[]
        for b in prog.blocks, i in b.instructions
            i isa _BVm.IntrinsicGCAlloc && push!(allocs, i)
        end
        @test length(allocs) == 1
        a = allocs[1]
        @test a.dest === :m
        @test a.nbytes_operand === :sz               # a[2] bound to :sz
        @test a.type_tag === :typ                    # a[3] bound to :typ (ptls dropped)
    end

    # ------------------------------------------------------------------
    # (3) forward / inverse round-trip through the arena path (reverses for free).
    # ------------------------------------------------------------------
    @testset "forward+inverse: arena cursor round-trips" begin
        IS = _BVm.IState
        s = IS(1, Dict{Symbol,Int64}(), :running, Dict{Int64,Int64}())
        pre = deepcopy(s)
        instr = _BVm.IntrinsicGCAlloc(:m, Int64(64), Int64(99))  # 64 bytes = 8 cells
        p = _BVm.predelta_payload(instr, s)          # PRE-forward L2 capture
        _BVm.forward(instr, s)
        @test _BVm.active_locals(s)[:m] == _ABm      # first alloc → ARENA_BASE + 0
        @test s.arena_top == 8                        # 64 ÷ 8 = 8 cells
        _BVm.inverse(instr, s, p)
        @test s == pre                                # bit-identical to pre-forward
        @test s.arena_top == 0
        @test !haskey(_BVm.active_locals(s), :m)
    end

    # ------------------------------------------------------------------
    # (4) Coupling — the durable invariant: tolerate-here ⟺ ingest-there.
    #     Bennett's closed-world classifier set MUST equal BVM's heap dispatch.
    # ------------------------------------------------------------------
    @testset "coupling: Bennett._D1B_MODELED_HEAP_INTRINSICS == BennettVM._HEAP_DISPATCH" begin
        @test Set(_Bm._D1B_MODELED_HEAP_INTRINSICS) == _BVm._HEAP_DISPATCH
        # the allocator this bead added is present on BOTH sides.
        @test :jl_alloc_genericmemory_unchecked in _Bm._D1B_MODELED_HEAP_INTRINSICS
        @test :jl_alloc_genericmemory_unchecked in _BVm._HEAP_DISPATCH
    end

    # ------------------------------------------------------------------
    # (5) End-to-end fdict set — NOT lowered here. The CLOSED 4-body set from
    #     Bennett (`extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
    #     ptr_cells=true)`) does NOT yet survive `lower_vm(set)`. The `#`-in-key
    #     reject (blocker 0 — the canonical keys are `<barename>#<digest>`) is now
    #     CLEARED by bead `bennettvm-5m1t` (`_vm_funcname` de-digests keys +
    #     `_vm_dispatch_name` sanitises the closure '#'; see
    #     `test_5m1t_content_addressed_keys.jl`). The `julia.get_pgcstack` SoftCall
    #     reject AND the negative-offset GC-preamble GEP guard are now cleared by
    #     bead `bennettvm-p81t` (2026-07-10; `_BENIGN_CELL_DISPATCH` +
    #     `TLS_BASE`); the set now dies at a const-cond `IRSelect` wall (NOT
    #     const-globals as the 416r.12 handoff predicted — the IRSelect const-cond
    #     wall precedes it). Those are separate follow-up beads, NOT this bead's
    #     scope. This test deliberately does NOT feed the full set to lower_vm.
    # ------------------------------------------------------------------

end
