# test/test_x3t0_multikey_return.jl — multi-key aggregate RETURN across a
# reversible VM call (bead `bennettvm-x3t0`, CW-D blocker 4; ADR 0019 §4).
#
# # What this file pins
#
# The follow-on to the acq / 416r.15 aggregate-BODY work: a callee that RETURNS
# a `{i64, i8}`-style heterogeneous aggregate by VALUE (`ret_width == sum(
# ret_elem_widths)`), and a caller that receives it into a per-slot family and
# reads the fields back with `IRExtractValue`. Before this bead the aggregate-
# return `IRRet` reject ("returns aggregate SSA value … DEFERRED") fired; the
# multi-key return replaces it with a slot-family `EndInstruction.returns`
# keyed off `ret_elem_widths` and a slot-family `CallEnter.targets` at the call
# site.
#
# # The runtime is ALREADY N-ary (zero interpreter changes)
#
# `ReturnExit` (src/ir/call_transitions.jl), the End→ReturnExit synthesis
# (src/interpreter/Interpreter.jl), `predelta_payload`, `forward`, and
# `inverse` all loop over N returns/targets already. Testset (a) below PINS
# that contract on a HAND-BUILT 2-value-return module — it is GREEN before the
# ingest change and must stay GREEN after (the bead relies on it). The entire
# x3t0 change lives in the ingest/lowering layer.
#
# # The uniform slot-family rule
#
# An aggregate SSA value is modelled as a FAMILY of N synthetic per-slot keys
# `_agg_slot_name(name, k)`, one per element (the acq bead). x3t0 extends the
# family to CALL TOKENS: a value-ABI `IRCall` dest whose callee returns N > 1
# elements (`ret_width == sum(ret_elem_widths)`) acquires the slot structure at
# the call site, so a caller can `extractvalue` the returned aggregate and a
# forwarding function can RETURN the call token directly.
#
# # The `ret_width == sum(ret_elem_widths)` discriminator (NOT arg arity)
#
# Guard-5 distinguishes the VALUE-return ABI (this bead) from the sret_box
# MEMORY ABI (blocker 5, out of scope) by `ret_width == sum(ret_elem_widths)`,
# NOT by argument arity: the self-recursive `ht_keyindex2` call passes 1 arg
# vs 2 params (a separate frontend gap), so an arg-arity discriminator would
# false-wall it. The sret_box caller (`setindex!` → `ht_keyindex2` with
# `ret_width = 64 ≠ 72`) fails loud STATICALLY at ingest with a blocker-5
# message (Rule 1 — fail at the cause, not a downstream runtime symptom).
#
# # Ref
#   * `docs/adr/0019-reversible-calls.md` §4 (ReturnExit; N-ary returns).
#   * `src/ir/call_transitions.jl` — ReturnExit (already N-ary).
#   * `src/ir/ingest.jl` — the IRRet slot-family End + agg_dests call admission.
#   * `src/ir/ingest_body.jl` — guard-5 slot-family targets + the sret wall.
#   * `src/ir/ingest_multi.jl` — `_declared_returns` arity off ret_elem_widths.
#   * `src/ir/call_frames.jl` — FunctionEntry.ret_elem_widths.
#   * `test/test_call_roundtrip.jl` — the hand-built call/return idiom mirrored.
#   * `test/test_416r15_insertbits.jl` — the IRInsertBits build idiom mirrored.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known-correct value), Rule 11.

using Test
using BennettVM
import Bennett
const _BV = BennettVM
const _B = Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# ---------------------------------------------------------------------
# Dummy named callees whose `nameof` is the guard-5 callee identity.
# ---------------------------------------------------------------------
function mk_pair end        # builds a {i64,i8} aggregate via IRInsertBits
function fwd_pair end       # forwards a call token directly (no InsertBits)

# ---------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------

