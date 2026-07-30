# test/test_0fw7_dup_call_args.jl — bead `bennettvm-0fw7`: one call may pass
# the SAME caller SSA value in two argument positions.
#
# # The wall
#
# `CallEnter`'s inner constructor (`src/ir/call_transitions.jl`) carried
#
#     allunique(args) ||
#         error("CallEnter: duplicate arg names in ", args,
#               " (an SSA name cannot be moved into a callee twice).")
#
# so ANY lowering that emitted `g(x, x)` died at LOWERING time, before a
# single step ran:
#
#     LOWER FAILED: CallEnter: duplicate arg names in
#       [Symbol("new::Dict"), :value_phi, :value_phi]
#       (an SSA name cannot be moved into a callee twice).
#
# The trigger is not exotic. `d[i] = i` lowers to `setindex!(d, i, i)` — the
# value and the key are the same SSA name — so EVERY `for i in 1:N; d[i] = i;
# end` hit the wall, and so does a bare straight-line `f(x) = g(x, x)`. The IR
# is ordinary and verifier-legal; nothing about it is loop-specific. (The
# 14-insert `Dict` fixtures in `test_rnhv_phi_multiuse.jl` are written out
# straight-line for exactly this reason — see the corrected note there.)
#
# # Why the guard was wrong (ADR 0023)
#
# The message states the MOVE model of ADR 0019 §3 (Vieri 1995 p. 22: a call
# arg is READ AND CONSUMED out of the caller frame). Under a MOVE, naming one
# value twice really is ill-formed — you cannot consume it twice. But ADR 0019
# **Amendment A.1** (hostile-review-ratified 2026-06-10) already replaced the
# MOVE with a COPY, because LLVM SSA values are multi-use. Today
# `_handle_call_dispatch!` (`src/interpreter/Interpreter.jl`) only READS the
# caller's args
#
#     for a in instr.args ... push!(argv, caller[a]) end          # read-only
#     for (p, v) in zip(fe.params, argv) callee_locals[p] = v end # distinct keys
#
# and zips the values onto the callee's params, which `FunctionEntry` already
# forces to be distinct. Reading one key twice is harmless; the two params are
# different keys; nothing is erased. The guard outlived its semantics.
#
# It was also SELF-INCONSISTENT: a duplicate CONSTANT arg (`g(3, 3)`) passed,
# because `src/ir/ingest.jl` mints a fresh per-position `_callconst_*` name for
# every constant operand, while a duplicate SSA arg was rejected. Same program
# shape, opposite verdicts, decided by whether the front-end happened to have
# renamed.
#
# # The fix
#
# Remove `allunique(args)` from `CallEnter` (and, identically, from the
# superseded `CallInstruction` stub so the two do not diverge). Every OTHER
# structural check stays: duplicate targets, the target/arg overlap guard, the
# callee-shadow guards, the run-time closed-world callee resolution and the
# arity check. This mirrors ADR 0022's adjudication at the φ-edge — RELAX the
# over-strict transfer rule rather than teach the front-end to duplicate values
# around it.
#
# # What this file pins (Rule 4 — known values, never "didn't throw")
#
#   (1) UNIT WITNESS — a hand-built two-function `VMProgram` whose `CallEnter`
#       passes `[:y, :y]`. RED before the fix at CONSTRUCTION. Forward value vs
#       a closed-form oracle, both callee params observed bound to the one
#       caller value AND the caller's binding observed to survive (the COPY
#       statement), `unrun!` to the exact initial state with empty history,
#       under BOTH L2 (`compute_must_cache`) and L3 (empty must_cache), plus a
#       per-step inverse sweep.
#   (2) STRAIGHT-LINE e2e — `@noinline g(a,b) = 3a+b`, `f(x) = g(x,x)` through
#       `extract_parsed_ir_set_from_julia` → `lower_vm` → `run!`, value vs the
#       native Julia oracle, round-trip under L2 and L3, per-step inverse. The
#       lowered program is also asserted to CARRY a duplicate-arg `CallEnter`
#       (trajectory-independent), so the gate cannot go vacuous if the
#       front-end stops emitting the shape.
#   (3) FOR-LOOP `Dict` e2e at BOTH widths — the shape the bead was filed on:
#       `d = Dict{T,T}(); for i in 1:14; d[i] = i; end; d[a] = b; d[a]`, at
#       `T = Int8` and `T = Int64`, ≥2 (k,v) probes each against the native
#       oracle, `unrun!` to empty history + exact initial state under L2 and
#       L3. 14 inserts forces `Dict`'s `rehash!` GROW branch, so the gate
#       covers the grow path, not just the flat insert path.
#   (4) GUARD SURVIVORS — the relaxation is SURGICAL. Duplicate targets, the
#       target/arg overlap, both callee-shadow forms, the unknown-callee and
#       arity run-time checks, and every retained `CallInstruction` check all
#       still fail loud. These assertions are GREEN both before and after the
#       fix, which is what makes (1)–(3)'s RED attributable to the relaxed
#       guard rather than to the harness.
#
# # Mutation-proof (Rule 5)
#
# Written and run against unmodified `src/` FIRST: (1), (2), (3) and the two
# relaxation-specific assertions in (4') all RED with the exact
# `CallEnter: duplicate arg names in [...]` / `CallInstruction: duplicate arg
# names in [...]` message; (4)'s survivor set stayed GREEN throughout. Restoring
# `allunique(args)` reproduces that split. Forward results are checked against
# the IRREVERSIBLE native Julia oracle everywhere (the M8.2 lesson: a
# round-trip assertion alone is blind to a wrong FORWARD value — `unrun!` of a
# wrong computation is still a clean `unrun!`).
#
# # Ref
#   * `docs/adr/0023-callenter-duplicate-args.md` — the decision record, plus
#     its §"Amendment / follow-through (p3j2)": the SIBLING `t in args` guard
#     keeps its behaviour (unreachable shape ⇒ zero-false-positive tripwire);
#     only its MOVE-era rationale was rewritten. Do not read §(4) below as
#     merely deferring that question — it is settled.
#   * `docs/adr/0019-reversible-calls.md` Amendment A.1 — COPY args (the
#     semantics this guard contradicted), amended by 0023.
#   * `docs/adr/0022-phi-edge-binding.md` — the same relax-don't-duplicate
#     adjudication at the φ-edge.
#   * `src/ir/call_transitions.jl` — `CallEnter`.
#   * `src/interpreter/Interpreter.jl` — `_handle_call_dispatch!` (COPY).
#   * `src/ir/ingest.jl` — the `_callconst_*` per-position constant renaming
#     that made the old guard self-inconsistent.
#   * `test/test_rnhv_phi_multiuse.jl` — the sibling φ-edge gate / template.
#   * `test/test_a70z_dict64_roundtrip.jl` — the i64-`Dict` sibling.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known values), Rule 5 (mutation-
#     proof), Rule 11 (literate).

