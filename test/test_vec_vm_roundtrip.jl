# test/test_vec_vm_roundtrip.jl — SC9 Case A `mem=:vm` END-TO-END round-trip
# gate, driven from JULIA SOURCE (bead `Bennett-jfw6`; ADR 0016).
#
# # What this gate proves, and why it is THE Case-A milestone
#
# `test_dyn_roundtrip.jl` proves BennettVM round-trips a dynamic-`Vector`
# program when the IR arrives from a hand-trimmed C `.ll` (`frtN.ll`). This
# file closes the remaining gap: it drives the SAME `IRAlloca(dyn) + IRVarGEP
# + IRStore/IRLoad` shape from a REAL Julia `Vector{T}(undef, n)` function,
# through the Bennett.jl `mem=:vm` Case-A Memory recogniser (`src/extract/
# vector_vm.jl`, ADR 0016) that strips Julia's GC / GenericMemory skeleton, all
# the way to empty history. It is the executable proof that a dynamic Julia
# `Vector` is reversible end-to-end under `target=:reversible_vm` — the highest-
# value milestone in the project (the raison d'être: unlock while-loops /
# dynamic memory for next-version Bennett.jl).
#
# # The two programs (golden-master oracles; Rule 4 — every assert vs a value)
#
#   vsum(n)  = (v=Vector{Int8}(undef,n);  s=Int8(0); for i in 1:n; v[i]=Int8(i); s+=v[i]; end; s)
#   fvec(n)  = (v=Vector{Int64}(undef,n); s=0;       for i in 1:n; v[i]=i;       s+=v[i]; end; s)
#
# with co-located irreversible oracles. `vsum` is the i8 variant — it exercises
# the D6 stride recovery (`mul %off, 1` → cell stride; a hardcoded ÷8 would
# miscompile it) AND the `Int8(i)` truncation/inexact diamond. `fvec` is the
# i64 keystone (`mul %off, 8`), congruent to the proven C `frtN` shape. Both
# WRITE then READ-BACK a single dynamic array and reduce — the full Case-A
# program, with the loop CFG preserved (a MULTI-block ParsedIR).
#
# # The adversarial gates (must FAIL LOUD — Rule 1 / ADR 0016 fail-loud matrix)
#
#   * `optimize=true` `fvec` — the O2/SIMD program is a DIFFERENT program (the
#     read loop is deleted, the write loop is `store <4 x i64>`); D1 rejects it.
#   * two distinct dynamic `Vector`s — Case A is single-array; the second
#     `jl_alloc_genericmemory_unchecked` rejects (→ the `uil` multi-array bead).
#
# # Ref
#   * `docs/adr/0016-case-a-mem-vm-recognizer.md` — the recogniser design
#     (D1–D8 + fail-loud matrix + this test plan).
#   * `test/test_dyn_roundtrip.jl` — the C `frtN` Case-A gate this mirrors.
#   * `../Bennett.jl/src/extract/vector_vm.jl` — the recogniser under test.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known values), Rule 5 (mutation-
#     proof), Rule 11 (literate).

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# ---- The programs + their irreversible golden-master oracles (Rule 4). ----
# Defined as top-level functions so `extract_parsed_ir` can JIT them.

vsum(n) = (v = Vector{Int8}(undef, n); s = Int8(0);
           for i in 1:n; v[i] = Int8(i); s += v[i]; end; s)
fvec(n) = (v = Vector{Int64}(undef, n); s = 0;
           for i in 1:n; v[i] = i; s += v[i]; end; s)

# Oracles. `vsum` wraps in i8 (Julia `Int8 +` overflows mod 256); `fvec` is
# wide enough for the n exercised. `init` handles n<=0 (empty Vector → 0).
vsum_ref(n::Integer) = (s = Int8(0); for i in 1:n; s += Int8(i); end; s)
fvec_ref(n::Integer) = sum(i for i in 1:n; init = 0)

# A second-Vector program (the `uil` reject — two dynamic backings).
fvec2(n) = (a = Vector{Int64}(undef, n); b = Vector{Int64}(undef, n); s = 0;
            for i in 1:n; a[i] = i; b[i] = i; s += a[i] + b[i]; end; s)

# The routine result SSA name — the `IRRet` operand (the return block is not
# necessarily emitted last under the loop-preserving CFG, so scan for it).
function _vec_vm_ret_key(p)
    for b in p.blocks
        b.terminator isa Bennett.IRRet && return b.terminator.op.name
    end
    error("no IRRet in the extracted Case-A ParsedIR")
