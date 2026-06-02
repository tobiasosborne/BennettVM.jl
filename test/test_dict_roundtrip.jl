# test/test_dict_roundtrip.jl — SC9 Case B end-to-end Dict round-trip gate
# (bead `bennettvm-7xa`; THE SC9 Case B milestone, PRD v4 §3.6.2 + §6 SC9).
#
# # What this gate proves, and the honest boundary it documents
#
# SC9 Case B is the load-bearing claim that a Julia `Dict` round-trips under
# `target=:reversible_vm`. The canonical program is
# `fdict(k,v) = (d=Dict{Int8,Int8}(); d[k]=v; d[k])`, with the runtime gate
# `fdict(Int8(3),Int8(7)) == 7`, forward bit-exact vs the native oracle, then
# `unrun!` to empty history (`step_count==0 && isempty(history)`).
#
# This gate is split into THREE parts that together establish exactly what the
# milestone can soundly claim today (CLAUDE.md Rule 1 / Rule 4 — assert real
# invariants, never a fake green):
#
#   * Part A — the BennettVM half, END-TO-END from a `ParsedIR`. We hand-build
#     the EXACT `ParsedIR` the front-end recogniser is designed to emit for
#     `fdict` (`IRMapInsert(k,v); IRMapGet(:result,k); ret :result`), drive it
#     through the REAL `lower_vm` ingest (`src/ir/ingest.jl`, the new IRMap*
#     arms) into a `VMProgram`, and run the FULL gate on it: forward to
#     `result == 7 == fdict_ref(3,7)` (oracle bit-match), then `unrun!` to empty
#     history under BOTH the L2 (`compute_must_cache`) and L3 (empty
#     must_cache) regimes, plus the per-step-inverse sweep (the M8.2 blind-spot
#     discipline). This is the ingest counterpart to the hand-built-VMProgram
#     `test_revmap_roundtrip.jl` Part A: it proves the Bennett.jl→BennettVM
#     ParsedIR→VMProgram path produces a correct, reversible artifact.
#
#   * Part B — the Bennett.jl front-end recogniser, SOUND positive path. The
#     `mem=:vm` Dict recogniser (`Bennett.jl/src/extract/dict_vm.jl`) drops the
#     GC frame + Dict `ijl_gc_small_alloc` skeleton and rewrites the surviving
#     `@j_setindex!_NNN(dict, v, k)` callee into `IRMapInsert(key=k, value=v)` —
#     un-permuting the VALUE-BEFORE-KEY Julia operand order. We extract a
#     `setindex!`-only fragment and assert the emitted `IRMapInsert` carries
#     key=`k`, value=`v` (the un-permutation is correct, not silently swapped),
#     and that the GC/Dict skeleton was dropped (a single IRMapInsert + a const
#     return, no stray heap nodes).
#
#   * Part C — the inlined-`getindex` BLOCKER, asserted as a LOUD reject. On
#     Julia 1.12.5 (the live version) the trailing `d[k]` in the bare `fdict`
#     body is FULLY INLINED into raw hash arithmetic + a Memory-backing-store
#     probe at BOTH optimize levels — `getindex` does NOT survive as a callee
#     for an isbits (`Int8`/`Int64`) key (it DOES for a `String` key; verified).
#     Recognising that inlined probe as `M[k]` soundly would require
#     understanding the hash and proving the KeyError block dead — a separate,
#     research-grade recogniser not yet built. Per Rule 1 the recogniser FAILS
#     LOUD rather than miscompile; this part asserts `extract_parsed_ir(fdict,
#     …; mem=:vm)` THROWS (it does not silently emit a wrong ParsedIR). This is
#     the documented, executable record of why the bare-`fdict` end-to-end
#     extraction gate is not yet green — the blocker is in Bennett.jl's
#     front-end inlining, NOT in BennettVM's VM/ingest half (Part A proves the
#     latter complete).
#
# # Status (honest)
#
# Parts A + B GREEN: the BennettVM VM + ingest half and the Bennett.jl
# setindex!/skeleton-drop recogniser are complete and sound. Part C documents
# the remaining gap: the bare `fdict(Int8,Int8)` extraction is blocked on the
# inlined-getindex recogniser (a research-grade Bennett.jl front-end build,
# tracked on bead `bennettvm-0do`). When that lands, Part C flips from
# "asserts the reject" to "asserts the full extract→lower→run→round-trip", and
# fdict(Int8(3),Int8(7)) is end-to-end green. The runtime semantics it WOULD
# exercise are already proven bit-for-bit by Part A here.
#
# # Ref
#   * `src/ir/revmap.jl` — the VM-side IRMap* ops + reversibility (proven by
#     `test_revmap.jl` / `test_revmap_roundtrip.jl`).
#   * `src/ir/ingest.jl` — the new IRMapInsert/IRMapGet/IRMapDelete ingest arms.
#   * `Bennett.jl/src/ir_types.jl` — the three language-neutral IRMap* IRInst
#     types the recogniser emits and ingest consumes.
#   * `Bennett.jl/src/extract/dict_vm.jl` — the `mem=:vm` Dict recogniser.
#   * `docs/adr/0008-dict-reversibility.md`, ADR 0013 §D-3.
#   * `test/test_revmap_roundtrip.jl` — the hand-built-VMProgram sibling.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (real invariants), Rule 11.

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