using Test
using BennettVM
import Bennett

const _BVd = BennettVM
const _Bd  = Bennett

# ---------------------------------------------------------------------
# Shared helpers (the `test_rnhv_phi_multiuse.jl` shapes)
# ---------------------------------------------------------------------

# The two history regimes every round-trip below is exercised under.
_0fw7_regimes(prog) = (("L2 (compute_must_cache)", _BVd.compute_must_cache(prog)),
                       ("L3 (empty must_cache)",   Set{Tuple{Symbol,Int}}()))

# The load-bearing invariant (CLAUDE.md P0.6 / Rule 4): forward to halt, check
# the value against a KNOWN-CORRECT oracle, then `unrun!` back to the EXACT
# initial state with an empty history and a zero step count.
function _0fw7_roundtrip(prog, inputs, readout, expected; mc, K = 64,
                         max_steps = 5_000_000)
    rs = _BVd.initial_state(prog, inputs)
    init = deepcopy(rs.current)
    _BVd.run!(rs, prog; max_steps = max_steps, checkpoint_interval = K,
              must_cache_set = mc)
    @test _BVd.is_halted(rs)
    @test _BVd.result(rs)[readout] == expected
    _BVd.unrun!(rs, prog; max_unsteps = max_steps)
    @test rs.current == init
    @test isempty(rs.history)
    @test rs.step_count == 0
    return nothing
end

