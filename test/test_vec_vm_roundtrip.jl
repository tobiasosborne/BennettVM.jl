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
# Int32 variant — stride=4 (a non-{1,8} byte stride). Proves the ADR 0016 D6
# byte-offset → element-index recovery uses the RECOGNISED stride (`mul %off, 4`),
# never a hardcoded ÷8 (the b5x trap) and never the i8 stride 1. Same
# write+read+reduce shape as `fvec`/`vsum`; `Int32 +` wraps mod 2^32 (the n
# exercised is far below overflow, so the oracle sum is exact).
fvec32(n) = (v = Vector{Int32}(undef, n); s = Int32(0);
             for i in 1:n; v[i] = Int32(i); s += v[i]; end; s)

# Oracles. `vsum` wraps in i8 (Julia `Int8 +` overflows mod 256); `fvec` is
# wide enough for the n exercised. `init` handles n<=0 (empty Vector → 0).
vsum_ref(n::Integer) = (s = Int8(0); for i in 1:n; s += Int8(i); end; s)
fvec_ref(n::Integer) = sum(i for i in 1:n; init = 0)
fvec32_ref(n::Integer) = (s = Int32(0); for i in 1:n; s += Int32(i); end; s)

# A second-Vector program (the `uil` reject — two dynamic backings).
fvec2(n) = (a = Vector{Int64}(undef, n); b = Vector{Int64}(undef, n); s = 0;
            for i in 1:n; a[i] = i; b[i] = i; s += a[i] + b[i]; end; s)

# ---- Adversarial-guard fixtures (Tasks for beads Bennett-msob / Bennett-bal6) --
# A Vector pointer escaping into a `@noinline` helper — exercises the ADR 0016
# P-callee fail-loud guard (`vector_vm_walk.jl`): the user CALL whose argument is
# the Vector pointer taints into `skel` and would be SILENTLY DROPPED (a Rule-1
# silent miscompile of the callee's effects) without the guard. `@noinline` keeps
# `g!` an out-of-line CALL at optimize=false (no inlining to dissolve it).
@noinline _vec_vm_g!(v::Vector{Int64}) = (v[1] = 99; nothing)
fvec_escape(n) = (v = Vector{Int64}(undef, n); _vec_vm_g!(v); s = 0;
                  for i in 1:n; v[i] = i; s += v[i]; end; s)

# A branch on a SKELETON-derived value (the Memory length) with BOTH arms live —
# exercises the ADR 0016 cond_skel-both-arms-live guard (`vector_vm_term.jl`).
# `length(v)` reads the Memory length field (a dropped-skeleton value), so the
# `if length(v) > 3` branch is skeleton-conditioned; both arms do real (kept)
# work, so neither collapses to a dead/throw arm. The recogniser cannot prove
# which direction the surviving slice takes → must fail loud rather than
# silently emit `succs[1]` (the wrong arm for a more complex program).
fvec_cond(n) = begin
    v = Vector{Int64}(undef, n); s = 0
    for i in 1:n; v[i] = i; end
    s = length(v) > 3 ? v[1] + 10 : v[1] + 20
    s