const _BV = BennettVM
const _BN = Bennett

# The irreversible Julia oracle (Rule 4): fdict(3,7) == 7.
fdict_oracle(k::Int8, v::Int8) = let d = Dict{Int8,Int8}(); d[k] = v; d[k] end

# The EXACT ParsedIR the `mem=:vm` Dict recogniser is designed to emit for
# `fdict`: one straight-line block, IRMapInsert(k,v) then IRMapGet(:result,k),
# returning :result. (The recogniser's setindex! arm is proven in Part B; its
# getindex arm is blocked on inlining, Part C — so we hand-build the ParsedIR
# here to drive the BennettVM half end-to-end, exactly as Part A of
# test_revmap_roundtrip.jl hand-builds the VMProgram.)
function _fdict_parsed_ir()
    blk = _BN.IRBasicBlock(
        :top,
        _BN.IRInst[
            _BN.IRMapInsert(_BN.ssa(:k), _BN.ssa(:v), 8, 8),   # d[k] = v
            _BN.IRMapGet(:result, _BN.ssa(:k), 8, 8),          # result = d[k]
        ],
        _BN.IRRet(_BN.ssa(:result), 8),
    )
    return _BN.ParsedIR(8, [(:k, 8), (:v, 8)], [blk], [8],
                        Dict{Symbol,Tuple{Vector{UInt64},Int}}())
end

