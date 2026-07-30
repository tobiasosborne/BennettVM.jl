# test/test_rnhv_phi_multiuse.jl — bead `bennettvm-rnhv`: a φ-incoming with a
# use that OUTLIVES the edge must survive the edge.
#
# # The bug
#
# `_dispatch_to_block!` transfers a cross-block edge's `args` into the
# destination's `params`. Until 2026-07 that transfer was DESTRUCTIVE — it ran
# `delete!(locals, a)` for every arg — implementing Mogensen RSSA
# (`references/reversible-ir/mogensen-2016-rssa.pdf`) §4, p. 210, note 2:
#
#     "Uses of variables as parameters to labels in exit points also destroy
#      these variables."
#
# That rule presupposes RSSA's **parameterized blocks**: every value live
# across a boundary is threaded through the label parameter list, so an exit
# arg really is that value's last use in the block. BennettVM's register file
# is a flat `Dict{Symbol,Int64}` per FRAME; non-φ values cross blocks
# implicitly, by dict persistence, and never appear in any args/params list.
# The rule was imported without the precondition that grounds it.
#
# The LLVM shape that breaks is ordinary, verifier-legal SSA — a φ-incoming
# that has another use later in the loop body:
#
#     load133:  %__v327 = add %__v326, 1             ; preheader: initial probe
#     L117:     %value_phi135 = phi [ %__v327, %load133 ], [ ..., latch ]
#     L131:     %__v76 = sub %value_phi135, %__v327  ; probe DISTANCE — 2nd use
#
# `%__v327` was deleted on the `load133 → L117` edge and the legitimate later
# read in `L131` died with a bare `KeyError`. Julia emits this for EVERY loop
# whose preheader value is re-read in the body; it is not Dict-specific.
#
# RED evidence at `2efd6bc` (the commit this file was written against):
#
#     KeyError: key :__v327 not found
#     instruction: Define(:__v76, :value_phi135, :sub, :__v327, 64)
#     frames: [(:__entry), (:setindex!), (:rehash!)]     # step 4603 of ~10790
#
# The SSA name drifts between compiles — it is NEVER pinned by this file.
#
# # Why this file is not just a Dict test — the bug was LATENT
#
# A static scan of the LOWERED program finds the identical hazard shape in
# programs the suite already asserts GREEN: the ONE-insert `Dict{Int8,Int8}`
# and `Dict{Int64,Int64}` fixtures (32 hazards each), plus collatz, matrix_tri
# and matrix_sum (2 each). Fourteen inserts merely make the `rehash!` grow
# branch REACHABLE. A test that only ran the 14-insert Dict would therefore be
# trajectory-dependent: it would pass again the moment the front-end changed
# which edge executes. §(5) below adds a trajectory-INDEPENDENT static scan so
# a cheap, already-green fixture guards the invariant directly.
#
# # The fix (ADR 0022)
#
# Remove the `delete!`; keep the two-phase capture-then-assign (still required
# for the permutation case) and the arity guard. `_rename_args_to_params!` is
# renamed `_bind_args_to_params!` so no reader carries the MOVE model forward.
# The no-harm argument: the destructive transfer `D` factors as `π ∘ N` with
# `N` the new bind and `π` the arg-key drop, so `D` injective ⟹ `N` injective;
# and every previously-passing program keeps a bit-identical trajectory,
# because the only difference is extra surviving keys and any instruction that
# read one of those would have thrown `KeyError` before.
#
# This is the SAME decision the project already ratified at the sibling
# boundary — ADR 0019 Amendment A.1 replaced `CallEnter`'s MOVE with a COPY
# for exactly this reason (`KeyError: :found`). `rnhv` is that bug at the
# φ-edge instead of the call edge.
#
# # What this file pins (Rule 4 — known values, never "didn't throw")
#
#   (1) HAND-BUILT STRAIGHT-LINE WITNESS — 2 blocks, no Bennett.jl, no LLVM,
#       no Dict, milliseconds. RED at `2efd6bc` with `KeyError: key :v not
#       found`. Forward value vs a closed-form oracle, then `unrun!` to the
#       exact initial state with EMPTY history, under BOTH L2 and L3.
#   (2) HAND-BUILT LOOP WITNESS — 4 blocks; a preheader value re-read on EVERY
#       iteration and once more after the loop. This is the actual `rehash!`
#       topology; the straight-line case alone does not cover it.
#   (3) CONTROL — the same straight-line shape with the second use REMOVED.
#       Green before AND after the fix, so (1)'s failure is attributable to
#       the multi-use hazard and not to the harness.
#   (4) ACCEPTANCE GATE — real 14-insert `Dict{Int8,Int8}` AND
#       `Dict{Int64,Int64}` through `extract_parsed_ir_set_from_julia(...;
#       ptr_cells=true)` → `lower_vm` → `run!`, value vs a native Julia
#       oracle, then `unrun!` to empty history, under L2 and L3.
#   (5) STATIC HAZARD SCAN — trajectory-independent. The scan is first
#       validated on the hand-built witnesses (non-zero on (2), ZERO on (3)),
#       then asserted NON-ZERO on the cheap ONE-insert `Dict{Int8,Int8}`
#       fixture, which is round-tripped in the same testset. That fixture is
#       green today and carries the hazard unexecuted — it is the guard that
#       survives a front-end change to which edge runs.
#
# # Mutation-proof (Rule 5)
#
# Re-inserting `delete!(locals, a)` into `_bind_args_to_params!` and running
# this file was verified RED, exactly where predicted: (1), (2) and (4) all
# error with `unbound SSA name`; the (3) control stays 41/41 GREEN, which is
# what makes the three failures attributable to the hazard rather than to the
# harness. (5) and (6) also stay green, by design and not by accident: (5) is
# a purely STRUCTURAL claim about the lowered program (its job is to fail if
# the front-end stops emitting the hazard shape, which would silently make (4)
# vacuous), and (6) tests the diagnostic, which is independent of the
# transfer. See WORKLOG.md for the run.
#
# # Ref
#   * `docs/adr/0022-phi-edge-binding.md` — the decision record.
#   * `docs/adr/0019-reversible-calls.md` Amendment A.1 — the call-edge
#     precedent, hostile-review-ratified 2026-06-10.
#   * `src/interpreter/Interpreter.jl` — `_bind_args_to_params!`.
#   * `src/ir/unbound_ssa.jl` — the Rule-1 diagnostic (`bennettvm-35yn`)
#     that mitigates this change's one real risk.
#   * `references/reversible-ir/mogensen-2016-rssa.pdf` §4 p. 210 note 2.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known values), Rule 5 (mutation-
#     proof), Rule 11 (literate).

