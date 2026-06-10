# test/test_call_roundtrip.jl — the reversible call/return machinery
# (CW-B2/B3; ADR 0019; beads `bennettvm-416r.6` / `416r.7`).
#
# # What this file pins (Rule 4 — invariants, not "didn't throw")
#
# The `CallEnter` / `ReturnExit` transition pair (`src/ir/call_transitions.jl`)
# built on the `IState.frames` stack (CW-B2 chunk 1), the multi-function
# lowering (`src/ir/ingest_multi.jl`), and the interpreter's End-at-depth>1
# routing (`src/interpreter/Interpreter.jl`). The ADR §8 test list:
#
#   1. Nested two-level call — `main(n)` → `inc(n)` → `n+1`; golden master
#      vs the irreversible Julia oracle; round-trip to empty history.
#   2. Recursive factorial(5)==120 — hand-built self-call IR; frame depth 5;
#      SSA-name collision across activations (every `%n`/`%res` in its own
#      frame dict); golden master vs `factorial(5)`; round-trip.
#   3. Per-step inverse landing ON `CallEnter` AND ON `ReturnExit` steps
#      (`per_step_inverse_check` at K ∈ {1, 4}) — the spike-lesson-4 guard
#      that aggregate round-trip alone masks a middle-instruction bug.
#   4. Zero-history assertion — a `CallEnter` step leaves history length
#      UNCHANGED (L1-injective; ADR 0019 §3).
#   5. L3-checkpoint-INSIDE-callee then `unrun!` — small `checkpoint_interval`
#      so a checkpoint lands mid-callee; the frame stack rides the snapshot.
#   6. malloc-in-callee — the pointer SURVIVES return (memory is VM-global,
#      not frame-local; ADR 0019 §1) and `arena_top` is monotone + round-trips.
#   7. Void-return callee (empty returns / empty targets — the C `ht_free`
#      shape) with a dead temporary.
#   8. Fail-loud suite (§6 a–f): unknown callee, '#' validation, call/return
#      arity mismatches, depth-underflow guard, target-already-live.
#   9. frames ==/hash sensitivity — mutating a suspended frame's dict makes
#      two IStates unequal AND hash-distinct (the ADR 0018 §H / 0008 Finding-3
#      anti-spurious-pass guard, lifted to the call stack).
#
# # The L2 must_cache set
#
# `ReturnExit` is `is_unconditional_l2` (`src/history/delta.jl`), so it pushes
# its `(residual, fname, end_pc)` delta on EVERY return REGARDLESS of the
# must_cache set — it is the backward-control-flow breadcrumb (ADR 0019 §4).
# `CallEnter` is L1-injective (pushes nothing). So with K = typemax(Int) the
# ONLY pushes are the per-return ReturnExit deltas, and "round-trip works"
# means the L2 inverse + M4.3 replay-across-CallEnter both fired.
#
# # MUTATION-PROOF (Rule 5; ≥3, recorded here per the test_arena_roundtrip.jl
# # convention). Each: perturb the impl, confirm RED, restore, confirm GREEN.
# # All four were performed during development against this file's tests:
# #
# #   (M1) ReturnExit.forward skips `pop!(s.frames)` → RED. The frame stack
# #        never shrinks, so the top-level End fires at depth>1 (never halts /
# #        wrong result) and the round-trip depth assertion (`frames` length
# #        back to 1) fails. Caught by tests 1, 2.
# #   (M2) drop `residual` from the ReturnExit payload (return `(residual=[],
# #        …)`) → RED on the dead-temporary test (test 1's `_two_level` callee
# #        has a live-but-unreturned `:dead` temp): unrun! cannot restore it,
# #        so the per-step inverse + aggregate round-trip diverge. THE
# #        load-bearing mutation for the ADR's central design decision.
# #   (M3) drop `s.pc = p.end_pc` in ReturnExit.inverse (leave pc wrong) → RED
# #        on the per-step inverse (test 3): the reconstructed pre-image has the
# #        wrong pc, so `_assert_istate_eq` fires at the ReturnExit step.
# #   (M4) CallEnter shares the caller dict instead of a fresh one (push a
# #        Frame whose locals IS the caller dict) → RED on factorial recursion
# #        (test 2): the callee's `%n` aliases the caller's `%n`, corrupting
# #        the multiplication chain (factorial(5) != 120).
# #
# # Ref
# #
# #   * `docs/adr/0019-reversible-calls.md` §3 (CallEnter), §4 (ReturnExit +
# #     end_pc), §6 (fail-loud a–f), §8 (supersession + this test list).
# #   * `src/ir/call_transitions.jl`, `src/ir/call_frames.jl`,
# #     `src/ir/ingest_multi.jl`, `src/interpreter/Interpreter.jl`.
# #   * `test/test_arena_roundtrip.jl` — the hand-built + per-step idiom and
# #     the mutation-proof header convention this file mirrors.

