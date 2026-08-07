# test/test_sy29_arena_src_vm.jl — the BennettVM (downstream) half of Bennett.jl
# bead `Bennett-sy29` (xkl frontier wall 9).
#
# # What upstream changed
#
# Bennett.jl's const-size `llvm.memcpy` arm now admits a `julia.gc_alloc_obj`
# ARENA root on EITHER SIDE, under the closed-world `ptr_cells` gate, and stamps
# each side's addresses from that side's OWN allocation scale (`_root_scale`):
#
#   | side                        | scale | IRPtrOffset stamp | cell of elem k |
#   |-----------------------------|-------|-------------------|----------------|
#   | `julia.gc_alloc_obj` (byte) | 1     | 8                 | `base + 8k`    |
#   | `alloca [N x i64]`  (word)  | 8     | 64                | `base + k`     |
#
# while the `IRLoad`/`IRStore` VALUE width stays 64 on BOTH sides — the
# Bennett-4y0d address/value split, applied per side. That is a MIXED-TIER
# pairing in one instruction, which is exactly the shape this file exists to
# execute rather than argue about.
#
# # BennettVM src changes: ZERO. This file is the proof, not the assertion.
#
# The decomposition emits only nodes that already ingest — `IRPtrOffset` →
# `Define(d, b, :add, off ÷ (ew÷8))` (`src/ir/ingest_body.jl:534`), `IRLoad` →
# `MemoryLoad`, `IRStore` → `MemoryStore`, plus the pre-existing
# `IntrinsicGCAlloc` and `StackAlloca`. Gate (2) asserts that as a SET, so a
# future upstream change that reaches for a new node kind turns this red.
#
# Crucially it does NOT emit `IntrinsicMemcpy`. That is deliberate on both sides:
#
#   * BennettVM's `_enforce_julia_heap_tier!`
#     (`src/ir/intrinsics_genericmemory.jl:192-199`) REFUSES `IntrinsicMemcpy` /
#     `IntrinsicMemmove` in any `gc_alloc_obj`-bearing (byte-granular) program,
#     and is right to: `_copy_range!` (`src/ir/intrinsics_bulk.jl:105-113`)
#     strides ONE CELL per element with `cells = nbytes ÷ 8`, which is the WORD
#     tier's map and would copy an eighth of a byte-tier range. So the bulk-call
#     route was never open for this program class (`bennettvm-rxgy` owns the
#     byte-exact successors).
#   * and because no `IntrinsicMemcpy` is emitted, its RUNTIME OVERLAP CHECK
#     (`forward(::IntrinsicMemcpy)`, `intrinsics_bulk.jl:117-121`) is not in the
#     path either. Overlap safety for this route is therefore proven UPSTREAM, at
#     extraction, by the generalised Predicate 7 ("distinct allocation roots") —
#     see gate (6). Contrast Bennett-vau9: `memmove` MAY overlap and routes to
#     `IRCall(:memmove)` precisely because `_copy_range!` snapshots the src range
#     first. memmove delegates overlap safety to the VM; sy29 must prove it.
#
# # What this file pins (Rule 4 — known values, never "didn't throw")
#
#   (1) HANDOFF SHAPE — the per-side stamps as `(offset_bytes, elem_width)`
#       pairs, and the cells they resolve to under BVM's own formula. At K = 2
#       the second element's offset is NON-ZERO, so a collapsed single-stamp
#       emission is visible; at K = 1 it would not be (offset 0 is cell 0 under
#       every stamp — the trap that hid the pre-4y0d vbv9 defect).
#   (2) lower_vm produces ONLY pre-existing instruction kinds, and no bulk-copy
#       intrinsic.
#   (3) ORACLE, BOTH DIRECTIONS — arena→alloca (K = 2) and its alloca→arena
#       mirror (K = 2), on one program, under L2 and L3 history regimes.
#       NON-VACUOUS: the two seeded values are DISTINCT and non-zero, so a
#       byte-tier stamp that collapsed to word cells would read cells `+1`/`+2`
#       of the box (never written) and every assertion below would break.
#   (4) EXACT `unrun!` — the initial `IState` restored bit-for-bit (memory,
#       locals, arena cursor, stack cursor, pc) with a DRAINED history. The
#       Bennett-1973 invariant, which is what makes the arena-DST direction
#       reversible at all: that write is a DESTRUCTIVE overwrite of a live cell,
#       reversed by the history tape and NOT by any freshness precondition
#       (the Bennett-u2kk justification, not vbv9's STEP-0c argument).
#   (5) PER-STEP INVERSE at two checkpoint intervals.
#   (6) THE OVERLAP GUARD IS UPSTREAM — a same-root arena↔arena memcpy is
#       refused at EXTRACTION, so no such program ever reaches this VM. Pinned
#       here (not only upstream) because the reason it must be refused is a
#       BennettVM fact: `forward(::IntrinsicMemcpy)`'s overlap check is not in
#       this route.
#
# # Ref
#   * `../Bennett.jl/test/test_sy29_arena_src_memcpy.jl` — the upstream gate.
#   * `../Bennett.jl/docs/design/sy29_scout.md` — the ratified design.
#   * `../Bennett.jl/src/extract/instructions.jl` — `_handle_memcpy_arm`,
#     `_gc_alloc_root_ref`, `_gc_alloc_root_offset`, `_root_scale`.
#   * `test_bvmd_byte_tier_vm.jl` — the byte-tier sibling; structure mirrored.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known values), Rule 11 (literate).

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