using Test
using BennettVM
import Bennett

const _BVr = BennettVM
const _Br  = Bennett

# ---------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------

# Run forward under a given must-cache regime, assert halt, return the RState.
function _rnhv_run(prog, inputs; mc, K = 64, max_steps = 5_000_000)
    rs = _BVr.initial_state(prog, inputs)
    _BVr.run!(rs, prog; max_steps = max_steps, checkpoint_interval = K,
              must_cache_set = mc)
    return rs
end

# The load-bearing invariant (CLAUDE.md P0.6 / Rule 4): forward to halt, check
# the value against a known-correct oracle, then `unrun!` back to the EXACT
# initial state with an empty history and a zero step count.
function _rnhv_roundtrip(prog, inputs, readout, expected; mc, K = 64,
                         max_steps = 5_000_000)
    rs = _BVr.initial_state(prog, inputs)
    init = deepcopy(rs.current)
    _BVr.run!(rs, prog; max_steps = max_steps, checkpoint_interval = K,
              must_cache_set = mc)
    @test _BVr.is_halted(rs)
    @test _BVr.result(rs)[readout] == expected
    _BVr.unrun!(rs, prog; max_unsteps = max_steps)
    @test rs.current == init
    @test isempty(rs.history)
    @test rs.step_count == 0
    return nothing
end

# The two history regimes every round-trip is exercised under.
_rnhv_regimes(prog) = (("L2 (compute_must_cache)", _BVr.compute_must_cache(prog)),
                       ("L3 (empty must_cache)",   Set{Tuple{Symbol,Int}}()))

# --- the static hazard scan (§(5)) ------------------------------------
#
# A "hazard" is an exit arg whose SSA name has a use that OUTLIVES the edge:
# block `B` sends `a` on one of its edges, and some OTHER block `C` of the same
# function READS `a` as an operand while neither binding it as an entry param
# nor defining it in its own body. Under the pre-rnhv destructive transfer such
# a read is live iff control reaches `C` after that edge — i.e. it is a latent
# `KeyError` waiting for the right trajectory.
#
# Blocks are keyed by their `func#label` prefix so that the per-body `__vN`
# names — which DO collide across bodies — cannot manufacture a cross-function
# false positive.

