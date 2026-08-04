# test/test_vau9_memmove_vm.jl — the BennettVM (downstream) half of Bennett.jl
# bead `Bennett-vau9`.
#
# # What upstream changed
#
# Under the closed-world `ptr_cells` gate, `llvm.memmove.p0.p0.i64(dst, src,
# nbytes, i1 false)` no longer fails loud: it routes to
#   IRCall(dest, :memmove, [dst_cell, src_cell, nbytes], [64,64,64], 64)
# (the D5b void-call dest-sentinel shape ratified by Bennett-8bys for
# variable-size memset). This is wall 4 of the `bennettvm-xkl` push!-Vector
# chain — the `_growend!` grow-copy that moves the old elements into the newly
# allocated buffer.
#
# # Why BVM has ZERO src changes (and what this file is for)
#
# `:memmove` was ALREADY in `_HEAP_DISPATCH` (`src/ir/ingest_call.jl:171`) with
# its own ingest arm (:100-105), and `IntrinsicMemmove`
# (`src/ir/intrinsics_bulk.jl:84-147`) is overlap-safe by construction: its
# `_copy_range!` snapshots the ENTIRE src range into a temporary before writing
# any dest cell, so a forward-overlapping and a backward-overlapping move are
# both correct without any direction analysis. It reverses via the L2
# dest-range delta (`is_l2_capable(::Type{IntrinsicMemmove}) = true`), which is
# complete because the clobbered src cells are a SUBSET of the dest range.
#
# `test_arena_roundtrip.jl:224-239` already pins that at the INSTRUCTION level
# (hand-built `IntrinsicMemmove`, 2 overlapping cells, forward + inverse). What
# has NEVER been executed is the END-TO-END claim, and in particular the two
# unit conversions on the path from LLVM to the arena:
#
#   * `nbytes` is carried in BYTES all the way to `IntrinsicMemmove`, and only
#     `_cell_count` divides by 8 — pinned explicitly below (`nbytes_operand`
#     must be 16, NOT 2, for a two-cell move). A premature ÷8 upstream would
#     silently copy an eighth of the range.
#   * a `getelementptr i64, ptr %p, i64 1` becomes `IRPtrOffset(.., 8, 64)`
#     upstream and `Define(:p1, :p, :add, 1)` here — BYTES to CELLS.
#
# This file is the cross-repo E2E: hand-written `.ll` → the REAL Bennett
# front-end (`extract_parsed_ir_from_ll`, ptr_cells=true) → `lower_vm` →
# `run!` vs a hand-computed oracle → `unrun!` exact, under L2 AND L3, plus
# per-step inverse at two checkpoint densities.
#
# # What this pins (Rule 4 — known values, never "didn't throw")
#
#   (1) the ParsedIR BVM receives really carries `IRCall(:memmove)` with the
#       dst/src operands in LLVM argument ORDER and a BYTE count;
#   (2) `lower_vm` produces `IntrinsicMemmove(dest_ptr, src_ptr, nbytes)` with
#       the same order and the count still in BYTES;
#   (3) forward `run!` matches a hand-computed oracle for FORWARD-overlapping,
#       BACKWARD-overlapping, DISJOINT and VARIABLE-length moves — the overlap
#       cases are the ones Bennett-8bys's memset siblings could not cover, and
#       they are constructed so a naive ascending in-place copy gives a
#       DIFFERENT answer;
#   (4) `unrun!` returns the EXACT initial state with a drained history under
#       both history regimes, and `per_step_inverse_check` passes at K ∈ {1,4}.
#
# # HONEST SCOPE BOUNDARY — this file is the C/word tier only
#
# Every fixture here allocates with `malloc`, i.e. the C heap tier (word-
# granular ÷8 reservations). The REAL `_growend!` grow-copy will arrive in a
# JULIA-tier program (`gc_alloc_obj` / `jl_alloc_genericmemory_unchecked`,
# byte-granular reservations), and `_enforce_julia_heap_tier!`
# (`src/ir/intrinsics_genericmemory.jl:192-199`) FAILS LOUD on an
# `IntrinsicMemcpy`/`IntrinsicMemmove` in such a program — its `÷8` span would
# silently copy an eighth of the byte range. That reject is DELIBERATE and
# already names the follow-up (`bennettvm-rxgy`: a byte-exact
# `IntrinsicMemmoveBytes`, the sibling of the existing `IntrinsicMemsetBytes`).
#
# So: Bennett-vau9's extraction-side routing is complete and the VM mechanism
# is proven here end-to-end, but the push! chain will meet the rxgy byte-tier
# wall at `lower_vm` once its remaining EXTRACTION walls clear. Nothing in this
# file claims otherwise. `_cell_count` is likewise fail-loud on a non-cell-
# divisible or negative `nbytes` (`src/ir/intrinsics.jl:128-139`), so a
# sub-cell C-tier memmove is a loud run-time error, never a short copy.
#
# # Ref
#   * `../Bennett.jl/test/test_vau9_variable_memmove.jl` — the upstream gate
#     (extraction-side predicates + the push!-set advancement pin).
#   * `../Bennett.jl/src/extract/instructions.jl` — the memmove arm.
#   * `src/ir/intrinsics_bulk.jl` — `IntrinsicMemmove` / `_copy_range!`.
#   * `test/test_3vf2_dead_use_global_load.jl` — the hand-written-`.ll`-through-
#     the-real-front-end E2E idiom reused here.

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

