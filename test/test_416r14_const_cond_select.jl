# test/test_416r14_const_cond_select.jl — const-cond IRSelect fold
# (bead `bennettvm-416r.14`; downstream of `bennettvm-p81t` / CW-D; ADR 0012 §D3).
#
# # What this file pins (Rule 4 — known values, not "didn't throw")
#
# A closed-world Julia set extracted at `optimize=false` (Bennett Rule 5,
# mandated for predictable IR) mirrors LLVM's UNFOLDED
# `select i1 <const>, t, f` verbatim: instcombine would fold these at
# `optimize=true`, but Bennett does NO IR-level fold (its circuit path folds
# them DOWNSTREAM at the GATE level via `_fold_constants`; the utzc pruner only
# touches dead-block terminators). BVM is an interpreter with no gate layer, so
# a const-cond select reaches ingest un-folded and the old IRSelect arm
# (`ingest_body.jl`) died on it: it required an `SSAOperand` predicate.
#
# The 42-select census across the closed fdict set (root 10, rehash! 9,
# ht_keyindex2 23, setindex! 0) vs 69 SSA-cond selects (untouched): cond encoding
# is `ConstOperand(0)` ×41 (LLVM i1 false → false arm op2) and `ConstOperand(-1)`
# ×1 (LLVM sign-extended i1 true → true arm op1). Never a bare `1` in-corpus, but
# `1` MUST be accepted (i1 true). All widths 64.
#
# The fold statically resolves the taken arm and emits the established
# non-injective `Define` create (both `Define` and `SelectInstruction` are
# `is_injective == false`, reversed by the SAME L3 checkpoint-replay — the fold
# is reversibility-neutral; cf. the p81t `Define` idiom). i1 const encoding is
# masked to the low bit (`(c & 1) == 1`), which on this whitelist {0,1,-1} equals
# the interpreter's own `cond != 0` predicate (`select_instruction.jl`), so the
# fold is behaviorally IDENTICAL to the select it replaces. NO width masking:
# `SelectInstruction` never masks its arms, so the fold must not either. The
# UNTAKEN arm is NEVER resolved — false-path-safe by construction.
#
# After the fold, the REAL set advances to the `IRInsertBits` wall (bits-struct
# sret packing, Bennett-dv1z) — the const-cond IRSelect wall is CLEARED. That
# successor is bead bennettvm-416r.15 (the IRInsertBits successor).
#
# Ref: `src/ir/ingest_body.jl` (the const-cond fold arm); `src/ir/define_instruction.jl`
#   (the non-injective create emitted); `src/ir/select_instruction.jl` (the SSA-cond
#   path, unchanged; the `cond != 0` predicate the fold matches);
#   `docs/adr/0012-collatz-lowering.md` §D3; CLAUDE.md Rule 1, Rule 4, Rule 11.

using Test
using BennettVM
import Bennett
const _BV = BennettVM
const _B  = Bennett