# Real lowered blocks are labelled `func#block` (ADR 0019 §2). Hand-built
# fixtures in this file carry bare labels; they all belong to one routine, so
# an unqualified label maps to a single shared sentinel rather than to itself
# (mapping it to itself would put every hand-built block in its own "function"
# and make the scan silently blind — the first version of this helper did
# exactly that, and §(1) caught it).
_rnhv_func_of(label::Symbol) =
    (s = String(label); i = findfirst('#', s);
     i === nothing ? Symbol("#unqualified") : Symbol(SubString(s, 1, i - 1)))

# Every `Symbol` operand READ by a body instruction, and every `Symbol` it
# DEFINES. Field-name based rather than type-based so the scan keeps working as
# new instruction subtypes land (Rule 3: do not silently miss what you don't
# know about).
const _RNHV_DEF_FIELDS  = (:target, :dest)
const _RNHV_SKIP_FIELDS = (:width, :label, :callee, :op, :modop, :predicate)

function _rnhv_reads_defs(instr)
    reads = Symbol[]
    defs  = Symbol[]
    for f in fieldnames(typeof(instr))
        f in _RNHV_SKIP_FIELDS && continue
        v = getfield(instr, f)
        sink = f in _RNHV_DEF_FIELDS ? defs : reads
        if v isa Symbol
            push!(sink, v)
        elseif v isa Vector{Symbol}
            append!(sink, v)
        end
    end
    return reads, defs
end

"""
    _rnhv_hazards(prog) -> Vector{NamedTuple}

Every (sender block, exit arg, reader block) triple where the arg's use
outlives the edge. Trajectory-independent: a purely structural scan of the
lowered `VMProgram`, so it holds whether or not the offending edge executes.
"""
function _rnhv_hazards(prog)
    # Per block: entry params, body defs, body reads.
    params = Dict{Symbol,Set{Symbol}}()
    defs   = Dict{Symbol,Set{Symbol}}()
    reads  = Dict{Symbol,Set{Symbol}}()
    for b in prog.blocks
        params[b.label] = Set{Symbol}(hasfield(typeof(b.entry), :params) ?
                                      b.entry.params : Symbol[])
        d = Set{Symbol}(); r = Set{Symbol}()
        for ins in b.instructions
            rr, dd = _rnhv_reads_defs(ins)
            union!(r, rr); union!(d, dd)
        end
        defs[b.label] = d
        reads[b.label] = r
    end
    out = NamedTuple[]
    for b in prog.blocks
        e = b.exit
        hasfield(typeof(e), :args) || continue          # EndInstruction
        fn = _rnhv_func_of(b.label)
        for a in e.args
            for c in prog.blocks
                c.label === b.label && continue
                _rnhv_func_of(c.label) === fn || continue
                (a in reads[c.label]) || continue
                (a in params[c.label]) && continue
                (a in defs[c.label]) && continue
                push!(out, (sender = b.label, arg = a, reader = c.label))
            end
        end
    end
    return out
end

# ---------------------------------------------------------------------
# (1) Hand-built straight-line witness — RED at 2efd6bc
# ---------------------------------------------------------------------
#
#   entry: Begin(:f, [:x]); [ :v := :x + 1 ];        -> body(:v)
#   body:  body(:p);        [ :d := :p - :v ];       end :f (:d)
#
# `:v` is BOTH the φ-incoming sent on the edge AND read again in the
# destination's body. Destructively transferring it deletes it before the
# second read.
#
# The value is a deliberate 0 (`(x+1) - (x+1)`) so that a self-aliasing
# miscompile — one that resolved `:v` to `:p` — would still produce it; the
# discriminating assertion is (2)'s n-dependent oracle plus the round-trip.

