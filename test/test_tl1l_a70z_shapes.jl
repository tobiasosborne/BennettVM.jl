# test/test_tl1l_a70z_shapes.jl — the BennettVM (downstream) half of Bennett.jl
# bead `Bennett-tl1l`: the TWO a70z emission shapes the real `Dict` corpus never
# produces.
#
# # Why this file exists
#
# `Bennett-a70z` gave `extractvalue {iN,i1} %c, 1` (off an
# `llvm.{s,u}{mul,add}.with.overflow.iN` with one compile-time-constant operand)
# an EXACT overflow bit: the admissible-interval membership test
# `bit = (x < L) | (x > U)`, folded at extraction time. `_fuse_overflow_extract-
# value` (`../Bennett.jl/src/extract/instructions.jl:2523`) has THREE emission
# shapes, not one:
#
#   TWO-SIDED    (both bounds strictly inside the iN domain)
#                → 2 `IRICmp` into `__vN` temporaries + `IRBinOp(dest,:or,·,·,1)`
#                  (`instructions.jl:2572-2577`)
#   ONE-SIDED    (one bound at/outside the domain edge, so its arm is
#                 constant-false and is DROPPED)
#                → a SINGLE `IRICmp` carrying the extractvalue's OWN dest, no
#                  `:or`, and ZERO `counter` consumption
#                  (`instructions.jl:2578-2582`)
#   BOTH-CONST   (both intrinsic operands compile-time constants)
#                → `IRBinOp(dest,:add,iconst(bit),iconst(0),1)` — the
#                  byte-identical Bennett-lbot fold shape, the literal bit from
#                  `_ovf_const_bit` (`instructions.jl:2543-2553`)
#
# `test_a70z_dict64_roundtrip.jl` proves the TWO-SIDED shape downstream, because
# that is the only shape the real `Dict{Int64,Int64}` corpus emits (`rehash!`'s
# `smul(%value_phi, 8)`: `[-2^60, 2^60-1]`, both bounds interior). The other two
# were `argued`, never `proven`, downstream — residual gaps (1) and (2) of
# `Bennett-tl1l`. **This file is that proof.**
#
# One-sidedness is NOT an exotic corner: it is the MAJORITY shape.
# `_ovf_admissible_range` (`instructions.jl:2602`) drops the low arm for EVERY
# unsigned op (`L = 0` is the unsigned domain floor) and drops exactly one arm
# for EVERY `sadd`/`uadd` (`smin - c` leaves the domain below when `c > 0`,
# `smax - c` leaves it above when `c < 0`). Only signed MUL is generally
# two-sided. A downstream regression on the one-sided shape would therefore go
# unnoticed by every existing gate.
#
# # RESEARCH STEP (Bennett.jl Rule 9 — recorded here because it is not
# # derivable from the diff, and a future agent will otherwise redo it)
#
# From-source fixtures are preferred. Probed 2026-07-30, Julia 1.12 / this repo
# pair; BOTH plain-Julia routes to these shapes are CLOSED today:
#
#   (i) `Base.Checked.add_with_overflow(x, c)` / `checked_add(x, c)` —
#       the natural one-sided source. Extraction FAILS, and NOT on anything
#       a70z-related: the `Tuple{Int64,Bool}` return is built by `insertvalue`
#       into an `{ i64, i8 } undef` aggregate, and Bennett.jl rejects `undef`
#       operands (`Bennett-bjdg` / U80, CLAUDE.md §1):
#
#         extraction FAILED for callee `p_sadd64#…` — ir_extract.jl:
#         UndefValue operand: { i64, i8 } undef — reading undef is
#         implementation-defined per LLVM LangRef.
#
#       Reproduced at i16/i32/i64 and for both `add_with_overflow` and
#       `mul_with_overflow`, signed and unsigned. The wall is UPSTREAM of the
#       overflow bit — it is about the tuple RETURN, not the intrinsic — which
#       is exactly why the `Dict` corpus (where the intrinsic result is consumed
#       in-body, never returned as a tuple) sails past it.
#
#  (ii) both-constant from source — e.g.
#       `add_with_overflow(Int64(3), Int64(4))[2] ? -1 : x`. Julia's OWN
#       compiler constant-folds it during inference: the extracted body has
#       ZERO instructions (`n = 0`). No `.with.overflow` intrinsic ever reaches
#       LLVM, so the front-end arm cannot be reached from source at all. Also
#       reproduced with the second operand behind a `const` global.
#
# Both observations are PINNED as tripwires in testset (0) below: if either
# route ever opens (a `bjdg` fix; a Julia inference change), that testset goes
# RED and the next agent should replace the fixtures here with from-source ones.
#
# # What the fixtures are (and why they are NOT "hand-built ParsedIR")
#
# The fallback used here is strictly stronger than the hand-built `ParsedIR` the
# bead offered as the cheap option: these are hand-written `.ll` modules driven
# through the REAL Bennett.jl front-end
# (`Bennett.extract_parsed_ir_from_ll` → `_convert_instruction` →
# `_fuse_overflow_extractvalue`), so the emitted shape is whatever
# `instructions.jl` actually emits today — not a transcription of it. They are
# the SAME fixture shapes the upstream gate uses
# (`../Bennett.jl/test/test_a70z_overflow_const_bit.jl` `_a70z_fixture` /
# `_a70z_fixture_cc`), continued one stage further: `lower_vm` → `run!` →
# `unrun!`. `%o` is kept live by a `br i1`, matching the real `memorynew` shape;
# extraction runs no DCE, but the branch keeps the shape honest.
#
# # What this file pins (Rule 4 — known values, never "didn't throw")
#
#   (0) RESEARCH TRIPWIRES — the two closed from-source routes, pinned by their
#       actual failure mode (see above).
#   (1) ONE-SIDED, four fixtures spanning widths 64 / 32 / 16 and all three
#       one-sided causes (`sadd` c>0 → `sgt`; `smul` c=-1 → `slt`, the
#       `x == typemin` bit; `uadd` → `ugt` with a SEXT-ENCODED bound; `sadd`
#       c<0 at i32 → `slt`):
#         (a) SHAPE PIN at the ParsedIR level — exactly ONE `IRICmp`, carrying
#             the extractvalue's own dest `:o`, NO width-1 `:or`, no `__vN`
#             counter names, no surviving `IRCall`/`IRExtractValue`; and the
#             bound is the exact `_ovf_bound_const` value.
#         (b) SHAPE PIN at the VM level — it ingested as ONE `Define(:o, :x,
#             pred, bound, W)` at the OPERAND width, and no `:or` `Define`.
#         (c) DOWNSTREAM PROOF — `run!` to halt, the a70z bit `:o` AND the
#             wrapped product `:p` AND the preserved input `:x` all against the
#             native `Base.Checked` oracle, over ≥5 probes per fixture that
#             INCLUDE the two inputs straddling the 0→1 flip; then `unrun!` to
#             the exact initial state with empty history and zero step count —
#             under BOTH the L2 (`compute_must_cache`) and L3 (empty must-cache)
#             regimes. Plus a per-step inverse sweep.
#   (2) BOTH-CONSTANT, NINE fixtures at widths 64 / 32 / 16. **All four
#       intrinsic arms** (`sadd`, `smul`, `umul`, `uadd`) appear in **both bit
#       polarities**, and `uadd` additionally at W = 64. That completeness is
#       load-bearing, not decorative: the `bit == 0` emission is byte-identical
#       to the pre-existing lbot fold-to-zero shape, so ONLY an arm's `bit == 1`
#       fixture discriminates `_ovf_const_bit` — an arm present at bit 0 alone
#       would be covered in name only.
#         (a) SHAPE PIN — exactly one `IRBinOp(:o,:add,ConstOperand(bit),
#             ConstOperand(0),1)`, NO `IRICmp` anywhere (a const-vs-const
#             compare would be the OTHER design and is deliberately not
#             emitted), no `__vN` churn.
#         (b) VM PIN — `Define(:o, bit, :add, 0, 1)`.
#         (c) DOWNSTREAM PROOF — same run/unrun discipline. The bit is
#             INPUT-INDEPENDENT here, so "boundary probe" is meaningless; the
#             0→1 discrimination comes from running BOTH polarities of each arm
#             and asserting the CONTROL FLOW they select (`bit == 1` must take
#             the `oflow` arm — the analogue of the throw the native code takes).
#         The expected bit is NOT a hand-computed literal: `_tl1l_cbit`
#         recomputes it from the fixture's OWN constants through
#         `Base.Checked.{add,mul}_with_overflow` at the fixture's native width
#         and signedness. The table's `want` column is retained as a statement
#         of intent and is cross-checked against that oracle, so a typo in
#         either one fails loudly instead of agreeing with itself.
#
# # Honest boundary
#
#   * The `bit == 0` both-constant shape is BYTE-IDENTICAL to the Bennett-lbot
#     fold-to-zero shape (`IRBinOp(dest,:add,0,0,1)`) — deliberately so, per the
#     a70z design (D3). So only the `bit == 1` fixtures discriminate the
#     `_ovf_const_bit` path from the pre-existing fold. That is why testset (2)
#     carries EVERY arm at bit 1 and asserts that coverage rule explicitly: the
#     first cut of this file had `uadd` at bit 0 only, which left the unsigned-
#     add branch of `_ovf_const_bit` with no downstream discrimination at all
#     (hostile review, 2026-07-30). The bit-0 fixtures remain as the
#     byte-identity half of the pair.
#   * The wrapped product `:p` at W < 64 is asserted against BVM's own
#     narrow-width convention: `_apply_binop` masks arithmetic results to the
#     low `W` bits (ADR 0012 R1 / `bennettvm-bgc`), so an i32 `x+5` reads back
#     as a NON-NEGATIVE `Int64` in `[0, 2^32)`, not as a sign-extended `Int32`.
#     The oracles below encode that explicitly via `reinterpret(UInt32, ·)`.
#     This is a BVM representation choice, not an a70z claim.
#   * These are hand-written `.ll` fixtures, not real-corpus programs; the
#     real-corpus (two-sided) proof lives in `test_a70z_dict64_roundtrip.jl`.
#     Nothing here claims a Julia program that emits the one-sided shape exists
#     today — testset (0) pins the opposite.
#
# # Ref
#   * `../Bennett.jl/src/extract/instructions.jl:2523` —
#     `_fuse_overflow_extractvalue`; `:2602` `_ovf_admissible_range`; `:2648`
#     `_ovf_bound_const`; `:2660` `_ovf_const_bit`.
#   * `../Bennett.jl/test/test_a70z_overflow_const_bit.jl` — the upstream gate;
#     (c)/(d) pin one-sided emission, (a4) pins the both-constant fold, and
#     (a5)/(a6)/(a7) (added by `Bennett-tl1l`) sweep N ∈ {16, 32}.
#   * `test/test_a70z_dict64_roundtrip.jl` — the TWO-SIDED, real-corpus sibling.
#   * `test/test_0fw7_dup_call_args.jl` — the L2/L3 regime + per-step-inverse
#     harness shapes reused here.
#   * `src/ir/arithmetic_assignment.jl` — `_apply_binop` (the i`W` masking
#     convention the `:p` oracles encode).
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known values), Rule 11 (literate).