# Callee `mk_pair(x)`: builds a {i64,i8} = (2x, x+1) heterogeneous aggregate
# via a ZERO_AGG-rooted ascending-contiguous IRInsertBits chain and returns it
# by VALUE (ret_width = 72 = sum([64,8])). ASYMMETRIC fields so the slot ORDER
# is observable downstream (field0 = 2x, field1 = x+1).
function _mk_pair_ir()
    blk = _B.IRBasicBlock(:top,
        _B.IRInst[
            _B.IRBinOp(:f0, :mul, _B.SSAOperand(:x), _B.ConstOperand(2), 64),
            _B.IRBinOp(:f1, :add, _B.SSAOperand(:x), _B.ConstOperand(1), 64),
            _B.IRInsertBits(:agg0, _B.ZERO_AGG, _B.SSAOperand(:f0), 0, 64, 72),
            _B.IRInsertBits(:agg1, _B.SSAOperand(:agg0), _B.SSAOperand(:f1), 64, 8, 72)],
        _B.IRRet(_B.SSAOperand(:agg1), 72))
    return _B.ParsedIR(72, Tuple{Symbol,Int}[(:x, 64)], [blk], Int[64, 8])
end

# Caller `use(n)`: value-ABI call to mk_pair, read both fields, combine
# ASYMMETRICALLY (e0 + 100*e1) so slot mis-ordering changes the result.
#   use(n) = 2n + 100*(n+1) = 102n + 100.
function _use_module()
    use_blk = _B.IRBasicBlock(:top,
        _B.IRInst[
            _B.IRCall(:v, mk_pair, _B.IROperand[_B.SSAOperand(:n)], Int[64], 72),
            _B.IRExtractValue(:e0, _B.SSAOperand(:v), 0, 0, 2, Int[64, 8]),
            _B.IRExtractValue(:e1, _B.SSAOperand(:v), 1, 0, 2, Int[64, 8]),
            _B.IRBinOp(:e1s, :mul, _B.SSAOperand(:e1), _B.ConstOperand(100), 64),
            _B.IRBinOp(:s, :add, _B.SSAOperand(:e0), _B.SSAOperand(:e1s), 64)],
        _B.IRRet(_B.SSAOperand(:s), 64))
    use_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:n, 64)], [use_blk], Int[64])
    return _BV.lower_vm(Pair{Symbol,_B.ParsedIR}[:use => use_ir,
                                                 :mk_pair => _mk_pair_ir()];
                        entry = :use)
end
_use_oracle(n) = 2n + 100 * (n + 1)

# Forwarding chain: `fwd(x)` calls mk_pair value-ABI and RETURNS the token
# directly (no IRInsertBits in fwd — the token itself carries slot structure).
# `top(n)` calls fwd value-ABI, reads both fields, combines identically.
function _forward_module()
    fwd_blk = _B.IRBasicBlock(:top,
        _B.IRInst[_B.IRCall(:v, mk_pair, _B.IROperand[_B.SSAOperand(:x)], Int[64], 72)],
        _B.IRRet(_B.SSAOperand(:v), 72))
    fwd_ir = _B.ParsedIR(72, Tuple{Symbol,Int}[(:x, 64)], [fwd_blk], Int[64, 8])
    top_blk = _B.IRBasicBlock(:top,
        _B.IRInst[
            _B.IRCall(:w, fwd_pair, _B.IROperand[_B.SSAOperand(:n)], Int[64], 72),
            _B.IRExtractValue(:e0, _B.SSAOperand(:w), 0, 0, 2, Int[64, 8]),
            _B.IRExtractValue(:e1, _B.SSAOperand(:w), 1, 0, 2, Int[64, 8]),
            _B.IRBinOp(:e1s, :mul, _B.SSAOperand(:e1), _B.ConstOperand(100), 64),
            _B.IRBinOp(:s, :add, _B.SSAOperand(:e0), _B.SSAOperand(:e1s), 64)],
        _B.IRRet(_B.SSAOperand(:s), 64))
    top_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:n, 64)], [top_blk], Int[64])
    return _BV.lower_vm(Pair{Symbol,_B.ParsedIR}[:top => top_ir,
                                                 :fwd_pair => fwd_ir,
                                                 :mk_pair => _mk_pair_ir()];
                        entry = :top)
