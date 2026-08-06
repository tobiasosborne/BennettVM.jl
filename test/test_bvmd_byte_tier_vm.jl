# test/test_bvmd_byte_tier_vm.jl — the BennettVM (downstream) half of
# Bennett.jl bead `Bennett-bvmd` (xkl frontier wall 8), and the gate that
# discharges the `Bennett-foz5` ADR 0017 §4a validation debt FOR THE MECHANISM.
#
# # What upstream changed
#
# BennettVM has always been TWO-TIERED about cells and said so in code:
#
#     _alloc_cells(::IntrinsicGCAlloc) = _byte_cells(nbytes)   # 1 byte per cell
#     _alloc_cells(::IntrinsicMalloc)  = _cell_count(nbytes)   # 8 bytes per cell
#     _lower_alloca!  reserves `n` cells; "`elem_width` (in bits) does NOT
#                     enter the address"                       (ingest_body.jl)
#
# and `IRPtrOffset(d, b, off, ew)` lowers to `Define(d, b, :add, off ÷ (ew÷8))`,
# so `elem_width` is nothing but the BYTES-PER-CELL SCALE of the object being
# addressed. Bennett.jl's stamps did not always agree with that scale. Two
# consequences were live in the push! ROOT body:
#
#   * `gep i8 %obj, 8` stamped 8 → cell +8, while
#     `gep {ptr,ptr} %obj, 0, 1` on the SAME `julia.gc_alloc_obj` object
#     stamped 64 → cell +1. TWO CELLS FOR ONE FIELD, six times over.
#   * `alloca [9 x i64]` reserved NINE cells while Julia codegen addressed it
#     with `gep i8 …, 56` → cell +56, forty-eight cells past its own
#     reservation, inside the next allocation (`Bennett-z2ia`).
#
# `Bennett-bvmd` makes the extractor READ the scale off this repo's own
# allocator table (never invent a tier), stamp every address-forming arm from
# it, BYTE-NORMALISE the reservation of an all-byte-addressed word-tier `alloca`
# (`IRAlloca(d, 64, n)` → `IRAlloca(d, 8, 8n)` — expressible TODAY because
# `_lower_alloca!` ignores `elem_width`), and refuse loudly when one object is
# genuinely addressed at two granularities.
#
# # BennettVM src changes: ZERO. This file is the proof, not the assertion.
#
# Every node below already ingests: `IntrinsicGCAlloc` byte-reserves,
# `IRPtrOffset(_, _, o, 8)` lowers to `Define(_, _, :add, o ÷ 1)` (the
# divisibility guard is trivially satisfied at `ew_bytes == 1`), and
# `IRAlloca(d, 8, 8n)` reserves `8n` cells by the same `+N` rule as before.
# The byte tier was always BVM's model; only the upstream stamps disagreed.
#
# # What this file pins (Rule 4 — known values, never "didn't throw")
#
#   (1) HANDOFF SHAPE — the ParsedIR BVM receives carries the byte-tier
#       emission: the decomposition's `IRPtrOffset(_, obj, {0,8}, 8)`, the
#       class-D struct GEP at `(8, 8)`, the class-A byte GEP at `(8, 8)`, and
#       closure env as `IRAlloca(:env, 8, 72)` — cell +56 now inside it.
#   (2) CELL AGREEMENT, EXECUTED — the class-A byte read and the class-D struct
#       read of the SAME field return the SAME pointer, and it is the one the
#       aggregate store wrote. NON-VACUOUS: field 0 holds a DIFFERENT pointer,
#       so a shared cell would make the two disagree.
#   (3) THE §4a (INV) MECHANISM — a closure-env `alloca` is WRITTEN BY
#       EXTRACTED CODE through a byte GEP and READ BACK through it, and the
#       value read back drives a `ptrtoint`/`sub`/`icmp`/`br` CONFINED guard in
#       foz5's exact sense (every use of the `sub` is an `icmp`; the false edge
#       is a pruned throw skeleton). This is the first RUNTIME evidence for
#       foz5's premise that a byte-cell difference equals the native byte
#       difference.
#   (4) ORACLE on in-bounds inputs, under L2 and L3 history regimes.
#   (5) EXACT `unrun!` — the initial `IState` is restored bit-for-bit (memory,
#       locals, arena cursor, pc) with a DRAINED history. The Bennett-1973
#       invariant.
#   (6) OUT-OF-BOUNDS halts at `:__unreachable__` rather than returning a wrong
#       value (`status === :error`, ADR 0017 §4 / Bennett-utzc).
#
# # HONEST SCOPE — read this before citing the file
#
# This fixture discharges the foz5 §4a debt **FOR THE MECHANISM**, on a program
# that HAS the mechanism. It does **NOT** discharge it for the corpus, and the
# bead text's premise that clearing wall 8 "lets the full push! corpus RUN" is
# FALSE — measured. After bvmd the push! set still walls at EXTRACTION:
#
#   wall 9  — the arena-src memcpy (`Bennett-37mt` Phase 1 / `Bennett-8bys`)
#   wall 10 — a base-cancelling difference escaping as an ELEMENT-INDEX VALUE
#             through `udiv exact`, which foz5's §4a clause (iii) ("every use
#             is an `icmp`") does NOT admit — it needs a third contract
#   wall 11 — `Bennett-p06b`'s own silent-skip `alloca {ptr,ptr}` target
#
# and `bennettvm-rxgy` (byte-exact `IntrinsicMemmoveBytes`) still blocks
# `_growend!`'s grow-copy at `lower_vm` even if extraction cleared.
#
# Gate (6) is constructible ONLY IN THE FIXTURE. On the real corpus
# `push!` on a freshly allocated `Vector` never takes the `oob` edge, so §4a's
# residual — "the throw may be missed, or the halt spurious" — stays
# UNDISCHARGED by any test this arc can write. Do not read gate (6) as closing
# it.
#
# # Ref
#   * `../Bennett.jl/test/test_bvmd_root_scale.jl` — the upstream (SC) gate.
#   * `../Bennett.jl/src/extract/instructions.jl` — `_root_scale`,
#     `_cell_elem_width_struct_gep`, `_check_scale_coherence!`.
#   * `src/ir/intrinsics.jl:246-261` — the allocator scale table this reads.
#   * `src/ir/ingest_body.jl:495-534` (`IRPtrOffset` → `Define`), `:558-605`
#     (`_lower_alloca!`).
#   * ADR 0017 §4 (`:__unreachable__` sink), §4a (the confined-value contract).
#   * `test/test_p06b_aggregate_store_vm.jl` — the word-tier sibling of this
#     file; the structure is deliberately mirrored.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known values), Rule 11 (literate).

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

