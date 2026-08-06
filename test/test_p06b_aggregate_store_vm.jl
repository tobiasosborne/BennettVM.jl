# test/test_p06b_aggregate_store_vm.jl — the BennettVM (downstream) half of
# Bennett.jl bead `Bennett-p06b`.
#
# # What upstream changed
#
# Under the closed-world `ptr_cells` gate, a WHOLE-AGGREGATE
#
#     store <S> %agg, ptr %p              ; S an unpacked StructType
#
# no longer hits the Bennett-lgzx / U114 `vt isa IntegerType` reject. It is
# DECOMPOSED, for each field k of S, into
#
#     IRExtractValue(fk, <agg>, k, 0, N, field_widths)
#     IRPtrOffset(ak, <p>, LLVMOffsetOfElement(S, k), 64)
#     IRStore(ssa(ak), ssa(fk), 64)
#
# — EXACTLY the field-wise spelling the extractor already emitted for the same
# operation written the long way. This is `bennettvm-xkl` wall 6: Julia's
# `MemoryRef` write-back in `_growend!` `%L93`.
#
# # Why BVM has ZERO src changes (and what this file is for)
#
# All three emitted node types are ALREADY produced under `ptr_cells` today and
# already ingest:
#
#   * `IRExtractValue` → one non-destructive slot COPY,
#     `Define(dest, _agg_<agg>_slot<k>, :add, 0)` (`src/ir/ingest.jl`, bead
#     `bennettvm-acq`) — guarded by the `agg.name ∈ agg_dests` MEMBERSHIP check,
#     which is precisely why the upstream arm requires the stored aggregate to
#     be an `insertvalue` (the sole populator of `agg_dests`);
#   * `IRPtrOffset` → `Define(dest, base, :add, offset_bytes ÷ (elem_width÷8))`
#     (`src/ir/ingest_body.jl`);
#   * `IRStore` → `MemoryStore` (`src/ir/ingest_body.jl`), the L2/L3-logged
#     single-cell write.
#
# So p06b is an EXTRACTION-only bead, like the five before it. What has never
# been executed is the END-TO-END claim, and in particular:
#
#   * CELL AGREEMENT. The decomposition writes cells `φ(%p)+k`. The SAME object
#     is READ BACK through the untouched BVM ADR 0020 D4 two-index struct-GEP
#     arm, which computes its cells from the SAME `LLVMOffsetOfElement` with the
#     SAME `elem_width` stamp. If the two ever disagreed, the read-back would
#     silently return the wrong field. Gate (3) is the operational form of that
#     claim: the two fields must land in DISTINCT cells and each must read back
#     as ITSELF (a NON-VACUOUS witness — if both fields landed in one cell,
#     last-write-wins would make field 0's read-back equal field 1's value).
#   * REVERSIBILITY. N independent single-cell writes must reverse as the
#     reverse-ordered composition of N invertible cell writes, under both
#     history regimes and per-step.
#
# # What this pins (Rule 4 — known values, never "didn't throw")
#
#   (1) the ParsedIR BVM receives really carries the p06b six-node emission for
#       a `{ptr,ptr}` store — `IRExtractValue(_, agg, k, 0, 2, [64,64])`,
#       `IRPtrOffset(_, base, {0,8}, 64)`, `IRStore(_, _, 64)` — AND the D4
#       read-back GEPs carry the IDENTICAL `(offset_bytes, elem_width)` pairs;
#   (2) `lower_vm` produces two slot-copy `Define`s, two offset `Define`s and
#       two `MemoryStore`s — no new instruction kind;
#   (3) ORACLE + NON-VACUITY: both fields round-trip through the word-granular
#       struct GEPs, in DISTINCT cells, with the allocator's injectivity pinned
#       operationally (`buf`, `alt`, `slot` at distinct arena addresses), for
#       x ∈ {0, 7, -3} under L2 AND L3;
#   (4) `unrun!` returns the EXACT initial state with a DRAINED history under
#       both regimes;
#   (5) `per_step_inverse_check` at K ∈ {1, 4} under both regimes;
#   (6) the SELF-REFERENTIAL case (the store target is also stored as a field)
#       — store order is immaterial because every field value is read from the
#       SSA aggregate, never from memory.
#
# # HONEST SCOPE BOUNDARY — this file is the C/word tier only
#
# The fixtures allocate with `malloc` (the C heap tier). The REAL `_growend!`
# write-back arrives in a JULIA-tier program and cannot yet run E2E: after p06b
# the push! closed-world set advances only as far as `%idxend41`, where it meets
# `ptrtoint ptr %memory_data53 to i64` — a GenericMemory `.data`-base coercion
# whose root `_memdata_root` does not yet recognise (Bennett-583s, tracked as
# bead Bennett-foz5, xkl wall 7). Nothing here claims otherwise; this file
# proves the MECHANISM, not the corpus.
#
# # KNOWN CLOBBER — Bennett-khb2 (read before trusting this file)
#
# Everything below exercises targets whose capacity the extractor CERTIFIES
# (`malloc(16)` = 2 cells for a 2-field store). A `:load` target — which is the
# REAL CORPUS SHAPE — has NO static capacity proof, and the VM does not catch
# the overflow either: measured 2026-08-06, a 2-field store into a `malloc(8)`
# reached through a `load ptr` silently overwrote the NEXT allocation
# (EXPECTED 999, ACTUAL 42) and BennettVM raised nothing. A region-MEMBERSHIP
# bounds check (`bennettvm-pdqx`) would NOT catch it either — the clobbered cell
# belongs to a live neighbouring reservation, so it is in-bounds by that
# predicate; catching it needs pointer PROVENANCE, which the VM does not have.
# The upstream gate pins the shape as KNOWN-ADMITTED
# (`p06b_khb2_loadclobber`); nothing in this file should be read as evidence
# that out-of-reservation aggregate stores are safe.
#
# # Ref
#   * `../Bennett.jl/test/test_p06b_aggregate_store.jl` — the upstream gate
#     (the (P1)-(P6) predicates + the adversarial reject matrix).
#   * `../Bennett.jl/src/extract/instructions.jl` — the p06b arm and its
#     exactness / determinism comment block.
#   * `test/test_jbko_ptr_identity_vm.jl` — the immediately preceding wall's
#     E2E half; this file deliberately mirrors its structure.

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