# Per-step inverse over the whole trajectory (the M8.2 discipline, in the
# `test_a70z_dict64_roundtrip.jl` (e) shape): the AGGREGATE round-trip can mask
# a mid-trajectory inverse bug, so every intermediate pre-image is compared.
function _0fw7_per_step_inverse(prog, inputs; mc, K = 32, max_steps = 200_000)
    rs = _BVd.initial_state(prog, inputs)
    init = deepcopy(rs.current)
    snaps = _BVd.IState[]
    while !_BVd.is_halted(rs)
        _BVd.step!(rs, prog; checkpoint_interval = K, must_cache_set = mc)
        push!(snaps, deepcopy(rs.current))
        length(snaps) <= max_steps ||
            error("0fw7 per-step sweep exceeded ", max_steps, " steps")
    end
    @test !isempty(snaps)
    ok = true
    while rs.step_count > 0
        _BVd.unstep!(rs, prog)
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

"""
    _0fw7_dup_call_sites(prog) -> Vector{CallEnter}

Every `CallEnter` in the lowered program that names one SSA value in two or
more argument positions. Trajectory-INDEPENDENT (a purely structural scan), so
it keeps discriminating even if the front-end changes which edge executes: if
this ever returns empty for a fixture below, that fixture has stopped testing
the bead and the assertion says so instead of passing silently.
"""
_0fw7_dup_call_sites(prog) =
    [i for b in prog.blocks for i in b.instructions
     if i isa _BVd.CallEnter && !allunique(i.args)]

# The entry body's single return SSA name (the test_a70z / test_rnhv idiom;
# `result(rs)` keys by SSA name).
function _0fw7_return_symbol(prog, entry::Symbol)
    for b in prog.blocks
        if b.exit isa _BVd.EndInstruction && b.exit.label === entry &&
           !isempty(b.exit.returns)
            return b.exit.returns[1]
        end
    end
    error("no EndInstruction with returns for entry :$entry")
end

# Extraction of a closed-world set is the expensive step; memoise it per
# fixture so a LOWERING failure (the RED state) does not force a re-extract in
# the next testset, and so the green run pays for each set exactly once.
const _0FW7_SETS = Dict{Symbol,Any}()
_0fw7_set(key::Symbol, f, T) =
    get!(() -> _Bd.extract_parsed_ir_set_from_julia(f, T; ptr_cells = true),
         _0FW7_SETS, key)

function _0fw7_build(key::Symbol, f, T)
    set  = _0fw7_set(key, f, T)
    prog = _BVd.lower_vm(set; entry = first(set).first)
    entry_vm = _BVd._vm_funcname(first(set).first)
    return (set = set, prog = prog,
            ret = _0fw7_return_symbol(prog, entry_vm),
            args = first(set).second.args)
end

# ---------------------------------------------------------------------
# (1) UNIT WITNESS — hand-built `CallEnter(:g, [:y, :y], [:r])`
# ---------------------------------------------------------------------
#
#   main#top: Begin(:main,[:n]); [ y := n + 1 ; call g(y, y) -> r ]; end(:main,[r])
#   g#top:    Begin(:g,[:a,:b]); [ t := a * 3 ; s := t + b ];        end(:g,[s])
#
# Oracle: `y = n+1`, `s = 3y + y = 4(n+1)`.
#
# `:a` and `:b` are used ASYMMETRICALLY (`3a + b`) so that a mis-zip which
# bound the two params in the wrong order, or bound only one of them, cannot
# accidentally reproduce the oracle for every `n`. The callee's `End` doubles
# as its return at depth > 1 — the `test_call_roundtrip.jl` `_void_module`
# idiom.

_0fw7_unit_oracle(n::Int64) = 4 * (n + 1)

function _0fw7_unit_program()
    main = _BVd.BasicBlock(Symbol("main#top"),
        _BVd.BeginInstruction(:main, Symbol[:n]),
        _BVd.Instruction[_BVd.Define(:y, :n, :add, Int64(1)),
                         _BVd.CallEnter(:g, Symbol[:y, :y], Symbol[:r])],
        _BVd.EndInstruction(:main, Symbol[:r]))
    g = _BVd.BasicBlock(Symbol("g#top"),
        _BVd.BeginInstruction(:g, Symbol[:a, :b]),
        _BVd.Instruction[_BVd.Define(:t, :a, :mul, Int64(3)),
                         _BVd.Define(:s, :t, :add, :b)],
        _BVd.EndInstruction(:g, Symbol[:s]))
    blocks = [main, g]
    fns = Dict(:main => _BVd.FunctionEntry(:main, Symbol("main#top"),
                                           Symbol[:n], Symbol[:r]),
               :g    => _BVd.FunctionEntry(:g, Symbol("g#top"),
                                           Symbol[:a, :b], Symbol[:s]))
    return _BVd.VMProgram(blocks, _BVd.LabelTable(blocks), Symbol("main#top"),
                          Int[64], Int[64], fns, :main)
