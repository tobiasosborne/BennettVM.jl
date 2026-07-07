# test/test_utzc_unreachable_sink.jl — Bennett-utzc / CW-D (ADR 0017 §4).
#
# # What this gate proves
#
# The BennettVM half of the reversible `:__unreachable__` halt sink. The
# Bennett.jl frontend (a separate later sub-step) will emit a provably-dead
# throw arm as an empty block whose terminator is
# `IRBranch(nothing, :__unreachable__, nothing)` — an unconditional branch to
# the reserved sentinel label `:__unreachable__`, a branch TARGET with NO
# matching source block (a dangling target). Before this bead, `lower_vm`
# KeyError'd on that dangling target (`by_label[dst]` in the Phase-1 edge loop,
# `src/ir/ingest.jl`). This gate pins the fix:
#
#   1. NOT-TAKEN round-trip — an input that AVOIDS the dead edge lowers, runs
#      to a correct `:halted` result, and reverses to empty history. The sink
#      block exists in the program but is never executed. (RED today without
#      the fix: `lower_vm` throws `KeyError: :__unreachable__`; GREEN after.)
#   2. TAKEN halts LOUD — an input that TAKES the dead edge reaches the
#      synthetic sink, whose sole body instruction `UnreachableHalt()` sets
#      `status = :error` (distinct from a normal `EndInstruction`'s `:halted`)
#      on entry; `run!` then raises loudly (Rule 1 fail-loud). Driving `step!`
#      to the sink by hand pins `status === :error`.
#   3. MULTI-FUNCTION — a genuine caller→callee module where BOTH functions
#      carry a `:__unreachable__` arm. Per-function sinks are `#`-qualified
#      (`<fname>#__unreachable__`, ADR 0019 §2), so they never collide; the
#      not-taken cross-function call returns correctly.
#
# # Sink block shape (the materialization contract, Rule 4)
#
# The ingest pass materialises the dangling target as a synthetic per-function
# block `UnconditionalEntry(<fn>#__unreachable__, []) / [UnreachableHalt()] /
# EndInstruction(routine, [])`. The trailing `EndInstruction` is vestigial — a
# halt-on-entry never reaches it — present only to satisfy the `BasicBlock`
# exit-slot invariant. Testset 1 asserts this exact shape.
#
# # Ref
#   * ADR 0017 §4 (reversible-throw halt sink; Bennett-utzc / CW-D).
#   * `src/ir/unreachable_halt.jl` — the `UnreachableHalt` instruction.
#   * `src/ir/ingest.jl` — `_lower_parsed_ir` sink materialization + halt inject.
#   * `src/interpreter/Interpreter.jl` — `run!`'s `status === :running` loop +
#     the post-loop `:error` loud fail.
#   * `src/history/Injective.jl` — `is_injective(::Type{UnreachableHalt}) = true`.
#   * `test/test_dict_roundtrip.jl` Part A — the hand-built-ParsedIR idiom
#     reused here; `test/test_per_step_inverse.jl` — the per-step blind-spot
#     discipline.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (real invariants), Rule 11.

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

const _BV = BennettVM
const _BN = Bennett

# ---------------------------------------------------------------------
# Single-function fixture: a diamond whose `:dead` arm branches to the
# dangling `:__unreachable__` sentinel and whose `:live` arm returns x+1.
#
#   top:  c = icmp eq x, 0 ; br c ? dead : live   (c=1 ⟺ x==0 ⇒ dead taken)
#   dead: (empty) ; br → :__unreachable__          (the dangling target)
#   live: a = x + 1 ; ret a
#
# Oracle (not-taken, x != 0): f(x) = x + 1. The dead edge fires ONLY on x==0.
# ---------------------------------------------------------------------
_utzc_oracle(x::Int64) = x + 1

function _utzc_parsed_ir()
    b_top = _BN.IRBasicBlock(:top,
        _BN.IRInst[_BN.IRICmp(:c, :eq, _BN.SSAOperand(:x),
                              _BN.ConstOperand(0), 64)],
        _BN.IRBranch(_BN.SSAOperand(:c), :dead, :live))
    b_dead = _BN.IRBasicBlock(:dead,
        _BN.IRInst[],
        _BN.IRBranch(nothing, :__unreachable__, nothing))
    b_live = _BN.IRBasicBlock(:live,
        _BN.IRInst[_BN.IRBinOp(:a, :add, _BN.SSAOperand(:x),
                               _BN.ConstOperand(1), 64)],
        _BN.IRRet(_BN.SSAOperand(:a), 64))
    return _BN.ParsedIR(64, [(:x, 64)], [b_top, b_dead, b_live], [64])
end