const _BVs = BennettVM
const _BNs = Bennett

# ---------------------------------------------------------------------------
# The fixture. One function, both directions, K = 2 each way.
#
#   leg 1  a 24-byte `julia.gc_alloc_obj` box, seeded at BYTE offsets 8 and 16
#          with two DISTINCT non-zero values
#   leg 2  ARENA → ALLOCA, K = 2: `memcpy(%slot, gep i8 %box 8, 16)`
#          src cells {+8, +16} (byte tier) → dst cells {+0, +1} (word tier)
#   leg 3  ALLOCA → ARENA, K = 2 (the MIRROR, corpus site #6's direction):
#          `memcpy(gep i8 %box 0, %slot, 16)`
#          src cells {+0, +1} (word tier) → dst cells {+0, +8} (byte tier)
#   leg 4  read every cell back through its own tier
#
# ORACLE. `t0 = x`, `t1 = y` (leg 2 read the box's two seeded fields), and after
# leg 3 `b0 = x`, `b8 = y` (the mirror wrote them back into box bytes 0 and 8 —
# note that box byte 8 originally held `x` and is DESTRUCTIVELY overwritten with
# `y`, which is the reversibility case gate (4) exercises). `r = 2x + 2y`.
#
# NON-VACUITY. Had the arena side's stamp collapsed to the word tier, the K = 2
# src offsets would resolve to cells `%box+8 + 1` and the mirror's dst to
# `%box + 1` — cells that were never written — so `t1` and `b8` could not equal
# `y`. The `x != y` and `y != 0` assertions below are what make that visible.
# ---------------------------------------------------------------------------
const _IR_SY29 = """
target datalayout = "e-p:64:64:64-i64:64-n8:16:32:64-S128"

declare ptr @julia.gc_alloc_obj(ptr, i64, ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)

define i64 @sy29_e2e(ptr %task, ptr %tag, i64 %x, i64 %y) {
top:
  ; ---- leg 1: the byte-tier box, seeded at bytes 8 and 16 ----
  %box = call ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %p8  = getelementptr inbounds i8, ptr %box, i32 8
  store i64 %x, ptr %p8, align 8
  %p16 = getelementptr inbounds i8, ptr %box, i32 16
  store i64 %y, ptr %p16, align 8

  ; ---- leg 2: ARENA -> ALLOCA, K = 2 ----
  %slot = alloca [2 x i64], align 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %slot, ptr align 8 %p8, i64 16, i1 false)
  %s0g = getelementptr inbounds i64, ptr %slot, i32 0
  %t0  = load i64, ptr %s0g, align 8
  %s1g = getelementptr inbounds i64, ptr %slot, i32 1
  %t1  = load i64, ptr %s1g, align 8

  ; ---- leg 3: ALLOCA -> ARENA, K = 2 (the mirror) ----
  %p0 = getelementptr inbounds i8, ptr %box, i32 0
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %p0, ptr align 8 %slot, i64 16, i1 false)

  ; ---- leg 4: read both arena cells back through the byte tier ----
  %b0 = load i64, ptr %p0, align 8
  %b8 = load i64, ptr %p8, align 8

  %u = add i64 %t0, %t1
  %v = add i64 %b0, %b8
  %r = add i64 %u, %v
  ret i64 %r
}
"""

