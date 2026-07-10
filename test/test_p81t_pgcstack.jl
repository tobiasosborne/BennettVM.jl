# test/test_p81t_pgcstack.jl — julia.get_pgcstack TLS-sentinel ingest +
# negative-offset GEP relaxation (bead `bennettvm-p81t`; downstream of
# `bennettvm-5m1t` / CW-D; ADR 0018 §C IRCall-arm ordering; ADR 0009 Decision 2b).
#
# # What this file pins (Rule 4 — known values, not "didn't throw")
#
# The closed fdict set (`extract_parsed_ir_set_from_julia(fdict_d1b,
# Tuple{Int8,Int8}; ptr_cells=true)`) cleared the 5m1t '#'-key wall and dies at
# TWO co-located walls in the Julia GC preamble:
#
#   1. `julia.get_pgcstack` — a NULLARY named intrinsic returning the per-task
#      pgcstack pointer, which has NO VM meaning. Under the deterministic VM it
#      is a FIXED cell at `TLS_BASE = 2^56` (the fifth address tier, above
#      GLOBAL_BASE=2^48 with a 2^48-cell margin). It appears in 2 of the 4
#      bodies (root `fdict_d1b` + `rehash!`), always a bare Symbol callee, 0
#      args, ret_width 64. Old behaviour: fell through to the SoftCall allowlist
#      reject ("unknown callee_name :julia.get_pgcstack"). New: lifted to the
#      `_BENIGN_CELL_DISPATCH` set beside `_HEAP_DISPATCH` (joining the
#      `julia.gc_loaded` launder, which MOVED into `_lower_benign_cell_call`),
#      emits `Define(dest, TLS_BASE, :add, 0)`, reversed by L3 checkpoint-replay
#      (`Define` non-injective, ADR 0012 §D1).
#
#   2. The GC preamble immediately walks the current-task struct via
#      `gep i8 %pgcstack, -152` (`current_task = TLS_BASE-152`) → `gep +168`
#      (`ptls_field = TLS_BASE+16`), i.e. NEGATIVE byte offsets. The old
#      IRPtrOffset guard hard-errored on `offset_bytes < 0` ("no production site
#      emits a negative offset") — falsified by this site. The negative-offset
#      guard is REMOVED; the whole-byte and divisibility guards (sign-agnostic)
#      stay. `Define(dest, base, :add, idx)` is exact signed pointer arithmetic.
#
# The one IRLoad through the chain (`ptls_load = load ptls_field`) reads an
# absent cell at `TLS_BASE+16` (zero-init) whose value feeds ONLY
# `jl_alloc_genericmemory_unchecked`'s DROPPED ptls arg (ADR 0021 D3) — the
# read is STRUCTURALLY DEAD, so any constant is sound; TLS_BASE is collision-
# free by construction. `TLS_BASE+16 >= GLOBAL_BASE`, so the load reads the
# read-only globals ROM (`s.globals.cells`) with the absent=0 convention.
#
# Ref: `src/ir/ingest_call.jl` (`_BENIGN_CELL_DISPATCH` / `_lower_benign_cell_call`
#   / `TLS_BASE`); `src/ir/ingest_body.jl` (the set-dispatch arm + the relaxed
#   IRPtrOffset guard); `../Bennett.jl/src/extract/julia_set.jl:45-74`
#   (`_D1B_BENIGN_INTRINSIC_PREFIXES`); `test/test_igr3_gc_loaded_ingest.jl`
#   (the gc_loaded arm that moved); CLAUDE.md Rule 1, Rule 4, Rule 11.

using Test
using BennettVM
import Bennett
const _BV = BennettVM
const _B  = Bennett

