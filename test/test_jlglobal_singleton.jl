# test_jlglobal_singleton.jl — bead `bennettvm-416r.13` (+ tail of 416r.4):
# `jl_global#NNN` empty-GenericMemory singleton-data globals as read-only VM
# segments, and module-wide (multi-function) const-global segments.
#
# # What this pins
#
# The FIRST RUNTIME wall of the fdict closed-world chain was a `KeyError:
# Symbol("jl_global#NNN")` in `Define.forward` at Dict construction: the front-
# end DROPPED the singleton `load ptr, ptr @"jl_global#NNN"` and left a dangling
# SSA operand. Design B (the front-end models each singleton as a zeroed 16-cell
# Memory header shipped in `ParsedIR.globals`, aliasing every drifting load-
# result name to the canonical global-variable name; the VM seeds the header
# into the read-only `GlobalROM` at a deterministic `GLOBAL_BASE` address and
# binds the name via a prepended `Define`). This file pins the VM half:
#
#   (a) a hand-built single-function ParsedIR whose `.globals` carries a
#       `jl_global#N` zeroed header materialises + Define-prepends the pointer,
#       reads length@0 == 0, and round-trips (`unrun!` → exact initial state);
#   (b) module-wide DISJOINT segments — two functions each referencing a
#       singleton get DISJOINT `GLOBAL_BASE`-relative windows (the ex-guard
#       path: `ingest_multi.jl`'s old single-function-only fail-loud is gone);
#   (c) adversarial: a STORE onto a singleton address (`>= GLOBAL_BASE`) fails
#       loud (a `const` singleton is read-only);
#   (d) adversarial: a LOAD past a modelled header (globals tier, unseeded)
#       fails loud (the read-window trap), while the pgcstack TLS-tier read
#       (near `TLS_BASE = 2^56`) still serves zero-init (the carve-out);
#   (e) the REAL fdict set lowers AND `run!` gets PAST Dict construction (the
#       jl_global wall is cleared) — names extracted PROGRAMMATICALLY, so no
#       literal `#NNN` is pinned (drift-immune).
#
# Ref: scratchpad/design-jlglobal-B.md (D3/D4/D5/D7/D8), scratchpad/scout-
#      jlglobal-census.md (Q1–Q6), src/ir/ingest.jl (`_global_segment`),
#      src/ir/ingest_multi.jl (module-wide merge), src/ir/memory_floor.jl
#      (read-window trap + TLS carve-out), CLAUDE.md Rule 1/4.

using Test
using BennettVM
import Bennett
const _BV = BennettVM
const _B = Bennett

# Build a single-block ParsedIR that references a `jl_global#N` singleton as an
# IRPtrOffset base (cell 0 = the length field) and LOADS length@0. `gname` is a
# parameter so no literal number is pinned. Header = zeroed 16 cells.
function _singleton_ir(gname::Symbol)
    blk = _B.IRBasicBlock(:top,
        _B.IRInst[
            # p := singleton + 0 cells  (offset_bytes 0, elem_width 8b ⇒ cell 0)
            _B.IRPtrOffset(:p, _B.SSAOperand(gname), 0, 8),
            # len := *p  (length@cell0 of the empty singleton ⇒ 0)
            _B.IRLoad(:len, _B.SSAOperand(:p), 64)],
        _B.IRRet(_B.SSAOperand(:len), 64))
    return _B.ParsedIR(64, Tuple{Symbol,Int}[(:x, 64)], [blk], Int[64],
                       Dict{Symbol,Tuple{Vector{UInt64},Int}}(
                           gname => (zeros(UInt64, 16), 8)))
end