const _BVP = BennettVM
const _BNP = Bennett

# `agg_store` builds a `{ptr,ptr}` in the arena with ONE whole-aggregate store
# and reads BOTH halves back through word-granular two-index struct GEPs. The
# oracle is `x + 1` iff BOTH halves round-trip; `x + 100` otherwise. That
# `+ 100` arm is what makes the witness NON-VACUOUS: if the two fields shared a
# cell, last-write-wins would give `%r0 == alt` and the guard would fail.
#
# `agg_store_selfref` stores the TARGET pointer itself as field 1 — the
# order-immateriality case (§3.2 of both designs).
const _IRP06B = """
target datalayout = "e-p:64:64:64-i64:64-n8:16:32:64-S128"

declare ptr @malloc(i64)

define i64 @agg_store(i64 %x) {
entry:
  %buf  = call ptr @malloc(i64 32)
  %alt  = call ptr @malloc(i64 32)
  %slot = call ptr @malloc(i64 16)
  %a0  = insertvalue { ptr, ptr } zeroinitializer, ptr %buf, 0
  %agg = insertvalue { ptr, ptr } %a0, ptr %alt, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  %f0 = getelementptr inbounds { ptr, ptr }, ptr %slot, i32 0, i32 0
  %f1 = getelementptr inbounds { ptr, ptr }, ptr %slot, i32 0, i32 1
  %r0 = load ptr, ptr %f0, align 8
  %r1 = load ptr, ptr %f1, align 8
  %e0 = icmp eq ptr %r0, %buf
  %e1 = icmp eq ptr %r1, %alt
  %ok = and i1 %e0, %e1
  br i1 %ok, label %good, label %bad
good:
  %rg = add i64 %x, 1
  ret i64 %rg
bad:
  %rb = add i64 %x, 100
  ret i64 %rb
}

define i64 @agg_store_selfref(i64 %x) {
entry:
  %buf  = call ptr @malloc(i64 32)
  %slot = call ptr @malloc(i64 16)
  %a0  = insertvalue { ptr, ptr } zeroinitializer, ptr %buf, 0
  %agg = insertvalue { ptr, ptr } %a0, ptr %slot, 1
  store { ptr, ptr } %agg, ptr %slot, align 8
  %f0 = getelementptr inbounds { ptr, ptr }, ptr %slot, i32 0, i32 0
  %f1 = getelementptr inbounds { ptr, ptr }, ptr %slot, i32 0, i32 1
  %r0 = load ptr, ptr %f0, align 8
  %r1 = load ptr, ptr %f1, align 8
  %e0 = icmp eq ptr %r0, %buf
  %e1 = icmp eq ptr %r1, %slot
  %ok = and i1 %e0, %e1
  br i1 %ok, label %good, label %bad
good:
  %rg = add i64 %x, 1
  ret i64 %rg
bad:
  %rb = add i64 %x, 100
  ret i64 %rb
}
"""