const _BVb = BennettVM
const _BNb = Bennett

# ---------------------------------------------------------------------------
# The fixture. Every leg of the scout's six-part design, on ONE function.
#
#   leg 1  `julia.gc_alloc_obj(task, 24, tag)`     — a 24-byte box, 24 cells
#   leg 2  `store {ptr,ptr} %agg, ptr %obj`        — the bvmd decomposition
#   leg 3  a class-D `gep {ptr,ptr} %obj, 0, 1` AND a class-A `gep i8 %obj, 8`
#          read of the SAME field                  — the CW-D4 split, resolved
#   leg 4  a closure-env `alloca [9 x i64]` written and read back at byte 56
#          by extracted code                        — foz5's (INV) mechanism
#   leg 5  `ptrtoint`/`sub`/`icmp`/`br` over leg 4, false edge = throw skeleton
#   leg 6  oracle / exact reversal / `:__unreachable__` on OOB
#
# ORACLE. For `0 <= idx < len` the guard passes and the result is `idx + 1`
# (the `+ 100` arm is the NON-VACUITY witness: it fires iff either read of
# field 1 failed to return `%mem`). For `idx >= len` the guard's false edge is
# taken and the program must HALT, not return.
# ---------------------------------------------------------------------------
const _IR_BVMD = """
target datalayout = "e-p:64:64:64-i64:64-n8:16:32:64-S128"

declare ptr @julia.gc_alloc_obj(ptr, i64, ptr)
declare void @ijl_bounds_error_int(ptr, i64)

define i64 @bvmd_e2e(ptr %task, ptr %tag, i64 %idx, i64 %len) {
top:
  ; ---- leg 1: the byte-tier box, plus a GenericMemory header and its data ----
  %obj  = call ptr @julia.gc_alloc_obj(ptr %task, i64 24, ptr %tag)
  %mem  = call ptr @julia.gc_alloc_obj(ptr %task, i64 16, ptr %tag)
  %data = call ptr @julia.gc_alloc_obj(ptr %task, i64 64, ptr %tag)
  %lg = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 0
  store i64 %len, ptr %lg, align 8
  %dg = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 1
  store ptr %data, ptr %dg, align 8

  ; ---- leg 2: the WHOLE-AGGREGATE store, decomposed at BYTE cells 0 and 8 ----
  %a0  = insertvalue { ptr, ptr } zeroinitializer, ptr %data, 0
  %agg = insertvalue { ptr, ptr } %a0, ptr %mem, 1
  store { ptr, ptr } %agg, ptr %obj, align 8

  ; ---- leg 3: the SAME field, read two ways (class D and class A) ----
  %w1 = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 1
  %rD = load ptr, ptr %w1, align 8
  %b8 = getelementptr inbounds i8, ptr %obj, i32 8
  %rA = load ptr, ptr %b8, align 8
  %w0 = getelementptr inbounds { ptr, ptr }, ptr %obj, i32 0, i32 0
  %rE = load ptr, ptr %w0, align 8

  ; ---- leg 4: the closure-env frame, byte-addressed by extracted code ----
  %env = alloca [9 x i64], align 8
  %eg  = getelementptr inbounds i8, ptr %env, i32 56
  store ptr %data, ptr %eg, align 8
  %d2  = load ptr, ptr %eg, align 8

  ; ---- leg 5: the CONFINED bounds guard over leg 4's value ----
  %bo = mul i64 %idx, 8
  %e  = getelementptr i8, ptr %d2, i64 %bo
  %mg = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 1
  %mdata = load ptr, ptr %mg
  %b = ptrtoint ptr %mdata to i64
  %x = ptrtoint ptr %e to i64
  %s = sub i64 %x, %b
  %l2 = getelementptr inbounds { i64, ptr }, ptr %mem, i32 0, i32 0
  %ln = load i64, ptr %l2, align 8
  %bl = mul i64 %ln, 8
  %c = icmp ult i64 %s, %bl
  br i1 %c, label %ok, label %oob
ok:
  %eD = icmp eq ptr %rD, %mem
  %eA = icmp eq ptr %rA, %mem
  %eE = icmp eq ptr %rE, %data
  %k1 = and i1 %eD, %eA
  %k2 = and i1 %k1, %eE
  %sel = select i1 %k2, i64 1, i64 100
  %r = add i64 %idx, %sel
  ret i64 %r
oob:
  call void @ijl_bounds_error_int(ptr %mem, i64 %idx)
  unreachable
}
"""