@testset "Bennett-utzc — :__unreachable__ halt sink (ADR 0017 §4)" begin

    # =================================================================
    # 1. NOT-TAKEN — the dead edge is avoided; lower + run + round-trip.
    #    (RED without the fix: lower_vm throws KeyError :__unreachable__.)
    # =================================================================
    @testset "not-taken → lowers, runs to :halted, round-trips" begin
        pir = _utzc_parsed_ir()
        prog = lower_vm(pir)   # RED today: KeyError :__unreachable__; GREEN after.

        # The synthetic sink block exists with the documented shape (Rule 4):
        # UnconditionalEntry / [UnreachableHalt] / EndInstruction. Selected by
        # EXACT label (single-function ⇒ `_q` is identity ⇒ label is
        # `:__unreachable__`); the trampoline `:e_dead___unreachable__` also
        # ends in `__unreachable__`, so an exact match is the unambiguous pick.
        sink = only(bb for bb in prog.blocks if bb.label === :__unreachable__)
        @test sink.entry isa _BV.UnconditionalEntry
        @test length(sink.instructions) == 1
        @test sink.instructions[1] isa _BV.UnreachableHalt
        @test sink.exit isa _BV.EndInstruction

        for x in (Int64(5), Int64(-3), Int64(42))   # all != 0 ⇒ live arm.
            s = initial_state(prog, Dict(:x => x))
            run!(s, prog)
            @test is_halted(s)                        # normal :halted exit.
            @test s.current.status === :halted
            @test result(s)[:a] == _utzc_oracle(x)    # ORACLE (known value).

            unrun!(s, prog)
            @test s.step_count == 0                    # P0.6 reset.
            @test isempty(s.history)                   # P0.6 drained.
            @test s.current == s.initial               # P0.6 reversed.
        end

        # Per-step inverse (mid-instruction reversal bugs unrun! can mask —
        # the M8.2 blind-spot discipline), under both L3 and L2 regimes.
        @test per_step_inverse_check(prog, Dict(:x => Int64(5));
            checkpoint_interval = 1, label = "utzc/not-taken/L3") === nothing
        @test per_step_inverse_check(prog, Dict(:x => Int64(5));
            checkpoint_interval = 1,
            must_cache_set = _BV.compute_must_cache(prog),
            label = "utzc/not-taken/L2") === nothing
    end

    # =================================================================
    # 2. TAKEN — the dead edge fires; the sink halts LOUD with :error.
    # =================================================================
    @testset "taken → halts loud (status=:error, distinct from :halted)" begin
        pir = _utzc_parsed_ir()
        prog = lower_vm(pir)

        # run! raises loudly, naming :__unreachable__ / status=:error (Rule 1).
        s = initial_state(prog, Dict(:x => Int64(0)))   # x==0 ⇒ dead arm taken.
        @test_throws ErrorException run!(s, prog)

        msg = ""
        try
            run!(initial_state(prog, Dict(:x => Int64(0))), prog)
        catch e
            msg = sprint(showerror, e)
        end
        @test occursin("__unreachable__", msg)
        @test occursin("status=:error", msg)

        # Driving step! to the sink by hand: the trap sets :error (NOT :halted),
        # so the sink is distinguishable from a normal EndInstruction halt.
        s2 = initial_state(prog, Dict(:x => Int64(0)))
        guard = 0
        while s2.current.status === :running && guard < 10_000
            step!(s2, prog)
            guard += 1
        end
        @test s2.current.status === :error   # the taken dead abort.
        @test !is_halted(s2)                  # :error is NOT :halted.
    end

    # =================================================================
    # 3. MULTI-FUNCTION — per-function `#`-qualified sinks never collide;
    #    the not-taken cross-function call returns correctly.
    # =================================================================
    @testset "multi-function → per-function sinks distinct, not-taken returns" begin
        # helper(y): if y<0 → :__unreachable__ else ret y.
        h_top = _BN.IRBasicBlock(:htop,
            _BN.IRInst[_BN.IRICmp(:hc, :slt, _BN.SSAOperand(:y),
                                  _BN.ConstOperand(0), 64)],
            _BN.IRBranch(_BN.SSAOperand(:hc), :hdead, :hlive))
        h_dead = _BN.IRBasicBlock(:hdead, _BN.IRInst[],
            _BN.IRBranch(nothing, :__unreachable__, nothing))
        h_live = _BN.IRBasicBlock(:hlive, _BN.IRInst[],
            _BN.IRRet(_BN.SSAOperand(:y), 64))
        helper_ir = _BN.ParsedIR(64, Tuple{Symbol,Int}[(:y, 64)],
                                 [h_top, h_dead, h_live], Int[64])

        # main(n): if n<0 → :__unreachable__ else r = helper(n); ret r.
        m_top = _BN.IRBasicBlock(:mtop,
            _BN.IRInst[_BN.IRICmp(:mc, :slt, _BN.SSAOperand(:n),
                                  _BN.ConstOperand(0), 64)],
            _BN.IRBranch(_BN.SSAOperand(:mc), :mdead, :mcall))
        m_dead = _BN.IRBasicBlock(:mdead, _BN.IRInst[],
            _BN.IRBranch(nothing, :__unreachable__, nothing))
        m_call = _BN.IRBasicBlock(:mcall,
            _BN.IRInst[_BN.IRCall(:r, :helper,
                                  _BN.IROperand[_BN.SSAOperand(:n)], Int[64], 64)],
            _BN.IRRet(_BN.SSAOperand(:r), 64))
        main_ir = _BN.ParsedIR(64, Tuple{Symbol,Int}[(:n, 64)],
                               [m_top, m_dead, m_call], Int[64])

        prog = lower_vm(Pair{Symbol,_BN.ParsedIR}[:main => main_ir,
                                                  :helper => helper_ir])

        # Two per-function sinks, `#`-qualified — distinct, no collision.
        sinks = sort([string(bb.label) for bb in prog.blocks
                      if endswith(string(bb.label), "#__unreachable__")])
        @test sinks == ["helper#__unreachable__", "main#__unreachable__"]
        @test length(sinks) == length(unique(sinks))

        # Not-taken: main(7) → helper(7) → 7 (both dead arms avoided).
        s = initial_state(prog, Dict(:n => Int64(7)))
        run!(s, prog)
        @test is_halted(s)
        @test result(s)[:r] == 7
        unrun!(s, prog)
        @test s.step_count == 0
        @test isempty(s.history)
        @test s.current == s.initial
    end
end
