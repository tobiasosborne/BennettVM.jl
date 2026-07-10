# test/test_416r15_insertbits.jl — ingest of `IRInsertBits` for heterogeneous
# `{i64, i8}`-style bits-struct sret packing (bead `bennettvm-416r.15`,
# Bennett-dv1z; a 416r.14 follow-up on the closed-world fdict set).
#
# # What this file pins
#
# Bennett.jl's sret path (`_synthesize_sret_bits`,
# `../Bennett.jl/src/extract/sret.jl:947`) packs a heterogeneous bits-struct
# return value (`ht_keyindex2_shorthash!`'s `{i64, i8}` = `(hash, slot)`) as a
# ZERO_AGG-rooted, ASCENDING-CONTIGUOUS `IRInsertBits` chain: field `k` at bit
# offset `sum(widths[0:k-1])`, `total_width == sum(field widths)` (NOT the padded
# ABI size). The terminal dest flows into `IRRet(dest, total_width)` with
# `ret_elem_widths` in field order. There is NO `IRExtractBits` — unpacking
# happens at the return ABI via `ret_elem_widths`, not an instruction.
#
# Because each field lives in its OWN Int64 cell, the aggregate is modelled with
# the SAME per-field slot family the acq bead built for IRInsertValue
# (`_agg_slot_name(dest, k)`), reusing the scalar `Define`-copy machinery. The
# `total_width > 64` crux (72 here) DISSOLVES: the packed value is never
# materialised — only the per-field scalars are. The dense field index `k` comes
# from FOLLOWING THE CHAIN (ZERO_AGG-rooted ⇒ k=0; SSAOperand naming a prior
# IRInsertBits dest ⇒ k = prior k + 1), and the contiguity of the synthesised
# chain is asserted fail-loud (Rule 1) — a non-contiguous or non-bit-0-rooted
# chain is an unmodelled shape `_synthesize_sret_bits` never emits.
#
# The slot family interoperates with the EXISTING IRExtractValue arm (both key
# off `_agg_slot_name` + the `agg_dests` registry), so a build-via-IRInsertBits /
# read-via-IRExtractValue round-trip runs and reverses.
#
# # The successor wall (Rule 1 — the real set advances, does not pass)
#
# This bead makes the closed fdict set clear the IRInsertBits body-lowering wall.
# It then dies at the PRE-EXISTING aggregate-RETURN reject (bead `bennettvm-acq`;
# the multi-key return keyed off `ret_elem_widths` is the follow-on, bead
# `bennettvm-x3t0`): the terminal IRInsertBits dest dangles into a single-symbol
# `EndInstruction.returns`. Returns are OUT OF SCOPE here — pinned advancing.
#
# # Ref
#   * `../Bennett.jl/src/ir_types.jl:180-196` — the IRInsertBits struct (field
#     order, ctor invariants; read-only, Rule 14).
#   * `../Bennett.jl/src/extract/sret.jl:933-965` — `_synthesize_sret_bits`, the
#     ascending-contiguous ZERO_AGG-rooted chain this arm decomposes (Law 1).
#   * `src/ir/ingest.jl` — the IRInsertBits body arm (chain-follower slot
#     decomposition), beside the IRInsertValue/IRExtractValue arms.
#   * `test/test_aggregate_extract_insert.jl` — the acq IRInsertValue slot-family
#     round-trip + fail-loud idiom mirrored here.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known-correct value), Rule 11.

using Test
using BennettVM
import Bennett

# Build the `{i64, i8}` bits-struct via an IRInsertBits chain, read both fields
# back via the EXISTING IRExtractValue arm, and add them. Scalar return.
#   a = insertbits ZERO_AGG, %x, off=0,  vw=64, tw=72   ; field 0 (i64) := %x
#   b = insertbits a,        %y, off=64, vw=8,  tw=72   ; field 1 (i8)  := %y
#   e0 = extractvalue b, 0                              ; e0 := %x
#   e1 = extractvalue b, 1                              ; e1 := %y
#   r  = add e0, e1                                     ; r  := %x + %y
#   ret r
function _bits_scalar_block()
    return Bennett.IRBasicBlock(
        :entry,
        Bennett.IRInst[
            Bennett.IRInsertBits(:a, Bennett.ZERO_AGG,
                                 Bennett.SSAOperand(:x), 0, 64, 72),
            Bennett.IRInsertBits(:b, Bennett.SSAOperand(:a),
                                 Bennett.SSAOperand(:y), 64, 8, 72),
            Bennett.IRExtractValue(:e0, Bennett.SSAOperand(:b), 0, 64, 2),
            Bennett.IRExtractValue(:e1, Bennett.SSAOperand(:b), 1, 8, 2),
            Bennett.IRBinOp(:r, :add, Bennett.SSAOperand(:e0),
                            Bennett.SSAOperand(:e1), 64),
        ],
        Bennett.IRRet(Bennett.SSAOperand(:r), 64),
    )