end

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

    # bead bennettvm-1z0 — Int32 (stride=4) proves D6 recovers a non-{1,8} byte
    # stride from the recognised `mul %off, 4`, not a hardcoded ÷8 (b5x trap).
    @testset "fvec32 (Int32) — D6 stride (mul %off,4), non-{1,8} stride proof" begin
        p = _vec_vm_roundtrip(fvec32, fvec32_ref, (1, 2, 5, 8))
        # The synthetic alloca's element width is the i32 width (32 bits): D6
        # recovered the stride-4 cell width, not the i64 (64) / i8 (8) default.
        dyn = [a for b in p.blocks for a in b.instructions
               if a isa Bennett.IRAlloca && a.n_elems isa Bennett.SSAOperand]
        @test length(dyn) == 1
        @test dyn[1].elem_width == 32
    end

    # bead bennettvm-y3f2 — n=0 (empty Vector / loop-skipped). The `1:0`
    # UnitRange is empty so the write+read loop body never runs; the reduce stays
    # at its identity (0). The DynAlloca(base, n=0) still allocates a zero-length
    # region and the round-trip must drain to empty history (P0.6) at n=0 too.
    @testset "n=0 empty Vector / loop-skip round-trip (bennettvm-y3f2)" begin
        _vec_vm_roundtrip(fvec,  fvec_ref,  (0,))
        _vec_vm_roundtrip(vsum,  vsum_ref,  (0,))
        _vec_vm_roundtrip(fvec32, fvec32_ref, (0,))
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

    # bead Bennett-msob — P-callee fail-loud (HIGH gap B). A Vector pointer
    # escaping into a `@noinline` helper taints into `skel`; without the guard it
    # is SILENTLY DROPPED (miscompiling away the callee's effects). The guard
    # names the unrecognised callee and refuses.
    @testset "Vector → @noinline helper rejects loud (P-callee, Bennett-msob)" begin
        @test_throws ErrorException Bennett.extract_parsed_ir(
            fvec_escape, Tuple{Int64}; optimize = false, mem = :vm)
        # Rule 4: pin the INTENDED reject (P-callee), not any unrelated error.
        local msg = ""
        try
            Bennett.extract_parsed_ir(fvec_escape, Tuple{Int64};
                                      optimize = false, mem = :vm)
        catch e
            msg = sprint(showerror, e)
        end
        @test occursin("P-callee", msg)
        @test occursin("not an allowlisted Case-A callee", msg)
    end

    # bead Bennett-bal6 — cond_skel-both-arms-live fail-loud (HIGH gap A). A
    # branch on a skeleton-derived value (`length(v)`) whose BOTH arms are live
    # in a KEPT block: the recogniser cannot prove the direction and must reject
    # rather than silently emit `succs[1]` (the wrong arm). CONTRARY to ADR
    # 0016's test-plan note that this "may be hard to construct from O0 Julia
    # source" — it IS constructible: `length(v) > k` reads the Memory length
    # field (skeleton) and a `?:` keeps both arms live. (Bounds/inexact guards
    # always have one dead arm, so THOSE never reach this path; an explicit
    # length-conditioned user branch does.)
    @testset "skeleton-cond branch, both arms live, rejects loud (Bennett-bal6)" begin
        @test_throws ErrorException Bennett.extract_parsed_ir(
            fvec_cond, Tuple{Int64}; optimize = false, mem = :vm)
        local msg = ""
        try
            Bennett.extract_parsed_ir(fvec_cond, Tuple{Int64};
                                      optimize = false, mem = :vm)
        catch e
            msg = sprint(showerror, e)
        end
        @test occursin("BOTH arms are live", msg)
    end
end