end

@testset "(1) 0fw7 — hand-built CallEnter with duplicate args" begin
    # The construction itself is the unit-level witness: RED before the fix.
    ce = _BVd.CallEnter(:g, Symbol[:y, :y], Symbol[:r])
    @test ce isa _BVd.CallEnter
    @test ce.args == Symbol[:y, :y]
    @test ce.targets == Symbol[:r]

    prog = _0fw7_unit_program()
    @test length(_0fw7_dup_call_sites(prog)) == 1

    for (label, mc) in _0fw7_regimes(prog)
        for n in Int64[-7, -1, 0, 1, 42, 1000]
            # :r = 4(n+1).  ($label)
            _0fw7_roundtrip(prog, Dict(:n => n), :r, _0fw7_unit_oracle(n);
                            mc = mc, K = 8, max_steps = 1_000)
        end
        _0fw7_per_step_inverse(prog, Dict(:n => Int64(9)); mc = mc, K = 4,
                               max_steps = 1_000)
    end

    # THE COPY STATEMENT, observed mid-trajectory: step until the callee frame
    # is on the stack, then assert BOTH params carry the one caller value AND
    # the caller's own binding SURVIVED the call (a MOVE would have deleted it,
    # and a single-bind zip would leave one param missing).
    rs = _BVd.initial_state(prog, Dict(:n => Int64(41)))
    mc = _BVd.compute_must_cache(prog)
    nstep = 0
    while !_BVd.is_halted(rs) && length(rs.current.frames) < 2
        _BVd.step!(rs, prog; checkpoint_interval = 8, must_cache_set = mc)
        nstep += 1
        nstep <= 100 || error("0fw7: callee frame never pushed")
    end
    @test length(rs.current.frames) == 2                 # the callee is active
    callee = _BVd.active_locals(rs.current)
    @test callee[:a] == 42
    @test callee[:b] == 42                               # BOTH positions bound
    @test rs.current.frames[1].locals[:y] == 42          # caller KEPT its value
end

# ---------------------------------------------------------------------
# (2) STRAIGHT-LINE e2e — `f(x) = g(x, x)`, real Julia → LLVM → VM
# ---------------------------------------------------------------------
#
# The minimal REAL trigger: no loop, no `Dict`, no memory. If this passes and
# the loop fixtures below fail, the cause is not duplicate call args.

@noinline _0fw7_g(a::Int64, b::Int64) = 3 * a + b
_0fw7_f(x::Int64) = _0fw7_g(x, x)

# A distinct binding from the program under test, so neither can be silently
# folded into the other (the `test_a70z` oracle convention).
_0fw7_f_oracle(x::Int64) = 3 * x + x

@testset "(2) 0fw7 — straight-line g(x,x) end-to-end + round-trip" begin
    built = _0fw7_build(:sl, _0fw7_f, Tuple{Int64})

    # `@noinline` really kept `_0fw7_g` a separate closed-world body, and the
    # lowered program really carries the duplicate-arg call (non-vacuity: if
    # the front-end ever inlines or renames, this fails instead of going
    # quietly green).
    @test length(built.set) >= 2
    @test any(p -> startswith(String(p.first), "_0fw7_g"), built.set)
    dups = _0fw7_dup_call_sites(built.prog)
    @test !isempty(dups)
    @test any(c -> length(c.args) == 2 && c.args[1] === c.args[2], dups)

    for (label, mc) in _0fw7_regimes(built.prog)
        for x in Int64[-7, -1, 0, 1, 42, 1000]
            inputs = Dict(n => v for ((n, _w), v) in zip(built.args, (x,)))
            # ($label)
            _0fw7_roundtrip(built.prog, inputs, built.ret, _0fw7_f_oracle(x);
                            mc = mc, K = 16, max_steps = 100_000)
        end
        _0fw7_per_step_inverse(built.prog,
                               Dict(n => v for ((n, _w), v) in
                                    zip(built.args, (Int64(42),)));
                               mc = mc, K = 4)
    end