end

# Block finder helper.
_find_block(prog, lbl) = prog.blocks[findfirst(b -> b.label === lbl, prog.blocks)]

# ---------------------------------------------------------------------
# (a) runtime contract pin (already green) — a hand-built 2-value return.
# ---------------------------------------------------------------------
@testset "x3t0 (a) runtime contract pin — N-ary ReturnExit" begin
    # callee pair2(x): a := x+1, b := x+2; End returns [a, b].
    callee_blk = _BV.BasicBlock(Symbol("pair2#top"),
        _BV.BeginInstruction(:pair2, Symbol[:x]),
        _BV.Instruction[_BV.Define(:a, :x, :add, Int64(1)),
                        _BV.Define(:b, :x, :add, Int64(2))],
        _BV.EndInstruction(:pair2, Symbol[:a, :b]))
    # main(n): pair2(n) → [t0, t1]; s := t0 + 100*t1; return s.
    main_blk = _BV.BasicBlock(Symbol("main#top"),
        _BV.BeginInstruction(:main, Symbol[:n]),
        _BV.Instruction[_BV.CallEnter(:pair2, Symbol[:n], Symbol[:t0, :t1]),
                        _BV.Define(:t1s, :t1, :mul, Int64(100)),
                        _BV.Define(:s, :t0, :add, :t1s)],
        _BV.EndInstruction(:main, Symbol[:s]))
    blocks = [main_blk, callee_blk]
    fns = Dict(:main  => _BV.FunctionEntry(:main, Symbol("main#top"), Symbol[:n], Symbol[:s]),
               :pair2 => _BV.FunctionEntry(:pair2, Symbol("pair2#top"), Symbol[:x], Symbol[:a, :b]))
    prog = _BV.VMProgram(blocks, _BV.LabelTable(blocks), Symbol("main#top"),
                         Int[64], Int[64], fns, :main)
    # oracle: main(n) = (n+1) + 100*(n+2) = 101n + 201.
    oracle(n) = (n + 1) + 100 * (n + 2)
    mc = _BV.compute_must_cache(prog)
    for n in Int64[0, 1, 5, 42, -3]
        rs = _BV.initial_state(prog, Dict(:n => n))
        init = deepcopy(rs.current)
        _BV.run!(rs, prog; max_steps = 100_000, checkpoint_interval = typemax(Int),
                 must_cache_set = mc)
        @test _BV.is_halted(rs)
        @test _BV.result(rs)[:s] == oracle(n)
        _BV.unrun!(rs, prog; max_unsteps = 100_000)
        @test isempty(rs.history)
        @test length(rs.current.frames) == 1
        @test rs.current == init
    end
end

# ---------------------------------------------------------------------
# (b) ingest: InsertBits aggregate return → multi-key End.
# ---------------------------------------------------------------------
@testset "x3t0 (b) InsertBits aggregate return → multi-key End" begin
    prog = _use_module()
    # Callee `mk_pair` End.returns is the 2-slot family of its terminal agg (:agg1).
    mk_blk = _find_block(prog, Symbol("mk_pair#top"))
    @test mk_blk.exit isa _BV.EndInstruction
    @test mk_blk.exit.returns ==
          Symbol[_BV._agg_slot_name(:agg1, 0), _BV._agg_slot_name(:agg1, 1)]
    # Caller CallEnter.targets is the 2-slot family of the call dest (:v).
    use_blk = _find_block(prog, Symbol("use#top"))
    ce = use_blk.instructions[findfirst(i -> i isa _BV.CallEnter, use_blk.instructions)]
    @test ce.targets == Symbol[_BV._agg_slot_name(:v, 0), _BV._agg_slot_name(:v, 1)]

    mc = _BV.compute_must_cache(prog)
    for n in Int64[0, 1, 5, 42, -3]
        rs = _BV.initial_state(prog, Dict(:n => n))
        init = deepcopy(rs.current)
        _BV.run!(rs, prog; max_steps = 100_000, checkpoint_interval = typemax(Int),
                 must_cache_set = mc)
        @test _BV.is_halted(rs)
        @test _BV.result(rs)[:s] == _use_oracle(n)   # golden master (pins slot ORDER)
        _BV.unrun!(rs, prog; max_unsteps = 100_000)
        @test isempty(rs.history)
        @test length(rs.current.frames) == 1
        @test rs.current == init
    end