# BVM's arena base — the value the DETERMINISTIC bump allocator hands to the
# first allocation. Pinned here (not imported) so the test states the constant
# the determinism argument names.
const _P06B_ARENA_BASE = Int64(1) << 40

_p06b_build(entry) = mktempdir() do dir
    path = joinpath(dir, "p06b.ll")
    write(path, _IRP06B)
    p = _BNP.extract_parsed_ir_from_ll(path; entry_function=entry, ptr_cells=true)
    return (p, _BVP.lower_vm(p))
end

_p06b_insts(pir) = [i for b in pir.blocks for i in b.instructions]

@testset "Bennett-p06b — decomposed aggregate store runs and reverses on the VM" begin

    # ==================================================================
    # (1) THE HANDOFF SHAPE — the ParsedIR BVM receives really carries the
    #     p06b six-node emission, and the D4 read-back GEPs carry the
    #     IDENTICAL (offset_bytes, elem_width) pairs. That identity IS the
    #     cell-agreement theorem; everything below is its consequence.
    # ==================================================================
    @testset "(1) the ParsedIR carries the p06b triples, cells agreeing" begin
        pir, _ = _p06b_build("agg_store")
        insts = _p06b_insts(pir)

        evs = [i for i in insts if i isa _BNP.IRExtractValue]
        @test length(evs) == 2
        @test [e.index for e in evs] == [0, 1]
        for e in evs
            @test e.agg == _BNP.SSAOperand(:agg)
            @test e.elem_width == 0            # the 6bu3 StructType discriminator
            @test e.n_elems == 2
            @test e.field_widths == [64, 64]
        end
        # the aggregate REALLY is an insertvalue-built slot family — the
        # `agg_dests` membership guard's precondition, checked upstream.
        ivs = [i for i in insts if i isa _BNP.IRInsertValue]
        @test length(ivs) == 2
        @test ivs[2].dest === :agg

        sts = [i for i in insts if i isa _BNP.IRStore]
        @test length(sts) == 2
        @test all(s -> s.width == 64, sts)
        @test [s.val for s in sts] ==
              [_BNP.SSAOperand(evs[1].dest), _BNP.SSAOperand(evs[2].dest)]

        pos = [i for i in insts if i isa _BNP.IRPtrOffset]
        store_ptrs = Symbol[s.ptr.name for s in sts]
        wr = [o for o in pos if o.dest in store_ptrs]
        @test length(wr) == 2
        @test all(o -> o.base == _BNP.SSAOperand(:slot), wr)
        @test [(o.offset_bytes, o.elem_width) for o in wr] == [(0, 64), (8, 64)]

        # ---- CELL AGREEMENT, as a handoff assertion ----
        f0 = only([o for o in pos if o.dest === :f0])
        f1 = only([o for o in pos if o.dest === :f1])
        @test (f0.offset_bytes, f0.elem_width) == (0, 64)
        @test (f1.offset_bytes, f1.elem_width) == (8, 64)
        @test f0.base == f1.base == _BNP.SSAOperand(:slot)
        @test Set((o.offset_bytes, o.elem_width) for o in wr) ==
              Set([(0, 64), (8, 64)])
    end

    # ==================================================================
    # (2) lower_vm: slot copies, offset Defines and MemoryStores — every
    #     one an EXISTING instruction kind. ZERO BVM src changes.
    # ==================================================================
    @testset "(2) lower_vm: two slot Defines, two offsets, two MemoryStores" begin
        pir, prog = _p06b_build("agg_store")
        body = [i for b in prog.blocks for i in b.instructions]

        stores = [i for i in body if i isa _BVP.MemoryStore]
        @test length(stores) == 2

        insts = _p06b_insts(pir)
        evs = [i for i in insts if i isa _BNP.IRExtractValue]
        sts = [i for i in insts if i isa _BNP.IRStore]
        defs = [i for i in body if i isa _BVP.Define]
        # each p06b extractvalue became a Define of its dest (a slot COPY)
        for e in evs
            @test any(d -> d.target === e.dest, defs)
        end
        # each p06b address became a Define of its dest (base + cell index)
        for s in sts
            @test any(d -> d.target === s.ptr.name, defs)
        end
    end

    # ==================================================================
    # (3)+(4)+(5) THE ORACLE, EXACT REVERSAL, PER-STEP INVERSE.
    #
    #     NON-VACUITY: `%r0 == buf` AND `%r1 == alt` simultaneously is the
    #     witness that the two fields landed in DISTINCT cells. If they
    #     shared a cell, last-write-wins would give `%r0 == alt`, `%e0`
    #     would be 0, and the oracle would be `x + 100`.
    # ==================================================================
    @testset "(3)+(4)+(5) oracle, distinct cells, exact reversal" begin
        pir, prog = _p06b_build("agg_store")
        regimes = (("L2 (compute_must_cache)", _BVP.compute_must_cache(prog)),
                   ("L3 (empty must_cache)",   Set{Tuple{Symbol,Int}}()))
        for (rlabel, mcs) in regimes, x in Int64[0, 7, -3]
            s = _BVP.initial_state(prog, Dict(:x => x))
            init = deepcopy(s.current)
            _BVP.run!(s, prog; max_steps=10_000, checkpoint_interval=4,
                      must_cache_set=mcs)
            # ANCHOR ($rlabel, x = $x)
            @test _BVP.is_halted(s)
            @test s.current.status === :halted
            res = _BVP.result(s)
            @test res[:rg] == x + 1               # the good-arm oracle
            @test res[:x] == x                    # input preserved
            # BOTH fields round-tripped, through the word-granular struct GEPs
            @test res[:e0] == 1
            @test res[:e1] == 1
            @test res[:r0] == res[:buf]
            @test res[:r1] == res[:alt]
            # ... and they are DISTINCT values, so they cannot have shared a
            # cell (this is what makes the two assertions above non-vacuous)
            @test res[:r0] != res[:r1]
            # allocator determinism + injectivity, pinned operationally
            @test res[:buf] == _P06B_ARENA_BASE
            @test res[:alt] != res[:buf]
            @test res[:slot] != res[:buf]
            @test res[:slot] != res[:alt]
            _BVP.unrun!(s, prog; max_unsteps=20_000)
            @test s.current == init
            @test isempty(s.history)
            @test s.step_count == 0
        end

        for K in (1, 4)
            @test per_step_inverse_check(prog, Dict(:x => Int64(7));
                                         checkpoint_interval=K,
                                         label="p06b/agg_store/L3/K=$K") === nothing
            @test per_step_inverse_check(prog, Dict(:x => Int64(7));
                                         checkpoint_interval=K,
                                         must_cache_set=_BVP.compute_must_cache(prog),
                                         label="p06b/agg_store/L2/K=$K") === nothing
        end
    end

    # ==================================================================
    # (6) SELF-REFERENCE — the store target is ALSO stored as field 1.
    #     Every field value is read from the SSA aggregate (registers),
    #     never from memory, so the N cell writes cannot observe each
    #     other and ascending field order is a formatting choice.
    # ==================================================================
    @testset "(6) self-referential aggregate store: order is immaterial" begin
        _, prog = _p06b_build("agg_store_selfref")
        regimes = (("L2", _BVP.compute_must_cache(prog)),
                   ("L3", Set{Tuple{Symbol,Int}}()))
        for (rlabel, mcs) in regimes, x in Int64[0, 7, -3]
            s = _BVP.initial_state(prog, Dict(:x => x))
            init = deepcopy(s.current)
            _BVP.run!(s, prog; max_steps=10_000, checkpoint_interval=4,
                      must_cache_set=mcs)
            # ANCHOR ($rlabel, x = $x)
            @test _BVP.is_halted(s)
            res = _BVP.result(s)
            @test res[:rg] == x + 1
            @test res[:r0] == res[:buf]
            @test res[:r1] == res[:slot]      # the target read back as itself
            @test res[:r0] != res[:r1]
            _BVP.unrun!(s, prog; max_unsteps=20_000)
            @test s.current == init
            @test isempty(s.history)
            @test s.step_count == 0
        end
        for K in (1, 4)
            @test per_step_inverse_check(prog, Dict(:x => Int64(7));
                                         checkpoint_interval=K,
                                         label="p06b/selfref/L3/K=$K") === nothing
            @test per_step_inverse_check(prog, Dict(:x => Int64(7));
                                         checkpoint_interval=K,
                                         must_cache_set=_BVP.compute_must_cache(prog),
                                         label="p06b/selfref/L2/K=$K") === nothing
        end
    end

end
