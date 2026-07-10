# test/test_5m1t_content_addressed_keys.jl — content-addressed Julia-set keys
# (CW-D; bead `bennettvm-5m1t`).
#
# # What this file pins (Rule 4 — invariants, not "didn't throw")
#
# Bennett's `extract_parsed_ir_set_from_julia` (`julia_set.jl:120-121/338`)
# emits CONTENT-ADDRESSED table keys of the shape `<barename>#<8hex-digest>`
# (e.g. `setindex!#cfbb045b`) — the digest disambiguates argtype
# specialisations of one generic function. Two layers broke on this:
#
#   1. `lower_vm(::Vector{Pair})` REJECTED any '#'-bearing key at ingest
#      (`ingest_multi.jl`; '#' reserved for label qualification, ADR 0019 §2).
#   2. Even past the reject, the table was keyed by the DIGESTED key while
#      the in-set call sites carry a BARE `nameof` (digest-free) callee, so
#      guard-5 (`ingest_body.jl`) would miss every cross-body call.
#
# The fix de-digests the key to a VM function name (`_vm_funcname`) and
# sanitises the call-site dispatch name (`_vm_dispatch_name`) so the two
# converge. Closure barenames (`#9`) themselves carry '#'; it is sanitised
# to '.' — a char `nameof` can NEVER produce, so a sanitised closure name can
# never alias a genuine function name (structurally impossible).
#
# The REAL fdict set now clears the '#' wall and advances past the
# `julia.get_pgcstack` + negative-offset GC-preamble walls (both cleared by
# bead `bennettvm-p81t`, 2026-07-10) AND the const-cond IRSelect wall (cleared
# by bead `bennettvm-416r.14`, 2026-07-10) to the `IRInsertBits` wall
# (bits-struct sret packing, Bennett-dv1z). Testset (b) pins that exact current
# successor.

using Test
using BennettVM
import Bennett
const _BV = BennettVM
const _B = Bennett

# ---------------------------------------------------------------------
# Local round-trip harness (mirrors test_call_roundtrip.jl's _run_result /
# _assert_roundtrip — defined locally to avoid running that file's testsets).
# ---------------------------------------------------------------------
function _rt_run(prog, inputs; mc = _BV.compute_must_cache(prog), K = typemax(Int))
    rs = _BV.initial_state(prog, inputs)
    _BV.run!(rs, prog; max_steps = 100_000, checkpoint_interval = K, must_cache_set = mc)
    return rs
end
function _rt_assert(prog, inputs; mc = _BV.compute_must_cache(prog), K = typemax(Int))
    rs = _BV.initial_state(prog, inputs)
    init = deepcopy(rs.current)
    _BV.run!(rs, prog; max_steps = 100_000, checkpoint_interval = K, must_cache_set = mc)
    _BV.unrun!(rs, prog; max_unsteps = 100_000)
    @test isempty(rs.history)
    @test length(rs.current.frames) == 1
    @test rs.current == init
end