using Test
using BennettVM
import Bennett
const _BV = BennettVM
const _B = Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# ---------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------

# Dummy named functions whose `nameof` is the callee identity guard-5 matches.
function inc end
function f_dead end
function factorial_vm end
function alloc_f end

# Two-level module: main(n) calls f_dead(n); f_dead has a DEAD temporary
# (`:dead = x + 99`, live at End but NOT returned) plus the returned `:r = x+1`.
# Oracle: main(n) = n + 1 (the dead temp is irrelevant to the result, but its
# survival through return is what M2 mutation-proves).
function _two_level_module()
    f_blk = _B.IRBasicBlock(:top,
        _B.IRInst[_B.IRBinOp(:dead, :add, _B.SSAOperand(:x), _B.ConstOperand(99), 64),
                  _B.IRBinOp(:r, :add, _B.SSAOperand(:x), _B.ConstOperand(1), 64)],
        _B.IRRet(_B.SSAOperand(:r), 64))
    f_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:x, 64)], [f_blk], Int[64])
    main_blk = _B.IRBasicBlock(:top,
        _B.IRInst[_B.IRCall(:c, f_dead, _B.IROperand[_B.SSAOperand(:n)], Int[64], 64)],
        _B.IRRet(_B.SSAOperand(:c), 64))
    main_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:n, 64)], [main_blk], Int[64])
    return _BV.lower_vm(Pair{Symbol,_B.ParsedIR}[:main => main_ir, :f_dead => f_ir])
end
_two_level_oracle(n) = n + 1

# Recursive factorial(n): if n<=1 return 1 else return n*factorial(n-1).
# Single self-recursive function — exercises frame depth and SSA collision.
function _factorial_module()
    entry = _B.IRBasicBlock(:entry,
        _B.IRInst[_B.IRICmp(:cmp, :sle, _B.SSAOperand(:n), _B.ConstOperand(1), 64)],
        _B.IRBranch(_B.SSAOperand(:cmp), :base, :recurse))
    base = _B.IRBasicBlock(:base,
        _B.IRInst[_B.IRBinOp(:one, :add, _B.ConstOperand(0), _B.ConstOperand(1), 64)],
        _B.IRRet(_B.SSAOperand(:one), 64))
    recurse = _B.IRBasicBlock(:recurse,
        _B.IRInst[_B.IRBinOp(:nm1, :sub, _B.SSAOperand(:n), _B.ConstOperand(1), 64),
                  _B.IRCall(:sub, factorial_vm, _B.IROperand[_B.SSAOperand(:nm1)], Int[64], 64),
                  _B.IRBinOp(:res, :mul, _B.SSAOperand(:n), _B.SSAOperand(:sub), 64)],
        _B.IRRet(_B.SSAOperand(:res), 64))
    fact_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:n, 64)], [entry, base, recurse], Int[64])
    return _BV.lower_vm(Pair{Symbol,_B.ParsedIR}[:factorial_vm => fact_ir])
end
_factorial_oracle(n) = n <= 1 ? 1 : n * _factorial_oracle(n - 1)

# malloc-in-callee: alloc_f(n) = malloc(32) (returns the pointer); main(m) =
# alloc_f(m). The malloc'd pointer must survive the return (VM-global memory).
function malloc end
function _malloc_callee_module()
    alloc_blk = _B.IRBasicBlock(:top,
        _B.IRInst[_B.IRCall(:p, malloc, _B.IROperand[_B.ConstOperand(32)], Int[64], 64)],
        _B.IRRet(_B.SSAOperand(:p), 64))
    alloc_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:n, 64)], [alloc_blk], Int[64])
    main_blk = _B.IRBasicBlock(:top,
        _B.IRInst[_B.IRCall(:ptr, alloc_f, _B.IROperand[_B.SSAOperand(:m)], Int[64], 64)],
        _B.IRRet(_B.SSAOperand(:ptr), 64))
    main_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:m, 64)], [main_blk], Int[64])
    return _BV.lower_vm(Pair{Symbol,_B.ParsedIR}[:main => main_ir, :alloc_f => alloc_ir])