using Test
using BennettVM
import Bennett

const _BVt = BennettVM
const _Bt  = Bennett

using Base.Checked: add_with_overflow, mul_with_overflow

# ---------------------------------------------------------------------
# Fixture machinery — hand-written `.ll` through the REAL front-end
# ---------------------------------------------------------------------

# Width-parametric, operand-parametric; identical in shape to the upstream
# `_a70z_fixture` / `_a70z_fixture_cc`. `%o` is kept live by the `br i1`.
function _tl1l_ll(intr::AbstractString, w::Int, a::AbstractString, b::AbstractString)
    """
    declare {i$w,i1} @llvm.$(intr).with.overflow.i$w(i$w, i$w)
    define i$w @f(i$w %x) {
    top:
      %c = call {i$w,i1} @llvm.$(intr).with.overflow.i$w(i$w $(a), i$w $(b))
      %p = extractvalue {i$w,i1} %c, 0
      %o = extractvalue {i$w,i1} %c, 1
      br i1 %o, label %oflow, label %ok
    ok:    ret i$w %p
    oflow: ret i$w %x
    }
    """
end

function _tl1l_build(ir::AbstractString)
    return mktempdir() do dir
        path = joinpath(dir, "f.ll")
        write(path, ir)
        pir = _Bt.extract_parsed_ir_from_ll(path; entry_function = "f", ptr_cells = true)
        return (pir, _BVt.lower_vm(pir))
    end