function _rnhv_straightline(; second_use::Bool)
    body = second_use ?
        _BVr.Instruction[_BVr.Define(:d, :p, :sub, :v)] :
        _BVr.Instruction[_BVr.Define(:d, :p, :sub, Int64(1))]
    eb = _BVr.BasicBlock(:entry,
        _BVr.BeginInstruction(:f, Symbol[:x]),
        _BVr.Instruction[_BVr.Define(:v, :x, :add, Int64(1))],
        _BVr.UnconditionalExit(:body, Symbol[:v]))
    bb = _BVr.BasicBlock(:body,
        _BVr.UnconditionalEntry(:body, Symbol[:p]),
        body,
        _BVr.EndInstruction(:f, Symbol[:d]))
    blocks = [eb, bb]
    fns = Dict(:f => _BVr.FunctionEntry(:f, :entry, Symbol[:x], Symbol[:d]))
    return _BVr.VMProgram(blocks, _BVr.LabelTable(blocks), :entry,
                          Int[64], Int[64], fns, :f)
end

@testset "(1) rnhv — straight-line φ-incoming with a second use" begin
    prog = _rnhv_straightline(second_use = true)
    # The hazard IS present structurally (and the scan sees it).
    hz = _rnhv_hazards(prog)
    @test length(hz) == 1
    @test hz[1] == (sender = :entry, arg = :v, reader = :body)

    for (label, mc) in _rnhv_regimes(prog)
        for x in Int64[-7, -1, 0, 1, 42, 1000]
            # :d = (x+1) - (x+1) = 0, for every x.  ($label)
            _rnhv_roundtrip(prog, Dict(:x => x), :d, Int64(0);
                            mc = mc, K = 8, max_steps = 1_000)
        end
    end

    # The sender's arg SURVIVES the edge, bound to the value it was sent with
    # (this is the behavioural statement of the fix, and it is what the
    # `:d` read above depends on).
    rs = _rnhv_run(prog, Dict(:x => Int64(41));
                   mc = _BVr.compute_must_cache(prog), K = 8, max_steps = 1_000)
    @test _BVr.active_locals(rs.current)[:v] == 42
    @test _BVr.active_locals(rs.current)[:p] == 42
end

# ---------------------------------------------------------------------
# (2) Hand-built LOOP witness — the real `rehash!` topology
# ---------------------------------------------------------------------
#
#   ph:    Begin(:g,[:n]); [ base := n+1 ; lim := n+2 ]; -> hdr(base)
#   hdr:   hdr(i);         [ d := i - base ;             # ← re-read EVERY iter
#                            c := d < lim ];  c ? -> latch(i) : -> done(i)
#   latch: latch(j);       [ i2 := j + 1 ];              -> hdr(i2)
#   done:  done(k);        [ r := k + base ];            # ← re-read AFTER loop
#                          end :g (r)
#
# The loop runs `lim = n+2` times, so `k = base + lim` and
# `r = 2·base + lim = 2(n+1) + (n+2) = 3n + 4`.
#
# The straight-line witness (1) exercises the hazard once; this one exercises
# it on a BACK EDGE, where the pre-rnhv transfer would have had to delete
# `:base` on the very first edge and then fail on every subsequent iteration.

_rnhv_loop_oracle(n::Int64) = 3n + 4

function _rnhv_loop_program()
    ph = _BVr.BasicBlock(:ph,
        _BVr.BeginInstruction(:g, Symbol[:n]),
        _BVr.Instruction[_BVr.Define(:base, :n, :add, Int64(1)),
                         _BVr.Define(:lim,  :n, :add, Int64(2))],
        _BVr.UnconditionalExit(:hdr, Symbol[:base]))
    hdr = _BVr.BasicBlock(:hdr,
        _BVr.UnconditionalEntry(:hdr, Symbol[:i]),
        _BVr.Instruction[_BVr.Define(:d, :i, :sub, :base),
                         _BVr.Define(:c, :d, :slt, :lim)],
        _BVr.ConditionalExit(:c, :latch, :done, Symbol[:i]))
    latch = _BVr.BasicBlock(:latch,
        _BVr.UnconditionalEntry(:latch, Symbol[:j]),
        _BVr.Instruction[_BVr.Define(:i2, :j, :add, Int64(1))],
        _BVr.UnconditionalExit(:hdr, Symbol[:i2]))
    done = _BVr.BasicBlock(:done,
        _BVr.UnconditionalEntry(:done, Symbol[:k]),
        _BVr.Instruction[_BVr.Define(:r, :k, :add, :base)],
        _BVr.EndInstruction(:g, Symbol[:r]))
    blocks = [ph, hdr, latch, done]
    fns = Dict(:g => _BVr.FunctionEntry(:g, :ph, Symbol[:n], Symbol[:r]))
    return _BVr.VMProgram(blocks, _BVr.LabelTable(blocks), :ph,
                          Int[64], Int[64], fns, :g)