@testset "bennettvm-p81t — julia.get_pgcstack + negative-offset GEP" begin

    # ------------------------------------------------------------------
    # (a) get_pgcstack → Define(dest, TLS_BASE, :add, 0) (NOT a SoftCall reject).
    # ------------------------------------------------------------------
    @testset "get_pgcstack → Define(TLS_BASE)" begin
        inst = _B.IRCall(:pg, Symbol("julia.get_pgcstack"),
                         _B.IROperand[], Int[], 64)
        out = _BV._lower_body_inst(inst)
        @test out isa _BV.Define
        @test out.target === :pg
        @test out.lhs == _BV.TLS_BASE        # the fixed TLS sentinel cell
        @test out.op === :add
        @test out.rhs == Int64(0)            # nullary constant-create
        # the sentinel tier sits ABOVE globals with a wide margin.
        @test _BV.TLS_BASE == Int64(1) << 56
        @test _BV.TLS_BASE > _BV.GLOBAL_BASE
    end

    # ------------------------------------------------------------------
    # (b) a non-0-arity get_pgcstack reaches THIS arm and fails loud (Rule 1).
    # ------------------------------------------------------------------
    @testset "arity fail-loud (expects 0 args)" begin
        inst = _B.IRCall(:pg, Symbol("julia.get_pgcstack"),
                         _B.IROperand[_B.SSAOperand(:x)], Int[64], 64)
        msg = try
            _BV._lower_body_inst(inst); ""
        catch e
            e isa InterruptException && rethrow()
            sprint(showerror, e)
        end
        @test occursin("get_pgcstack", msg)
        @test occursin("expects 0 args", msg)
    end

    # ------------------------------------------------------------------
    # (c) a NEGATIVE IRPtrOffset now lowers (was a hard error); divisibility
    #     still fails loud (the sign-agnostic guard is kept).
    # ------------------------------------------------------------------
    @testset "negative IRPtrOffset lowers; divisibility still fails" begin
        # -152 bytes, i8 elements (elem_width=8 → 1 byte/cell) → -152 cells.
        inst = _B.IRPtrOffset(:ct, _B.SSAOperand(:pg), -152, 8)
        out = _BV._lower_body_inst(inst)
        @test out isa _BV.Define
        @test out.target === :ct
        @test out.lhs === :pg
        @test out.op === :add
        @test out.rhs == Int64(-152)         # exact signed cell index

        # divisibility is sign-agnostic and STILL fails loud: -3 bytes over
        # 16-bit (2-byte) elements is a sub-element offset.
        bad = _B.IRPtrOffset(:bad, _B.SSAOperand(:pg), -3, 16)
        msg = try
            _BV._lower_body_inst(bad); ""
        catch e
            e isa InterruptException && rethrow()
            sprint(showerror, e)
        end
        @test occursin("not evenly divisible", msg)
    end

    # ------------------------------------------------------------------
    # (d) micro round-trip (Rule 4 / P0.6): the GC-preamble chain
    #     pg = get_pgcstack(); ct = gep(pg,-152); pf = gep(ct,+168);
    #     pl = load(pf); ret pl.  pf = TLS_BASE+16 (globals tier) → pl == 0.
    # ------------------------------------------------------------------
    @testset "micro round-trip: pgcstack GC-preamble chain reads 0" begin
        blk = _B.IRBasicBlock(:entry,
            _B.IRInst[
                _B.IRCall(:pg, Symbol("julia.get_pgcstack"),
                          _B.IROperand[], Int[], 64),
                _B.IRPtrOffset(:ct, _B.SSAOperand(:pg), -152, 8),   # TLS_BASE-152
                _B.IRPtrOffset(:pf, _B.SSAOperand(:ct), 168, 8),    # +168 = +16
                _B.IRLoad(:pl, _B.SSAOperand(:pf), 64),             # absent → 0
            ],
            _B.IRRet(_B.SSAOperand(:pl), 64))
        parsed = _B.ParsedIR(64, Tuple{Symbol,Int}[(:x, 64)], [blk], Int[64])
        prog = _BV.lower_vm(parsed)

        # the load address lands in the globals tier (absent-read = 0).
        @test _BV.TLS_BASE + 16 >= _BV.GLOBAL_BASE

        rs = _BV.initial_state(prog, Dict(:x => Int64(0)))
        _BV.run!(rs, prog; checkpoint_interval = 2)
        @test _BV.is_halted(rs)
        @test _BV.result(rs)[:pf] == _BV.TLS_BASE + 16   # +16 net cell address
        @test _BV.result(rs)[:pl] == 0                    # zero-init globals read

        _BV.unrun!(rs, prog)
        @test rs.current == rs.initial     # P0.6 — reversed to start
        @test isempty(rs.history)          # P0.6 — history drained
        @test rs.step_count == 0           # P0.6 — counter reset
    end

    # ------------------------------------------------------------------
    # (e) directional coupling: every BVM-modeled benign cell callee is
    #     TOLERATED by Bennett's closed-world benign-intrinsic prefix list.
    #     Directional subset BY DESIGN — Bennett tolerates MORE (genuinely
    #     dropped intrinsics); equality would be wrong.
    # ------------------------------------------------------------------
    @testset "coupling: BVM-models ⟹ Bennett-tolerates (directional)" begin
        prefixes = _B._D1B_BENIGN_INTRINSIC_PREFIXES
        for c in _BV._BENIGN_CELL_DISPATCH
            @test any(p -> startswith(String(c), p), prefixes)
            # ingest-smoke: each modeled callee lowers to a Define.
            inst = c === Symbol("julia.gc_loaded") ?
                _B.IRCall(:d, c, _B.IROperand[_B.SSAOperand(:mem),
                                              _B.SSAOperand(:data)], Int[64, 64], 64) :
                _B.IRCall(:d, c, _B.IROperand[], Int[], 64)
            @test _BV._lower_body_inst(inst) isa _BV.Define
        end
    end

    # ------------------------------------------------------------------
    # (f) the REAL fdict set now clears the pgcstack, negative-offset,
    #     const-cond IRSelect (bead bennettvm-416r.14), AND IRInsertBits
    #     bits-struct sret (bead bennettvm-416r.15, Bennett-dv1z) walls,
    #     advancing to the aggregate-RETURN reject (the multi-key return keyed
    #     off ret_elem_widths is the follow-on bead bennettvm-x3t0). When THAT
    #     lands, this flips.
    # ------------------------------------------------------------------
    @testset "fdict set advances to the sret_box gate (blocker 5)" begin
        fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])
        set = _B.extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                                                  ptr_cells = true)
        threw = false
        msg = ""
        try
            _BV.lower_vm(set; entry = first(set).first)
        catch e
            threw = true
            msg = sprint(showerror, e)
        end
        @test threw                                    # still throws (successor wall)
        @test !occursin("julia.get_pgcstack", msg)     # pgcstack wall CLEARED
        @test !occursin("is negative", msg)            # negative-offset wall CLEARED
        @test !occursin("IRSelect cond is", msg)       # const-cond IRSelect wall CLEARED
        @test !occursin("IRInsertBits", msg)            # IRInsertBits wall CLEARED (416r.15)
        @test !occursin("returns aggregate SSA value", msg)  # aggregate-return wall CLEARED (x3t0)
        # the successor wall is the sret_box MEMORY-ABI gate: `setindex!` calls
        # `ht_keyindex2` with `ret_width = 64 ≠ 72 = sum([64,8])` — the explicit
        # result-buffer ABI, the blocker-5 sret_box bead `bennettvm-416r.16` (filed by the
        # orchestrator). When it lands this assert flips — intended.
        @test occursin("sret_box", msg)                # the blocker-5 sret_box gate
        @test occursin("blocker-5", msg)
    end
end