end

_tl1l_pir_insts(pir) = [i for b in pir.blocks for i in b.instructions]
_tl1l_vm_insts(prog) = [i for b in prog.blocks for i in b.instructions]

# The two history regimes (the `test_0fw7` / `test_rnhv` idiom).
_tl1l_regimes(prog) = (("L2 (compute_must_cache)", _BVt.compute_must_cache(prog)),
                       ("L3 (empty must_cache)",   Set{Tuple{Symbol,Int}}()))

"""
    _tl1l_downstream(prog, probes, bitof, prodof; label)

Forward to halt under BOTH regimes, check the a70z overflow bit `:o`, the
wrapped product `:p` and the preserved input `:x` against the native oracles,
then `unrun!` to the exact initial state with an empty history. `probes` are the
values as STORED in `IState.locals` (raw low-`W` patterns for the unsigned
fixtures, plain `Int64` at W = 64).
"""
function _tl1l_downstream(prog, probes::Vector{Int64}, bitof, prodof; label::String)
    for (rlabel, mcs) in _tl1l_regimes(prog)
        for x in probes
            rs   = _BVt.initial_state(prog, Dict(:x => x))
            init = deepcopy(rs.current)
            _BVt.run!(rs, prog; max_steps = 10_000, checkpoint_interval = 8,
                      must_cache_set = mcs)
            @test _BVt.is_halted(rs)
            res = _BVt.result(rs)
            # THE a70z CONTRACT ($label, $rlabel, x = $x)
            @test res[:o] == (bitof(x) ? 1 : 0)
            @test res[:p] == prodof(x)
            @test res[:x] == x                      # input preserved
            _BVt.unrun!(rs, prog; max_unsteps = 10_000)
            @test rs.current == init
            @test isempty(rs.history)
            @test rs.step_count == 0
        end
    end
    return nothing