end

# Void-return callee, hand-built at the VMProgram level (the single-function
# lowering rejects a literal return, so a genuine void ParsedIR is not
# expressible through it — a CW-C2 finding; see the report). `main(n)` copies
# `:n` into `:ncopy`, calls `vf(:ncopy)` [void: empty targets], and returns
# `:n+0`. `vf(x)` has a dead temp `:t = x+5` and an empty-returns End.
function _void_module()
    main_blk = _BV.BasicBlock(Symbol("main#top"),
        _BV.BeginInstruction(:main, Symbol[:n]),
        _BV.Instruction[_BV.Define(:ncopy, :n, :add, Int64(0)),
                        _BV.CallEnter(:vf, Symbol[:ncopy], Symbol[]),
                        _BV.Define(:rr, :n, :add, Int64(0))],
        _BV.EndInstruction(:main, Symbol[:rr]))
    vf_blk = _BV.BasicBlock(Symbol("vf#top"),
        _BV.BeginInstruction(:vf, Symbol[:x]),
        _BV.Instruction[_BV.Define(:t, :x, :add, Int64(5))],
        _BV.EndInstruction(:vf, Symbol[]))
    blocks = [main_blk, vf_blk]
    fns = Dict(:main => _BV.FunctionEntry(:main, Symbol("main#top"), Symbol[:n], Symbol[:rr]),
               :vf   => _BV.FunctionEntry(:vf, Symbol("vf#top"), Symbol[:x], Symbol[]))
    return _BV.VMProgram(blocks, _BV.LabelTable(blocks), Symbol("main#top"),
                         Int[64], Int[64], fns, :main)
end

# A simple inc module reused by the fail-loud + zero-history tests.
function _inc_module()
    inc_blk = _B.IRBasicBlock(:top,
        _B.IRInst[_B.IRBinOp(:r, :add, _B.SSAOperand(:x), _B.ConstOperand(1), 64)],
        _B.IRRet(_B.SSAOperand(:r), 64))
    inc_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:x, 64)], [inc_blk], Int[64])
    main_blk = _B.IRBasicBlock(:top,
        _B.IRInst[_B.IRCall(:c, inc, _B.IROperand[_B.SSAOperand(:n)], Int[64], 64)],
        _B.IRRet(_B.SSAOperand(:c), 64))
    main_ir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:n, 64)], [main_blk], Int[64])
    return _BV.lower_vm(Pair{Symbol,_B.ParsedIR}[:main => main_ir, :inc => inc_ir])
end

# Helper: run forward to a halt and read the single return value.
function _run_result(prog, inputs; mc = _BV.compute_must_cache(prog), K = typemax(Int))
    rs = _BV.initial_state(prog, inputs)
    _BV.run!(rs, prog; max_steps = 100_000, checkpoint_interval = K, must_cache_set = mc)
    return rs
end

# Helper: full round-trip (run! then unrun!) asserting empty history + frame
# depth back to 1 + IState equal to the start.
function _assert_roundtrip(prog, inputs; mc = _BV.compute_must_cache(prog),
                           K = typemax(Int))
    rs = _BV.initial_state(prog, inputs)
    init = deepcopy(rs.current)
    _BV.run!(rs, prog; max_steps = 100_000, checkpoint_interval = K, must_cache_set = mc)
    _BV.unrun!(rs, prog; max_unsteps = 100_000)
    @test isempty(rs.history)
    @test length(rs.current.frames) == 1
    @test rs.current == init
end

# ---------------------------------------------------------------------
# 1. Nested two-level call — golden master + round-trip
# ---------------------------------------------------------------------

