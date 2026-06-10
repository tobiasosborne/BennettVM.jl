# test/test_opcode_coverage.jl — the executable coverage matrix
# (bead `bennettvm-d7t`, M_OPCODE.3; PRD v4 §3.6.1 maximum-opcode-coverage
# north-star).
#
# # Why this file exists
#
# `docs/coverage-matrix.md` is a *prose* audit: it claims, row by row, that
# BennettVM's `lower_vm` ingest (`src/ir/ingest.jl`) handles each of the
# **19** concrete Bennett.jl `IRInst` subtypes in one of three ways —
# **DONE** (lowers to a documented VM instruction), **GAP** (raises a
# Rule-1 fail-loud error naming the unsupported op), or **N/A** (a
# frontend-pre-expanded shape that never reaches BennettVM). As of M_FP.2
# (bead `bennettvm-8ox`, ADR 0011) `IRCall` (row 13) moved GAP → DONE for a
# `soft_f*` callee (lowers to `SoftCall`); a NON-soft callee still raises
# loud (the allowlist boundary). As of M_DICT (beads `bennettvm-0do`/`7xa`)
# the three language-neutral map ops (`IRMapInsert`/`IRMapGet`/`IRMapDelete`,
# rows 17-19) ingest 1:1 to the VM-side IRMap* ops — all DONE. As of bead
# `bennettvm-acq` (OPCODE G2) `IRInsertValue` (row 5) and `IRExtractValue`
# (row 12) moved GAP → DONE for homogeneous ArrayType `[N x iW]` aggregates
# (the per-slot `Define` family model; StructType still fails loud upstream).
# As of bead `bennettvm-b5x` (Bennett.jl field `Bennett-xv0u`) `IRPtrOffset`
# (row 7) moved GAP → DONE: the cell-addressed STATIC GEP lowers to
# `Define(dest, base, :add, element_index)` (ADR 0009 Decision 2b).
# The tally is now 18 DONE / 0 GAP / 1 N/A.
# Prose rots.
# This file turns every row into an `@test`, so a future change to
# `_lower_body_inst` / `_successors` / `_lower_alloca!` that silently
# starts (or stops) handling a subtype trips a RED test here, cross-
# referenced to the matrix row it contradicts.
#
# The bead text and the matrix once disagreed on the count ("17 at pin
# 5731cec" vs the corrected **16**); the matrix is the authority and this
# file asserts the 19-way taxonomy explicitly (testset 0).
#
# # What each subtype testset asserts (Rule 4 — never bare "didn't throw")
#
# DONE (18): a minimal hand-built `ParsedIR` fragment containing the
#   subtype is run through the REAL `lower_vm`; the test asserts the
#   resulting `VMProgram`'s entry block (or exit marker) contains the
#   *documented* VM instruction TYPE (`IRBinOp → Define`, `IRCast →
#   CastInstruction`, `IRInsertValue/IRExtractValue → Define` slot-family
#   copies — bead `bennettvm-acq`). Two of the data/control DONE rows are
#   additionally driven
#   END-TO-END via `initial_state`/`run!`/`unrun!` against a hand-computed
#   oracle and round-tripped to empty history (P0.6):
#     • the DIAMOND witness (testset "DONE end-to-end #1") spans
#       `IRICmp`/`IRBinOp`/`IRBranch`/`IRPhi`/`IRRet` — the control-flow
#       quintet — through a conditional join with a φ-merge;
#     • the STRAIGHT-LINE witness (testset "DONE end-to-end #2") spans
#       `IRSelect`/`IRCast`/`IRAlloca`(static)/`IRVarGEP`/`IRStore`/
#       `IRLoad` (+ `IRBinOp`/`IRICmp`/`IRRet`) — the data + memory floor.
#   Between them the two witnesses run ALL eleven DONE subtypes end-to-end.
#   The per-subtype testsets then add the single explicit "this row of the
#   matrix is true" type-assertion that is the VALUE of this file (the
#   existing collatz / matrix_sum / memory-floor round-trip tests already
#   prove the dynamics; this file proves the COVERAGE claim, once per row).
#
# GAP (0): this group is now EMPTY. `IRPtrOffset` left it at bead
#   `bennettvm-b5x` — it now LOWERS to `Define(dest, base, :add, element_index)`
#   (the cell-addressed STATIC GEP, ADR 0009 Decision 2b; see row 7's testset).
#   (`IRCall` left at M_FP.2: a soft_f* callee lowers to `SoftCall`; only a
#   NON-soft callee raises, via the SoftCall allowlist — see row 13.
#   `IRInsertValue` / `IRExtractValue` left at bead `bennettvm-acq` — they now
#   lower to per-slot `Define` families; see rows 5 / 12.) The shared
#   `_lower_body_inst` `else` remains as a pure belt-and-suspenders firewall:
#   no real IRInst subtype reaches it any more, and Julia cannot inject a
#   synthetic IRInst subtype from a test file, so it is a structural guard
#   (defence in depth), not a directly-exercisable tested path.
#
# N/A (1) `IRSwitch`: the matrix records it is pre-expanded by
#   `_expand_switches` (Bennett.jl `extract/module_walk.jl`) into
#   `IRICmp`/`IRBranch` BEFORE `ParsedIR` is returned, so it never reaches
#   `lower_vm`. BennettVM stands alone via the ParsedIR interface (Rule 14)
#   and does not reach into Bennett.jl internals, so there is no runtime
#   assertion of the frontend invariant here — it is DOCUMENTED. We DO add
#   the cheap belt-and-suspenders defensive assertion that IF an `IRSwitch`
#   ever did arrive as a terminator, `_successors` (`src/ir/ingest.jl:417`)
#   fails loud naming `IRSwitch` rather than silently miscompiling it.
#
# # Discrepancy audit (Rule 3 skepticism)
#
# Every assertion below was first probed in a REPL against the live
# `lower_vm` this session; NO discrepancy was found between
# `docs/coverage-matrix.md` and actual behavior. If a future edit makes a
# DONE row error or a GAP row lower, the relevant testset goes RED and the
# matrix must be re-audited (do NOT paper over it — see CLAUDE.md Rule 3).
#
# # Why hand-built ParsedIR (Law 2 — reuse the existing idiom)
#
# The fragments are built with the SAME `Bennett.IRBasicBlock` /
# `Bennett.ParsedIR` constructor idiom as `test/test_memory_floor.jl`,
# `test/test_alloca_delta.jl`, and `test/test_liveness.jl` — not a new one.
# `IRInst` / `IRBasicBlock` are NOT exported from Bennett.jl; they are
# accessed qualified (`Bennett.IRBinOp`, …). Field shapes verified against
# `Bennett.jl/src/ir_types.jl` (read-only).
#
# # Ref
#
#   * `docs/coverage-matrix.md` — THE authority (19 subtypes, 15/3/1 tally,
#     each row citing an `ingest.jl` line).
#   * `src/ir/ingest.jl` — `_lower_body_inst` (:202), `_successors` (:417),
#     `_lower_alloca!` (:337); the dispatch this file pins.
#   * `src/lower_vm.jl` — the `lower_vm(parsed)` entry.
#   * `Bennett.jl/src/ir_types.jl` — the 19 `IRInst` subtype constructors
#     (read-only; Rule 14).
#   * `test/test_memory_floor.jl` / `test/test_alloca_delta.jl` — the
#     hand-built ParsedIR idiom reused here.
#   * PRD v4 §3.6.1 (maximum-opcode-coverage north-star).
#   * CLAUDE.md Rule 1 (fail loud), Rule 3 (skepticism — matrix is not
#     truth until checked), Rule 4 (known value / specific error), Rule 11.

