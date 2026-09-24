# test_hsm3_literal_certification_vm.jl — Bennett-hsm3 (+ Bennett-gcf7 D1/D2/D3):
# the BennettVM end-to-end gate for SEMANTIC certification of Julia's interned
# heap literals `@"jl_global#N"` (ADR 0021 Decision 3 Amendment B).
#
# # Why this file exists
#
# Julia's codegen names EVERY interned heap literal `jl_global#N` — a
# `const Ref(…)`, a struct box, a `String`, a non-empty `Memory`, and the empty
# `GenericMemory` singleton alike. The 416r.13 front end certified "is the empty
# singleton" from the NAME, so `const RI = Ref(42); h3(x) = RI[] + x` extracted
# as a load off a zero blob and THIS VM returned 0/10/−5 against the oracle
# 42/52/37 — and reversed cleanly (gcf7 hostile review, executed). A clean
# reversal is exactly why the miscompile was silent: the round-trip invariant
# says nothing about agreement with the oracle.
#
# Since Bennett-hsm3 the front end admits a literal only when, in the live
# producing session, its address is a member of the live empty-GenericMemory
# singleton set (never a dereference). This file pins, on the VM:
#
#   (1) the gcf7 counterexamples (h1 struct-Ref via memcpy, h3 scalar Ref, m3 a
#       non-empty Memory) THROW `Bennett-hsm3` AT EXTRACTION — `lower_vm` never
#       runs, so no wrong answer can be produced (the gate gcf7 asked for, no
#       longer vacuous);
#   (2) the user-held empty singleton (`const UM = Memory{Int}(undef, 0)`, and
#       the `Memory{Int}()` spelling) is certified, runs `== oracle` for several
#       inputs, and reverses exactly (Law P0.5 golden master + P0.6 round-trip);
#   (3) D3: the certified header's data pointer is the non-null
#       `Bennett._EMPTY_MEMORY_DATA_SENTINEL`, which lies in this VM's
#       globals-tier read-window TRAP BAND, and is what the ROM actually holds;
#   (4) a `MemoryLoad` AT the sentinel (a dereference of a length-0 Memory's
#       data pointer — always UB in Julia) traps loud, while reading the
#       data-pointer FIELD itself serves the sentinel and round-trips.
#
# Ref: ../Bennett.jl/docs/design/hsm3/orchestrator_review.md (decisions 1–8),
#      ../Bennett.jl/docs/design/5viz_gcf7_hostile_review.md (D1–D3),
#      ../Bennett.jl/src/extract/jlglobal_cert.jl, docs/adr/0021 Amendment B,
#      src/ir/memory_floor.jl (the read-window trap), CLAUDE.md Rule 1/4.

using Test
using BennettVM
import Bennett
const _HBV = BennettVM
const _HB = Bennett

struct _Hsm3VmS2; a::Int; b::Int; end
const _HSM3VM_R  = Ref(_Hsm3VmS2(3, 4))
const _HSM3VM_RI = Ref(42)
const _HSM3VM_M3 = Memory{Int}([7, 8, 9])
const _HSM3VM_UM = Memory{Int}(undef, 0)
const _HSM3VM_EM = Memory{Int}()
_hsm3vm_h1(x::Int) = _HSM3VM_R[].a + x
_hsm3vm_h3(x::Int) = _HSM3VM_RI[] + x
_hsm3vm_m3(x::Int) = length(_HSM3VM_M3) + x
_hsm3vm_u1(x::Int) = length(_HSM3VM_UM) + x
_hsm3vm_he(x::Int) = length(_HSM3VM_EM) + x

# Extract → lower → run → read the entry's return → unrun (the gcf7 p4_vm harness).
function _hsm3vm_run(f, x::Int)
    set = _HB.extract_parsed_ir_set_from_julia(f, Tuple{Int}; ptr_cells = true)
    prog = _HBV.lower_vm(set; entry = first(set).first)
    entry_pir = first(set).second
    inputs = Dict(n => Int64(v) for ((n, _w), v) in zip(entry_pir.args, (x,)))
    mc = _HBV.compute_must_cache(prog)
    rs = _HBV.initial_state(prog, inputs)
    init = deepcopy(rs.current)
    _HBV.run!(rs, prog; max_steps = 100_000, checkpoint_interval = 8,
              must_cache_set = mc)
    halted = _HBV.is_halted(rs)
    entry_vm = _HBV._vm_funcname(first(set).first)
    ret = only(b.exit.returns for b in prog.blocks
               if b.exit isa _HBV.EndInstruction && b.exit.label === entry_vm &&
                  !isempty(b.exit.returns))[1]
    r = _HBV.result(rs)[ret]
    _HBV.unrun!(rs, prog; max_unsteps = 200_000)
    return (; set, prog, halted, r, reversed = rs.current == init,
            empty_hist = isempty(rs.history))