@testset "bennettvm-5m1t — content-addressed Julia-set keys" begin

    # ------------------------------------------------------------------
    # (a) de-digest helper unit.
    # ------------------------------------------------------------------
    @testset "de-digest helper unit" begin
        @test _BV._vm_funcname(Symbol("setindex!#cfbb045b")) === :setindex!
        @test _BV._vm_funcname(Symbol("#9#deadbeef")) === Symbol(".9")
        @test _BV._vm_funcname(:ht_new) === :ht_new        # C-track fixed point
        @test _BV._vm_funcname(Symbol("fdict_d1b#4a8d3eda")) === :fdict_d1b
        # malformed: '#'-bearing but NOT digest-shaped ⇒ fail loud (Rule 1).
        @test_throws ErrorException _BV._vm_funcname(Symbol("a#b"))
    end

    # ------------------------------------------------------------------
    # (b) the REAL fdict set clears the '#' wall, hits the aggregate-return wall.
    # ------------------------------------------------------------------
    @testset "fdict set clears the '#' wall (advances to aggregate-return)" begin
        fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])
        set = _B.extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                                                  ptr_cells = true)
        # sanity: the set really carries digested keys with '#'.
        @test any(p -> occursin('#', string(p.first)), set)
        threw = false
        msg = ""
        try
            _BV.lower_vm(set; entry = first(set).first)
        catch e
            threw = true
            msg = sprint(showerror, e)
        end
        @test threw                                    # DOES still throw (next wall)
        @test !occursin("contains '#'", msg)           # but NOT the '#' reject
        # bead bennettvm-p81t (2026-07-10) cleared the julia.get_pgcstack SoftCall
        # reject AND the negative-offset GEP guard; bead bennettvm-416r.14
        # (2026-07-10) cleared the const-cond IRSelect wall; bead bennettvm-416r.15
        # (2026-07-10) cleared the IRInsertBits bits-struct sret wall (Bennett-dv1z).
        # The successor wall is now the aggregate-RETURN reject — the terminal
        # IRInsertBits dest dangles into a single-symbol EndInstruction.returns;
        # the multi-key return (keyed off ret_elem_widths) is the follow-on bead
        # bennettvm-x3t0. When THAT lands, this flips — intended.
        @test !occursin("julia.get_pgcstack", msg)
        @test !occursin("IRSelect cond is", msg)
        @test !occursin("IRInsertBits", msg)           # IRInsertBits wall CLEARED
        @test occursin("returns aggregate SSA value", msg)
    end

    # ------------------------------------------------------------------
    # (c) hand-built digested 2-body set lowers + round-trips.
    # ------------------------------------------------------------------
    @testset "hand-built digested 2-body set lowers + round-trips" begin
        # inc#bbbb2222(x) = x + 1; main#aaaa1111(n) = inc(n). The in-set call
        # site carries the BARE name :inc (digest-free), matching Bennett's
        # Function-callee `nameof`.
        inc_blk = _B.IRBasicBlock(:top,
            _B.IRInst[_B.IRBinOp(:r, :add, _B.SSAOperand(:x), _B.ConstOperand(1), 64)],
            _B.IRRet(_B.SSAOperand(:r), 64))
        inc_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:x, 64)], [inc_blk], Int[64])
        main_blk = _B.IRBasicBlock(:top,
            _B.IRInst[_B.IRCall(:c, :inc, _B.IROperand[_B.SSAOperand(:n)], Int[64], 64)],
            _B.IRRet(_B.SSAOperand(:c), 64))
        main_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:n, 64)], [main_blk], Int[64])
        set = Pair{Symbol,_B.ParsedIR}[Symbol("main#aaaa1111") => main_ir,
                                       Symbol("inc#bbbb2222") => inc_ir]
        prog = _BV.lower_vm(set; entry = Symbol("main#aaaa1111"))
        @test prog isa _BV.VMProgram
        @test haskey(prog.functions, :inc)             # de-digested table key
        @test haskey(prog.functions, :main)
        @test prog.entry_function === :main
        # a CallEnter to :inc was emitted (guard-5 resolved the bare call site).
        insts = reduce(vcat, [b.instructions for b in prog.blocks];
                       init = _BV.Instruction[])
        ce = only(filter(i -> i isa _BV.CallEnter, insts))
        @test ce.callee === :inc
        # full forward + reverse round-trip with correct output + empty history.
        for n in Int64[0, 1, 5, 42, -3]
            rs = _rt_run(prog, Dict(:n => n))
            @test _BV.is_halted(rs)
            @test _BV.result(rs)[:c] == n + 1          # golden master
            _rt_assert(prog, Dict(:n => n))
        end
    end

    # ------------------------------------------------------------------
    # (d) closure barename sanitised: key `#9#deadbeef` ↔ call site `#9`.
    # ------------------------------------------------------------------
    @testset "closure barename sanitised (#9 ↔ .9)" begin
        # First confirm the design premise: _callee_sym on a raw Symbol callee
        # is identity, so a Symbol("#9") callee only needs the '#'→'.' sanitise
        # to converge with the table key _vm_funcname(#9#deadbeef) = .9.
        @test _BV._callee_sym(Symbol("#9")) === Symbol("#9")
        @test _BV._vm_dispatch_name(Symbol("#9")) === Symbol(".9")

        clo_blk = _B.IRBasicBlock(:top,
            _B.IRInst[_B.IRBinOp(:r, :add, _B.SSAOperand(:x), _B.ConstOperand(1), 64)],
            _B.IRRet(_B.SSAOperand(:r), 64))
        clo_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:x, 64)], [clo_blk], Int[64])
        main_blk = _B.IRBasicBlock(:top,
            _B.IRInst[_B.IRCall(:c, Symbol("#9"),
                                _B.IROperand[_B.SSAOperand(:n)], Int[64], 64)],
            _B.IRRet(_B.SSAOperand(:c), 64))
        main_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:n, 64)], [main_blk], Int[64])
        set = Pair{Symbol,_B.ParsedIR}[Symbol("main#aaaa1111") => main_ir,
                                       Symbol("#9#deadbeef") => clo_ir]
        prog = _BV.lower_vm(set; entry = Symbol("main#aaaa1111"))
        @test prog isa _BV.VMProgram
        @test haskey(prog.functions, Symbol(".9"))     # sanitised closure key
        insts = reduce(vcat, [b.instructions for b in prog.blocks];
                       init = _BV.Instruction[])
        ce = only(filter(i -> i isa _BV.CallEnter, insts))
        @test ce.callee === Symbol(".9")               # resolution landed
    end

    # ------------------------------------------------------------------
    # (e) same-bare collision fails loud, naming BOTH originating keys.
    # ------------------------------------------------------------------
    @testset "same-bare collision fails loud (naming both keys)" begin
        blk = _B.IRBasicBlock(:top,
            _B.IRInst[_B.IRBinOp(:r, :add, _B.SSAOperand(:x), _B.ConstOperand(1), 64)],
            _B.IRRet(_B.SSAOperand(:r), 64))
        ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:x, 64)], [blk], Int[64])
        set = Pair{Symbol,_B.ParsedIR}[Symbol("f#aaaa1111") => ir,
                                       Symbol("f#bbbb2222") => ir]
        threw = false
        msg = ""
        try
            _BV.lower_vm(set; entry = Symbol("f#aaaa1111"))
        catch e
            threw = true
            msg = sprint(showerror, e)
        end
        @test threw
        @test occursin("f#aaaa1111", msg)
        @test occursin("f#bbbb2222", msg)
    end

    # ------------------------------------------------------------------
    # (f) entry kwarg accepts a digested key AND the internal (de-digested) name.
    # ------------------------------------------------------------------
    @testset "entry kwarg accepts digested key and internal name" begin
        inc_blk = _B.IRBasicBlock(:top,
            _B.IRInst[_B.IRBinOp(:r, :add, _B.SSAOperand(:x), _B.ConstOperand(1), 64)],
            _B.IRRet(_B.SSAOperand(:r), 64))
        inc_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:x, 64)], [inc_blk], Int[64])
        main_blk = _B.IRBasicBlock(:top,
            _B.IRInst[_B.IRCall(:c, :inc, _B.IROperand[_B.SSAOperand(:n)], Int[64], 64)],
            _B.IRRet(_B.SSAOperand(:c), 64))
        main_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:n, 64)], [main_blk], Int[64])
        mkset() = Pair{Symbol,_B.ParsedIR}[Symbol("main#aaaa1111") => main_ir,
                                           Symbol("inc#bbbb2222") => inc_ir]
        prog_digest = _BV.lower_vm(mkset(); entry = Symbol("main#aaaa1111"))
        prog_bare   = _BV.lower_vm(mkset(); entry = :main)
        @test prog_digest.entry_function === :main
        @test prog_bare.entry_function === :main
        @test prog_digest.entry_label === prog_bare.entry_label
        @test prog_digest.entry_label === Symbol("main#top")
    end
end