end

# Run one Julia source program through extract → lower → run!/unrun!, asserting
# forward == oracle bit-for-bit and a clean reverse to empty history.
function _vec_vm_roundtrip(f, oracle, inputs; K = 4)
    p = Bennett.extract_parsed_ir(f, Tuple{Int64}; optimize = false, mem = :vm)
    @test p isa Bennett.ParsedIR
    @test length(p.blocks) >= 2          # the loop CFG is PRESERVED (D7)

    # Exactly ONE dynamic-N IRAlloca (the single recognised Vector backing).
    dyn = [a for b in p.blocks for a in b.instructions
           if a isa Bennett.IRAlloca && a.n_elems isa Bennett.SSAOperand]
    @test length(dyn) == 1
    # Element access is a single-index IRVarGEP onto that alloca's base.
    geps = [g for b in p.blocks for g in b.instructions if g isa Bennett.IRVarGEP]
    @test !isempty(geps)
    @test all(g -> g.base == Bennett.SSAOperand(dyn[1].dest), geps)

    vm = lower_vm(p)
    @test vm isa VMProgram
    mcs = BennettVM.compute_must_cache(vm)

    arg_key = p.args[1][1]
    ret_key = _vec_vm_ret_key(p)

    for n in inputs
        rs = initial_state(vm, Dict(arg_key => Int64(n)))
        initial_snap = deepcopy(rs.initial)
        run!(rs, vm; checkpoint_interval = K, must_cache_set = mcs)
        @test is_halted(rs)
        @test result(rs)[ret_key] == oracle(n)        # golden master, bit-exact
        unrun!(rs, vm)
        @test rs.current == rs.initial                 # P0.6 — reversed to start
        @test isempty(rs.history)                      # P0.6 — history drained
        @test rs.step_count == 0                       # P0.6 — counter reset
        @test rs.initial == initial_snap               # initial never mutated
    end
    return p
end

@testset "Case A mem=:vm — Julia Vector round-trip (Bennett-jfw6 / ADR 0016)" begin

    @testset "fvec (Int64) — write+read+reduce, congruent to frtN" begin
        _vec_vm_roundtrip(fvec, fvec_ref, (1, 2, 5, 8))
    end

    @testset "vsum (Int8) — D6 stride (mul %off,1), Int8(i) inexact diamond" begin
        _vec_vm_roundtrip(vsum, vsum_ref, (1, 2, 5, 8))
    end

    @testset "per-step inverse (mixed L2/L3) — fvec at K in {1, 4}" begin
        p = Bennett.extract_parsed_ir(fvec, Tuple{Int64}; optimize = false, mem = :vm)
        vm = lower_vm(p)
        mcs = BennettVM.compute_must_cache(vm)
        arg_key = p.args[1][1]
        for K in (1, 4)
            @test per_step_inverse_check(
                vm, Dict(arg_key => Int64(5));
                checkpoint_interval = K, must_cache_set = mcs,
                label = "fvec/K=$K") === nothing
        end
    end

    @testset "mixed L2/L3 history occurs (the DynAlloca (base,n) + store deltas)" begin
        p = Bennett.extract_parsed_ir(fvec, Tuple{Int64}; optimize = false, mem = :vm)
        vm = lower_vm(p)
        mcs = BennettVM.compute_must_cache(vm)
        arg_key = p.args[1][1]
        rs = initial_state(vm, Dict(arg_key => Int64(5)))
        run!(rs, vm; checkpoint_interval = 4, must_cache_set = mcs)
        deltas = filter(e -> e isa BennettVM.DeltaEntry, rs.history)
        ckpts  = filter(e -> e isa BennettVM.CheckpointEntry, rs.history)
        @test length(deltas) >= 1
        @test length(ckpts) >= 1
        alloca_deltas = filter(e -> e.instruction isa BennettVM.DynAlloca, deltas)
        @test length(alloca_deltas) == 1
        @test alloca_deltas[1].payload.n == 5
    end

    # ---- Adversarial: the fail-loud matrix (Rule 1 / ADR 0016). ----
    @testset "optimize=true rejects loud (D1 — O2/SIMD is a different program)" begin
        @test_throws Exception Bennett.extract_parsed_ir(
            fvec, Tuple{Int64}; optimize = true, mem = :vm)
    end

    @testset "two dynamic Vectors reject loud (→ multi-array `uil` bead)" begin
        @test_throws Exception Bennett.extract_parsed_ir(
            fvec2, Tuple{Int64}; optimize = false, mem = :vm)
    end
end