# (6) SAME-ROOT arena↔arena — must be refused at EXTRACTION, never reach the VM.
const _IR_SY29_OVERLAP = """
target datalayout = "e-p:64:64:64-i64:64-n8:16:32:64-S128"

declare ptr @julia.gc_alloc_obj(ptr, i64, ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)

define i64 @sy29_overlap(ptr %task, ptr %tag) {
top:
  %box = call ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %d = getelementptr inbounds i8, ptr %box, i32 0
  %s = getelementptr inbounds i8, ptr %box, i32 8
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %d, ptr align 8 %s, i64 8, i1 false)
  ret i64 0
}
"""

# (7) ARENA → ARENA, K = 2 (reviewer probe `p7_a2a`, promoted to a permanent
# gate under the hostile review). Two DISTINCT arena roots, both ranges strictly
# IN-OBJECT, so upstream Predicate 6d admits it and Predicate 7 (distinct roots)
# is genuinely sound for it. Both sides are byte tier ⇒ both stamp 8: the
# DEGENERATE case of the per-side rule, and the one case where a single shared
# stamp would coincidentally look right — which is exactly why it needs its own
# EXECUTED gate rather than inheriting gate (1)/(3)'s mixed-tier evidence.
const _IR_SY29_A2A = """
target datalayout = "e-p:64:64:64-i64:64-n8:16:32:64-S128"

declare ptr @julia.gc_alloc_obj(ptr, i64, ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)

define i64 @sy29_a2a(ptr %t, ptr %g, i64 %x, i64 %y) {
top:
  %a = call ptr @julia.gc_alloc_obj(ptr %t, i64 24, ptr %g)
  %b = call ptr @julia.gc_alloc_obj(ptr %t, i64 24, ptr %g)
  %a8 = getelementptr inbounds i8, ptr %a, i32 8
  %a16 = getelementptr inbounds i8, ptr %a, i32 16
  store i64 %x, ptr %a8, align 8
  store i64 %y, ptr %a16, align 8
  %b0 = getelementptr inbounds i8, ptr %b, i32 0
  call void @llvm.memcpy.p0.p0.i64(ptr %b0, ptr %a8, i64 16, i1 false)
  %b8 = getelementptr inbounds i8, ptr %b, i32 8
  %r0 = load i64, ptr %b0, align 8
  %r1 = load i64, ptr %b8, align 8
  %s = add i64 %r0, %r1
  ret i64 %s
}
"""

_sy29_extract(ir, fn) = mktempdir() do dir
    path = joinpath(dir, "$(fn).ll")
    write(path, ir)
    return _BNs.extract_parsed_ir_from_ll(path; entry_function = fn,
                                          ptr_cells = true)
end

function _sy29_build()
    p = _sy29_extract(_IR_SY29, "sy29_e2e")
    return (p, _BVs.lower_vm(p))
end

_sy29_insts(pir) = [i for b in pir.blocks for i in b.instructions]

# The cell an emitted offset node resolves to, computed the way BVM computes it.
_sy29_cell(o) = o.offset_bytes ÷ (o.elem_width ÷ 8)

_sy29_offs(pir, base::Symbol) =
    [o for o in _sy29_insts(pir)
     if o isa _BNs.IRPtrOffset && o.base isa _BNs.SSAOperand &&
        o.base.name === base]