const _BVM9 = BennettVM
const _BNM9 = Bennett

# Every routine mallocs a small arena buffer, seeds it with its arguments, does
# ONE memmove, and reads back every cell (so `result` exposes all of them).
const _IRVAU9 = """
declare ptr @malloc(i64)
declare void @llvm.memmove.p0.p0.i64(ptr nocapture writeonly, ptr nocapture readonly, i64, i1 immarg)

; FORWARD overlap (dst > src): cells [a,b,c] --memmove(+1 <- +0, 2 cells)-->
; [a,a,b]. A naive ASCENDING in-place copy would give [a,a,a] — cell 2 would
; read the ALREADY-overwritten cell 1. This is the discriminating probe.
define i64 @mm_fwd_overlap(i64 %a, i64 %b, i64 %c) {
entry:
  %p = call ptr @malloc(i64 32)
  %p1 = getelementptr i64, ptr %p, i64 1
  %p2 = getelementptr i64, ptr %p, i64 2
  store i64 %a, ptr %p
  store i64 %b, ptr %p1
  store i64 %c, ptr %p2
  call void @llvm.memmove.p0.p0.i64(ptr %p1, ptr %p, i64 16, i1 false)
  %r0 = load i64, ptr %p
  %r1 = load i64, ptr %p1
  %r2 = load i64, ptr %p2
  ret i64 %r2
}

; BACKWARD overlap (dst < src): cells [a,b,c] --memmove(+0 <- +1, 2 cells)-->
; [b,c,c]. A naive DESCENDING in-place copy would give [c,c,c].
define i64 @mm_bwd_overlap(i64 %a, i64 %b, i64 %c) {
entry:
  %p = call ptr @malloc(i64 32)
  %p1 = getelementptr i64, ptr %p, i64 1
  %p2 = getelementptr i64, ptr %p, i64 2
  store i64 %a, ptr %p
  store i64 %b, ptr %p1
  store i64 %c, ptr %p2
  call void @llvm.memmove.p0.p0.i64(ptr %p, ptr %p1, i64 16, i1 false)
  %r0 = load i64, ptr %p
  %r1 = load i64, ptr %p1
  %r2 = load i64, ptr %p2
  ret i64 %r0
}

; DISJOINT (the memcpy-equivalent case, which memmove must also get right):
; cells [a,b,c,d] --memmove(+2 <- +0, 2 cells)--> [a,b,a,b].
define i64 @mm_disjoint(i64 %a, i64 %b, i64 %c, i64 %d) {
entry:
  %p = call ptr @malloc(i64 32)
  %p1 = getelementptr i64, ptr %p, i64 1
  %p2 = getelementptr i64, ptr %p, i64 2
  %p3 = getelementptr i64, ptr %p, i64 3
  store i64 %a, ptr %p
  store i64 %b, ptr %p1
  store i64 %c, ptr %p2
  store i64 %d, ptr %p3
  call void @llvm.memmove.p0.p0.i64(ptr %p2, ptr %p, i64 16, i1 false)
  %r0 = load i64, ptr %p
  %r1 = load i64, ptr %p1
  %r2 = load i64, ptr %p2
  %r3 = load i64, ptr %p3
  ret i64 %r2
}

; VARIABLE length — the real `_growend!` grow-copy shape: the byte count is a
; runtime SSA value, and the move forward-overlaps. n = 0 / 8 / 16 bytes.
define i64 @mm_var_n(i64 %a, i64 %b, i64 %c, i64 %n) {
entry:
  %p = call ptr @malloc(i64 32)
  %p1 = getelementptr i64, ptr %p, i64 1
  %p2 = getelementptr i64, ptr %p, i64 2
  store i64 %a, ptr %p
  store i64 %b, ptr %p1
  store i64 %c, ptr %p2
  call void @llvm.memmove.p0.p0.i64(ptr %p1, ptr %p, i64 %n, i1 false)
  %r0 = load i64, ptr %p
  %r1 = load i64, ptr %p1
  %r2 = load i64, ptr %p2
  ret i64 %r2
}
"""