@testset "SC9 Case B — Dict fdict round-trip (bead 7xa)" begin

    # =================================================================
    # Part A — the BennettVM half, end-to-end from ParsedIR ingest.
    # =================================================================
    @testset "Part A — ParsedIR ingest → lower_vm → fdict(3,7) round-trip" begin
        parsed = _fdict_parsed_ir()
        vm = _BV._lower_parsed_ir(parsed, :fdict)   # the REAL ingest path

        # Forward correctness vs the oracle (Rule 4). fdict(3,7) => 7.
        rs0 = initial_state(vm, Dict(:k => Int64(3), :v => Int64(7)))
        run!(rs0, vm)
        @test is_halted(rs0)
        @test result(rs0)[:result] == fdict_oracle(Int8(3), Int8(7))
        @test result(rs0)[:result] == 7                          # explicit (gate)
        @test rs0.current.revmap == Dict(Int64(3) => Int64(7))   # the opaque map

        # Round-trip BOTH ways (the M8.2 blind-spot discipline): L3 (empty
        # must_cache → IRMapInsert reverses via checkpoint-replay) and L2
        # (compute_must_cache → IRMapInsert reverses via its (key,prior) delta).
        for (mode, mc) in (
                ("L3 (empty must_cache)", Set{Tuple{Symbol,Int}}()),
                ("L2 (compute_must_cache)", _BV.compute_must_cache(vm)),
            )
            rs = initial_state(vm, Dict(:k => Int64(3), :v => Int64(7)))
            initial_snap = deepcopy(rs.initial)

            run!(rs, vm; must_cache_set = mc)
            @test is_halted(rs)
            @test result(rs)[:result] == 7                       # forward correct

            if !isempty(mc)
                # L2: the single IRMapInsert pushed exactly one (key,prior)
                # DeltaEntry (proving L2 fired — Rule 4). IRMapGet is L3-only.
                ndelta = count(e -> e isa _BV.DeltaEntry, rs.history)
                @test ndelta == 1
                de = only(filter(e -> e isa _BV.DeltaEntry, rs.history))
                @test de.instruction isa _BV.IRMapInsert
                @test de.payload.key == 3
                @test de.payload.prior === missing               # key 3 absent
            end

            unrun!(rs, vm)
            @test rs.current == rs.initial                       # P0.6 reversed
            @test isempty(rs.history)                            # P0.6 drained
            @test rs.step_count == 0                             # P0.6 reset
            @test isempty(rs.current.revmap)                     # map → empty
            @test rs.initial == initial_snap                     # initial intact
        end

        # Per-step inverse (mid-instruction reversal bugs the aggregate
        # round-trip can mask — the M8.2 lesson) under BOTH regimes.
        @test per_step_inverse_check(
            vm, Dict(:k => Int64(3), :v => Int64(7));
            checkpoint_interval = 1, label = "fdict/L3") === nothing
        @test per_step_inverse_check(
            vm, Dict(:k => Int64(3), :v => Int64(7));
            checkpoint_interval = 1,
            must_cache_set = _BV.compute_must_cache(vm),
            label = "fdict/L2") === nothing
    end

    # =================================================================
    # Part B — the Bennett.jl recogniser, sound setindex! positive path.
    # =================================================================
    @testset "Part B — mem=:vm recogniser: setindex! → IRMapInsert (value-before-key)" begin
        # A setindex!-only fragment: the read is replaced by a constant, so the
        # whole getindex inlining is absent. setindex! survives as a callee; the
        # Dict alloc + GC frame is dead skeleton; the ret is a constant.
        fset(k::Int8, v::Int8) = let d = Dict{Int8,Int8}(); d[k] = v; Int8(0) end

        pir = _BN.extract_parsed_ir(fset, Tuple{Int8,Int8}; mem = :vm)
        @test length(pir.blocks) == 1                            # single block
        blk = pir.blocks[1]

        inserts = filter(i -> i isa _BN.IRMapInsert, blk.instructions)
        @test length(inserts) == 1                               # exactly one
        ins = inserts[1]
        # The CRUX: value-before-key un-permutation is correct. The LLVM callee
        # is setindex!(dict, v, k); the emitted op must carry key=k, value=v.
        @test ins.key isa _BN.SSAOperand && ins.key.name === Symbol("k::Int8")
        @test ins.value isa _BN.SSAOperand && ins.value.name === Symbol("v::Int8")
        @test ins.key_width == 8 && ins.value_width == 8

        # The GC/Dict skeleton was dropped: NO heap/alloc/store nodes survive,
        # only the one IRMapInsert (the const return is the terminator).
        @test all(i -> i isa _BN.IRMapInsert, blk.instructions)
        @test blk.terminator isa _BN.IRRet
    end

    # =================================================================
    # Part C — the inlined-getindex blocker, asserted as a LOUD reject.
    # =================================================================
    @testset "Part C — bare fdict(Int8,Int8): inlined getindex fails LOUD (Rule 1)" begin
        # On Julia 1.12.5 the trailing d[k] is inlined to raw hash arithmetic
        # (no @j_getindex callee for an isbits key). The recogniser must REJECT
        # LOUD rather than emit a skeleton-laden / wrong ParsedIR (Rule 1). This
        # asserts the milestone does NOT silently miscompile fdict; the runtime
        # semantics it would produce are proven sound in Part A.
        @test_throws ErrorException _BN.extract_parsed_ir(
            fdict_oracle, Tuple{Int8,Int8}; mem = :vm)

        # The reject is the mem=:vm Dict recogniser's (not a generic walker
        # crash), and it names the inlined-getindex / surviving-live-computation
        # cause — so a future agent reading the failure knows the exact blocker.
        local msg = ""
        try
            _BN.extract_parsed_ir(fdict_oracle, Tuple{Int8,Int8}; mem = :vm)
        catch e
            msg = sprint(showerror, e)
        end
        @test occursin("mem=:vm Dict recogniser", msg)
        @test occursin("SC9 Case B", msg)
    end
end