@testset "Bennett-sy29 — mixed-tier arena memcpy runs and reverses on the VM" begin

    # ==================================================================
    # (1) THE HANDOFF SHAPE — per-side stamps, and the cells they mean.
    # ==================================================================
    @testset "(1) the ParsedIR carries PER-SIDE byte/word stamps" begin
        pir, _ = _sy29_build()

        # --- leg 2 src: the ARENA side, byte tier. Element 1 at cell +8. ---
        src2 = _sy29_offs(pir, :p8)
        @test Set((o.offset_bytes, o.elem_width) for o in src2) ==
              Set([(0, 8), (8, 8)])
        @test Set(_sy29_cell(o) for o in src2) == Set([0, 8])

        # --- leg 2 dst / leg 3 src: the ALLOCA side, word tier. Cell +1. ---
        wslot = _sy29_offs(pir, :slot)
        @test Set((o.offset_bytes, o.elem_width) for o in wslot) ==
              Set([(0, 64), (8, 64)])
        @test Set(_sy29_cell(o) for o in wslot) == Set([0, 1])

        # --- leg 3 dst: the ARENA side again, byte tier. ---
        dst3 = _sy29_offs(pir, :p0)
        @test Set((o.offset_bytes, o.elem_width) for o in dst3) ==
              Set([(0, 8), (8, 8)])
        @test Set(_sy29_cell(o) for o in dst3) == Set([0, 8])

        # THE MIXED-TIER FACT, stated as an inequality: byte offset 8 means TWO
        # DIFFERENT CELLS on the two sides of ONE memcpy, and that is correct.
        @test 8 ÷ (8 ÷ 8) != 8 ÷ (64 ÷ 8)

        # The VALUE width is 64 everywhere — a whole cell in BOTH tiers.
        insts = _sy29_insts(pir)
        cp_lds = [l for l in insts if l isa _BNs.IRLoad]
        cp_sts = [s for s in insts if s isa _BNs.IRStore]
        @test all(l -> l.width == 64, cp_lds)
        @test all(s -> s.width == 64, cp_sts)
        # 2 seeding stores + 2 (leg 2) + 2 (leg 3) decomposed stores
        @test length(cp_sts) == 6

        # The alloca's own reservation is untouched word tier (2 cells): the
        # use-directed byte-normalisation must NOT fire here, because the memcpy
        # stamps this root at 64 and normalisation requires ALL-byte addressing.
        slot = only([a for a in insts
                     if a isa _BNs.IRAlloca && a.dest === :slot])
        @test slot.elem_width == 64
        @test slot.n_elems == _BNs.ConstOperand(2)
    end

    # ==================================================================
    # (2) ZERO new instruction kinds — the ninth consecutive bead with no
    #     BennettVM src change, asserted rather than claimed.
    # ==================================================================
    @testset "(2) lower_vm produces only pre-existing instruction kinds" begin
        _, prog = _sy29_build()
        body = [i for b in prog.blocks for i in b.instructions]
        kinds = Set(typeof(i) for i in body)
        @test kinds ⊆ Set([_BVs.Define, _BVs.IntrinsicGCAlloc,
                           _BVs.MemoryLoad, _BVs.MemoryStore,
                           _BVs.StackAlloca])
        @test count(i -> i isa _BVs.IntrinsicGCAlloc, body) == 1
        @test count(i -> i isa _BVs.StackAlloca, body) == 1
        @test count(i -> i isa _BVs.MemoryStore, body) == 6
        # NO bulk-copy intrinsic: route R1 decomposes, it does not delegate.
        # (`_enforce_julia_heap_tier!` would refuse one here anyway — see the
        # header — so this also pins that we never provoke that refusal.)
        @test !any(i -> i isa _BVs.IntrinsicMemcpy, body)
        @test !any(i -> i isa _BVs.IntrinsicMemmove, body)
    end

    # ==================================================================
    # (3)+(4)+(5) ORACLE BOTH DIRECTIONS, EXACT REVERSAL, PER-STEP INVERSE.
    # ==================================================================
    @testset "(3)+(4) oracle both directions, exact reversal" begin
        _, prog = _sy29_build()
        regimes = (("L2 (compute_must_cache)", _BVs.compute_must_cache(prog)),
                   ("L3 (empty must_cache)",   Set{Tuple{Symbol,Int}}()))
        cases = ((Int64(7), Int64(11)),
                 (Int64(-3), Int64(1) << 40),
                 (Int64(1), Int64(-1)))
        for (rlabel, mcs) in regimes, (x, y) in cases
            # NON-VACUITY PRECONDITION, asserted rather than assumed.
            @test x != y && y != 0

            s = _BVs.initial_state(prog, Dict(:x => x, :y => y,
                                              :task => Int64(0),
                                              :tag => Int64(0)))
            init = deepcopy(s.current)
            _BVs.run!(s, prog; max_steps=50_000, checkpoint_interval=4,
                      must_cache_set=mcs)
            # ANCHOR ($rlabel, x = $x, y = $y)
            @test _BVs.is_halted(s)
            @test s.current.status === :halted
            res = _BVs.result(s)

            # --- ARENA -> ALLOCA, K = 2. `t1` is the load-bearing one: it is
            #     the element whose src offset is NON-ZERO, i.e. the one a
            #     collapsed stamp would misaddress.
            @test res[:t0] == x
            @test res[:t1] == y

            # --- ALLOCA -> ARENA, K = 2 (the mirror). `b8` is load-bearing for
            #     the same reason on the DST side, and it is also the
            #     DESTRUCTIVE overwrite (box byte 8 held `x`, now holds `y`).
            @test res[:b0] == x
            @test res[:b8] == y

            @test res[:r] == 2x + 2y
            @test res[:x] == x && res[:y] == y      # inputs preserved

            # (4) EXACT reversal: the Bennett-1973 invariant, whole-state. This
            # is what makes the arena-DST direction sound — the overwrite of
            # box byte 8 is undone from the history tape, NOT prevented by a
            # freshness precondition (Bennett-u2kk's justification).
            _BVs.unrun!(s, prog; max_unsteps=100_000)
            @test s.current == init
            @test isempty(s.history)
            @test s.step_count == 0
        end
    end

    @testset "(5) per-step inverse at two checkpoint intervals" begin
        _, prog = _sy29_build()
        for K in (1, 4)
            @test per_step_inverse_check(prog,
                    Dict(:x => Int64(7), :y => Int64(11),
                         :task => Int64(0), :tag => Int64(0));
                    checkpoint_interval=K,
                    label="sy29/e2e/L3/K=$K") === nothing
        end
    end

    # ==================================================================
    # (6) THE OVERLAP GUARD LIVES UPSTREAM — and must, because BennettVM's
    #     own overlap check is not in this route.
    # ==================================================================
    @testset "(6) a same-root arena memcpy never reaches the VM" begin
        msg = try
            _sy29_extract(_IR_SY29_OVERLAP, "sy29_overlap")
            ""
        catch e
            e isa InterruptException && rethrow()
            sprint(showerror, e)
        end
        @test msg != ""
        @test occursin("Bennett-sy29", msg)
        @test occursin("memmove", msg)          # "semantically memmove"
        # The message must say WHY the guard has to be upstream.
        @test occursin("IntrinsicMemcpy", msg)
    end

    # ==================================================================
    # (7) ARENA → ARENA, K = 2 — the degenerate (both-byte-tier) pairing,
    #     EXECUTED. Added under hostile review; the arm admitted this shape
    #     from the start and no test exercised it.
    # ==================================================================
    @testset "(7) arena→arena K=2 runs, matches oracle, reverses exactly" begin
        pir = _sy29_extract(_IR_SY29_A2A, "sy29_a2a")

        # BOTH sides byte tier ⇒ BOTH stamp 8, and element 1 lands at cell +8.
        for base in (:a8, :b0)
            offs = Set((o.offset_bytes, o.elem_width) for o in _sy29_offs(pir, base))
            @test offs == Set([(0, 8), (8, 8)])
            @test Set(_sy29_cell(o) for o in _sy29_offs(pir, base)) == Set([0, 8])
        end

        prog = _BVs.lower_vm(pir)
        body = [i for b in prog.blocks for i in b.instructions]
        @test Set(typeof(i) for i in body) ⊆
              Set([_BVs.Define, _BVs.IntrinsicGCAlloc, _BVs.MemoryLoad,
                   _BVs.MemoryStore, _BVs.StackAlloca])
        @test !any(i -> i isa _BVs.IntrinsicMemcpy, body)

        for (x, y) in ((Int64(7), Int64(11)), (Int64(-3), Int64(1) << 40))
            @test x != y && y != 0            # non-vacuity, asserted
            s = _BVs.initial_state(prog, Dict(:x => x, :y => y,
                                              :t => Int64(0), :g => Int64(0)))
            init = deepcopy(s.current)
            _BVs.run!(s, prog; max_steps=50_000, checkpoint_interval=4,
                      must_cache_set=_BVs.compute_must_cache(prog))
            # ANCHOR (a2a, x = $x, y = $y)
            @test _BVs.is_halted(s)
            r = _BVs.result(s)
            @test r[:r0] == x                 # element 0
            @test r[:r1] == y                 # element 1 — the load-bearing cell
            @test r[:s] == x + y
            _BVs.unrun!(s, prog; max_unsteps=100_000)
            @test s.current == init
            @test isempty(s.history)
            @test s.step_count == 0
        end
    end
end