_bvmd_build() = mktempdir() do dir
    path = joinpath(dir, "bvmd_e2e.ll")
    write(path, _IR_BVMD)
    p = _BNb.extract_parsed_ir_from_ll(path; entry_function="bvmd_e2e",
                                       ptr_cells=true)
    return (p, _BVb.lower_vm(p))
end

_bvmd_insts(pir) = [i for b in pir.blocks for i in b.instructions]

@testset "Bennett-bvmd — byte-tier cells run and reverse on the VM" begin

    # ==================================================================
    # (1) THE HANDOFF SHAPE. Every claim about cells is an assertion about
    #     `(offset_bytes, elem_width)` pairs, because that pair IS the cell
    #     under `Define(d, b, :add, off ÷ (ew÷8))`.
    # ==================================================================
    @testset "(1) the ParsedIR carries the byte-tier emission" begin
        pir, _ = _bvmd_build()
        insts = _bvmd_insts(pir)
        pos = [i for i in insts if i isa _BNb.IRPtrOffset]

        # --- leg 2: the decomposition writes BYTE cells 0 and 8 of %obj ---
        sts = [i for i in insts if i isa _BNb.IRStore]
        store_ptrs = Symbol[s.ptr.name for s in sts]
        wr = [o for o in pos if o.dest in store_ptrs &&
                                o.base == _BNb.SSAOperand(:obj)]
        @test length(wr) == 2
        @test Set((o.offset_bytes, o.elem_width) for o in wr) ==
              Set([(0, 8), (8, 8)])

        # --- leg 3: class D and class A agree, as a SYNTACTIC identity ---
        w1 = only([o for o in pos if o.dest === :w1])
        b8 = only([o for o in pos if o.dest === :b8])
        @test (w1.offset_bytes, w1.elem_width) == (8, 8)
        @test (b8.offset_bytes, b8.elem_width) == (8, 8)
        # the cell each resolves to, computed the way BVM computes it
        cell(o) = o.offset_bytes ÷ (o.elem_width ÷ 8)
        @test cell(w1) == cell(b8) == 8
        # ... and that is the cell the aggregate store's field 1 wrote
        @test 8 in [cell(o) for o in wr]
        # BEFORE bvmd the struct GEP stamped 64 and resolved to cell +1:
        @test cell(w1) != 8 ÷ (64 ÷ 8)

        # --- leg 4: the closure env's RESERVATION is BYTE-NORMALISED ---
        # `alloca [9 x i64]` reserves NINE cells; Julia addresses it with
        # `gep i8 …, 56` → cell +56, forty-eight cells past its own reservation.
        # Upstream widens the RESERVATION to 72 byte cells rather than
        # re-stamping the ACCESS.
        #
        # WHY THAT WAY ROUND (measured upstream, worth knowing here): the access
        # re-stamp is NOT closed under function boundaries. The coherence pass
        # runs per function, so a caller would re-stamp its box to word cells
        # while the CALLEE — receiving the same object as a scale-unknown
        # pointer parameter — kept byte cells. Caller writes +1, callee reads
        # +8. Executed witness: `test_40ys_closure_callee_vm.jl` gate (g)
        # returned 30 for an oracle of 42. Widening the reservation changes
        # SIZE, never addressing, so every function keeps agreeing.
        env = only([a for a in insts
                    if a isa _BNb.IRAlloca && a.dest === :env])
        @test env.elem_width == 8
        @test env.n_elems == _BNb.ConstOperand(72)
        @test 64 * 9 == env.elem_width * env.n_elems.value    # wire-count-neutral
        eg = only([o for o in pos if o.dest === :eg])
        @test (eg.offset_bytes, eg.elem_width) == (56, 8)
        @test cell(eg) == 56
        @test cell(eg) < env.n_elems.value                    # inside the 72
    end

    # ==================================================================
    # (2) lower_vm: ZERO new instruction kinds. The byte tier is expressed
    #     entirely in `Define` / `MemoryStore` / `IntrinsicGCAlloc` /
    #     `IntrinsicAlloca`, all of which shipped before this bead.
    # ==================================================================
    @testset "(2) lower_vm produces only pre-existing instruction kinds" begin
        _, prog = _bvmd_build()
        body = [i for b in prog.blocks for i in b.instructions]
        @test count(i -> i isa _BVb.MemoryStore, body) >= 4
        @test count(i -> i isa _BVb.IntrinsicGCAlloc, body) == 3
        # the byte-offset addresses are ordinary constant-add Defines
        @test count(i -> i isa _BVb.Define, body) > 0
    end

    # ==================================================================
    # (3)+(4)+(5) ORACLE, CELL AGREEMENT EXECUTED, EXACT REVERSAL.
    #
    #     NON-VACUITY: `%rD == %mem` AND `%rA == %mem` AND `%rE == %data`
    #     simultaneously. `%mem` and `%data` are DISTINCT arena addresses, so
    #     if fields 0 and 1 had shared a cell, last-write-wins would break
    #     `%rE` and the oracle would be `idx + 100`.
    # ==================================================================
    @testset "(3)+(4)+(5) oracle, agreeing cells, exact reversal" begin
        _, prog = _bvmd_build()
        regimes = (("L2 (compute_must_cache)", _BVb.compute_must_cache(prog)),
                   ("L3 (empty must_cache)",   Set{Tuple{Symbol,Int}}()))
        for (rlabel, mcs) in regimes, idx in Int64[0, 1, 5]
            s = _BVb.initial_state(prog, Dict(:idx => idx, :len => Int64(8),
                                              :task => Int64(0),
                                              :tag => Int64(0)))
            init = deepcopy(s.current)
            _BVb.run!(s, prog; max_steps=50_000, checkpoint_interval=4,
                      must_cache_set=mcs)
            # ANCHOR ($rlabel, idx = $idx)
            @test _BVb.is_halted(s)
            @test s.current.status === :halted
            res = _BVb.result(s)
            @test res[:r] == idx + 1              # the good-arm oracle
            @test res[:idx] == idx                # input preserved
            # BOTH readings of field 1 returned the stored pointer ...
            @test res[:rD] == res[:mem]
            @test res[:rA] == res[:mem]
            # ... and field 0 is intact, which is what makes that non-vacuous
            @test res[:rE] == res[:data]
            @test res[:mem] != res[:data]
            # the closure-env slot round-tripped through the byte GEP — the
            # foz5 §4a (INV) mechanism, executed
            @test res[:d2] == res[:data]
            # EXACT reversal: the Bennett-1973 invariant, whole-state.
            _BVb.unrun!(s, prog; max_unsteps=100_000)
            @test s.current == init
            @test isempty(s.history)
            @test s.step_count == 0
        end

        for K in (1, 4)
            @test per_step_inverse_check(prog,
                    Dict(:idx => Int64(5), :len => Int64(8),
                         :task => Int64(0), :tag => Int64(0));
                    checkpoint_interval=K,
                    label="bvmd/e2e/L3/K=$K") === nothing
            @test per_step_inverse_check(prog,
                    Dict(:idx => Int64(5), :len => Int64(8),
                         :task => Int64(0), :tag => Int64(0));
                    checkpoint_interval=K,
                    must_cache_set=_BVb.compute_must_cache(prog),
                    label="bvmd/e2e/L2/K=$K") === nothing
        end
    end

    # ==================================================================
    # (6) OUT OF BOUNDS HALTS — it does not return a wrong value.
    #
    #     CONSTRUCTIBLE ONLY HERE. On the real corpus `push!` on a fresh
    #     `Vector` never takes the `oob` edge, which is exactly why foz5's
    #     §4a residual ("the throw may be missed, or the halt spurious")
    #     stays undischarged by any test this arc can write.
    # ==================================================================
    @testset "(6) an out-of-bounds index halts at :__unreachable__" begin
        _, prog = _bvmd_build()
        # the sink block really is materialised, per-function `#`-qualified
        labels = [b.label for b in prog.blocks]
        @test any(l -> occursin("__unreachable__", String(l)), labels)

        s = _BVb.initial_state(prog, Dict(:idx => Int64(9), :len => Int64(8),
                                          :task => Int64(0), :tag => Int64(0)))
        # `run!` fails LOUD on the `:error` status the sink's `UnreachableHalt`
        # sets on entry (Rule 1) — the halt is the OBSERVABLE, not a return.
        @test_throws Exception _BVb.run!(s, prog; max_steps=50_000,
                                         checkpoint_interval=4)
        @test s.current.status === :error
        # ... and `:error` is NOT `:halted`: the sink's `UnreachableHalt` sets
        # a status distinct from a normal `EndInstruction`'s, so a wrong answer
        # cannot be mistaken for a result (ADR 0017 §4, test_utzc gate 2).
        @test !_BVb.is_halted(s)
    end
end