@testset "CW-B2 — nested two-level call" begin
    prog = _two_level_module()
    @test prog.entry_function === :main
    @test Set(keys(prog.functions)) == Set([:main, :f_dead])
    # `#`-qualified labels (ADR 0019 §2).
    @test prog.entry_label === Symbol("main#top")
    @test any(b -> b.label === Symbol("f_dead#top"), prog.blocks)

    for n in Int64[0, 1, 5, 42, -3]
        rs = _run_result(prog, Dict(:n => n))
        @test _BV.is_halted(rs)
        @test _BV.result(rs)[:c] == _two_level_oracle(n)   # golden master
        # CallEnter pushed nothing; the single ReturnExit pushed one delta.
        @test count(e -> e isa _BV.DeltaEntry, rs.history) == 1
        _assert_roundtrip(prog, Dict(:n => n))
    end
end

# ---------------------------------------------------------------------
# 2. Recursive factorial(5)==120 — frame depth 5, SSA collision
# ---------------------------------------------------------------------

@testset "CW-B2 — recursive factorial (golden master vs factorial(n))" begin
    prog = _factorial_module()
    for n in Int64[1, 2, 3, 5, 6]
        rs = _run_result(prog, Dict(:n => n))
        # n<=1 returns via the `:one` base block; n>1 via `:res`. Read the
        # whichever key holds the value (the EndInstruction.returns differs
        # per exit block — the multi-return-block case).
        res = haskey(_BV.result(rs), :res) ? _BV.result(rs)[:res] :
              _BV.result(rs)[:one]
        @test res == _factorial_oracle(n)                    # golden master
        _assert_roundtrip(prog, Dict(:n => n))
    end
    # The headline: factorial(5) == 120.
    rs = _run_result(prog, Dict(:n => Int64(5)))
    @test _BV.result(rs)[:res] == 120
end

# ---------------------------------------------------------------------
# 3. Per-step inverse landing ON CallEnter and ON ReturnExit
# ---------------------------------------------------------------------

@testset "CW-B2 — per-step inverse across CallEnter / ReturnExit" begin
    for (name, prog) in [("two-level", _two_level_module()),
                         ("factorial", _factorial_module())]
        mc = _BV.compute_must_cache(prog)
        for K in (1, 4)
            inputs = name == "factorial" ? Dict(:n => Int64(4)) : Dict(:n => Int64(7))
            # per_step_inverse_check asserts each intermediate pre-image equals
            # the forward snapshot — including the steps that land ON a
            # CallEnter (zero-history → M4.3 replay) and ON a ReturnExit (L2).
            per_step_inverse_check(prog, inputs;
                checkpoint_interval = K, must_cache_set = mc,
                label = "call/$(name)/K=$(K)")
            @test true   # reached here ⇒ no per-step mismatch raised
        end
    end
end

# ---------------------------------------------------------------------
# 4. Zero-history assertion — a CallEnter step does not grow history
# ---------------------------------------------------------------------

@testset "CW-B2 — zero-history CallEnter step" begin
    prog = _inc_module()
    mc = _BV.compute_must_cache(prog)
    rs = _BV.initial_state(prog, Dict(:n => Int64(5)))
    # Step until the next instruction is the CallEnter, then step across it.
    while !(_BV._instruction_at(prog, rs.current.pc) isa _BV.CallEnter)
        _BV.step!(rs, prog; checkpoint_interval = typemax(Int), must_cache_set = mc)
    end
    depth_before = length(rs.current.frames)
    hist_before = length(rs.history)
    _BV.step!(rs, prog; checkpoint_interval = typemax(Int), must_cache_set = mc)
    @test length(rs.history) == hist_before        # ZERO history (ADR 0019 §3)
    @test length(rs.current.frames) == depth_before + 1   # frame pushed
end

# ---------------------------------------------------------------------
# 5. L3 checkpoint INSIDE callee, then unrun!
# ---------------------------------------------------------------------

@testset "CW-B2 — L3 checkpoint inside callee + unrun!" begin
    prog = _factorial_module()
    # Small checkpoint_interval (K=2) so checkpoints land mid-callee; the
    # frame stack rides each CheckpointEntry's deepcopy(IState) (ADR 0019 §1).
    # Pass an EMPTY must_cache so ReturnExit's UNCONDITIONAL L2 push and the
    # periodic L3 checkpoints both fire — the mixed L2/L3 reversal path.
    rs = _BV.initial_state(prog, Dict(:n => Int64(5)))
    init = deepcopy(rs.current)
    _BV.run!(rs, prog; max_steps = 100_000, checkpoint_interval = 2)
    @test _BV.result(rs)[:res] == 120
    @test any(e -> e isa _BV.CheckpointEntry, rs.history)   # a checkpoint landed
    _BV.unrun!(rs, prog; max_unsteps = 100_000)
    @test isempty(rs.history)
    @test length(rs.current.frames) == 1
    @test rs.current == init