end

# ---------------------------------------------------------------------
# (3) FOR-LOOP `Dict` e2e — the shape the bead was filed on
# ---------------------------------------------------------------------
#
# `d[i] = i` lowers to `setindex!(d, i, i)`: ONE call, the same SSA value in
# the key and the value position. 14 inserts is the threshold at which `Dict`'s
# load factor forces the `rehash!` GROW branch, so this also covers the grow
# path (the `test_rnhv_phi_multiuse.jl` §(4) threshold, reached here through
# the loop the sibling had to avoid).

function _0fw7_fdictloop_i8(a::Int8, b::Int8)
    d = Dict{Int8,Int8}()
    for i in Int8(1):Int8(14)
        d[i] = i
    end
    d[a] = b
    return d[a]
end

function _0fw7_fdictloop_i64(a::Int64, b::Int64)
    d = Dict{Int64,Int64}()
    for i in 1:14
        d[i] = i
    end
    d[a] = b
    return d[a]
end

# Separate bindings, used as the irreversible native oracle (Rule 4).
function _0fw7_oracle_i8(a::Int8, b::Int8)
    d = Dict{Int8,Int8}()
    for i in Int8(1):Int8(14)
        d[i] = i
    end
    d[a] = b
    return d[a]
end

function _0fw7_oracle_i64(a::Int64, b::Int64)
    d = Dict{Int64,Int64}()
    for i in 1:14
        d[i] = i
    end
    d[a] = b
    return d[a]
end

@testset "(3) 0fw7 — for-loop 14-insert Dict, i8 and i64, e2e + round-trip" begin
    for (name, key, f, T, oracle, probes) in
        (("Dict{Int8,Int8}", :d8, _0fw7_fdictloop_i8, Tuple{Int8,Int8},
          _0fw7_oracle_i8,
          Tuple{Int8,Int8}[(Int8(3), Int8(77)), (Int8(20), Int8(-5))]),
         ("Dict{Int64,Int64}", :d64, _0fw7_fdictloop_i64, Tuple{Int64,Int64},
          _0fw7_oracle_i64,
          Tuple{Int64,Int64}[(Int64(3), Int64(77)), (Int64(20), Int64(-5))]))

        built = _0fw7_build(key, f, T)

        # The closed-world set really is the 4-body `Dict` set including the
        # GROW path, and the lowered program really carries the duplicate-arg
        # `setindex!(d, i, i)` call. ($name)
        @test length(built.set) >= 4
        names = String[String(p.first) for p in built.set]
        @test any(n -> startswith(n, "rehash!"), names)
        @test any(n -> startswith(n, "setindex!"), names)
        @test length(built.prog.blocks) > 100
        @test !isempty(_0fw7_dup_call_sites(built.prog))

        for (label, mc) in _0fw7_regimes(built.prog)
            for (a, b) in probes
                inputs = Dict(n => v for ((n, _w), v) in zip(built.args, (a, b)))
                # Golden master: the native Julia function on the same input.
                # ($name, $label)
                _0fw7_roundtrip(built.prog, inputs, built.ret,
                                Int64(oracle(a, b)); mc = mc, K = 64)
            end
        end

        # NON-VACUITY: the trajectory is thousands of steps and passes through
        # the `rehash!` activation — a program that halted early would
        # round-trip trivially. ($name)
        inputs = Dict(n => v for ((n, _w), v) in zip(built.args, probes[1]))
        rs = _BVd.initial_state(built.prog, inputs)
        _BVd.run!(rs, built.prog; max_steps = 5_000_000, checkpoint_interval = 64,
                  must_cache_set = _BVd.compute_must_cache(built.prog))
        @test _BVd.is_halted(rs)
        @test rs.step_count > 5_000
        @test haskey(built.prog.functions, :rehash!)
    end
end

# ---------------------------------------------------------------------
# (4) GUARD SURVIVORS — the relaxation is SURGICAL
# ---------------------------------------------------------------------
#
# GREEN both before and after the fix. Without this set, (1)–(3)'s RED could be
# blamed on the harness, and a future agent deleting the whole constructor
# would still see a green file.