end
_bits_oracle(x, y) = x + y

# {i8, i8} tw=16 (≤64 total_width) — the SAME slot family, no >64 special case.
#   a = insertbits ZERO_AGG, %x, off=0, vw=8, tw=16
#   b = insertbits a,        %y, off=8, vw=8, tw=16
#   e0/e1 extract; r = e0 + e1.
function _bits_narrow_block()
    return Bennett.IRBasicBlock(
        :entry,
        Bennett.IRInst[
            Bennett.IRInsertBits(:a, Bennett.ZERO_AGG,
                                 Bennett.SSAOperand(:x), 0, 8, 16),
            Bennett.IRInsertBits(:b, Bennett.SSAOperand(:a),
                                 Bennett.SSAOperand(:y), 8, 8, 16),
            Bennett.IRExtractValue(:e0, Bennett.SSAOperand(:b), 0, 8, 2),
            Bennett.IRExtractValue(:e1, Bennett.SSAOperand(:b), 1, 8, 2),
            Bennett.IRBinOp(:r, :add, Bennett.SSAOperand(:e0),
                            Bennett.SSAOperand(:e1), 64),
        ],
        Bennett.IRRet(Bennett.SSAOperand(:r), 64),
    )
end

# Lower a single-block bits routine and return the raised error (or `nothing`).
function _lower_bits_err(insts;
                         ret = Bennett.IRRet(Bennett.SSAOperand(:x), 64),
                         args = [(:x, 64), (:y, 8)])
    blk = Bennett.IRBasicBlock(:entry, Bennett.IRInst[insts...], ret)
    parsed = Bennett.ParsedIR(64, args, [blk], [64])
    try
        lower_vm(parsed; opts = :bits_fail)
        nothing
    catch ex
        ex
    end
end

