# test/test_igr3_gc_loaded_ingest.jl — julia.gc_loaded data-ptr launder ingest
# (Bennett-igr3; downstream of Bennett-qmv7; ADR 0018 §C IRCall-arm ordering).
#
# # What this file pins (Rule 4 — known values, not "didn't throw")
#
# Bennett.jl's qmv7 extraction emits the heap-Memory base of a `setindex!`
# value-store as `IRCall(:d, Symbol("julia.gc_loaded"), [mem, data], [64,64], 64)`
# — the GC-rooting launder `julia.gc_loaded(mem, data)` that RETURNS `data`
# (args[2]); `mem` (args[1]) only keeps the Memory GC-rooted and is structurally
# UNREAD. Operand order verified against `test/reference/fdict_O0.ll`, Bennett.jl
# `src/extract/instructions.jl:149`, and empirically against the qmv7 `GCL_I8`
# fixture (2026-06-26): the emitted callee is the un-canonicalised LLVM name
# `Symbol("julia.gc_loaded")` (contrast `:gc_alloc_obj`, which Bennett.jl
# canonicalises). In the cell-addressed VM the laundered data pointer IS the
# Memory's virtual base cell, so ingest aliases `dest := data` via the
# established pointer-identity create `Define(dest, data, :add, 0)`
# (`src/ir/array_index.jl:15`; reversed by L3 checkpoint-replay — `Define` is
# non-injective, ADR 0012 §D1). Before this arm landed, the IRCall fell through
# to the SoftCall allowlist and failed loud ("unknown callee_name
# :julia.gc_loaded").
#
#   1. Ingest shape: `lower_vm` of the gc_loaded IRCall yields
#      `Define(:d, :data, :add, 0)` — lhs is `data` (args[2]), NEVER `mem`.
#   2. forward: binds `:d == value(:data)`.
#   3. mem-invariance (THE soundness witness, mirroring gc_alloc_obj tag-
#      invariance): a WILDLY different `:mem` yields a bit-identical `:d`.
#   4. wrong arity fails loud with a gc_loaded-SPECIFIC message (Rule 1).
#
# Ref: `src/ir/ingest_body.jl` (the `Symbol("julia.gc_loaded")` IRCall arm);
#   `test/test_gc_alloc_obj_ingest.jl` (the sibling ingest test this mirrors);
#   Bennett-igr3; CLAUDE.md Rule 1 (fail loud), Rule 4 (known values).

using Test
using BennettVM
import Bennett
const _BV = BennettVM
const _B  = Bennett

# Single-block ParsedIR holding ONE gc_loaded IRCall with `nargs` args, ret :d.
# nargs=2 is the well-formed shape; nargs=1 exercises the fail-loud arity guard.
function _igr3_pir(; nargs::Int=2)
    args   = _B.IROperand[_B.ssa(:mem), _B.ssa(:data)][1:nargs]
    widths = fill(64, nargs)
    blk = _B.IRBasicBlock(:entry,
            _B.IRInst[_B.IRCall(:d, Symbol("julia.gc_loaded"), args, widths, 64)],
            _B.IRRet(_B.ssa(:d), 64))
    return _B.ParsedIR(64, Tuple{Symbol,Int}[(:mem, 64), (:data, 64)],
                       _B.IRBasicBlock[blk], [64])
end

_igr3_insts(prog) =
    reduce(vcat, [b.instructions for b in prog.blocks]; init = _BV.Instruction[])

@testset "Bennett-igr3 julia.gc_loaded data-ptr launder ingest" begin

    # (1)+(2)+(3): ingest shape + forward semantics + mem-invariance, all routed
    # through lower_vm so the whole block is RED until the ingest arm lands.
    @testset "ingest → Define(:d,:data,:add,0); forward binds :d==data; mem unread" begin
        prog = _BV.lower_vm(_igr3_pir())
        defs = filter(i -> i isa _BV.Define && i.target === :d, _igr3_insts(prog))
        @test length(defs) == 1
        d = defs[1]
        @test d.lhs === :data          # aliases args[2] (data ptr), NOT mem
        @test d.op  === :add
        @test d.rhs === Int64(0)        # identity passthrough

        # forward: :d := value(:data) + 0; mem present but unread.
        _fwd(memval) = begin
            s = _BV.IState(1, Dict{Symbol,Int64}(:mem => memval, :data => 424242),
                           :running, Dict{Int64,Int64}())
            _BV.forward(d, s)
            _BV.active_locals(s)[:d]
        end
        @test _fwd(111) == 424242                       # binds to data
        @test _fwd(0) == _fwd(999999) == 424242         # mem-invariance witness
    end

    # (4): a non-2 arity gc_loaded reaches THIS arm and fails loud with the
    # gc_loaded-specific arity message — distinct from the old SoftCall reject.
    @testset "wrong arity fails loud (Rule 1), gc_loaded-specific message" begin
        msg = try
            _BV.lower_vm(_igr3_pir(nargs = 1)); ""
        catch e
            e isa InterruptException && rethrow()
            sprint(showerror, e)
        end
        @test occursin("gc_loaded", msg)
        @test occursin("expects 2", msg)   # the arity guard, NOT the SoftCall reject
    end
end
