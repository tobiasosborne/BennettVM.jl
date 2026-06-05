# test/test_aggregate_extract_insert.jl — ingest of `IRExtractValue` /
# `IRInsertValue` for homogeneous ArrayType aggregates (bead `bennettvm-acq`,
# OPCODE G2; epic `bennettvm-x49`; PRD v4 §3.6.1 maximum-opcode-coverage).
#
# # What this file pins
#
# Bennett.jl emits `IRExtractValue` / `IRInsertValue` ONLY for homogeneous
# scalar-element ArrayType aggregates (`[N x iW]`); StructType aggregates fail
# loud UPSTREAM in extract, so they never reach BennettVM (deferred to the
# Bennett.jl BG4 fill, U10 / Bennett-tu6i — see
# `../Bennett.jl/src/extract/instructions.jl:1948-1978`). This bead lowers the
# ArrayType case.
#
# An aggregate SSA value `agg` has N scalar elements but `IState.locals` is a
# FLAT `Dict{Symbol,Int64}` — one key cannot hold N elements. So an aggregate
# is modelled as a FAMILY of N synthetic per-slot keys, one per element
# (`_agg_slot_name(agg, k) = :_agg_<agg>_slotk`), reusing the scalar `Define`
# copy machinery so the IState type, its equality/hash, and the L3 checkpoint-
# replay reversal all carry over UNCHANGED (no new instruction, no new state).
#
#   * `IRExtractValue(dest, agg, index, …)` → ONE `Define(dest := agg.slot<index>)`
#     (a non-destructive copy — `Define(dest, slot, :add, 0)`).
#   * `IRInsertValue(dest, agg, val, index, …)` → N `Define`s rebuilding the
#     aggregate family: slot `index` gets the inserted `val`, every other slot
#     j is copied from `agg`'s slot j (or zero-initialised, when `agg` is the
#     `ZERO_AGG` sentinel = an all-zero `[N x iW]` zeroinitializer base).
#
# Because `insertvalue` emits N `Define`s it does NOT fit the single-instruction
# `_lower_body_inst` contract (one `IRInst` → one `Instruction`); it is special-
# cased in the body loop, mirroring the `IRAlloca` branch.
#
# # The hand-built program (golden master; Rule 4 — assert vs a known value)
#
# Build a `[2 x i32]` aggregate, read both elements back, and add them:
#
#   a0 = insertvalue ZERO_AGG, %x, 0     ; [%x, 0]
#   a1 = insertvalue a0,       7,  1     ; [%x, 7]
#   e0 = extractvalue a1, 0              ; e0 := %x
#   e1 = extractvalue a1, 1              ; e1 := 7
#   r  = add e0, e1                      ; r  := %x + 7
#   ret r
#
# Oracle (irreversible Julia reference): `f(x) = x + 7`. With `:__x => 5`,
# `result(rs)[:r] == 12`. Forward must match the oracle bit-for-bit; then the
# program round-trips to empty history (P0.6 — the load-bearing invariant), and
# `per_step_inverse_check` (test_per_step_inverse.jl) catches a middle-step
# inverse bug the aggregate round-trip alone can mask.
#
# # The still-deferred adversarial gate (Rule 1 — fail loud)
#
# This bead scopes scalar-CONSUMED extract/insert: every aggregate is fully
# decomposed into scalar slots before the routine returns. An aggregate that
# DANGLES into the `IRRet` (a returned `[N x iW]` aggregate) is the multi-key-
# return follow-on (keyed off `ret_elem_widths`) and is NOT in scope — the
# decomposed slot family would silently drop into a single-symbol
# `EndInstruction.returns`. The IRRet guard rejects it loud (deferred-message),
# pinned below by `@test_throws`.
#
# # Ref
#   * `../Bennett.jl/src/ir_types.jl:115-122` (IRInsertValue),
#     `:273-279` (IRExtractValue) — struct field order (read-only; Rule 14).
#   * `../Bennett.jl/src/extract/instructions.jl:1948-1978` — the ArrayType-only
#     emission + the StructType upstream fail-loud.
#   * `../Bennett.jl/src/ir_types.jl:36,49` — the `ZeroAggSentinel` / `ZERO_AGG`.
#   * `src/ir/ingest.jl` — `_agg_slot_name`, the body-loop insertvalue special-
#     case, the extractvalue arm, and the aggregate-IRRet guard.
#   * `test/test_array_floor.jl` — the hand-built ParsedIR + round-trip idiom
#     reused here.
#   * `test/test_per_step_inverse.jl` — the `per_step_inverse_check` scaffold.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known-correct value), Rule 11.

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# The in-scope chain: build [2 x i32] = [%x, 7], read both, add. Scalar return.
function _agg_scalar_blocks()
    return Bennett.IRBasicBlock(
        :entry,
        Bennett.IRInst[
            # a0 = insertvalue ZERO_AGG, %x, 0   →  [%x, 0]
            Bennett.IRInsertValue(:a0, Bennett.ZERO_AGG,
                                  Bennett.SSAOperand(:__x), 0, 32, 2),
            # a1 = insertvalue a0, 7, 1          →  [%x, 7]
            Bennett.IRInsertValue(:a1, Bennett.SSAOperand(:a0),
                                  Bennett.ConstOperand(7), 1, 32, 2),
            # e0 = extractvalue a1, 0            →  %x
            Bennett.IRExtractValue(:e0, Bennett.SSAOperand(:a1), 0, 32, 2),
            # e1 = extractvalue a1, 1            →  7
            Bennett.IRExtractValue(:e1, Bennett.SSAOperand(:a1), 1, 32, 2),
            # r = add e0, e1                     →  %x + 7
            Bennett.IRBinOp(:r, :add, Bennett.SSAOperand(:e0),
                            Bennett.SSAOperand(:e1), 32),
        ],
        Bennett.IRRet(Bennett.SSAOperand(:r), 32),
    )
