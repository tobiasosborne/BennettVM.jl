# test/test_6bu3_struct_agg_ingest.jl — ingest of StructType `IRInsertValue` /
# `IRExtractValue` (Bennett-6bu3; the `{ptr,ptr}` GenericMemoryRef-body shape
# and fixed-width-integer tuples) into the per-slot `Define` family.
#
# # What this file pins
#
# Bennett-6bu3 extends Bennett.jl's IRInsertValue/IRExtractValue with an
# ADDITIVE `field_widths::Vector{Int}` so a StructType aggregate (per-field bit
# layout) lowers in addition to the original homogeneous ArrayType `[N x iW]`
# case (bead `bennettvm-acq`). The discriminator is `isempty(field_widths)`:
# empty ⇒ homogeneous (`elem_width`/`n_elems`); non-empty ⇒ StructType
# (`n_elems == length(field_widths)`, `elem_width == 0` sentinel).
#
# BennettVM's ingest (`src/ir/ingest.jl` insertvalue/extractvalue arms) is
# INDEX-KEYED and WIDTH-AGNOSTIC: the slot loop is `for j in 0:(n_elems-1)` and
# never reads `elem_width`/`field_widths`. Because 6bu3 keeps `n_elems ==
# length(field_widths)`, the existing slot loop + bounds guards handle the
# `{ptr,ptr}` struct UNCHANGED — this test proves it (no BVM code change beyond
# stale-comment edits).
#
# # The hand-built program (golden master; Rule 4 — assert vs a known value)
#
# Build a `{ptr, ptr}` (field_widths [64,64]) aggregate from two cell-sized
# scalars `%data` / `%mem`, read field 0 back, and return it:
#
#   a0 = insertvalue ZERO_AGG, %data, 0      ; {%data, 0}
#   a1 = insertvalue a0,       %mem,  1      ; {%data, %mem}
#   d  = extractvalue a1, 0                  ; d := %data
#   ret d
#
# Oracle (irreversible Julia reference): `f(data, mem) = data`. Forward must
# match bit-for-bit; then the program round-trips to EMPTY history (P0.6 — the
# load-bearing invariant), and `per_step_inverse_check` catches a middle-step
# inverse bug the aggregate round-trip alone can mask.
#
# # Ref
#   * `../Bennett.jl/src/ir_types.jl` (IRInsertValue/IRExtractValue + the
#     `field_widths` discriminator) — read-only; Rule 14.
#   * `src/ir/ingest.jl` — `_agg_slot_name`, the body-loop insertvalue special-
#     case, the extractvalue arm (width-agnostic).
#   * `test/test_aggregate_extract_insert.jl` — the homogeneous-ArrayType analogue
#     this file mirrors.
#   * `test/test_per_step_inverse.jl` — the `per_step_inverse_check` scaffold.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known-correct value), Rule 11.

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# Build {ptr,ptr} = {%data, %mem}, read field 0, return it. field_widths=[64,64]
# (the ptr-cell width), n_elems=2, elem_width=0 (the StructType sentinel).
function _struct_agg_blocks()
    FW = [64, 64]
    return Bennett.IRBasicBlock(
        :entry,
        Bennett.IRInst[
            # a0 = insertvalue ZERO_AGG, %data, 0   →  {%data, 0}
            Bennett.IRInsertValue(:a0, Bennett.ZERO_AGG,
                                  Bennett.SSAOperand(:data), 0, 0, 2, FW),
            # a1 = insertvalue a0, %mem, 1           →  {%data, %mem}
            Bennett.IRInsertValue(:a1, Bennett.SSAOperand(:a0),
                                  Bennett.SSAOperand(:mem), 1, 0, 2, FW),
            # d = extractvalue a1, 0                 →  %data
            Bennett.IRExtractValue(:d, Bennett.SSAOperand(:a1), 0, 0, 2, FW),
        ],
        Bennett.IRRet(Bennett.SSAOperand(:d), 64),
    )
end

# Irreversible golden-master oracle (Rule 4 / P0.5): field 0 round-trips.
_struct_agg_oracle(data, mem) = data

@testset "StructType aggregate extract/insert ingest (Bennett-6bu3; {ptr,ptr})" begin

    # ------------------------------------------------------------------
    # (1) End-to-end: lower → forward == oracle → round-trip to empty.
    # ------------------------------------------------------------------
    @testset "{ptr,ptr} build/read lowers, runs, round-trips (L3)" begin
        parsed = Bennett.ParsedIR(64, [(:data, 64), (:mem, 64)],
                                  [_struct_agg_blocks()], [64])
        vm = lower_vm(parsed; opts = :struct_agg)
        @test vm isa VMProgram

        # Cell-sized inputs (each field is one Int64 VM cell).
        for (data, mem) in ((Int64(0), Int64(0)),
                            (Int64(5), Int64(99)),
                            (Int64(123456789), Int64(-7)),
                            (Int64(-1), Int64(42)))
            rs = initial_state(vm, Dict(:data => data, :mem => mem))
            run!(rs, vm; checkpoint_interval = 4)
            @test is_halted(rs)
            @test result(rs)[:d] == _struct_agg_oracle(data, mem)  # golden master

            unrun!(rs, vm)
            @test rs.current == rs.initial    # P0.6 — reversed to start
            @test isempty(rs.history)         # P0.6 — history drained
            @test rs.step_count == 0          # P0.6 — counter reset
        end
    end

    # ------------------------------------------------------------------
    # (2) Per-step inverse (L3) at two checkpoint densities — catches a
    #     mid-program (insert/extract) reversal bug the aggregate round-
    #     trip can mask.
    # ------------------------------------------------------------------
    @testset "per-step inverse (L3) — K ∈ {1, 4}" begin
        parsed = Bennett.ParsedIR(64, [(:data, 64), (:mem, 64)],
                                  [_struct_agg_blocks()], [64])
        vm = lower_vm(parsed; opts = :struct_agg)
        for K in (1, 4)
            @test per_step_inverse_check(
                vm, Dict(:data => Int64(5), :mem => Int64(99));
                checkpoint_interval = K,
                label = "struct_agg/K=$K") === nothing
        end
    end

    # ------------------------------------------------------------------
    # (3) The slot family is materialised as synthetic per-slot Defines —
    #     proves the index-keyed slot loop ran over the StructType
    #     aggregate exactly as for ArrayType (n_elems == length(field_widths)).
    # ------------------------------------------------------------------
    @testset "insertvalue lowers to N slot Defines; extractvalue to one" begin
        parsed = Bennett.ParsedIR(64, [(:data, 64), (:mem, 64)],
                                  [_struct_agg_blocks()], [64])
        vm = lower_vm(parsed; opts = :struct_agg)
        body = first(vm.blocks).instructions
        targets = Symbol[i.target for i in body if i isa BennettVM.Define]
        # a0 slots: _agg_a0_slot0, _agg_a0_slot1; a1 slots likewise; d copy.
        @test BennettVM._agg_slot_name(:a0, 0) in targets
        @test BennettVM._agg_slot_name(:a0, 1) in targets
        @test BennettVM._agg_slot_name(:a1, 0) in targets
        @test BennettVM._agg_slot_name(:a1, 1) in targets
        @test :d in targets        # extractvalue dest is a plain scalar
    end
end