end

@testset "Bennett-hsm3 — jl_global literal certification, VM end-to-end" begin
    S  = _HB._EMPTY_MEMORY_DATA_SENTINEL
    GB = _HBV.GLOBAL_BASE

    @testset "(1) non-singleton literals throw Bennett-hsm3 at extraction" begin
        for f in (_hsm3vm_h1, _hsm3vm_h3, _hsm3vm_m3)
            msg = try
                _hsm3vm_run(f, 10)
                ""
            catch e
                e isa InterruptException && rethrow()
                sprint(showerror, e)
            end
            @test occursin("Bennett-hsm3", msg)
            @test occursin("NOT the empty GenericMemory singleton", msg)
        end
    end

    @testset "(2) certified empty singleton runs == oracle and reverses" begin
        for f in (_hsm3vm_u1, _hsm3vm_he), x in (0, 10, -5, Int(typemax(Int32)))
            out = _hsm3vm_run(f, x)
            @test out.halted
            @test out.r == f(x)                  # golden master: length 0 + x
            @test out.reversed                   # exact reverse
            @test out.empty_hist
        end
    end

    @testset "(3) D3: sentinel in the trap band, and it is what the ROM holds" begin
        @test GB < S < _HBV.TLS_BASE - _HBV._TLS_TIER_GUARD
        out = _hsm3vm_run(_hsm3vm_u1, 1)
        root = first(out.set).second
        ks = [k for k in keys(root.globals) if endswith(String(k), ".obj")]
        @test length(ks) == 1
        data, ew = root.globals[only(ks)]
        @test ew == 8 && data[1] == 0 && data[9] == S
        # the VM seeded the blob verbatim: length cell 0, data-ptr cell = S
        @test count(==(reinterpret(Int64, S)), values(out.prog.globals.cells)) == 1
        @test !haskey(out.prog.globals.cells, reinterpret(Int64, S))  # never seeded
    end

    @testset "(4) a MemoryLoad AT the sentinel traps; the field read round-trips" begin
        g = Symbol("jl_global#7.obj")
        blob = _HB._certified_header_blob(true)
        mk(insts, ret) = _HB.ParsedIR(64, Tuple{Symbol,Int}[(:x, 64)],
            [_HB.IRBasicBlock(:top, _HB.IRInst[insts...], _HB.IRRet(_HB.SSAOperand(ret), 64))],
            Int[64], Dict{Symbol,Tuple{Vector{UInt64},Int}}(g => blob))
        field = [_HB.IRPtrOffset(:dp, _HB.SSAOperand(g), 8, 8),   # byte-cell 8
                 _HB.IRLoad(:d, _HB.SSAOperand(:dp), 64)]         # the data POINTER
        # (a) reading the data-pointer FIELD serves the sentinel, and reverses
        prog = _HBV.lower_vm(mk(field, :d))
        rs = _HBV.initial_state(prog, Dict(:x => Int64(0)))
        init = deepcopy(rs.current)
        _HBV.run!(rs, prog; max_steps = 10_000, checkpoint_interval = 4)
        @test _HBV.is_halted(rs)
        @test _HBV.result(rs)[:d] == reinterpret(Int64, S)
        _HBV.unrun!(rs, prog; max_unsteps = 10_000)
        @test rs.current == init
        # (b) DEREFERENCING it (element 0 of a length-0 Memory) traps loud —
        #     with the pre-hsm3 null pointer this silently read memory[0] == 0.
        prog2 = _HBV.lower_vm(mk([field; _HB.IRLoad(:e, _HB.SSAOperand(:d), 64)], :e))
        rs2 = _HBV.initial_state(prog2, Dict(:x => Int64(0)))
        err = try
            _HBV.run!(rs2, prog2; max_steps = 10_000, checkpoint_interval = 4)
            nothing
        catch e
            e isa InterruptException && rethrow()
            e
        end
        @test err isa ErrorException
        @test err !== nothing && occursin("NOT seeded", sprint(showerror, err))
    end
end