using Test
using BennettVM
import Bennett
# `subtypes` lives in the `InteractiveUtils` stdlib, NOT in `Base` (it
# is one of the REPL-only reflection utilities). Testset (0) walks the
# live `Bennett.IRInst` type tree to pin the 19-way taxonomy against
# the matrix, so the reflection import is load-bearing here, not a
# convenience — without it testset (0) errors `UndefVarError: subtypes`.
using InteractiveUtils: subtypes

# ---------------------------------------------------------------------
# Local helpers (Law 2: same idiom as test_memory_floor.jl).
# ---------------------------------------------------------------------

# Lower a single-block routine (body `insts`, terminator `term`) via the
# REAL `lower_vm`, and return (vm, [types of the entry block's body
# instructions]). The entry block is `vm.blocks[1]` (ingest emits it first,
# `_lower_parsed_ir` Phase 2). One formal arg `:__x` (i32) by default.
function _coverage_lower(insts, term; args=[(:__x, 32)], ret=[32], opts=:coverage)
    blk = Bennett.IRBasicBlock(:entry, Bennett.IRInst[insts...], term)
    parsed = Bennett.ParsedIR(32, args, [blk], ret)
    vm = lower_vm(parsed; opts=opts)
    return vm, Type[typeof(i) for i in first(vm.blocks).instructions]
end

# A bare `IRRet` terminator returning SSA `:__x` (the trivial routine exit).
_ret_x() = Bennett.IRRet(Bennett.SSAOperand(:__x), 32)