# ---- Mutation-proof: the element-store classification (Rule 5; bead -p1vv) ----
#
# # Why this mutation-proof, and what it pins
#
# The Case-A round-trip above is GREEN; Rule 5 demands the suite itself PROVE
# that GREEN catches the load-bearing miscompile, not merely that the test was
# committed. The single most dangerous Case-A miscompile is reclassifying an
# element STORE from re-rooted TRAFFIC (emitted as `IRVarGEP + IRStore` onto the
# DynAlloca base) to dropped SKELETON: the partition's whole point (ADR 0016 D2)
# is that the element data is LIVE into the return, so silently dropping a store
# leaves the Vector unwritten and the read-back reduce yields the WRONG value —
# but the program still runs and reverses cleanly, so a weaker test stays GREEN.
#
# This testset follows `test/test_mutation_proof.jl`'s discipline exactly:
# `Bennett.eval(body)` shadows the canonical `_vec_vm_emit_access!`
# (the function that decides store→IRStore vs drop) with a mutation that OMITS
# the `IRStore` for a `:store` access (the skeleton↔traffic flip), confirms the
# round-trip goes RED (forward result ≠ oracle), then ALWAYS restores via
# `Base.delete_method` in a `try/finally` and re-runs a post-restore GREEN
# assertion (the load-bearing safety mechanism: if restoration silently fails,
# the GREEN check goes RED and aborts loudly rather than corrupting every
# subsequent test). World-age caveat (also from test_mutation_proof.jl): the
# JIT-compiled `extract_parsed_ir` will not see the freshly-`eval`'d method
# unless dispatch is forced at the current world, so every call into the mutated
# recogniser goes through `Base.invokelatest`.
#
# Mutating the RECOGNISER (Bennett.jl) rather than a BennettVM `inverse()` is the
# right target here: the miscompile this gate guards lives in the Case-A
# partition, not the reversible interpreter. Ref: CLAUDE.md Rule 5; ADR 0016
# "Mutation-proof"; test/test_mutation_proof.jl.
@testset "mutation-proof — element-store classification (Rule 5, bennettvm-p1vv)" begin
    # The canonical method's signature (1-based positional types of
    # `_vec_vm_emit_access!`). The set-diff snapshot/restore (robust to
    # identical-signature shadowing) mirrors test_mutation_proof.jl `_snapshot`.
    sig = Tuple{Vector{Bennett.IRInst}, Bennett._VecAccess,
                Bennett.LLVM.Function, Dict{Bennett._LLVMRef, Symbol},
                Ref{Int}, Symbol, Int}
    before = Set{Method}(methods(Bennett._vec_vm_emit_access!, sig))
    @test !isempty(before)        # the canonical method exists to be mutated.

    # The mutation: a `:store` access emits its IRVarGEP but DROPS the IRStore —
    # i.e. classifies the element store as skeleton (dropped) not traffic. The
    # written value never reaches the cell; the read-back reduce yields 0.
    mutation = quote
        function _vec_vm_emit_access!(body::Vector{IRInst}, a::_VecAccess,
                                     func::LLVM.Function, names::Dict{_LLVMRef,Symbol},
                                     counter::Ref{Int}, base_sym::Symbol, W::Int)
            gep_sym = Symbol("_vecvm_gep#", counter[]); counter[] += 1
            idx_v = _heap_value_for_ref(func, a.index)
            idx_v === nothing &&
                _vec_vm_error("element cell-index operand is unresolved")
            push!(body, IRVarGEP(gep_sym, SSAOperand(base_sym),
                                 _operand(idx_v, names), W))
            if a.kind == :store
                # MUTATION (skeleton↔traffic flip): drop the element store.
            else
                push!(body, IRLoad(names[a.inst], SSAOperand(gep_sym), W))
            end
            return nothing
        end
    end

    red = false
    try
        Bennett.eval(mutation)
        # RED driver: the round-trip forward result must diverge from the oracle
        # (or raise — both are RED). n=5 → oracle 15; the dropped store → 0.
        try
            p = Base.invokelatest(Bennett.extract_parsed_ir, fvec, Tuple{Int64};
                                  optimize = false, mem = :vm)
            vm = lower_vm(p)
            mcs = BennettVM.compute_must_cache(vm)
            arg_key = p.args[1][1]
            ret_key = _vec_vm_ret_key(p)
            rs = initial_state(vm, Dict(arg_key => Int64(5)))
            run!(rs, vm; checkpoint_interval = 4, must_cache_set = mcs)
            red = result(rs)[ret_key] != fvec_ref(5)
        catch
            red = true            # a raise under mutation is also RED.
        end
    finally
        # ALWAYS restore (set-diff: delete any method in `after \ before`).
        ndel = 0
        for m in methods(Bennett._vec_vm_emit_access!, sig)
            if !(m in before)
                Base.delete_method(m); ndel += 1
            end
        end
        # n>=1 FIRST: a zero-delete means the mutation added no method (signature
        # drift) and the RED above ran against the untouched original — the cycle
        # is meaningless. Raise before the GREEN check can mask it.
        ndel >= 1 || error("mutation-proof: eval added no _vec_vm_emit_access! " *
                           "method (n_deleted=0) — signature drift; cycle meaningless")
        # Post-restore GREEN (load-bearing): the canonical round-trip must pass
        # again. If restoration silently failed, this goes RED and aborts.
        p = Base.invokelatest(Bennett.extract_parsed_ir, fvec, Tuple{Int64};
                              optimize = false, mem = :vm)
        vm = lower_vm(p)
        mcs = BennettVM.compute_must_cache(vm)
        arg_key = p.args[1][1]
        ret_key = _vec_vm_ret_key(p)
        rs = initial_state(vm, Dict(arg_key => Int64(5)))
        run!(rs, vm; checkpoint_interval = 4, must_cache_set = mcs)
        result(rs)[ret_key] == fvec_ref(5) ||
            error("mutation-proof POST_RESTORE_GREEN failed: canonical " *
                  "round-trip wrong after restore — method table not restored")
    end
    @test red == true             # (Rule 5) the mutation was CAUGHT (RED).
end