@testset "bennettvm-416r.13 — jl_global singleton + module-wide globals" begin

    GB = _BV.GLOBAL_BASE

    # ---------------------------------------------------------------------
    # (a) single-function: materialise + Define-prepend + length-0 + round-trip.
    # ---------------------------------------------------------------------
    @testset "(a) singleton header: seed + bind + length-0 + round-trip" begin
        prog = _BV.lower_vm(_singleton_ir(Symbol("jl_global#7")))
        # 16-cell header seeded at GLOBAL_BASE, all zero.
        @test length(prog.globals.cells) == 16
        @test all(k -> haskey(prog.globals.cells, GB + k), 0:15)
        @test all(k -> prog.globals.cells[GB + k] == 0, 0:15)

        rs = _BV.initial_state(prog, Dict(:x => Int64(0)))
        init = deepcopy(rs.current)
        _BV.run!(rs, prog; max_steps = 10_000, checkpoint_interval = 4)
        @test _BV.is_halted(rs)
        @test _BV.result(rs)[:len] == 0            # empty-singleton length@0 == 0
        _BV.unrun!(rs, prog; max_unsteps = 10_000)
        @test rs.current == init                   # exact reverse
        @test isempty(rs.history)
    end

    # ---------------------------------------------------------------------
    # (b) module-wide DISJOINT segments (the ex-guard path). Two functions, each
    #     with its OWN singleton → two DISJOINT 16-cell windows in ONE merged ROM.
    # ---------------------------------------------------------------------
    @testset "(b) two functions → disjoint module-wide singleton windows" begin
        prog = _BV.lower_vm(
            Pair{Symbol,_B.ParsedIR}[:f1 => _singleton_ir(Symbol("jl_global#11")),
                                     :f2 => _singleton_ir(Symbol("jl_global#22"))];
            entry = :f1)
        # 16 + 16 = 32 cells across two DISJOINT windows (a collision would
        # alias them to 16 cells — the exact hazard the old guard deferred).
        @test length(prog.globals.cells) == 32
        @test haskey(prog.globals.cells, GB)        # f1's window @ GLOBAL_BASE
        @test haskey(prog.globals.cells, GB + 16)   # f2's window @ GLOBAL_BASE+16
        @test haskey(prog.globals.cells, GB + 31)   # f2's last cell (disjoint)

        rs = _BV.initial_state(prog, Dict(:x => Int64(0)))
        init = deepcopy(rs.current)
        _BV.run!(rs, prog; max_steps = 10_000, checkpoint_interval = 4)
        @test _BV.is_halted(rs)
        @test _BV.result(rs)[:len] == 0
        _BV.unrun!(rs, prog; max_unsteps = 10_000)
        @test rs.current == init
        @test isempty(rs.history)
    end

    # ---------------------------------------------------------------------
    # (c) adversarial — STORE onto a singleton address fails loud (read-only).
    # ---------------------------------------------------------------------
    @testset "(c) store onto a singleton address fails loud" begin
        s = _BV.IState(1, Dict{Symbol,Int64}(:p => GB + 8), :running)  # data-ptr cell
        @test_throws ErrorException _BV.forward(_BV.MemoryStore(:p, Int64(1)), s)
    end

    # ---------------------------------------------------------------------
    # (d) adversarial — read-window trap on the globals tier; TLS carve-out.
    # ---------------------------------------------------------------------
    @testset "(d) read past header fails loud; TLS read serves zero" begin
        # Seed a 16-cell header at GLOBAL_BASE.
        rom = _BV.GlobalROM(Dict{Int64,Int64}(GB + k => Int64(0) for k in 0:15))

        # In-window read (cell 8) is fine — returns 0.
        s_ok = _BV.IState(1, Dict{Symbol,Int64}(:p => GB + 8), :running)
        s_ok.globals = rom
        _BV.forward(_BV.MemoryLoad(:d, :p), s_ok)
        @test _BV.active_locals(s_ok)[:d] == 0

        # Out-of-window globals-tier read (cell 99, unseeded) fails loud.
        s_bad = _BV.IState(1, Dict{Symbol,Int64}(:p => GB + 99), :running)
        s_bad.globals = rom
        @test_throws ErrorException _BV.forward(_BV.MemoryLoad(:d, :p), s_bad)

        # TLS-tier read (pgcstack ptls_field ≈ TLS_BASE + 16) is CARVED OUT of
        # the trap and still serves zero-init (structurally-dead pgcstack read).
        s_tls = _BV.IState(1, Dict{Symbol,Int64}(:p => _BV.TLS_BASE + 16), :running)
        s_tls.globals = rom
        _BV.forward(_BV.MemoryLoad(:d, :p), s_tls)
        @test _BV.active_locals(s_tls)[:d] == 0
    end

    # ---------------------------------------------------------------------
    # (e) the REAL fdict set lowers AND run! gets PAST Dict construction. Names
    #     are extracted PROGRAMMATICALLY (no literal #NNN pinned — drift-immune).
    # ---------------------------------------------------------------------
    @testset "(e) real fdict set: lowers + run! past Dict construction" begin
        fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])
        set = _B.extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                                                  ptr_cells = true)
        # Every root-PIR singleton is a 16-cell/ew-8 header keyed by a
        # `jl_global#…` name (count/shape, NOT the drifting number).
        root_globals = first(set).second.globals
        singletons = [v for (k, v) in root_globals if occursin("jl_global", String(k))]
        @test !isempty(singletons)
        @test all(v -> length(v[1]) == 16 && v[2] == 8, singletons)

        prog = _BV.lower_vm(set; entry = first(set).first)
        @test prog isa _BV.VMProgram
        @test length(prog.globals.cells) > 0        # singletons seeded into ROM

        entry_pir = first(set).second
        inputs = Dict(n => Int64(v) for ((n, _w), v) in
                      zip(entry_pir.args, (Int64(3), Int64(7))))
        rmsg = ""
        try
            rs = _BV.initial_state(prog, inputs)
            _BV.run!(rs, prog; max_steps = 500_000)
        catch e
            rmsg = sprint(showerror, e)
        end
        # The jl_global const-global materialization wall is CLEARED: the run
        # advances PAST Dict construction, the GC-preamble TLS read, and INTO
        # setindex!/rehash!/ht_keyindex2. The successor wall is a Dict-SEMANTICS
        # gap: the final `d[a]` lookup returns not-found → the provably-dead
        # `:__unreachable__` throw sink (the empty-singleton header + allocation
        # model does not yet round-trip a stored key). Successor work: the
        # rehash!/setindex! element-traffic semantics (NOT global materialization).
        @test !occursin("jl_global", rmsg)          # old wall gone
        @test occursin("__unreachable__", rmsg)     # new wall pinned
    end
end