# Lower a GAP fragment and capture the raised exception (or `nothing`).
function _coverage_raise(insts, term; args=[(:__x, 32)], ret=[32])
    blk = Bennett.IRBasicBlock(:entry, Bennett.IRInst[insts...], term)
    parsed = Bennett.ParsedIR(32, args, [blk], ret)
    try
        lower_vm(parsed; opts=:gap)
        return nothing
    catch e
        return e
    end
end

@testset "IRInst opcode coverage (bennettvm-d7t; mirrors docs/coverage-matrix.md)" begin

    # =================================================================
    # (0) The taxonomy itself: 19 concrete IRInst subtypes, 17/1/1
    #     (DONE/GAP/N-A) as of bead `bennettvm-acq` (was 15/3/1 — the
    #     aggregate pair IRInsertValue/IRExtractValue moved GAP → DONE).
    #     coverage-matrix.md "The taxonomy" + Tally. We assert the COUNT
    #     (19, unchanged by the GAP→DONE move) against the LIVE Bennett.jl
    #     type tree so a Bennett.jl pin bump that adds / removes a subtype
    #     trips here (and forces a matrix re-audit).
    # =================================================================
    @testset "(0) 19 concrete IRInst subtypes (matrix taxonomy)" begin
        concrete = filter(isconcretetype,
                          subtypes(Bennett.IRInst))
        # 16 base IR opcodes + the 3 language-neutral reversible-map ops
        # (IRMapInsert/IRMapGet/IRMapDelete, SC9 Case B; ADR 0008 / 0013 §D-3).
        # These ingest 1:1 to the VM-side IRMap* ops (src/ir/revmap.jl); see
        # the DONE rows below. The pin moves 16→19 in lockstep with Bennett.jl's
        # test_q04a subtype pin.
        @test length(concrete) == 19
        # Every subtype this file references must be one of them (no typo'd
        # phantom type slips through as `Bennett.IRWhatever <: Any`).
        for T in (Bennett.IRBinOp, Bennett.IRICmp, Bennett.IRSelect,
                  Bennett.IRRet, Bennett.IRInsertValue, Bennett.IRCast,
                  Bennett.IRPtrOffset, Bennett.IRVarGEP, Bennett.IRLoad,
                  Bennett.IRStore, Bennett.IRAlloca, Bennett.IRExtractValue,
                  Bennett.IRCall, Bennett.IRBranch, Bennett.IRSwitch,
                  Bennett.IRPhi,
                  Bennett.IRMapInsert, Bennett.IRMapGet, Bennett.IRMapDelete)
            @test T <: Bennett.IRInst && isconcretetype(T)
        end
    end

    # =================================================================
    # DONE — per-row type assertions (the explicit coverage claim).
    # Each asserts: matrix row N says `IRXxx → VMYyy`; lower it and the
    # lowered VMProgram contains a VMYyy. ingest.jl line cited per row.
    # =================================================================

    # Row 1 — IRBinOp → Define (13 binops; ingest.jl:204).
    @testset "(1) DONE IRBinOp → Define" begin
        _, t = _coverage_lower(
            [Bennett.IRBinOp(:__d, :add, Bennett.SSAOperand(:__x),
                             Bennett.ConstOperand(1), 32)], _ret_x())
        @test BennettVM.Define in t
    end

    # Row 2 — IRICmp → Define (comparison op; ingest.jl:207).
    @testset "(2) DONE IRICmp → Define (comparison)" begin
        _, t = _coverage_lower(
            [Bennett.IRICmp(:__d, :eq, Bennett.SSAOperand(:__x),
                            Bennett.ConstOperand(1), 32)], _ret_x())
        @test BennettVM.Define in t
    end

    # Row 3 — IRSelect → SelectInstruction (ingest.jl:220). cond must be an
    # SSAOperand (ADR 0012 §D3), so an upstream IRICmp produces it.
    @testset "(3) DONE IRSelect → SelectInstruction" begin
        _, t = _coverage_lower(
            [Bennett.IRICmp(:__c, :eq, Bennett.SSAOperand(:__x),
                            Bennett.ConstOperand(0), 32),
             Bennett.IRSelect(:__d, Bennett.SSAOperand(:__c),
                              Bennett.SSAOperand(:__x),
                              Bennett.ConstOperand(9), 32)], _ret_x())
        @test BennettVM.SelectInstruction in t
    end

    # Row 4 — IRRet → EndInstruction (ingest.jl:697). The ret becomes the
    # ret-block's EXIT marker (not a body instruction), so assert on .exit.
    @testset "(4) DONE IRRet → EndInstruction (exit marker)" begin
        blk = Bennett.IRBasicBlock(:entry, Bennett.IRInst[], _ret_x())
        vm = lower_vm(Bennett.ParsedIR(32, [(:__x, 32)], [blk], [32]); opts=:ret)
        @test first(vm.blocks).exit isa BennettVM.EndInstruction
        @test first(vm.blocks).exit.returns == Symbol[:__x]
    end

    # Row 6 — IRCast → CastInstruction (sext/zext/trunc; ingest.jl:229).
    @testset "(6) DONE IRCast → CastInstruction" begin
        _, t = _coverage_lower(
            [Bennett.IRCast(:__d, :sext, Bennett.SSAOperand(:__x), 8, 32)],
            _ret_x())
        @test BennettVM.CastInstruction in t
    end

    # Row 8 — IRVarGEP → VarGEP (ingest.jl:282). Needs an alloca base.
    @testset "(8) DONE IRVarGEP → VarGEP" begin
        _, t = _coverage_lower(
            [Bennett.IRAlloca(:__a, 32, Bennett.ConstOperand(4)),
             Bennett.IRVarGEP(:__p, Bennett.SSAOperand(:__a),
                              Bennett.ConstOperand(0), 32)],
            Bennett.IRRet(Bennett.SSAOperand(:__a), 32))
        @test BennettVM.VarGEP in t
    end

    # Row 9 — IRLoad → MemoryLoad (ingest.jl:257).
    @testset "(9) DONE IRLoad → MemoryLoad" begin
        _, t = _coverage_lower(
            [Bennett.IRAlloca(:__a, 32, Bennett.ConstOperand(1)),
             Bennett.IRLoad(:__r, Bennett.SSAOperand(:__a), 32)],
            Bennett.IRRet(Bennett.SSAOperand(:__r), 32))
        @test BennettVM.MemoryLoad in t
    end

    # Row 10 — IRStore → MemoryStore (ingest.jl:245).
    @testset "(10) DONE IRStore → MemoryStore" begin
        _, t = _coverage_lower(
            [Bennett.IRAlloca(:__a, 32, Bennett.ConstOperand(1)),
             Bennett.IRStore(Bennett.SSAOperand(:__a),
                             Bennett.SSAOperand(:__x), 32)],
            _ret_x())
        @test BennettVM.MemoryStore in t
    end

    # Row 11 — IRAlloca → bump-allocator cursor (ingest.jl:337,
    # _lower_alloca!). Static-N (ConstOperand) materialises a StackAlloca (the
    # frame-relative `dest := base + stack_top` create, CW-C3 / ADR 0019 —
    # superseded the pre-CW-C3 `Define(dest, base, :add, 0)` so multi-function C
    # stack allocas are frame-disjoint); dynamic-N (SSAOperand) materialises a
    # DynAlloca. BOTH are DONE.
    @testset "(11) DONE IRAlloca → StackAlloca (static) / DynAlloca (dynamic)" begin
        # Static: ConstOperand(N) → StackAlloca(dest, base) (CW-C3).
        _, ts = _coverage_lower(
            [Bennett.IRAlloca(:__a, 32, Bennett.ConstOperand(4))],
            Bennett.IRRet(Bennett.SSAOperand(:__a), 32))
        @test BennettVM.StackAlloca in ts
        # Dynamic: SSAOperand → DynAlloca (bead 0zn; ADR 0009 Decision 2a).
        _, td = _coverage_lower(
            [Bennett.IRAlloca(:__a, 32, Bennett.SSAOperand(:__x))],
            Bennett.IRRet(Bennett.SSAOperand(:__a), 32))
        @test BennettVM.DynAlloca in td
    end

    # Row 14 — IRBranch → Conditional/UnconditionalExit + trampoline
    # (critical-edge split; ingest.jl:416 _successors / :701-707).
    # A conditional branch yields a ConditionalExit on the source block.
    @testset "(14) DONE IRBranch → ConditionalExit (+ trampoline)" begin
        b_entry = Bennett.IRBasicBlock(:entry,
            Bennett.IRInst[Bennett.IRICmp(:__c, :sgt, Bennett.SSAOperand(:__x),
                                          Bennett.ConstOperand(0), 32)],
            Bennett.IRBranch(Bennett.SSAOperand(:__c), :L_t, :L_f))
        b_t = Bennett.IRBasicBlock(:L_t, Bennett.IRInst[], _ret_x())
        b_f = Bennett.IRBasicBlock(:L_f, Bennett.IRInst[], _ret_x())
        vm = lower_vm(Bennett.ParsedIR(32, [(:__x, 32)],
                                       [b_entry, b_t, b_f], [32]); opts=:branch)
        eb = first(b for b in vm.blocks if b.label == :entry)
        @test eb.exit isa BennettVM.ConditionalExit
        # The critical-edge trampolines (`:e_entry_L_t`, `:e_entry_L_f`) exist.
        labels = Set(b.label for b in vm.blocks)
        @test :e_entry_L_t in labels
        @test :e_entry_L_f in labels
    end

    # Row 16 — IRPhi → block param (Mogensen RSSA §3; ingest.jl:284/394).
    # A φ at a join becomes the join block's entry `params`.
    @testset "(16) DONE IRPhi → block parameter" begin
        b_entry = Bennett.IRBasicBlock(:entry, Bennett.IRInst[],
            Bennett.IRBranch(nothing, :L_join, nothing))
        b_join = Bennett.IRBasicBlock(:L_join,
            Bennett.IRInst[Bennett.IRPhi(:__m, 32,
                Tuple{Bennett.IROperand,Symbol}[
                    (Bennett.SSAOperand(:__x), :entry)])],
            Bennett.IRRet(Bennett.SSAOperand(:__m), 32))
        vm = lower_vm(Bennett.ParsedIR(32, [(:__x, 32)],
                                       [b_entry, b_join], [32]); opts=:phi)
        jb = first(b for b in vm.blocks if b.label == :L_join)
        # φ.dest is the join block's entry parameter (NOT a body instruction).
        @test :__m in jb.entry.params
    end

    # Rows 17-19 — IRMapInsert / IRMapGet / IRMapDelete → BennettVM IRMap* ops
    # (SC9 Case B; ADR 0008 / 0013 §D-3; ingest.jl IRMap* arms). The
    # language-neutral reversible-map ops the mem=:vm Dict recogniser emits;
    # the end-to-end dynamics are proven in test_dict_roundtrip.jl Part A.
    @testset "(17) DONE IRMapInsert → BennettVM.IRMapInsert" begin
        _, t = _coverage_lower(
            [Bennett.IRMapInsert(Bennett.SSAOperand(:__x),
                                 Bennett.ConstOperand(7), 32, 32)], _ret_x())
        @test BennettVM.IRMapInsert in t
    end

    @testset "(18) DONE IRMapGet → BennettVM.IRMapGet" begin
        _, t = _coverage_lower(
            [Bennett.IRMapInsert(Bennett.SSAOperand(:__x),
                                 Bennett.ConstOperand(7), 32, 32),
             Bennett.IRMapGet(:__r, Bennett.SSAOperand(:__x), 32, 32)],
            Bennett.IRRet(Bennett.SSAOperand(:__r), 32))
        @test BennettVM.IRMapGet in t
    end

    @testset "(19) DONE IRMapDelete → BennettVM.IRMapDelete" begin
        _, t = _coverage_lower(
            [Bennett.IRMapInsert(Bennett.SSAOperand(:__x),
                                 Bennett.ConstOperand(7), 32, 32),
             Bennett.IRMapDelete(Bennett.SSAOperand(:__x), 32)], _ret_x())
        @test BennettVM.IRMapDelete in t
    end

    # =================================================================
    # DONE — END-TO-END round-trip witnesses (Rule 4: known value).
    # Together these run 11 of the 17 DONE subtypes through run!/unrun!.
    # IRCall → SoftCall (M_FP.2) is round-tripped end-to-end in
    # test_fp_roundtrip.jl and asserted per-subtype in row 13. The
    # aggregate pair (IRInsertValue / IRExtractValue, bead `bennettvm-acq`)
    # is round-tripped end-to-end in test_aggregate_extract_insert.jl and
    # asserted per-subtype in rows 5 / 12.
    # =================================================================

    # Witness #1 — control-flow quintet: IRICmp, IRBinOp, IRBranch, IRPhi,
    # IRRet. A diamond: entry tests x>0, branches to L_t (x+1) or L_f (x-1),
    # both join at L_join whose φ merges the two, then ret.
    #   Oracle: m == (x>0 ? x+1 : x-1).
    @testset "DONE end-to-end #1 — diamond (IRICmp/IRBinOp/IRBranch/IRPhi/IRRet)" begin
        b_entry = Bennett.IRBasicBlock(:entry,
            Bennett.IRInst[Bennett.IRICmp(:__c, :sgt, Bennett.SSAOperand(:__x),
                                          Bennett.ConstOperand(0), 32)],
            Bennett.IRBranch(Bennett.SSAOperand(:__c), :L_t, :L_f))
        b_t = Bennett.IRBasicBlock(:L_t,
            Bennett.IRInst[Bennett.IRBinOp(:__a, :add, Bennett.SSAOperand(:__x),
                                           Bennett.ConstOperand(1), 32)],
            Bennett.IRBranch(nothing, :L_join, nothing))
        b_f = Bennett.IRBasicBlock(:L_f,
            Bennett.IRInst[Bennett.IRBinOp(:__b, :sub, Bennett.SSAOperand(:__x),
                                           Bennett.ConstOperand(1), 32)],
            Bennett.IRBranch(nothing, :L_join, nothing))
        b_join = Bennett.IRBasicBlock(:L_join,
            Bennett.IRInst[Bennett.IRPhi(:__m, 32,
                Tuple{Bennett.IROperand,Symbol}[
                    (Bennett.SSAOperand(:__a), :L_t),
                    (Bennett.SSAOperand(:__b), :L_f)])],
            Bennett.IRRet(Bennett.SSAOperand(:__m), 32))
        vm = lower_vm(Bennett.ParsedIR(32, [(:__x, 32)],
                                       [b_entry, b_t, b_f, b_join], [32]);
                      opts=:diamond)
        # The i32 add/sub now compute in i32 semantics (ADR 0012 R1, bead
        # bennettvm-bgc): `result` carries the LOW-32-BIT representation, so a
        # NEGATIVE oracle (x=-5 → -6, x=0 → -1) is the zero-extended
        # `oracle & 0xFFFFFFFF`, not the sign-extended Int64. The `:sgt`
        # branch predicate is itself width-32 signed (operands sign-extended),
        # so x=-5 / x=0 still correctly take the `x-1` arm — the control flow
        # is unchanged; only the arithmetic carrier is the i32 low-bit form.
        _m32 = (Int64(1) << 32) - 1
        for x in (Int64(5), Int64(-5), Int64(0))
            oracle = (x > 0 ? x + 1 : x - 1) & _m32
            rs = initial_state(vm, Dict(:__x => x))
            run!(rs, vm; checkpoint_interval=4)
            @test is_halted(rs)
            @test result(rs)[:__m] == oracle      # ORACLE (i32 known value)
            unrun!(rs, vm)
            @test rs.current == rs.initial         # round-trip (P0.6)
            @test isempty(rs.history)
            @test rs.step_count == 0
        end
    end

    # Witness #2 — data + memory floor: IRSelect, IRCast, IRAlloca(static),
    # IRVarGEP, IRStore, IRLoad (+ IRICmp/IRBinOp/IRRet). Straight-line:
    #   c   = x sgt 0
    #   sel = c ? x : 0
    #   w   = sext sel  (i8→i32; identity for in-range ints)
    #   a   = alloca i32, 4 ; p = gep a,1 ; store p,w ; r0 = load p ; r = r0+0
    #   Oracle: r == (x>0 ? x : 0). Round-trips under L3 (every body op
    #   non-injective → checkpoint-replay reversal).
    @testset "DONE end-to-end #2 — straight-line (IRSelect/IRCast/IRAlloca/IRVarGEP/IRStore/IRLoad)" begin
        blk = Bennett.IRBasicBlock(:entry, Bennett.IRInst[
            Bennett.IRICmp(:__c, :sgt, Bennett.SSAOperand(:__x),
                           Bennett.ConstOperand(0), 32),
            Bennett.IRSelect(:__sel, Bennett.SSAOperand(:__c),
                             Bennett.SSAOperand(:__x),
                             Bennett.ConstOperand(0), 32),
            Bennett.IRCast(:__w, :sext, Bennett.SSAOperand(:__sel), 8, 32),
            Bennett.IRAlloca(:__a, 32, Bennett.ConstOperand(4)),
            Bennett.IRVarGEP(:__p, Bennett.SSAOperand(:__a),
                             Bennett.ConstOperand(1), 32),
            Bennett.IRStore(Bennett.SSAOperand(:__p), Bennett.SSAOperand(:__w), 32),
            Bennett.IRLoad(:__r0, Bennett.SSAOperand(:__p), 32),
            Bennett.IRBinOp(:__r, :add, Bennett.SSAOperand(:__r0),
                            Bennett.ConstOperand(0), 32),
        ], Bennett.IRRet(Bennett.SSAOperand(:__r), 32))
        vm = lower_vm(Bennett.ParsedIR(32, [(:__x, 32)], [blk], [32]);
                      opts=:straightline)
        for x in (Int64(5), Int64(-3), Int64(0))
            oracle = x > 0 ? x : Int64(0)
            rs = initial_state(vm, Dict(:__x => x))
            run!(rs, vm; checkpoint_interval=4)
            @test is_halted(rs)
            @test result(rs)[:__r] == oracle       # ORACLE (known value)
            unrun!(rs, vm)
            @test rs.current == rs.initial          # round-trip (P0.6)
            @test isempty(rs.history)
            @test rs.step_count == 0
        end
    end

    # =================================================================
    # GAP — each raises a Rule-1 fail-loud error NAMING the op. This group
    # is now EMPTY: IRPtrOffset left it at bead `bennettvm-b5x` (see DONE
    # row 7 below); IRInsertValue / IRExtractValue left at bead
    # `bennettvm-acq` (DONE rows 5 / 12). No non-terminator IRInst subtype
    # falls through `_lower_body_inst`'s shared `else` any more — the
    # fail-loud `else` is now a pure belt-and-suspenders firewall: a structural
    # guard not reachable by any concrete IRInst subtype, hence not directly
    # exercisable by a test.
    # =================================================================

    # Row 7 — IRPtrOffset → Define (DONE at bead `bennettvm-b5x`; the
    # cell-addressed STATIC GEP, ADR 0009 Decision 2b). `IRPtrOffset(dest,
    # base, offset_bytes, elem_width)` lowers to `Define(dest, base, :add,
    # element_index)` where `element_index = offset_bytes ÷ (elem_width÷8)`
    # — the constant-offset analogue of IRVarGEP (VarGEP stride-1 cell
    # address). The `elem_width` field (Bennett.jl `Bennett-xv0u`) is what
    # makes the byte→index recovery correct for non-i64 elements; the circuit
    # backend ignores it. off=8, ew=32 (i32) → element index 2.
    @testset "(7) DONE IRPtrOffset → Define(dest, base, :add, element_index)" begin
        vm, t = _coverage_lower(
            [Bennett.IRAlloca(:__a, 32, Bennett.ConstOperand(4)),
             Bennett.IRPtrOffset(:__d, Bennett.SSAOperand(:__a), 8, 32)],
            Bennett.IRRet(Bennett.SSAOperand(:__a), 32))
        @test BennettVM.Define in t
        # The lowered IRPtrOffset is Define(:__d, :__a, :add, 2) — element
        # index 2, NOT 8 (byte-addressed) and NOT 1 (a hardcoded ÷8). This is
        # the COVERAGE claim (Rule 4 — a known value, not "no throw").
        defs = [i for i in first(vm.blocks).instructions
                if i isa BennettVM.Define && i.target == :__d]
        @test length(defs) == 1
        @test defs[1].lhs == :__a
        @test defs[1].op == :add
        @test defs[1].rhs == Int64(2)
    end

    # Row 5 — IRInsertValue → N slot Defines (DONE at bead `bennettvm-acq`;
    # the ArrayType aggregate slot model, ingest.jl insertvalue body-loop
    # special case). `insertvalue ZERO_AGG, %x, 0` over a `[2 x i32]` emits a
    # `Define` per slot (slot 0 := %x; slot 1 := 0). We assert the lowered body
    # holds those slot creates (the multi-slot model) — Rule 4, the explicit
    # coverage claim. (StructType aggregates fail loud UPSTREAM in Bennett.jl
    # extract — U10 / Bennett-tu6i — so only the ArrayType case reaches ingest.)
    @testset "(5) DONE IRInsertValue → N slot Defines" begin
        _, t = _coverage_lower(
            [Bennett.IRInsertValue(:__d, Bennett.ZERO_AGG,
                                   Bennett.SSAOperand(:__x), 0, 32, 2)], _ret_x())
        @test BennettVM.Define in t
        # The lowered body materialises BOTH slots of the [2 x i32] family.
        names = Symbol[i.target for i in first(_coverage_lower(
            [Bennett.IRInsertValue(:__d, Bennett.ZERO_AGG,
                                   Bennett.SSAOperand(:__x), 0, 32, 2)],
            _ret_x())[1].blocks).instructions if i isa BennettVM.Define]
        @test BennettVM._agg_slot_name(:__d, 0) in names
        @test BennettVM._agg_slot_name(:__d, 1) in names
    end

    # Row 12 — IRExtractValue → Define slot copy (DONE at bead `bennettvm-acq`;
    # the ArrayType aggregate slot model, ingest.jl `_lower_body_inst`
    # IRExtractValue arm). `extractvalue agg, k` reads slot k of the aggregate's
    # synthetic per-slot family into the scalar `dest` (a non-destructive
    # `Define(dest, _agg_<agg>_slot<k>, :add, 0)`). The aggregate base must be a
    # prior insertvalue build-up (an SSAOperand), so we feed one upstream.
    @testset "(12) DONE IRExtractValue → Define (slot copy)" begin
        _, t = _coverage_lower(
            [Bennett.IRInsertValue(:__a, Bennett.ZERO_AGG,
                                   Bennett.SSAOperand(:__x), 0, 32, 2),
             Bennett.IRExtractValue(:__d, Bennett.SSAOperand(:__a), 0, 32, 2)],
            _ret_x())
        @test BennettVM.Define in t
    end

    # Row 13 — IRCall → SoftCall (DONE at M_FP.2; ADR 0011 §D1, ingest.jl).
    # A `soft_f*` callee lowers to a `SoftCall` (the SoftFloat-dispatch
    # create); a NON-soft callee (a general host inline) still raises loud,
    # via the SoftCall allowlist (`_SOFT_DISPATCH`), NOT the `_lower_body_inst`
    # final `else`. Both halves are asserted here (the row's full contract).
    @testset "(13) DONE IRCall(soft_f*) → SoftCall; non-soft raises" begin
        # DONE half — a soft_f* callee lowers to a SoftCall (f64 operands).
        _, t = _coverage_lower(
            [Bennett.IRCall(:__d, Bennett.soft_fadd,
                            Bennett.IROperand[Bennett.SSAOperand(:__x),
                                              Bennett.ConstOperand(0)],
                            [64, 64], 64)],
            Bennett.IRRet(Bennett.SSAOperand(:__d), 64);
            args=[(:__x, 64)], ret=[64])
        @test BennettVM.SoftCall in t

        # Allowlist half — a non-soft callee (here `identity`) is NOT a
        # recognised SoftFloat primitive, so the SoftCall constructor fails
        # loud naming the rejected callee (Rule 1). The message names the
        # callee and the allowlist, not "unsupported IRInst body subtype"
        # (that's the `else`-arm GAP message; non-soft IRCall now raises one
        # step earlier, in SoftCall's constructor). Widths are 64 (f64) so the
        # NON-SOFT-callee path is what is under test here — an f32 width would
        # instead trip the ingest-boundary f32-rejection guard (bead
        # `bennettvm-h0t`, ADR 0011 §D2), which is exercised separately in
        # `test_fp_f32_reject.jl`.
        e = _coverage_raise(
            [Bennett.IRCall(:__d, identity,
                            Bennett.IROperand[Bennett.SSAOperand(:__x)],
                            [64], 64)],
            Bennett.IRRet(Bennett.SSAOperand(:__x), 64);
            args=[(:__x, 64)], ret=[64])
        @test e isa ErrorException
        @test occursin("SoftCall", e.msg)
        @test occursin("identity", e.msg)
        @test occursin("SoftFloat", e.msg)
    end

    # =================================================================
    # N/A — IRSwitch (Row 15).
    # =================================================================
    #
    # The matrix records: `_expand_switches` (Bennett.jl
    # `extract/module_walk.jl`) rewrites every `switch` to IRICmp/IRBranch
    # BEFORE `ParsedIR` is returned, so an `IRSwitch` NEVER reaches
    # `lower_vm`. BennettVM consumes Bennett.jl only through the ParsedIR
    # interface and does NOT reach into Bennett.jl internals (Rule 14), so
    # the frontend pre-expansion invariant is NOT runtime-asserted here — it
    # is documented (this comment) and lives in Bennett.jl's own tests.
    #
    # What we CAN cheaply assert (belt-and-suspenders, Rule 1): if an
    # `IRSwitch` ever DID arrive as a terminator — a malformed handoff or a
    # frontend regression — BennettVM must FAIL LOUD naming it, not silently
    # miscompile. `_successors` (`src/ir/ingest.jl:417`) handles only
    # IRBranch / IRRet and raises on anything else. This asserts the
    # fail-loud floor, NOT that IRSwitch is a supported shape.
    @testset "(15) N/A IRSwitch — frontend-pre-expanded; fail-loud if it ever arrives" begin
        switch_term = Bennett.IRSwitch(
            Bennett.SSAOperand(:__x), 32, :entry,
            Tuple{Bennett.IROperand,Symbol}[(Bennett.ConstOperand(0), :entry)])
        e = _coverage_raise(Bennett.IRInst[], switch_term)
        @test e isa ErrorException
        @test occursin("IRSwitch", e.msg)
        @test occursin("unsupported terminator subtype", e.msg)
    end

end