# --- The irreversible ORACLE, written independently of the VM (Rule 4) ------
# `mem` is a plain Julia Vector of cells; `dst`/`src` are 1-based cell indices.
# The snapshot (`copy`) is the whole point: it is what makes a memmove
# overlap-safe, and it is the property `IntrinsicMemmove._copy_range!` claims.
function _vau9_oracle(cells::Vector{Int64}, dst::Int, src::Int, nbytes::Int)
    m = copy(cells)
    ncells = div(nbytes, 8)
    snap = m[src:(src + ncells - 1)]
    m[dst:(dst + ncells - 1)] = snap
    return m
end

_vau9_build(entry) = mktempdir() do dir
    path = joinpath(dir, "vau9.ll")
    write(path, _IRVAU9)
    p = _BNM9.extract_parsed_ir_from_ll(path; entry_function=entry, ptr_cells=true)
    return (p, _BVM9.lower_vm(p))
end

_vau9_only_call(pir) = only([i for b in pir.blocks for i in b.instructions
                             if i isa _BNM9.IRCall && i.callee === :memmove])
_vau9_only_mm(prog) = only([i for b in prog.blocks for i in b.instructions
                            if i isa _BVM9.IntrinsicMemmove])

@testset "Bennett-vau9 — routed memmove runs and reverses on the VM" begin

    # ==================================================================
    # (1)+(2) the handoff shape: IRCall(:memmove) → IntrinsicMemmove,
    #         operand ORDER preserved, count still in BYTES.
    # ==================================================================
    @testset "(1)+(2) handoff shape: order preserved, nbytes in BYTES" begin
        pir, prog = _vau9_build("mm_fwd_overlap")

        call = _vau9_only_call(pir)
        @test call.arg_widths == [64, 64, 64]
        @test call.ret_width == 64                        # D5b void sentinel
        @test call.args[1] == _BNM9.SSAOperand(:p1)       # dst
        @test call.args[2] == _BNM9.SSAOperand(:p)        # src
        @test call.args[3] == _BNM9.ConstOperand(16)      # BYTES

        mm = _vau9_only_mm(prog)
        @test mm.dest_ptr === :p1
        @test mm.src_ptr === :p
        # LOAD-BEARING: the count is still 16 BYTES here — `_cell_count`
        # divides by 8 at run time. A `2` would mean someone converted early
        # and every later byte-granular caller would copy 1/8th of the range.
        @test mm.nbytes_operand == 16

        # The byte→cell conversion that DOES happen upstream is the GEP:
        # `getelementptr i64, ptr %p, i64 1` (8 bytes) → `Define(:p1,:p,:add,1)`.
        defs = [i for b in prog.blocks for i in b.instructions
                if i isa _BVM9.Define && i.target === :p1]
        @test length(defs) == 1
        @test defs[1].rhs == 1                            # ONE cell, not 8
    end

    # ==================================================================
    # (3)+(4) forward == oracle, unrun! exact, under BOTH history regimes.
    # ==================================================================
    # (entry, args, cell seeds, dst cell (1-based), src cell, nbytes)
    _cases = (
        ("mm_fwd_overlap", (:a, :b, :c), 3, 2, 1, 16),
        ("mm_bwd_overlap", (:a, :b, :c), 3, 1, 2, 16),
        ("mm_disjoint",    (:a, :b, :c, :d), 4, 3, 1, 16),
    )

    @testset "(3)+(4) $(entry): forward == oracle; unrun! exact" for
            (entry, argnames, ncells, dst, src, nbytes) in _cases
        pir, prog = _vau9_build(entry)
        @test _vau9_only_mm(prog) isa _BVM9.IntrinsicMemmove

        regimes = (("L2 (compute_must_cache)", _BVM9.compute_must_cache(prog)),
                   ("L3 (empty must_cache)",   Set{Tuple{Symbol,Int}}()))
        seeds = (Int64[11, 22, 33, 44], Int64[-1, 0, 7, typemax(Int64)],
                 Int64[5, 5, 5, 5])
        for (rlabel, mcs) in regimes, seed in seeds
            vals = Int64[seed[i] for i in 1:ncells]
            args = Dict(argnames[i] => vals[i] for i in 1:ncells)
            s = _BVM9.initial_state(prog, args)
            init = deepcopy(s.current)
            _BVM9.run!(s, prog; max_steps=10_000, checkpoint_interval=4,
                       must_cache_set=mcs)
            @test _BVM9.is_halted(s)
            @test s.current.status === :halted

            want = _vau9_oracle(vals, dst, src, nbytes)
            res = _BVM9.result(s)
            for i in 1:ncells
                # ANCHOR ($rlabel, $entry, seed=$vals): cell i-1 after the move.
                @test res[Symbol("r", i - 1)] == want[i]
            end
            # inputs preserved
            for i in 1:ncells
                @test res[argnames[i]] == vals[i]
            end

            _BVM9.unrun!(s, prog; max_unsteps=10_000)
            @test s.current == init
            @test isempty(s.history)
            @test s.step_count == 0
        end
    end

    # ==================================================================
    # (3b) THE OVERLAP DISCRIMINATORS — spelled out as standalone claims so a
    #      regression to a naive in-place copy names itself.
    # ==================================================================
    @testset "(3b) forward-overlap is snapshot-safe, NOT an ascending copy" begin
        _, prog = _vau9_build("mm_fwd_overlap")
        s = _BVM9.initial_state(prog, Dict(:a => Int64(11), :b => Int64(22),
                                           :c => Int64(33)))
        _BVM9.run!(s, prog; max_steps=10_000, checkpoint_interval=4,
                   must_cache_set=_BVM9.compute_must_cache(prog))
        res = _BVM9.result(s)
        @test (res[:r0], res[:r1], res[:r2]) == (11, 11, 22)   # correct
        @test res[:r2] != 11                                    # NOT [a,a,a]
    end

    @testset "(3b) backward-overlap is snapshot-safe, NOT a descending copy" begin
        _, prog = _vau9_build("mm_bwd_overlap")
        s = _BVM9.initial_state(prog, Dict(:a => Int64(11), :b => Int64(22),
                                           :c => Int64(33)))
        _BVM9.run!(s, prog; max_steps=10_000, checkpoint_interval=4,
                   must_cache_set=_BVM9.compute_must_cache(prog))
        res = _BVM9.result(s)
        @test (res[:r0], res[:r1], res[:r2]) == (22, 33, 33)   # correct
        @test res[:r0] != 33                                    # NOT [c,c,c]
    end

    # ==================================================================
    # (3c) VARIABLE byte count — the real `_growend!` shape.
    # ==================================================================
    @testset "(3c) variable-n memmove: forward == oracle; unrun! exact" begin
        pir, prog = _vau9_build("mm_var_n")
        call = _vau9_only_call(pir)
        @test call.args[3] == _BNM9.SSAOperand(:n)     # runtime SSA byte count
        mm = _vau9_only_mm(prog)
        @test mm.nbytes_operand === :n                 # Symbol, resolved at run

        regimes = (("L2", _BVM9.compute_must_cache(prog)),
                   ("L3", Set{Tuple{Symbol,Int}}()))
        for (rlabel, mcs) in regimes, n in Int64[0, 8, 16]
            vals = Int64[11, 22, 33]
            s = _BVM9.initial_state(prog, Dict(:a => vals[1], :b => vals[2],
                                               :c => vals[3], :n => n))
            init = deepcopy(s.current)
            _BVM9.run!(s, prog; max_steps=10_000, checkpoint_interval=4,
                       must_cache_set=mcs)
            @test _BVM9.is_halted(s)
            want = _vau9_oracle(vals, 2, 1, Int(n))    # dst=+1, src=+0
            res = _BVM9.result(s)
            @test (res[:r0], res[:r1], res[:r2]) == (want[1], want[2], want[3])
            _BVM9.unrun!(s, prog; max_unsteps=10_000)
            @test s.current == init                    # n=0 is a true no-op
            @test isempty(s.history)
            @test s.step_count == 0
        end
    end

    # ==================================================================
    # (4b) per-step inverse (the M8.2 load-bearing pattern) at K ∈ {1,4},
    #      L2 (must-cache) and L3 (empty). A mid-program reversal bug shows
    #      up as a step-indexed mismatch rather than a masked aggregate pass.
    # ==================================================================
    @testset "(4b) per-step inverse, K ∈ {1,4}, L2 + L3" begin
        for entry in ("mm_fwd_overlap", "mm_bwd_overlap")
            _, prog = _vau9_build(entry)
            args = Dict(:a => Int64(11), :b => Int64(22), :c => Int64(33))
            for K in (1, 4)
                @test per_step_inverse_check(prog, args;
                    checkpoint_interval = K,
                    must_cache_set = _BVM9.compute_must_cache(prog),
                    label = "$(entry)/L2/K=$K") === nothing
                @test per_step_inverse_check(prog, args;
                    checkpoint_interval = K,
                    label = "$(entry)/L3/K=$K") === nothing
            end
        end
    end
end