end

# ---------------------------------------------------------------------
# (c) call-forwarded token (the __v207 shape).
# ---------------------------------------------------------------------
@testset "x3t0 (c) call-forwarded token returns slot family" begin
    prog = _forward_module()
    # `fwd_pair` returns the call dest (:v) directly — its End is :v's slot family
    # even though fwd_pair has NO IRInsertBits (the token carries slot structure).
    fwd_blk = _find_block(prog, Symbol("fwd_pair#top"))
    @test fwd_blk.exit isa _BV.EndInstruction
    @test fwd_blk.exit.returns ==
          Symbol[_BV._agg_slot_name(:v, 0), _BV._agg_slot_name(:v, 1)]

    mc = _BV.compute_must_cache(prog)
    for n in Int64[0, 1, 5, 42, -3]
        rs = _BV.initial_state(prog, Dict(:n => n))
        init = deepcopy(rs.current)
        _BV.run!(rs, prog; max_steps = 100_000, checkpoint_interval = typemax(Int),
                 must_cache_set = mc)
        @test _BV.is_halted(rs)
        @test _BV.result(rs)[:s] == _use_oracle(n)   # 3 frames deep: top→fwd→mk
        _BV.unrun!(rs, prog; max_unsteps = 100_000)
        @test isempty(rs.history)
        @test length(rs.current.frames) == 1
        @test rs.current == init
    end
end

# ---------------------------------------------------------------------
# (d) sret-ABI guard-5 defense-in-depth (bennettvm-416r.16).
# ---------------------------------------------------------------------
@testset "x3t0 (d) sret-ABI guard-5 defense-in-depth" begin
    # Caller `bad(n)` calls mk_pair with ret_width = 64 ≠ 72 = sum([64,8]) — the
    # sret_box MEMORY ABI (explicit result-buffer arg). Post-416r.16 the front-end
    # rewrites REAL consumed sret-out box calls to the value ABI (ret_width ==
    # sum) at extraction; this hand-built box-ABI call never gets that treatment,
    # so guard-5 still fails loud on it — now as DEFENSE-IN-DEPTH (an unreconciled
    # box-ABI call leaking to ingest is a front-end bug).
    bad_blk = _B.IRBasicBlock(:top,
        _B.IRInst[_B.IRCall(:v, mk_pair, _B.IROperand[_B.SSAOperand(:n)], Int[64], 64)],
        _B.IRRet(_B.SSAOperand(:v), 64))
    bad_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:n, 64)], [bad_blk], Int[64])
    threw = false; msg = ""
    try
        _BV.lower_vm(Pair{Symbol,_B.ParsedIR}[:bad => bad_ir, :mk_pair => _mk_pair_ir()];
                     entry = :bad)
    catch e
        threw = true; msg = sprint(showerror, e)
    end
    @test threw
    @test occursin("sret_box", msg)
    @test occursin("416r.16", msg)                        # the reconciliation bead
    @test occursin("did not fire", msg)                   # defense-in-depth wording
    @test !occursin("returns aggregate SSA value", msg)   # NOT the acq wall
end