end

@testset "(2) rnhv — loop: preheader value re-read on every iteration" begin
    prog = _rnhv_loop_program()
    # `:base` is sent on the `ph -> hdr` edge and read in BOTH `hdr` and
    # `done`; `:i` is sent on `hdr -> latch` and read nowhere else (it is
    # rebound as `:j` / `:k`), so exactly two hazards.
    hz = _rnhv_hazards(prog)
    @test Set((h.sender, h.arg, h.reader) for h in hz) ==
          Set([(:ph, :base, :hdr), (:ph, :base, :done)])

    for (label, mc) in _rnhv_regimes(prog)
        for n in Int64[0, 1, 2, 3, 5, 9]
            # ($label)
            _rnhv_roundtrip(prog, Dict(:n => n), :r, _rnhv_loop_oracle(n);
                            mc = mc, K = 8, max_steps = 10_000)
        end
    end

    # Non-vacuity: the loop really iterates (a program that fell straight
    # through would satisfy the oracle only at one `n`, but assert it anyway
    # — a 4-block program that halted in 4 steps would be no test at all).
    rs = _rnhv_run(prog, Dict(:n => Int64(9));
                   mc = _BVr.compute_must_cache(prog), K = 8, max_steps = 10_000)
    @test rs.step_count > 4 * 9        # ≥ one block traversal per iteration
    @test _BVr.active_locals(rs.current)[:base] == 10   # survived every edge
end

# ---------------------------------------------------------------------
# (3) CONTROL — the same shape with the second use removed
# ---------------------------------------------------------------------
#
# Green at `2efd6bc` AND after the fix. Without this, (1)'s RED could be
# blamed on the hand-built-program harness rather than on the hazard.

@testset "(3) rnhv control — no second use, green before and after" begin
    prog = _rnhv_straightline(second_use = false)
    @test isempty(_rnhv_hazards(prog))        # the scan is not trigger-happy
    for (label, mc) in _rnhv_regimes(prog)
        for x in Int64[-7, 0, 1, 42]
            # :d = (x+1) - 1 = x.  ($label)
            _rnhv_roundtrip(prog, Dict(:x => x), :d, x;
                            mc = mc, K = 8, max_steps = 1_000)
        end
    end
end

# ---------------------------------------------------------------------
# (4) + (5) The real Dict fixtures
# ---------------------------------------------------------------------
#
# Extraction of a closed-world set is the expensive step; each program is
# extracted and lowered exactly ONCE for the whole file.

# 14 inserts is the threshold at which `Dict`'s load factor forces the
# `rehash!` GROW branch — the branch that carries the hazard on an EXECUTED
# edge. Written out straight-line rather than as a loop because, when this file
# was written, `CallEnter`'s `allunique(args)` guard rejected the loop form at
# LOWERING time — a genuinely separate wall, deliberately not conflated with
# this one.
#
# CORRECTION (bead `bennettvm-0fw7`, 2026-07-30 — this note used to blame the
# LOOP, and that was wrong). The 0fw7 diagnosis showed the loop is INCIDENTAL:
# the trigger is ONE call passing the same SSA value in two ARGUMENT POSITIONS.
# `d[i] = i` lowers to `setindex!(d, i, i)` (LLVM CSEs the key and the value
# onto one `%value_phi`); a straight-line `g(x, x)` with no loop at all trips
# it identically, while a loop body `d[i] = v` — two distinct names — does not.
# The guard encoded the pre-Amendment-A MOVE semantics of ADR 0019 §3 and is
# REMOVED by ADR 0023; the loop form is now gated by
# `test/test_0fw7_dup_call_args.jl` §(3). The straight-line phrasing is KEPT
# here so this file's fixtures stay byte-identical to the ones its hazard
# counts and RED evidence were measured against.
function _rnhv_fdict14_i8(a::Int8, b::Int8)
    d = Dict{Int8,Int8}()
    d[Int8(1)]  = Int8(1);  d[Int8(2)]  = Int8(2);  d[Int8(3)]  = Int8(3)
    d[Int8(4)]  = Int8(4);  d[Int8(5)]  = Int8(5);  d[Int8(6)]  = Int8(6)
    d[Int8(7)]  = Int8(7);  d[Int8(8)]  = Int8(8);  d[Int8(9)]  = Int8(9)
    d[Int8(10)] = Int8(10); d[Int8(11)] = Int8(11); d[Int8(12)] = Int8(12)
    d[Int8(13)] = Int8(13); d[Int8(14)] = Int8(14)
    d[a] = b
    return d[a]