end

# Irreversible golden-master oracle (Rule 4 / P0.5).
_agg_oracle(x) = x + 7

@testset "aggregate extract/insert ingest (ArrayType; bead bennettvm-acq)" begin

    # ------------------------------------------------------------------
    # (1) End-to-end: lower → forward == oracle → round-trip to empty.
    # ------------------------------------------------------------------
    @testset "[2 x i32] build/read/add lowers, runs, round-trips (L3)" begin
        parsed = Bennett.ParsedIR(32, [(:__x, 32)], [_agg_scalar_blocks()], [32])
        vm = lower_vm(parsed; opts=:agg_scalar)
        @test vm isa VMProgram

        for x in (Int64(0), Int64(5), Int64(-3), Int64(100))
            rs = initial_state(vm, Dict(:__x => x))
            run!(rs, vm; checkpoint_interval = 4)
            @test is_halted(rs)
            @test result(rs)[:r] == _agg_oracle(x)      # golden master, bit-exact

            unrun!(rs, vm)
            @test rs.current == rs.initial               # P0.6 — reversed to start
            @test isempty(rs.history)                    # P0.6 — history drained
            @test rs.step_count == 0                     # P0.6 — counter reset
        end
    end

    # ------------------------------------------------------------------
    # (2) Per-step inverse (L3) at two checkpoint densities — catches a
    #     mid-program (insert/extract) reversal bug the aggregate round-
    #     trip can mask (the leading insert's inverse masks corruption).
    # ------------------------------------------------------------------
    @testset "per-step inverse (L3) — K ∈ {1, 4}" begin
        parsed = Bennett.ParsedIR(32, [(:__x, 32)], [_agg_scalar_blocks()], [32])
        vm = lower_vm(parsed; opts=:agg_scalar)
        for K in (1, 4)
            @test per_step_inverse_check(
                vm, Dict(:__x => Int64(5));
                checkpoint_interval = K,
                label = "agg_scalar/K=$K") === nothing
        end
    end

    # ------------------------------------------------------------------
    # (3) The slot family is materialised as synthetic per-slot Defines.
    #     a0/a1 each spawn 2 slot keys; e0/e1 copy from a1's slots. Pin
    #     that the lowered body holds those copies (the multi-slot model).
    # ------------------------------------------------------------------
    @testset "insertvalue lowers to N slot Defines; extractvalue to one" begin
        parsed = Bennett.ParsedIR(32, [(:__x, 32)], [_agg_scalar_blocks()], [32])
        vm = lower_vm(parsed; opts=:agg_scalar)
        body = first(vm.blocks).instructions
        targets = Symbol[i.target for i in body if i isa BennettVM.Define]
        # a0 slots: _agg_a0_slot0, _agg_a0_slot1; a1 slots likewise; e0/e1.
        @test BennettVM._agg_slot_name(:a0, 0) in targets
        @test BennettVM._agg_slot_name(:a0, 1) in targets
        @test BennettVM._agg_slot_name(:a1, 0) in targets
        @test BennettVM._agg_slot_name(:a1, 1) in targets
        @test :e0 in targets        # extractvalue dest is a plain scalar
        @test :e1 in targets
    end

    # ------------------------------------------------------------------
    # (4) DEFERRED — an aggregate dangling into IRRet fails loud (Rule 1).
    #     The multi-key return (EndInstruction.returns = [name_slot0…],
    #     keyed off ret_elem_widths) is the follow-on bead; do NOT let a
    #     decomposed aggregate name dangle into a single-symbol End.
    # ------------------------------------------------------------------
    @testset "DEFERRED aggregate IRRet → raises naming the deferral" begin
        # Same build-up but RETURN the aggregate a1 (a [2 x i32]) directly.
        ret_agg_block = Bennett.IRBasicBlock(
            :entry,
            Bennett.IRInst[
                Bennett.IRInsertValue(:a0, Bennett.ZERO_AGG,
                                      Bennett.SSAOperand(:__x), 0, 32, 2),
                Bennett.IRInsertValue(:a1, Bennett.SSAOperand(:a0),
                                      Bennett.ConstOperand(7), 1, 32, 2),
            ],
            Bennett.IRRet(Bennett.SSAOperand(:a1), 64),
        )
        parsed = Bennett.ParsedIR(64, [(:__x, 32)], [ret_agg_block], [32, 32])
        e = try
            lower_vm(parsed; opts=:agg_ret)
            nothing
        catch ex
            ex
        end
        @test e isa ErrorException
        @test occursin("aggregate", e.msg)
        @test occursin("DEFERRED", e.msg)        # the deferral verb (Rule 4)
        @test occursin("bennettvm-acq", e.msg)   # names the bead
    end

    # ------------------------------------------------------------------
    # (5) FAIL-LOUD completeness (Rule 1 + Rule 2 — every new fail-loud
    #     path is PROVEN, "runs without errors is not a passing test").
    #     Each of these would, WITHOUT the lower-time guard, either
    #     SILENTLY MISCOMPILE (drop the inserted value / emit zero
    #     Defines) or hit a contextless runtime KeyError. Assert each now
    #     raises a NAMED ErrorException at lower-time, citing the bead and
    #     the offending token. (Verified to fail RED with the guard
    #     reverted, then restored — mutation-proof, Rule 5.)
    # ------------------------------------------------------------------
    @testset "fail-loud: every new aggregate guard raises (Rule 1/2)" begin
        # Helper: lower a single-block routine and return the raised error
        # (or `nothing` if it did not raise). Keeps each case a one-liner.
        function _lower_err(insts; ret = Bennett.IRRet(Bennett.ConstOperand(0), 32),
                            args = [(:__x, 32)], ret_widths = [32])
            blk = Bennett.IRBasicBlock(:entry, Bennett.IRInst[insts...], ret)
            parsed = Bennett.ParsedIR(32, args, [blk], ret_widths)
            try
                lower_vm(parsed; opts = :fail_loud)
                nothing
            catch ex
                ex
            end
        end

        # (5a) insertvalue index >= n_elems — THE silent-miscompile reproducer.
        #      `IRInsertValue(:a, ZERO_AGG, %x, 2, 32, 2)`: slot loop j∈0:1 never
        #      hits j==2, so %x would be DROPPED. Must now fail loud.
        e = _lower_err([Bennett.IRInsertValue(:a, Bennett.ZERO_AGG,
                            Bennett.SSAOperand(:__x), 2, 32, 2)])
        @test e isa ErrorException
        @test occursin("bennettvm-acq", e.msg)
        @test occursin("IRInsertValue", e.msg)
        @test occursin("index", e.msg)

        # (5b) insertvalue index < 0 — same drop, negative side.
        e = _lower_err([Bennett.IRInsertValue(:a, Bennett.ZERO_AGG,
                            Bennett.SSAOperand(:__x), -1, 32, 2)])
        @test e isa ErrorException
        @test occursin("bennettvm-acq", e.msg)
        @test occursin("index", e.msg)

        # (5c) insertvalue n_elems == 0 — emits ZERO slot Defines (no family).
        e = _lower_err([Bennett.IRInsertValue(:a, Bennett.ZERO_AGG,
                            Bennett.SSAOperand(:__x), 0, 32, 0)])
        @test e isa ErrorException
        @test occursin("bennettvm-acq", e.msg)
        @test occursin("n_elems", e.msg)

        # (5d) extractvalue index >= n_elems — names a never-defined slot key.
        #      Build a real [2 x i32] aggregate first, then read slot 2.
        e = _lower_err([
            Bennett.IRInsertValue(:a0, Bennett.ZERO_AGG,
                Bennett.SSAOperand(:__x), 0, 32, 2),
            Bennett.IRExtractValue(:e0, Bennett.SSAOperand(:a0), 2, 32, 2),
        ])
        @test e isa ErrorException
        @test occursin("bennettvm-acq", e.msg)
        @test occursin("IRExtractValue", e.msg)
        @test occursin("index", e.msg)

        # (5e) extractvalue from a NON-aggregate SSA name (not in agg_dests).
        #      `:__x` is a plain scalar arg, never an insertvalue dest, so it
        #      has no slot family. Must fail the membership guard.
        e = _lower_err([Bennett.IRExtractValue(:e0, Bennett.SSAOperand(:__x),
                            0, 32, 2)])
        @test e isa ErrorException
        @test occursin("bennettvm-acq", e.msg)
        @test occursin("known aggregate", e.msg)
    end
end