end

# The native integer type of an `.ll` fixture width / signedness.
function _tl1l_ntype(w::Int, signed::Bool)
    signed && return w == 64 ? Int64 : w == 32 ? Int32 : w == 16 ? Int16 : Int8
    return w == 64 ? UInt64 : w == 32 ? UInt32 : w == 16 ? UInt16 : UInt8
end

# INDEPENDENT oracle for the both-constant overflow bit: recomputed from the
# fixture's own `.ll` constants via `Base.Checked` at the fixture's native width
# and signedness, rather than asserted as a hand-computed literal. `c1`/`c2` are
# the strings written into the `.ll`, i.e. the SEXT-decoded form the front-end's
# `_const_int_as_int` also sees; the unsigned arms re-decode by masking to the
# low W bits, exactly as `_ovf_const_bit` / `_ovf_admissible_range` do.
function _tl1l_cbit(intr::AbstractString, w::Int, c1::AbstractString, c2::AbstractString)
    signed = startswith(intr, "s")
    mulp   = endswith(intr, "mul")
    T = _tl1l_ntype(w, signed)
    m = (Int128(1) << w) - 1
    a = signed ? T(parse(Int64, c1)) : T(Int128(parse(Int64, c1)) & m)
    b = signed ? T(parse(Int64, c2)) : T(Int128(parse(Int64, c2)) & m)
    ovf = mulp ? mul_with_overflow(a, b)[2] : add_with_overflow(a, b)[2]
    return ovf ? 1 : 0
end

# The wrapped `%p` of a both-constant intrinsic, in BVM's storage convention
# (`_apply_binop` masks to the low W bits — ADR 0012 R1). `c1`/`c2` arrive as
# the SEXT-decoded strings written into the `.ll`.
function _tl1l_pconst(intr::AbstractString, w::Int, c1::AbstractString, c2::AbstractString)
    a = parse(Int64, c1)
    b = parse(Int64, c2)
    r = (intr == "smul" || intr == "umul") ? Int128(a) * Int128(b) : Int128(a) + Int128(b)
    m = (Int128(1) << w) - 1
    lo = r & m
    return w == 64 ? reinterpret(Int64, UInt64(lo)) : Int64(lo)
end