end

function _rnhv_fdict14_i64(a::Int64, b::Int64)
    d = Dict{Int64,Int64}()
    d[1]  = 1;  d[2]  = 2;  d[3]  = 3;  d[4]  = 4;  d[5]  = 5
    d[6]  = 6;  d[7]  = 7;  d[8]  = 8;  d[9]  = 9;  d[10] = 10
    d[11] = 11; d[12] = 12; d[13] = 13; d[14] = 14
    d[a] = b
    return d[a]
end

# The ONE-insert i8 fixture: green at `2efd6bc`, and the carrier of the LATENT
# hazard (§(5)). Distinct binding from the oracle so neither can be folded into
# the other.
_rnhv_fdict1_i8(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])
_rnhv_oracle1_i8(a::Int8, b::Int8) = (d = Dict{Int8,Int8}(); d[a] = b; d[a])

# The entry body's single return SSA name (the test_cwd4 / test_a70z idiom;
# `result(rs)` keys by SSA name).
function _rnhv_return_symbol(prog, entry::Symbol)
    for b in prog.blocks
        if b.exit isa _BVr.EndInstruction && b.exit.label === entry &&
           !isempty(b.exit.returns)
            return b.exit.returns[1]
        end
    end
    error("no EndInstruction with returns for entry :$entry")
end

function _rnhv_build(f, T)
    set  = _Br.extract_parsed_ir_set_from_julia(f, T; ptr_cells = true)
    prog = _BVr.lower_vm(set; entry = first(set).first)
    entry_vm = _BVr._vm_funcname(first(set).first)
    return (set = set, prog = prog,
            ret = _rnhv_return_symbol(prog, entry_vm),
            args = first(set).second.args)
end

const _RNHV_D14_I8  = _rnhv_build(_rnhv_fdict14_i8,  Tuple{Int8,Int8})
const _RNHV_D14_I64 = _rnhv_build(_rnhv_fdict14_i64, Tuple{Int64,Int64})
const _RNHV_D1_I8   = _rnhv_build(_rnhv_fdict1_i8,   Tuple{Int8,Int8})

@testset "(4) rnhv acceptance — 14-insert Dict, i8 and i64, e2e + round-trip" begin
    for (name, built, oracle, probes) in
        (("Dict{Int8,Int8}", _RNHV_D14_I8, _rnhv_fdict14_i8,
          Tuple{Int8,Int8}[(Int8(3), Int8(77)), (Int8(20), Int8(-5))]),
         ("Dict{Int64,Int64}", _RNHV_D14_I64, _rnhv_fdict14_i64,
          Tuple{Int64,Int64}[(Int64(3), Int64(77)), (Int64(20), Int64(-5))]))

        # The grow branch really is in the lowered program: 4 closed-world
        # bodies including `rehash!`, and a block count far past the
        # single-insert programs'.
        @test length(built.set) >= 4
        names = String[String(p.first) for p in built.set]
        @test any(n -> startswith(n, "rehash!"), names)               # ($name)
        @test any(n -> startswith(n, "setindex!"), names)
        @test length(built.prog.blocks) > 100

        for (label, mc) in _rnhv_regimes(built.prog)
            for (a, b) in probes
                inputs = Dict(n => v for ((n, _w), v) in
                              zip(built.args, (a, b)))
                # Golden master: the native Julia function on the same input.
                # ($name, $label)
                _rnhv_roundtrip(built.prog, inputs, built.ret,
                                Int64(oracle(a, b)); mc = mc, K = 64)
            end
        end
    end

    # NON-VACUITY of the whole gate: the 14-insert i8 trajectory is thousands
    # of steps long and passes through the `rehash!` activation. A program
    # that halted early would round-trip trivially.
    inputs = Dict(n => v for ((n, _w), v) in
                  zip(_RNHV_D14_I8.args, (Int8(3), Int8(77))))
    rs = _rnhv_run(_RNHV_D14_I8.prog, inputs;
                   mc = _BVr.compute_must_cache(_RNHV_D14_I8.prog))
    @test rs.step_count > 5_000
    @test haskey(_RNHV_D14_I8.prog.functions, :rehash!)