@testset "(4) 0fw7 — every OTHER CallEnter/CallInstruction guard still fires" begin
    # --- CallEnter structural checks -----------------------------------
    # duplicate TARGETS — an SSA name cannot receive two returns.
    @test_throws ErrorException _BVd.CallEnter(:g, Symbol[:a, :b], Symbol[:t, :t])
    # target/arg OVERLAP. 0fw7 did NOT touch its behaviour, and neither did the
    # `bennettvm-p3j2` follow-up (2026-07-30) that adjudicated it: the guard is
    # a Rule-1 TRIPWIRE, not a semantic necessity. Under COPY-args (A.1) +
    # OVERWRITE-targets-with-`target_olds` (A.2) an overlapping call would
    # round-trip — but SSA dominance forbids a call being its own operand, so
    # the shape is UNREACHABLE from LLVM-derived IR (135/135 raw call sites,
    # 105/105 extracted `IRCall`s in the corpus sweep). Zero false positives ⇒
    # keep it for hand-built programs. Only its MOVE-era error text changed.
    # See ADR 0023 §"Amendment / follow-through (p3j2)".
    @test_throws ErrorException _BVd.CallEnter(:g, Symbol[:a], Symbol[:a])
    # ... and it still fires when the arg list is ALSO duplicated — i.e. the
    # relaxation did not swallow the overlap case as collateral.
    @test_throws ErrorException _BVd.CallEnter(:g, Symbol[:a, :a], Symbol[:a])
    # callee shadows an arg / a target — dispatch ambiguity.
    @test_throws ErrorException _BVd.CallEnter(:a, Symbol[:a], Symbol[:r])
    @test_throws ErrorException _BVd.CallEnter(:r, Symbol[:a], Symbol[:r])

    # --- CallEnter run-time checks (ADR 0019 §6a/§6b) -------------------
    incb = _BVd.BasicBlock(Symbol("inc#top"),
        _BVd.BeginInstruction(:inc, Symbol[:x]),
        _BVd.Instruction[_BVd.Define(:r, :x, :add, Int64(1))],
        _BVd.EndInstruction(:inc, Symbol[:r]))

    fns_ar = Dict(:main => _BVd.FunctionEntry(:main, Symbol("main#top"),
                                              Symbol[:n, :m], Symbol[:c]),
                  :inc  => _BVd.FunctionEntry(:inc, Symbol("inc#top"),
                                              Symbol[:x], Symbol[:r]))

    # (a) unknown callee — closed-world miss.
    unk = _BVd.BasicBlock(Symbol("main#top"),
        _BVd.BeginInstruction(:main, Symbol[:n]),
        _BVd.Instruction[_BVd.CallEnter(:nope, Symbol[:n], Symbol[:c])],
        _BVd.EndInstruction(:main, Symbol[:c]))
    prog_unk = _BVd.VMProgram([unk], _BVd.LabelTable([unk]), Symbol("main#top"),
        Int[64], Int[64],
        Dict(:main => _BVd.FunctionEntry(:main, Symbol("main#top"),
                                         Symbol[:n], Symbol[:c])), :main)
    @test_throws ErrorException _BVd.run!(
        _BVd.initial_state(prog_unk, Dict(:n => Int64(1))), prog_unk)

    # (b) arity mismatch (args ↔ params).
    badmain = _BVd.BasicBlock(Symbol("main#top"),
        _BVd.BeginInstruction(:main, Symbol[:n, :m]),
        _BVd.Instruction[_BVd.CallEnter(:inc, Symbol[:n, :m], Symbol[:c])],
        _BVd.EndInstruction(:main, Symbol[:c]))
    prog_ar = _BVd.VMProgram([badmain, incb], _BVd.LabelTable([badmain, incb]),
        Symbol("main#top"), Int[64, 64], Int[64], fns_ar, :main)
    @test_throws ErrorException _BVd.run!(
        _BVd.initial_state(prog_ar, Dict(:n => Int64(1), :m => Int64(2))), prog_ar)

    # (c) an arg absent from the caller frame (ADR 0019 §6f).
    absent = _BVd.BasicBlock(Symbol("main#top"),
        _BVd.BeginInstruction(:main, Symbol[:n]),
        _BVd.Instruction[_BVd.CallEnter(:inc, Symbol[:ghost], Symbol[:c])],
        _BVd.EndInstruction(:main, Symbol[:c]))
    prog_ab = _BVd.VMProgram([absent, incb], _BVd.LabelTable([absent, incb]),
        Symbol("main#top"), Int[64], Int[64],
        Dict(:main => _BVd.FunctionEntry(:main, Symbol("main#top"),
                                         Symbol[:n], Symbol[:c]),
             :inc  => _BVd.FunctionEntry(:inc, Symbol("inc#top"),
                                         Symbol[:x], Symbol[:r])), :main)
    @test_throws ErrorException _BVd.run!(
        _BVd.initial_state(prog_ab, Dict(:n => Int64(1))), prog_ab)

    # --- CallInstruction (the superseded stub) keeps its OTHER checks ---
    # It is dead on the lowering path (only `reverse()` in `basic_block.jl` and
    # tests construct it), but it is relaxed in LOCKSTEP with `CallEnter` so a
    # reader cannot find two different answers to the same question.
    @test_throws ErrorException _BVd.CallInstruction([:x], :foo, [:y], :bogus)
    @test_throws ErrorException _BVd.CallInstruction([:x, :x], :foo, [:y], :call)
    @test_throws ErrorException _BVd.CallInstruction([:x, :y], :foo, [:y, :z], :call)
    @test_throws ErrorException _BVd.CallInstruction([:foo], :foo, [:y], :call)
    @test_throws ErrorException _BVd.CallInstruction([:x], :foo, [:foo], :call)