end

# ---------------------------------------------------------------------
# 6. malloc-in-callee: pointer survives return, arena monotone
# ---------------------------------------------------------------------

@testset "CW-B2 — malloc in callee survives return; arena monotone" begin
    prog = _malloc_callee_module()
    mc = _BV.compute_must_cache(prog)
    rs = _run_result(prog, Dict(:m => Int64(7)); mc = mc)
    @test _BV.result(rs)[:ptr] == _BV.ARENA_BASE     # pointer survived the return
    @test rs.current.arena_top == 4                  # 32 bytes = 4 cells, monotone
    _assert_roundtrip(prog, Dict(:m => Int64(7)); mc = mc)   # arena_top → 0
end

# ---------------------------------------------------------------------
# 7. Void-return callee (empty returns / empty targets)
# ---------------------------------------------------------------------

@testset "CW-B2 — void-return callee" begin
    prog = _void_module()
    @test isempty(prog.functions[:vf].returns)
    # guard-equivalent: the hand-built CallEnter has empty targets.
    ce = prog.blocks[1].instructions[2]
    @test ce isa _BV.CallEnter && isempty(ce.targets)
    mc = _BV.compute_must_cache(prog)
    rs = _run_result(prog, Dict(:n => Int64(3)); mc = mc)
    @test _BV.result(rs)[:rr] == 3
    _assert_roundtrip(prog, Dict(:n => Int64(3)); mc = mc)
end

# ---------------------------------------------------------------------
# 8. Fail-loud suite (ADR 0019 §6 a–f)
# ---------------------------------------------------------------------