@testset "bennettvm-416r.14 — const-cond IRSelect fold" begin

    # ------------------------------------------------------------------
    # (a) const-cond folds to a non-injective Define; SSA cond untouched.
    # ------------------------------------------------------------------
    @testset "unit: const-cond folds to Define" begin
        # cond 0 (false) → false arm op2 (the ×41 corpus case). op2 = SSA :x.
        s0 = _B.IRSelect(:d, _B.ConstOperand(0),
                         _B.SSAOperand(:t_arm), _B.SSAOperand(:x), 64)
        out0 = _BV._lower_body_inst(s0)
        @test out0 isa _BV.Define
        @test out0.target === :d
        @test out0.lhs === :x                 # false arm selected
        @test out0.op === :add
        @test out0.rhs == Int64(0)            # identity-copy create
        @test out0.width == 64                # NO width masking

        # cond -1 (sign-extended i1 true) → true arm op1 (the ×1 corpus case).
        # taken arm is itself a ConstOperand(0) — folds to Define(:d, 0, :add, 0).
        sm1 = _B.IRSelect(:d, _B.ConstOperand(-1),
                          _B.ConstOperand(0), _B.SSAOperand(:x), 64)
        outm1 = _BV._lower_body_inst(sm1)
        @test outm1 isa _BV.Define
        @test outm1.target === :d
        @test outm1.lhs == Int64(0)           # true arm (a literal) selected
        @test outm1.op === :add
        @test outm1.rhs == Int64(0)

        # cond 1 (bare i1 true, never in-corpus but MUST be accepted) → true arm.
        s1 = _B.IRSelect(:d, _B.ConstOperand(1),
                         _B.SSAOperand(:t_arm), _B.SSAOperand(:f_arm), 64)
        out1 = _BV._lower_body_inst(s1)
        @test out1 isa _BV.Define
        @test out1.lhs === :t_arm             # true arm selected

        # SSA cond is UNTOUCHED — still a SelectInstruction (the 69 SSA-cond
        # selects the fold must not disturb).
        ssa = _B.IRSelect(:d, _B.SSAOperand(:c),
                          _B.SSAOperand(:t_arm), _B.SSAOperand(:f_arm), 64)
        out_ssa = _BV._lower_body_inst(ssa)
        @test out_ssa isa _BV.SelectInstruction
        @test out_ssa.cond === :c
        @test out_ssa.val_true === :t_arm
        @test out_ssa.val_false === :f_arm
    end

    # ------------------------------------------------------------------
    # (b) a non-boolean const cond fails loud (Rule 1).
    # ------------------------------------------------------------------
    @testset "fail-loud: invalid i1 const" begin
        bad = _B.IRSelect(:d, _B.ConstOperand(2),
                          _B.SSAOperand(:t_arm), _B.SSAOperand(:f_arm), 64)
        msg = try
            _BV._lower_body_inst(bad); ""
        catch e
            e isa InterruptException && rethrow()
            sprint(showerror, e)
        end
        @test occursin("not a valid i1 constant", msg)
        @test occursin("2", msg)
    end

    # ------------------------------------------------------------------
    # (c) behavioral equivalence: the folded Define writes the SAME dest value
    #     as a hand-built SelectInstruction with the cond materialised into a
    #     local — for every i1 const in {0, 1, -1}.
    # ------------------------------------------------------------------
    @testset "behavioral equivalence: fold ≡ materialised select" begin
        for c in Int64[0, 1, -1]
            sel_ir = _B.IRSelect(:d, _B.ConstOperand(c),
                                 _B.SSAOperand(:t_arm), _B.SSAOperand(:f_arm), 64)
            folded = _BV._lower_body_inst(sel_ir)
            @test folded isa _BV.Define

            # drive the folded Define.
            s_fold = _BV.IState(0,
                Dict(:t_arm => Int64(10), :f_arm => Int64(20)), :running)
            _BV.forward(folded, s_fold)

            # drive a hand-built SelectInstruction with cond materialised.
            hand = _BV.SelectInstruction(:d, :cond, :t_arm, :f_arm)
            s_sel = _BV.IState(0,
                Dict(:cond => c, :t_arm => Int64(10), :f_arm => Int64(20)),
                :running)
            _BV.forward(hand, s_sel)

            @test _BV.active_locals(s_fold)[:d] == _BV.active_locals(s_sel)[:d]
            # concretely: c=0 → 20 (false arm); c ∈ {1,-1} → 10 (true arm).
            @test _BV.active_locals(s_fold)[:d] == (c == 0 ? Int64(20) : Int64(10))
        end
    end

    # ------------------------------------------------------------------
    # (d) micro round-trip (Rule 4 / P0.6): a const-cond select feeds the return.
    #     a = x + 10; d = select(true, a, x); ret d.  d == x + 10.
    # ------------------------------------------------------------------
    @testset "micro round-trip: const-cond select feeds return" begin
        blk = _B.IRBasicBlock(:entry,
            _B.IRInst[
                _B.IRBinOp(:a, :add, _B.SSAOperand(:x), _B.ConstOperand(10), 64),
                _B.IRSelect(:d, _B.ConstOperand(-1),            # i1 true
                            _B.SSAOperand(:a), _B.SSAOperand(:x), 64),
            ],
            _B.IRRet(_B.SSAOperand(:d), 64))
        parsed = _B.ParsedIR(64, Tuple{Symbol,Int}[(:x, 64)], [blk], Int[64])
        prog = _BV.lower_vm(parsed)

        for x in Int64[0, 1, 5, 42, -3]
            rs = _BV.initial_state(prog, Dict(:x => x))
            _BV.run!(rs, prog; checkpoint_interval = 2)
            @test _BV.is_halted(rs)
            @test _BV.result(rs)[:d] == x + 10        # golden master (true arm = a)

            _BV.unrun!(rs, prog)
            @test rs.current == rs.initial            # P0.6 — reversed to start
            @test isempty(rs.history)                 # P0.6 — history drained
            @test rs.step_count == 0                  # P0.6 — counter reset
        end
    end

    # ------------------------------------------------------------------
    # (e) the REAL fdict set clears the const-cond IRSelect wall AND the
    #     IRInsertBits bits-struct sret wall (bead bennettvm-416r.15,
    #     Bennett-dv1z) AND (bead bennettvm-x3t0) the aggregate-RETURN reject
    #     (multi-key return landed), advancing to the sret_box MEMORY-ABI gate
    #     (`setindex!` → `ht_keyindex2` with ret_width 64 ≠ 72; the blocker-5
    #     follow-up bead). ~2 min (full closed-world extraction). When it lands,
    #     this flips.
    # ------------------------------------------------------------------
    @testset "fdict set lowers to a VMProgram (static-wall chain DONE)" begin
        fdict_d1b(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])
        set = _B.extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
                                                  ptr_cells = true)
        # bead bennettvm-416r.16 (2026-07-11): the caller-side consumed-sret
        # reconciliation cleared the LAST static wall — setindex!'s ht_keyindex2
        # consumed sret-out box call is rewritten to the VALUE ABI (ret_width 72
        # == sum([64,8])), so lower_vm COMPLETES. The static chain is DONE; the
        # first RUNTIME wall is jl_global materialization (beads 416r.13 / 416r.4).
        prog = _BV.lower_vm(set; entry = first(set).first)
        @test prog isa _BV.VMProgram
        @test haskey(prog.functions, :ht_keyindex2_shorthash!)
        @test length(prog.functions[:ht_keyindex2_shorthash!].returns) == 2
    end
end