# ---------------------------------------------------------------------
# (e) fail-loud matrix.
# ---------------------------------------------------------------------
@testset "x3t0 (e) fail-loud matrix" begin
    # (e1) aggregate IRRet with ret_elem_widths length 1 → error (a decomposed
    # aggregate name in a NON-multi function cannot dangle into a scalar End).
    agg1_blk = _B.IRBasicBlock(:top,
        _B.IRInst[_B.IRInsertBits(:agg, _B.ZERO_AGG, _B.SSAOperand(:x), 0, 64, 64)],
        _B.IRRet(_B.SSAOperand(:agg), 64))
    agg1_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:x, 64)], [agg1_blk], Int[64])
    threw1 = false; msg1 = ""
    try
        _BV.lower_vm(agg1_ir)
    catch e
        threw1 = true; msg1 = sprint(showerror, e)
    end
    @test threw1
    @test occursin("NON-multi function", msg1)

    # (e2) multi-return FunctionEntry with EMPTY ret_elem_widths reaching guard-5
    # → internal-invariant error (a `returns` arity > 1 must carry per-element
    # widths). Driven directly through `_lower_body_inst`.
    fns = Dict(:callee => _BV.FunctionEntry(:callee, Symbol("callee#top"),
                                            Symbol[:x], Symbol[:r0, :r1]))  # empty ret_elem_widths
    ircall = _B.IRCall(:d, :callee, _B.IROperand[_B.SSAOperand(:a)], Int[64], 72)
    @test_throws ErrorException _BV._lower_body_inst(ircall, fns)

    # (e3) entry-function multi-return → error (both the single-function and the
    # multi-function entry paths reject a > 1-element by-value entry return).
    threw3s = false; msg3s = ""
    try
        _BV.lower_vm(_mk_pair_ir())   # single-function entry, ret_elem_widths=[64,8]
    catch e
        threw3s = true; msg3s = sprint(showerror, e)
    end
    @test threw3s
    @test occursin("entry", msg3s) && occursin("multi-return", msg3s)

    threw3m = false; msg3m = ""
    try
        _BV.lower_vm(Pair{Symbol,_B.ParsedIR}[:mk_pair => _mk_pair_ir()]; entry = :mk_pair)
    catch e
        threw3m = true; msg3m = sprint(showerror, e)
    end
    @test threw3m
    @test occursin("entry", msg3m) && occursin("multi-return", msg3m)
end

# ---------------------------------------------------------------------
# (f) the REAL fdict set LOWERS to a VMProgram (static-wall chain DONE); the
#     first RUNTIME wall is jl_global const-global materialization.
# ---------------------------------------------------------------------
@testset "x3t0 (f) real fdict set lowers; runtime wall is jl_global" begin
    fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])
    set = _B.extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                                              ptr_cells = true)
    # bead bennettvm-416r.16 (2026-07-11): the caller-side consumed-sret
    # reconciliation cleared the LAST static wall. setindex!'s ht_keyindex2
    # consumed sret-out box call is rewritten to the VALUE ABI (ret_width 72 ==
    # sum([64,8]); box loads → IRExtractValue) at extraction, so guard-5 lands its
    # slot family and lower_vm COMPLETES. The CW-D static-wall chain is DONE.
    prog = _BV.lower_vm(set; entry = first(set).first)
    @test prog isa _BV.VMProgram
    @test haskey(prog.functions, :ht_keyindex2_shorthash!)
    @test length(prog.functions[:ht_keyindex2_shorthash!].returns) == 2

    # The first RUNTIME wall is jl_global const-global materialization (successor
    # beads bennettvm-416r.13 / 416r.4) — a KeyError in Define.forward. Reached
    # quickly and deterministically (verified 2026-07-11: `KeyError: jl_global#…`).
    # Pins the successor bead's starting point.
    entry_pir = first(set).second
    inputs = Dict(n => Int64(v) for ((n, _w), v) in
                  zip(entry_pir.args, (Int64(3), Int64(7))))
    rthrew = false; rmsg = ""
    try
        rs = _BV.initial_state(prog, inputs)
        _BV.run!(rs, prog; max_steps = 500_000)
    catch e
        rthrew = true; rmsg = sprint(showerror, e)
    end
    @test rthrew
    @test occursin("jl_global", rmsg)
end