end

@testset "(5) rnhv — the hazard is LATENT in the green one-insert fixture" begin
    # The scan is calibrated on the hand-built witnesses first: non-zero where
    # the hazard is by construction, zero where it is by construction absent.
    # Without this pair the count below could be an artefact of the scan.
    @test !isempty(_rnhv_hazards(_rnhv_loop_program()))
    @test isempty(_rnhv_hazards(_rnhv_straightline(second_use = false)))

    # THE POINT: the ONE-insert Dict — a program the suite has asserted green
    # since CW-D4 — carries the identical hazard, merely on an edge its
    # trajectory never takes. This assertion is trajectory-INDEPENDENT, so it
    # keeps guarding the invariant even if the front-end changes which edge
    # executes and (4) stops discriminating.
    hz1 = _rnhv_hazards(_RNHV_D1_I8.prog)
    @test !isempty(hz1)
    @test length(hz1) >= 8
    # ... and it is present in `rehash!`, the body where the 14-insert program
    # actually died, not merely in some incidental corner.
    @test any(h -> _rnhv_func_of(h.sender) === :rehash!, hz1)

    # The same fixture still round-trips (the hazard is latent, not fatal):
    # value vs the native oracle, empty history, under both regimes.
    for (label, mc) in _rnhv_regimes(_RNHV_D1_I8.prog)
        for (a, b) in ((Int8(3), Int8(7)), (Int8(-9), Int8(120)))
            inputs = Dict(n => v for ((n, _w), v) in
                          zip(_RNHV_D1_I8.args, (a, b)))
            # ($label)
            _rnhv_roundtrip(_RNHV_D1_I8.prog, inputs, _RNHV_D1_I8.ret,
                            Int64(_rnhv_oracle1_i8(a, b)); mc = mc, K = 32)
        end
    end

    # And the 14-insert programs carry MORE of them than the 1-insert one —
    # the grow path adds edges, it does not remove the latent ones.
    @test length(_rnhv_hazards(_RNHV_D14_I8.prog)) >= length(hz1)
end

# ---------------------------------------------------------------------
# (6) The Rule-1 diagnostic (`bennettvm-35yn`)
# ---------------------------------------------------------------------
#
# ADR 0022 §Risks: relaxing the transfer means a genuinely malformed lowering
# can now find a STALE binding and read it silently instead of failing loud.
# The mitigation is that the failure which DOES fire carries enough context to
# localise it. Pin the message contents, not just the exception type.

@testset "(6) rnhv/35yn — unbound SSA read fails loud WITH context" begin
    bad = _BVr.BasicBlock(:only,
        _BVr.BeginInstruction(:h, Symbol[:x]),
        _BVr.Instruction[_BVr.Define(:r, :x, :add, :nowhere)],
        _BVr.EndInstruction(:h, Symbol[:r]))
    fns = Dict(:h => _BVr.FunctionEntry(:h, :only, Symbol[:x], Symbol[:r]))
    prog = _BVr.VMProgram([bad], _BVr.LabelTable([bad]), :only,
                          Int[64], Int[64], fns, :h)
    rs = _BVr.initial_state(prog, Dict(:x => Int64(3)))
    err = try
        _BVr.run!(rs, prog; max_steps = 100)
        nothing
    catch e
        e
    end
    @test err isa ErrorException          # NOT a bare KeyError
    m = err.msg
    @test occursin("unbound SSA name :nowhere", m)   # the symbol
    @test occursin("Define", m)                      # the full instruction
    @test occursin("pc", m)                          # the pc
    # The frame stack, as `fname@pc=N` per activation. The bottom frame is the
    # `:__entry` activation `IState`'s constructor builds — NOT the routine
    # name `:h`; only a `CallEnter`-pushed frame carries the callee's name.
    @test occursin("__entry@pc=", m)
    @test occursin("bound here", m)                  # what WAS bound
    @test occursin(":x", m)                          # ... including :x
end