# Per-step inverse over the whole trajectory (the `test_a70z_dict64_roundtrip`
# (e) / `test_0fw7` discipline: the aggregate round-trip can mask a
# mid-trajectory inverse bug).
function _tl1l_per_step_inverse(prog, x::Int64)
    mc   = _BVt.compute_must_cache(prog)
    rs   = _BVt.initial_state(prog, Dict(:x => x))
    init = deepcopy(rs.current)
    snaps = _BVt.IState[]
    while !_BVt.is_halted(rs)
        _BVt.step!(rs, prog; checkpoint_interval = 4, must_cache_set = mc)
        push!(snaps, deepcopy(rs.current))
        length(snaps) <= 1_000 || error("tl1l per-step sweep exceeded 1000 steps")
    end
    @test !isempty(snaps)
    ok = true
    while rs.step_count > 0
        _BVt.unstep!(rs, prog)
        expected = rs.step_count > 0 ? snaps[rs.step_count] : init
        if rs.current != expected
            ok = false
            break
        end
    end
    @test ok
    @test rs.step_count == 0
    @test rs.current == init
    return nothing
end

# ---------------------------------------------------------------------
# (0) RESEARCH TRIPWIRES — both from-source routes are CLOSED today
# ---------------------------------------------------------------------

_tl1l_src_sadd(x::Int64)  = add_with_overflow(x, Int64(5))[2] ? Int64(-1) : x
_tl1l_src_umul(x::UInt32) = mul_with_overflow(x, UInt32(3))[2] ? UInt32(0) : x
_tl1l_src_cc(x::Int64)    = add_with_overflow(Int64(3), Int64(4))[2] ? Int64(-1) : x

@testset "(0) tl1l — the from-source routes to these shapes are closed" begin
    # (i) `Base.Checked.*_with_overflow` returns a `Tuple{T,Bool}`, which Julia
    #     builds by `insertvalue` into an `{ iN, i8 } undef` — the Bennett-bjdg
    #     / U80 undef wall, entirely upstream of the a70z fuse. If this EVER
    #     stops throwing, the one-sided fixtures below should be replaced with a
    #     from-source program (Bennett.jl Rule 9 / bead Bennett-tl1l).
    for (f, T) in ((_tl1l_src_sadd, Tuple{Int64}), (_tl1l_src_umul, Tuple{UInt32}))
        msg = try
            _Bt.extract_parsed_ir_set_from_julia(f, T; ptr_cells = true)
            ""
        catch e
            e isa InterruptException && rethrow()
            sprint(showerror, e)
        end
        @test msg != ""
        @test occursin("UndefValue operand", msg)
        @test occursin("undef", msg)
    end

    # (ii) Both-constant from source is folded away by Julia's OWN inference
    #      before LLVM ever sees an intrinsic: the extracted body is EMPTY.
    set = _Bt.extract_parsed_ir_set_from_julia(_tl1l_src_cc, Tuple{Int64};
                                               ptr_cells = true)
    @test length(set) == 1
    body = first(set).second
    @test isempty(_tl1l_pir_insts(body))
    @test !any(i -> i isa _Bt.IRCall, _tl1l_pir_insts(body))
end

# ---------------------------------------------------------------------
# (1) ONE-SIDED — a SINGLE IRICmp carrying the extractvalue's own dest
# ---------------------------------------------------------------------
#
# `_ovf_bound_const` values, computed here in Julia so the assertion is an
# independent statement of the bound rather than a copy of the emitted one:
#
#   sadd i64 c=5      U = typemax(Int64) - 5                  → `sgt`
#   smul i64 c=-1     L = cld(typemax(Int64), -1) = -typemax  → `slt`
#                     (the bit is exactly `x == typemin(Int64)`)
#   sadd i32 c=-1000  L = typemin(Int32) + 1000               → `slt`
#   uadd i16 c=1      U = 0xFFFE, SEXT-ENCODED as -2          → `ugt`