@testset "IRInsertBits bits-struct sret ingest (bead bennettvm-416r.15)" begin

    # ------------------------------------------------------------------
    # (a) slot family via IRExtractValue round-trip: {i64,i8} tw=72.
    #     Build via IRInsertBits, read via the EXISTING IRExtractValue arm
    #     (proves the slot families interoperate), add, forward == oracle,
    #     round-trip to empty history (P0.6).
    # ------------------------------------------------------------------
    @testset "slot family via IRExtractValue round-trip ({i64,i8} tw=72)" begin
        parsed = Bennett.ParsedIR(64, [(:x, 64), (:y, 8)],
                                  [_bits_scalar_block()], [64])
        vm = lower_vm(parsed; opts = :bits_scalar)
        @test vm isa VMProgram

        for (x, y) in ((Int64(0), Int64(0)), (Int64(5), Int64(3)),
                       (Int64(100), Int64(27)), (Int64(-4), Int64(9)))
            rs = initial_state(vm, Dict(:x => x, :y => y))
            run!(rs, vm; checkpoint_interval = 4)
            @test is_halted(rs)
            @test result(rs)[:r] == _bits_oracle(x, y)   # golden master

            unrun!(rs, vm)
            @test rs.current == rs.initial               # P0.6 — reversed
            @test isempty(rs.history)                    # P0.6 — history drained
            @test rs.step_count == 0                     # P0.6 — counter reset
        end
    end

    # ------------------------------------------------------------------
    # (b) contiguity guards fail loud (Rule 1). Each would otherwise model
    #     an unmodelled bits-struct shape `_synthesize_sret_bits` never emits.
    # ------------------------------------------------------------------
    @testset "contiguity guards fail loud (Rule 1)" begin
        # (b1) ZERO_AGG-rooted insert with bit_offset != 0.
        e = _lower_bits_err([Bennett.IRInsertBits(:a, Bennett.ZERO_AGG,
                                Bennett.SSAOperand(:x), 4, 64, 72)])
        @test e isa ErrorException
        @test occursin("must start at bit 0", e.msg)

        # (b2) a chain with a GAP: field 0 ends at bit 64, next inserts at 72.
        e = _lower_bits_err([
            Bennett.IRInsertBits(:a, Bennett.ZERO_AGG,
                Bennett.SSAOperand(:x), 0, 64, 80),
            Bennett.IRInsertBits(:b, Bennett.SSAOperand(:a),
                Bennett.SSAOperand(:y), 72, 8, 80),
        ])
        @test e isa ErrorException
        @test occursin("not contiguous", e.msg)

        # (b3) agg is an SSAOperand that is NOT a prior IRInsertBits dest.
        e = _lower_bits_err([Bennett.IRInsertBits(:b, Bennett.SSAOperand(:x),
                                Bennett.SSAOperand(:y), 0, 8, 8)])
        @test e isa ErrorException
        @test occursin("unmodelled bits-struct shape", e.msg)
    end

    # ------------------------------------------------------------------
    # (c) ≤64 total_width decomposes uniformly — {i8,i8} tw=16, no special
    #     case. Same slot family; extract + verify as in (a).
    # ------------------------------------------------------------------
    @testset "≤64 total_width decomposes uniformly ({i8,i8} tw=16)" begin
        parsed = Bennett.ParsedIR(64, [(:x, 64), (:y, 8)],
                                  [_bits_narrow_block()], [64])
        vm = lower_vm(parsed; opts = :bits_narrow)
        for (x, y) in ((Int64(0), Int64(0)), (Int64(3), Int64(5)),
                       (Int64(40), Int64(2)))
            rs = initial_state(vm, Dict(:x => x, :y => y))
            run!(rs, vm; checkpoint_interval = 4)
            @test is_halted(rs)
            @test result(rs)[:r] == _bits_oracle(x, y)

            unrun!(rs, vm)
            @test rs.current == rs.initial
            @test isempty(rs.history)
            @test rs.step_count == 0
        end
    end

    # ------------------------------------------------------------------
    # (d) mutation-proof spot check — assert the EXACT slot assignment (the
    #     k-derivation): field 0 of :b copies from field 0 of :a; field 1 of
    #     :b receives :y. A swapped-k bug would flip these (and (a)'s oracle
    #     would also catch it — this pins it STRUCTURALLY).
    # ------------------------------------------------------------------
    @testset "exact slot assignment (chain-follower field order)" begin
        parsed = Bennett.ParsedIR(64, [(:x, 64), (:y, 8)],
                                  [_bits_scalar_block()], [64])
        vm = lower_vm(parsed; opts = :bits_spot)
        body = first(vm.blocks).instructions
        defs = Dict{Symbol,BennettVM.Define}()
        for i in body
            i isa BennettVM.Define && (defs[i.target] = i)
        end
        a0 = BennettVM._agg_slot_name(:a, 0)
        b0 = BennettVM._agg_slot_name(:b, 0)
        b1 = BennettVM._agg_slot_name(:b, 1)
        # field 0 of :a is the inserted :x.
        @test haskey(defs, a0) && defs[a0].lhs === :x
        # field 0 of :b is inherited (copied) from field 0 of :a.
        @test haskey(defs, b0) && defs[b0].lhs === a0
        # field 1 of :b is the inserted :y (NOT :x — pins field order).
        @test haskey(defs, b1) && defs[b1].lhs === :y
    end

    # ------------------------------------------------------------------
    # (e) the REAL fdict set advances past the IRInsertBits wall to the
    #     PRE-EXISTING aggregate-RETURN reject (bead `bennettvm-x3t0`). ~2 min
    #     (full closed-world extraction). Returns are out of scope here.
    # ------------------------------------------------------------------
    @testset "real fdict set advances to the aggregate-return wall" begin
        fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])
        set = Bennett.extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                                                       ptr_cells = true)
        threw = false
        msg = ""
        try
            lower_vm(set; entry = first(set).first)
        catch e
            threw = true
            msg = sprint(showerror, e)
        end
        @test threw                                       # still throws (next wall)
        @test !occursin("IRInsertBits", msg)              # IRInsertBits wall CLEARED
        @test occursin("returns aggregate SSA value", msg)  # the aggregate-return wall
    end
end