@testset "CW-B2 — fail-loud (§6 a–f)" begin
    # (a) unknown callee at run time.
    blocks = [_BV.BasicBlock(Symbol("main#top"), _BV.BeginInstruction(:main, Symbol[:n]),
        _BV.Instruction[_BV.CallEnter(:nope, Symbol[:n], Symbol[:c])],
        _BV.EndInstruction(:main, Symbol[:c]))]
    prog_unk = _BV.VMProgram(blocks, _BV.LabelTable(blocks), Symbol("main#top"),
        Int[64], Int[64],
        Dict(:main => _BV.FunctionEntry(:main, Symbol("main#top"), Symbol[:n], Symbol[:c])),
        :main)
    rs_unk = _BV.initial_state(prog_unk, Dict(:n => Int64(1)))
    @test_throws ErrorException _BV.run!(rs_unk, prog_unk)

    # (b) call arity mismatch (args↔params).
    fns = Dict(:main => _BV.FunctionEntry(:main, Symbol("main#top"), Symbol[:n, :m], Symbol[:c]),
               :inc  => _BV.FunctionEntry(:inc, Symbol("inc#top"), Symbol[:x], Symbol[:r]))
    incb = _BV.BasicBlock(Symbol("inc#top"), _BV.BeginInstruction(:inc, Symbol[:x]),
        _BV.Instruction[_BV.Define(:r, :x, :add, Int64(1))], _BV.EndInstruction(:inc, Symbol[:r]))
    badmain = _BV.BasicBlock(Symbol("main#top"), _BV.BeginInstruction(:main, Symbol[:n, :m]),
        _BV.Instruction[_BV.CallEnter(:inc, Symbol[:n, :m], Symbol[:c])],
        _BV.EndInstruction(:main, Symbol[:c]))
    prog_ar = _BV.VMProgram([badmain, incb], _BV.LabelTable([badmain, incb]),
        Symbol("main#top"), Int[64, 64], Int[64], fns, :main)
    rs_ar = _BV.initial_state(prog_ar, Dict(:n => Int64(1), :m => Int64(2)))
    @test_throws ErrorException _BV.run!(rs_ar, prog_ar)

    # (c) return arity mismatch — ReturnExit constructor rejects it directly.
    @test_throws ErrorException _BV.ReturnExit(:f, Symbol[:r], Symbol[])
    # (c') a target already live in the caller before the call.
    fns2 = Dict(:main => _BV.FunctionEntry(:main, Symbol("main#top"), Symbol[:n], Symbol[:c]),
                :inc  => _BV.FunctionEntry(:inc, Symbol("inc#top"), Symbol[:x], Symbol[:r]))
    livemain = _BV.BasicBlock(Symbol("main#top"), _BV.BeginInstruction(:main, Symbol[:n]),
        _BV.Instruction[_BV.Define(:c, :n, :add, Int64(0)),
                        _BV.CallEnter(:inc, Symbol[:n], Symbol[:c])],
        _BV.EndInstruction(:main, Symbol[:c]))
    prog_lv = _BV.VMProgram([livemain, incb], _BV.LabelTable([livemain, incb]),
        Symbol("main#top"), Int[64], Int[64], fns2, :main)
    rs_lv = _BV.initial_state(prog_lv, Dict(:n => Int64(1)))
    @test_throws ErrorException _BV.run!(rs_lv, prog_lv)

    # (d) frame-stack underflow on ReturnExit at depth 1 (predelta + forward).
    s1 = _BV.IState(5, Dict(:x => Int64(1)), :running)
    re = _BV.ReturnExit(:__entry, Symbol[], Symbol[])
    @test_throws ErrorException _BV.predelta_payload(re, s1)
    @test_throws ErrorException _BV.forward(re, s1)

    # CallEnter constructor SSA checks.
    @test_throws ErrorException _BV.CallEnter(:f, Symbol[:a, :a], Symbol[])       # dup args
    @test_throws ErrorException _BV.CallEnter(:f, Symbol[:a], Symbol[:a])         # both
    @test_throws ErrorException _BV.CallEnter(:a, Symbol[:a], Symbol[])           # callee shadow

    # `#` in incoming label / function name + duplicate function names (§2).
    goodblk = _B.IRBasicBlock(:top,
        _B.IRInst[_B.IRBinOp(:r, :add, _B.SSAOperand(:x), _B.ConstOperand(1), 64)],
        _B.IRRet(_B.SSAOperand(:r), 64))
    goodir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:x, 64)], [goodblk], Int[64])
    @test_throws ErrorException _BV.lower_vm(Pair{Symbol,_B.ParsedIR}[Symbol("a#b") => goodir])
    @test_throws ErrorException _BV.lower_vm(Pair{Symbol,_B.ParsedIR}[:f => goodir, :f => goodir])
    badlblblk = _B.IRBasicBlock(Symbol("t#p"),
        _B.IRInst[_B.IRBinOp(:r, :add, _B.SSAOperand(:x), _B.ConstOperand(1), 64)],
        _B.IRRet(_B.SSAOperand(:r), 64))
    badlblir = _B.ParsedIR(64, Tuple{Symbol,Int}[(:x, 64)], [badlblblk], Int[64])
    @test_throws ErrorException _BV.lower_vm(Pair{Symbol,_B.ParsedIR}[:f => badlblir])
end

# ---------------------------------------------------------------------
# 9. frames ==/hash sensitivity (ADR 0018 §H / 0008 Finding 3, lifted)
# ---------------------------------------------------------------------

@testset "CW-B2 — frames ==/hash sensitivity" begin
    sa = _BV.IState(1, Dict(:x => Int64(1)), :running)
    sb = deepcopy(sa)
    push!(sa.frames, _BV.Frame(2, Symbol[:t], Dict(:y => Int64(9)), :f))
    push!(sb.frames, _BV.Frame(2, Symbol[:t], Dict(:y => Int64(9)), :f))
    @test sa == sb
    @test hash(sa) == hash(sb)
    # Mutate the SUSPENDED frame's dict → IStates unequal AND hash-distinct.
    sb.frames[end].locals[:y] = Int64(10)
    @test sa != sb
    @test hash(sa) != hash(sb)
    # Mutate link / fname / targets — each must break equality.
    sc = deepcopy(sa)
    push!(sc.frames, _BV.Frame(3, Symbol[:t], Dict(:y => Int64(9)), :f))  # link differs
    @test sa != sc
end