@testset "(1) tl1l — ONE-SIDED emission: shape pin + downstream proof" begin

    # ---- (1a) sadd i64, c = 5 → single `sgt x, typemax-5` --------------
    @testset "(1a) sadd i64 c=5 — sgt, W=64" begin
        pir, prog = _tl1l_build(_tl1l_ll("sadd", 64, "%x", "5"))
        ins  = _tl1l_pir_insts(pir)
        cmps = [i for i in ins if i isa _Bt.IRICmp]
        @test length(cmps) == 1                                   # ONE-SIDED
        @test !any(i -> i isa _Bt.IRBinOp && i.op === :or && i.width == 1, ins)
        c = cmps[1]
        @test c.dest === :o                                       # extractvalue's OWN dest
        @test c.predicate === :sgt
        @test c.width == 64
        @test c.op1 isa _Bt.SSAOperand && c.op1.name === :x
        @test c.op2 isa _Bt.ConstOperand && c.op2.value == typemax(Int64) - 5
        @test !any(i -> startswith(String(i.dest), "__v"), ins)    # zero counter churn
        @test !any(i -> i isa _Bt.IRCall || i isa _Bt.IRExtractValue, ins)

        vm  = _tl1l_vm_insts(prog)
        ods = [i for i in vm if i isa _BVt.Define && i.target === :o]
        @test length(ods) == 1
        @test ods[1].op === :sgt
        @test ods[1].lhs === :x
        @test ods[1].rhs == typemax(Int64) - 5
        @test ods[1].width == 64                                  # OPERAND width
        @test !any(i -> i isa _BVt.Define && i.op === :or, vm)

        # Probes straddle the flip: typemax-6/-5 → 0, typemax-4/typemax → 1.
        probes = Int64[typemin(Int64), 0, 7, typemax(Int64) - 6, typemax(Int64) - 5,
                       typemax(Int64) - 4, typemax(Int64)]
        bitof(x)  = add_with_overflow(x, Int64(5))[2]
        prodof(x) = add_with_overflow(x, Int64(5))[1]
        @test any(bitof, probes) && !all(bitof, probes)            # non-vacuity
        _tl1l_downstream(prog, probes, bitof, prodof; label = "sadd i64 c=5")
        _tl1l_per_step_inverse(prog, typemax(Int64) - 2)           # the overflow arm
        _tl1l_per_step_inverse(prog, Int64(11))                    # the ok arm
    end

    # ---- (1b) smul i64, c = -1 → single `slt x, -typemax` ---------------
    @testset "(1b) smul i64 c=-1 — slt, the x==typemin bit" begin
        pir, prog = _tl1l_build(_tl1l_ll("smul", 64, "%x", "-1"))
        ins  = _tl1l_pir_insts(pir)
        cmps = [i for i in ins if i isa _Bt.IRICmp]
        @test length(cmps) == 1
        @test !any(i -> i isa _Bt.IRBinOp && i.op === :or && i.width == 1, ins)
        c = cmps[1]
        @test c.dest === :o
        @test c.predicate === :slt
        @test c.width == 64
        @test c.op2 isa _Bt.ConstOperand && c.op2.value == -typemax(Int64)
        @test !any(i -> startswith(String(i.dest), "__v"), ins)

        vm  = _tl1l_vm_insts(prog)
        ods = [i for i in vm if i isa _BVt.Define && i.target === :o]
        @test length(ods) == 1 && ods[1].op === :slt && ods[1].rhs == -typemax(Int64)
        @test !any(i -> i isa _BVt.Define && i.op === :or, vm)

        probes = Int64[typemin(Int64), typemin(Int64) + 1, -1, 0, 1, typemax(Int64)]
        bitof(x)  = mul_with_overflow(x, Int64(-1))[2]
        prodof(x) = mul_with_overflow(x, Int64(-1))[1]
        @test any(bitof, probes) && !all(bitof, probes)
        # ONLY typemin overflows — the tightest possible one-sided interval.
        @test count(bitof, probes) == 1
        _tl1l_downstream(prog, probes, bitof, prodof; label = "smul i64 c=-1")
    end

    # ---- (1c) sadd i32, c = -1000 → single `slt x, typemin(Int32)+1000` -
    #      NON-64 WIDTH (the bead's elsize concern): the comparison must run in
    #      i32 semantics and the product must mask to the low 32 bits.
    @testset "(1c) sadd i32 c=-1000 — slt, W=32" begin
        pir, prog = _tl1l_build(_tl1l_ll("sadd", 32, "%x", "-1000"))
        ins  = _tl1l_pir_insts(pir)
        cmps = [i for i in ins if i isa _Bt.IRICmp]
        @test length(cmps) == 1
        @test !any(i -> i isa _Bt.IRBinOp && i.op === :or && i.width == 1, ins)
        c = cmps[1]
        @test c.dest === :o
        @test c.predicate === :slt
        @test c.width == 32                                        # OPERAND width
        @test c.op2 isa _Bt.ConstOperand &&
              c.op2.value == Int64(typemin(Int32)) + 1000
        @test !any(i -> startswith(String(i.dest), "__v"), ins)

        vm  = _tl1l_vm_insts(prog)
        ods = [i for i in vm if i isa _BVt.Define && i.target === :o]
        @test length(ods) == 1 && ods[1].op === :slt && ods[1].width == 32
        @test !any(i -> i isa _BVt.Define && i.op === :or, vm)

        # Stored values are the raw Int64s; `_apply_binop` masks/sign-extends
        # from W = 32 itself, so signed Int64 probes in the i32 range are exact.
        tmin32 = Int64(typemin(Int32))
        probes = Int64[tmin32, tmin32 + 999, tmin32 + 1000, tmin32 + 1001,
                       -1, 0, 42, Int64(typemax(Int32))]
        bitof(x)  = add_with_overflow(Int32(x), Int32(-1000))[2]
        # BVM narrow-width convention (ADR 0012 R1): results are masked to the
        # low W bits, so the readback is the UNSIGNED i32 pattern.
        prodof(x) = Int64(reinterpret(UInt32, add_with_overflow(Int32(x), Int32(-1000))[1]))
        @test any(bitof, probes) && !all(bitof, probes)
        _tl1l_downstream(prog, probes, bitof, prodof; label = "sadd i32 c=-1000")
        _tl1l_per_step_inverse(prog, tmin32 + 500)                 # overflow arm
    end

    # ---- (1d) uadd i16, c = 1 → single `ugt x, 0xFFFE` ------------------
    #      The bound 65534 does NOT fit a nonnegative i16, so `_ovf_bound_const`
    #      SEXT-encodes it as -2. This fixture is the downstream proof that the
    #      sext-encoded bound survives ingest and compares correctly (BVM's
    #      `:ugt` masks both operands to the low 16 bits — `-2 & 0xFFFF`).
    @testset "(1d) uadd i16 c=1 — ugt with a SEXT-encoded bound, W=16" begin
        pir, prog = _tl1l_build(_tl1l_ll("uadd", 16, "%x", "1"))
        ins  = _tl1l_pir_insts(pir)
        cmps = [i for i in ins if i isa _Bt.IRICmp]
        @test length(cmps) == 1
        @test !any(i -> i isa _Bt.IRBinOp && i.op === :or && i.width == 1, ins)
        c = cmps[1]
        @test c.dest === :o
        @test c.predicate === :ugt
        @test c.width == 16
        @test c.op2 isa _Bt.ConstOperand && c.op2.value == -2   # sext of 0xFFFE
        @test !any(i -> startswith(String(i.dest), "__v"), ins)

        vm  = _tl1l_vm_insts(prog)
        ods = [i for i in vm if i isa _BVt.Define && i.target === :o]
        @test length(ods) == 1 && ods[1].op === :ugt &&
              ods[1].rhs == -2 && ods[1].width == 16
        @test !any(i -> i isa _BVt.Define && i.op === :or, vm)

        # Raw unsigned i16 patterns; only 0xFFFF overflows.
        probes = Int64[0, 1, 100, 65533, 65534, 65535]
        bitof(x)  = add_with_overflow(UInt16(x), UInt16(1))[2]
        prodof(x) = Int64(add_with_overflow(UInt16(x), UInt16(1))[1])
        @test any(bitof, probes) && !all(bitof, probes)
        @test count(bitof, probes) == 1
        _tl1l_downstream(prog, probes, bitof, prodof; label = "uadd i16 c=1")
        _tl1l_per_step_inverse(prog, Int64(65535))                 # overflow arm
    end