end

# ---------------------------------------------------------------------
# (4') THE RELAXATION ITSELF — RED before the fix, GREEN after
# ---------------------------------------------------------------------
#
# Kept apart from (4) precisely so the mutation-proof split is legible: (4) is
# the invariant set, (4') is the delta.

@testset "(4') 0fw7 — duplicate ARGS are accepted, by BOTH constructors" begin
    ce = _BVd.CallEnter(:g, Symbol[:p, :p, :q], Symbol[:r, :s])
    @test ce.args == Symbol[:p, :p, :q]
    @test ce.callee === :g
    @test ce.targets == Symbol[:r, :s]

    ci = _BVd.CallInstruction([:x], :foo, [:y, :y], :call)
    @test ci.args == [:y, :y]
    @test ci.direction === :call

    # The overlap guard's MESSAGE, not merely its exception type: after the
    # relaxation a `[:a, :a]` / `[:a]` call must be rejected for OVERLAP, not
    # for duplication. (Before the fix this reads "duplicate arg names".)
    # `"appears in BOTH"` is the FACTUAL half of that message and survives the
    # p3j2 rationale rewrite by design — the clause that changed is the stale
    # MOVE-era explanation that followed it.
    err = try
        _BVd.CallEnter(:g, Symbol[:a, :a], Symbol[:a])
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("appears in BOTH", err.msg)

    # A duplicated arg list is now WELL-FORMED, so the RUN-TIME arity check is
    # what must reject 2 duplicate args into a 1-param callee — and it does.
    # (Before the fix the constructor rejected it first, so this asserted
    # nothing about arity.)
    incb = _BVd.BasicBlock(Symbol("inc#top"),
        _BVd.BeginInstruction(:inc, Symbol[:x]),
        _BVd.Instruction[_BVd.Define(:r, :x, :add, Int64(1))],
        _BVd.EndInstruction(:inc, Symbol[:r]))
    dupmain = _BVd.BasicBlock(Symbol("main#top"),
        _BVd.BeginInstruction(:main, Symbol[:n]),
        _BVd.Instruction[_BVd.CallEnter(:inc, Symbol[:n, :n], Symbol[:c])],
        _BVd.EndInstruction(:main, Symbol[:c]))
    prog_dup = _BVd.VMProgram([dupmain, incb], _BVd.LabelTable([dupmain, incb]),
        Symbol("main#top"), Int[64], Int[64],
        Dict(:main => _BVd.FunctionEntry(:main, Symbol("main#top"),
                                         Symbol[:n], Symbol[:c]),
             :inc  => _BVd.FunctionEntry(:inc, Symbol("inc#top"),
                                         Symbol[:x], Symbol[:r])), :main)
    @test_throws ErrorException _BVd.run!(
        _BVd.initial_state(prog_dup, Dict(:n => Int64(1))), prog_dup)
end