end

# ---------------------------------------------------------------------
# (2) BOTH-CONSTANT — the literal `IRBinOp(dest,:add,bit,0,1)` fold
# ---------------------------------------------------------------------
#
# The bit is INPUT-INDEPENDENT, so the discrimination is the CONTROL FLOW it
# selects: `bit == 1` must take the `oflow` arm (returning `%x`), `bit == 0` the
# `ok` arm (returning the wrapped `%p`).
#
# COVERAGE RULE (why the table looks redundant and is not): the `bit == 0`
# emission is BYTE-IDENTICAL to the pre-existing Bennett-lbot fold-to-zero
# shape, so an arm that appears only at bit 0 proves nothing about
# `_ovf_const_bit` — it would pass unchanged if the whole both-constant path
# were deleted. **Every one of the four arms therefore appears at bit 1.**

@testset "(2) tl1l — BOTH-CONSTANT literal fold: shape pin + downstream proof" begin
    # (name, intr, W, c1 (as written in the .ll, i.e. SEXT-decoded), c2, want)
    # `want` is the INTENT; the assertion oracle is `_tl1l_cbit` (below), which
    # recomputes the bit from c1/c2 through `Base.Checked` at the fixture's own
    # width and signedness. The two are cross-checked against each other.
    cases = (("sadd i64 typemax+1 → 1",  "sadd", 64, "9223372036854775807", "1", 1),
             ("sadd i64 3+4 → 0",        "sadd", 64, "3", "4", 0),
             ("smul i32 46341² → 1",     "smul", 32, "46341", "46341", 1),
             ("smul i32 46340² → 0",     "smul", 32, "46340", "46340", 0),
             ("umul i16 300*300 → 1",    "umul", 16, "300", "300", 1),
             ("umul i16 200*300 → 0",    "umul", 16, "200", "300", 0),
             # uadd, BOTH polarities — the arm the first cut of this file left
             # at bit 0 only (hostile-review MAJOR): 65534+3 = 65537 > 0xFFFF.
             ("uadd i16 65534+3 → 1",    "uadd", 16, "-2", "3", 1),
             ("uadd i16 65534+1 → 0",    "uadd", 16, "-2", "1", 0),
             # ... and at W = 64, where the constants are the two-operand
             # extremes of the unsigned domain: (2^64-1) + 1 = 2^64.
             ("uadd i64 (2^64-1)+1 → 1", "uadd", 64, "-1", "1", 1))

    # Every arm must be present at bit 1 (see the COVERAGE RULE above). Stated
    # as an assertion so a future edit that drops one fails here, loudly,
    # instead of quietly shrinking the discriminating half of the table.
    for arm in ("sadd", "smul", "umul", "uadd")
        @test any(c -> c[2] == arm && c[6] == 1, cases)
        @test any(c -> c[2] == arm && c[6] == 0, cases)
    end

    for (name, intr, w, c1, c2, want) in cases
        # INDEPENDENT oracle — not the table's literal. ($name)
        bit = _tl1l_cbit(intr, w, c1, c2)
        @test bit == want

        pir, prog = _tl1l_build(_tl1l_ll(intr, w, c1, c2))
        ins = _tl1l_pir_insts(pir)

        # (2a) SHAPE PIN: the byte-identical lbot fold shape, carrying the
        #      LITERAL bit. NO IRICmp: a const-vs-const compare is the design
        #      that was deliberately NOT chosen (a70z D3). ($name)
        lits = [i for i in ins if i isa _Bt.IRBinOp && i.dest === :o &&
                i.op === :add && i.width == 1 &&
                i.op1 isa _Bt.ConstOperand && i.op1.value == bit &&
                i.op2 isa _Bt.ConstOperand && i.op2.value == 0]
        @test length(lits) == 1
        @test !any(i -> i isa _Bt.IRICmp, ins)
        @test !any(i -> i isa _Bt.IRBinOp && i.op === :or, ins)
        @test !any(i -> i isa _Bt.IRCall || i isa _Bt.IRExtractValue, ins)
        @test !any(i -> startswith(String(i.dest), "__v"), ins)   # zero counter churn

        # (2b) VM PIN. ($name)
        vm  = _tl1l_vm_insts(prog)
        ods = [i for i in vm if i isa _BVt.Define && i.target === :o]
        @test length(ods) == 1
        @test ods[1].op === :add
        @test ods[1].lhs == bit
        @test ods[1].rhs == 0
        @test ods[1].width == 1
        @test !any(i -> i isa _BVt.Define && i.op in (:slt, :sgt, :ult, :ugt), vm)

        # (2c) DOWNSTREAM PROOF. The `oflow` arm returns `%x`, the `ok` arm the
        #      wrapped `%p`; either way `:o` must read back as the literal bit
        #      and `:x` must be preserved. ($name)
        probes = w == 64 ? Int64[typemin(Int64), -3, 0, 42, typemax(Int64)] :
                           Int64[0, 1, 42, (Int64(1) << w) - 1]
        _tl1l_downstream(prog, probes, _x -> bit == 1, _x -> _tl1l_pconst(intr, w, c1, c2);
                         label = name)
        _tl1l_per_step_inverse(prog, probes[end])
    end
end
