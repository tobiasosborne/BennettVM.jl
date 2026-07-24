# test/test_a70z_dict64_roundtrip.jl — the BennettVM (downstream) half of
# Bennett.jl bead `Bennett-a70z`: `Dict{Int64,Int64}` end-to-end.
#
# # What upstream changed, and why this file exists
#
# The `Dict{Int8,Int8}` closed-world set has been end-to-end green since
# `bennettvm-7xa` / CW-D4 (`test_x3t0_multikey_return.jl` (f),
# `test_cwd4_genericmemory.jl` (iv)). `Dict{Int64,Int64}` did NOT extract: with
# a `Int64` value type the Dict element size is 8 bytes, so `rehash!` emits
#
#     %r = call {i64,i1} @llvm.smul.with.overflow.i64(i64 %value_phi, i64 8)
#     %bit = extractvalue {i64,i1} %r, 1
#
# and the old Bennett-lbot overflow-bit prover only admitted the provably-
# no-overflow constants (mul by 0/1, add of 0), so extraction failed loud
# ("overflow bit … not provably zero"). At elsize 1 (the `Int8` Dict) the
# multiplier is 1 and the old fold applied — which is exactly why the i8 path
# worked and the i64 path did not.
#
# `Bennett-a70z` replaces the prover with the EXACT no-overflow interval when
# one operand is a compile-time constant. For `%value_phi * 8` the admissible
# interval is `[cld(typemin(Int64), 8), fld(typemax(Int64), 8)] = [-2^60, 2^60-1]`
# and the front-end emits, at each of the four `rehash!` sites:
#
#     IRICmp(lo,  :slt, %value_phi, -1152921504606846976, 64)
#     IRICmp(hi,  :sgt, %value_phi,  1152921504606846975, 64)
#     IRBinOp(bit, :or, lo, hi, 1)
#
# i.e. `bit == (v < -2^60) | (v > 2^60-1)`, which is precisely
# `Base.Checked.mul_with_overflow(v, 8)[2]`.
#
# The upstream implementer left the DOWNSTREAM half explicitly unverified:
# nothing proved BennettVM ingests those opcodes, and nothing exercised the
# `Dict{Int64,Int64}` set past extraction. **This file is that proof.** It is a
# cross-repo contract test: it fails if Bennett.jl changes the emission shape,
# if BVM stops ingesting `IRICmp`/`IRBinOp(:or)`, or if the interval bounds
# stop agreeing with Julia's own checked multiply.
#
# # What it pins (Rule 4 — known values, never "didn't throw")
#
#   (a) EXTRACT — the 4-body closed-world set, and the a70z emission really is
#       present in the ParsedIR: 4 `:slt`/`-2^60` sites, 4 `:sgt`/`2^60-1`
#       sites, 4 width-1 `:or` nodes fusing them, all inside `rehash!`, and NO
#       surviving `*.with.overflow` call anywhere in the set.
#   (b) INGEST — `lower_vm` produces a `VMProgram` and each a70z `IRICmp` /
#       `IRBinOp(:or)` became a `Define`. This is the claim the upstream bead
#       could only *argue* (Proposal B §5.4: "pre-existing shapes").
#   (c) RUN — `fdict64(3,7) == 7` and `fdict64(5,9) == 9` against the native
#       Julia oracle, then `unrun!` to the exact initial state with EMPTY
#       history (`step_count == 0`), under BOTH the L2 (`compute_must_cache`)
#       and L3 (empty must_cache) regimes.
#   (d0) BOUNDS ARITHMETIC — `[-2^60, 2^60-1]` is exactly (and tightly) the
#       no-overflow set of `v*8`, checked against `Base.Checked.mul_with_overflow`
#       at both boundaries, the adjacent rejects, the type extremes and a random
#       sweep. Trajectory-independent, so it catches an off-by-one in the
#       front-end's `cld`/`fld` that the runtime walk in (d) cannot.
#   (d) RUNTIME SEMANTICS of the a70z bit — the load-bearing one. Walking the
#       real `fdict64(3,7)` trajectory instruction by instruction, every
#       EXECUTED a70z `Define` is checked against hand-computed truth, and the
#       fused predicate is checked against `Base.Checked.mul_with_overflow(v, 8)`
#       for the operand value actually observed. Non-vacuity is asserted
#       (at least one site of each kind must execute) — a passing-but-never-
#       executed check would be worthless.
#   (e) PER-STEP INVERSE over the whole trajectory (the M8.2 discipline: the
#       aggregate round-trip can mask a mid-trajectory inverse bug).
#
# # Honest boundary
#
# Only 2 of the 4 emitted fuse sites execute on this trajectory (the other two
# sit on `rehash!` paths a single-insert Dict never takes), and the operand
# `%value_phi` is 16 at both (the `Dict{Int64,Int64}()` initial slot count), so
# the observed overflow bit is 0. This file therefore pins the NO-OVERFLOW arm
# at runtime; the overflowing arm is unreachable from any terminating `Dict`
# program (a Dict with > 2^60 slots cannot be allocated), and the *bounds* that
# separate the two arms are pinned arithmetically instead, in (d0) — plus the
# upstream fixture tests in
# `../Bennett.jl/test/test_a70z_overflow_const_bit.jl`.
#
# Dict GROWTH (≥ 14 inserts → the rehash-grow copy loop) is a SEPARATE, known
# wall tracked as `bennettvm-rnhv`; it is not in scope here and this file
# deliberately stays on the single-insert program, exactly like its i8 sibling.
#
# # Ref
#   * `../Bennett.jl/test/test_a70z_overflow_const_bit.jl` (e) — the upstream
#     extraction-side gate this file continues downstream.
#   * `../Bennett.jl/docs/design/a70z/` — the converged design (Proposal B).
#   * `test/test_x3t0_multikey_return.jl` (f) — the i8 sibling / template.
#   * `test/test_cwd4_genericmemory.jl` (iv)–(v) — the deeper i8 battery.
#   * `src/ir/ingest_body.jl:112` — the `IRICmp` → `Define` arm.
#   * `src/ir/define_instruction.jl` — `Define` (carries icmp predicates).
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known values), Rule 11 (literate).

using Test
using BennettVM
import Bennett

const _BVa = BennettVM
const _Ba = Bennett

# The a70z bounds for `v * 8`: cld(typemin(Int64), 8) / fld(typemax(Int64), 8).
const _A70Z_LO = -1152921504606846976
const _A70Z_HI = 1152921504606846975

# The irreversible Julia oracle (Rule 4).
_a70z64_oracle(a::Int64, b::Int64) = (d = Dict{Int64,Int64}(); d[a] = b; d[a])

# The program under test (a distinct binding from the oracle so that neither
# can be silently constant-folded into the other).
_a70z64_fdict(a::Int64, b::Int64) = (d = Dict{Int64,Int64}(); d[a] = b; d[a])

# The entry function's single return SSA name (the test_cwd4 / test_c_hashtable
# idiom; `result(rs)` keys by SSA name).
function _a70z64_return_symbol(prog, entry::Symbol)
    for b in prog.blocks
        if b.exit isa _BVa.EndInstruction && b.exit.label === entry &&
           !isempty(b.exit.returns)
            return b.exit.returns[1]
        end
    end
    error("no EndInstruction with returns for entry :$entry")
end

# Extraction of the real closed-world set is the expensive step (tens of
# seconds); do it ONCE for the whole file.
const _A70Z_SET  = _Ba.extract_parsed_ir_set_from_julia(
    _a70z64_fdict, Tuple{Int64,Int64}; ptr_cells = true)
const _A70Z_PROG = _BVa.lower_vm(_A70Z_SET; entry = first(_A70Z_SET).first)

@testset "Bennett-a70z — Dict{Int64,Int64} extract → ingest → run → round-trip" begin

    # ------------------------------------------------------------------
    # (a) EXTRACT — the closed-world set and the a70z emission shape.
    # ------------------------------------------------------------------
    @testset "(a) extract: 4-body set carrying the a70z interval-test emission" begin
        names = String[String(p.first) for p in _A70Z_SET]
        @test length(_A70Z_SET) >= 4
        @test any(n -> startswith(n, "rehash!"), names)
        @test any(n -> startswith(n, "setindex!"), names)
        @test any(n -> startswith(n, "ht_keyindex2_shorthash!"), names)

        # Per-body instruction inventory, so a site can be attributed.
        tagged = [(String(p.first), ins) for p in _A70Z_SET
                  for b in p.second.blocks for ins in b.instructions]

        los = [(f, i) for (f, i) in tagged if i isa _Ba.IRICmp && i.predicate === :slt &&
               i.width == 64 && i.op2 isa _Ba.ConstOperand && i.op2.value == _A70Z_LO]
        his = [(f, i) for (f, i) in tagged if i isa _Ba.IRICmp && i.predicate === :sgt &&
               i.width == 64 && i.op2 isa _Ba.ConstOperand && i.op2.value == _A70Z_HI]
        @test length(los) == 4
        @test length(his) == 4
        # Every site lives in rehash! (the elsize-8 `smul(%value_phi, 8)`).
        @test all(f -> startswith(f, "rehash!"), first.(los))
        @test all(f -> startswith(f, "rehash!"), first.(his))

        # The fused width-1 `:or` really joins a lo/hi PAIR — not two unrelated
        # i1 values. (This is the shape BVM must ingest.)
        lodests = Set(i.dest for (_, i) in los)
        hidests = Set(i.dest for (_, i) in his)
        ors = [(f, i) for (f, i) in tagged if i isa _Ba.IRBinOp && i.op === :or &&
               i.width == 1 &&
               i.op1 isa _Ba.SSAOperand && i.op1.name in lodests &&
               i.op2 isa _Ba.SSAOperand && i.op2.name in hidests]
        @test length(ors) == 4
        @test length(Set(i.op1.name for (_, i) in ors)) == 4   # one lo each
        @test length(Set(i.op2.name for (_, i) in ors)) == 4   # one hi each

        # PAIRING IDENTITY: each fuse joins the lo and hi of the SAME operand.
        # Membership in the right dest SETS (above) would not catch a fuse that
        # crossed two different sites' halves — this does.
        lomap = Dict(i.dest => i for (_, i) in los)
        himap = Dict(i.dest => i for (_, i) in his)
        @test all(((_f, i),) -> lomap[i.op1.name].op1 isa _Ba.SSAOperand &&
                                himap[i.op2.name].op1 isa _Ba.SSAOperand &&
                                lomap[i.op1.name].op1.name ===
                                himap[i.op2.name].op1.name, ors)
        # ... and that operand is the loop's slot-count phi (the `smul` LHS).
        @test all(((_f, i),) -> lomap[i.op1.name].op1.name === :value_phi, ors)

        # The `{i64,i1}` overflow aggregate is NEVER modelled: no
        # `*.with.overflow` call survives anywhere in the set.
        @test !any(((_, i),) -> i isa _Ba.IRCall &&
                       occursin("with.overflow",
                                String(i.callee isa Symbol ? i.callee : Symbol(i.callee))),
                   tagged)
    end

    # ------------------------------------------------------------------
    # (b) INGEST — the a70z opcodes reach the VM as `Define`s.
    # ------------------------------------------------------------------
    @testset "(b) ingest: a70z IRICmp/IRBinOp(:or) → Define in the VMProgram" begin
        @test _A70Z_PROG isa _BVa.VMProgram
        @test haskey(_A70Z_PROG.functions, :rehash!)
        @test haskey(_A70Z_PROG.functions, :setindex!)
        @test haskey(_A70Z_PROG.functions, :ht_keyindex2_shorthash!)

        vmins = [i for b in _A70Z_PROG.blocks for i in b.instructions]
        vmlos = [i for i in vmins if i isa _BVa.Define && i.op === :slt && i.rhs == _A70Z_LO]
        vmhis = [i for i in vmins if i isa _BVa.Define && i.op === :sgt && i.rhs == _A70Z_HI]
        @test length(vmlos) == 4
        @test length(vmhis) == 4
        @test all(i -> i.width == 64, vmlos)          # OPERAND width, not the i1 result
        @test all(i -> i.width == 64, vmhis)

        lotgts = Set(i.target for i in vmlos)
        hitgts = Set(i.target for i in vmhis)
        vmors = [i for i in vmins if i isa _BVa.Define && i.op === :or && i.width == 1 &&
                 i.lhs isa Symbol && i.lhs in lotgts &&
                 i.rhs isa Symbol && i.rhs in hitgts]
        @test length(vmors) == 4
    end

    # ------------------------------------------------------------------
    # (c) RUN — value vs oracle + round-trip, under L2 and L3.
    # ------------------------------------------------------------------
    @testset "(c) e2e: fdict64(a,b) == b, then unrun! to the exact initial state" begin
        entry_vm   = _BVa._vm_funcname(first(_A70Z_SET).first)
        ret        = _a70z64_return_symbol(_A70Z_PROG, entry_vm)
        entry_args = first(_A70Z_SET).second.args
        @test length(entry_args) == 2
        @test all(((_n, w),) -> w == 64, entry_args)   # the i64 case, not i8

        mc = _BVa.compute_must_cache(_A70Z_PROG)
        for (label, mcs) in (("L2 (compute_must_cache)", mc),
                             ("L3 (empty must_cache)", Set{Tuple{Symbol,Int}}()))
            for (a, b) in ((Int64(3), Int64(7)), (Int64(5), Int64(9)))
                inputs = Dict(n => v for ((n, _w), v) in zip(entry_args, (a, b)))
                rs = _BVa.initial_state(_A70Z_PROG, inputs)
                init = deepcopy(rs.current)
                _BVa.run!(rs, _A70Z_PROG; max_steps = 500_000,
                          checkpoint_interval = 32, must_cache_set = mcs)
                @test _BVa.is_halted(rs)
                # Value correctness ALONGSIDE reversibility: a self-aliasing
                # miscompile would still round-trip. NB on the oracle line: for
                # a single-insert Dict `_a70z64_oracle(a,b)` reduces to `b`
                # identically, so the two assertions are ONE claim written two
                # ways (the native run and the VM run agree). It is kept for the
                # house golden-master idiom, not as independent discrimination.
                @test _BVa.result(rs)[ret] == b
                @test _BVa.result(rs)[ret] == _a70z64_oracle(a, b)

                _BVa.unrun!(rs, _A70Z_PROG; max_unsteps = 500_000)
                @test rs.current == init      # exact reverse ($label)
                @test isempty(rs.history)
                @test rs.step_count == 0
            end
        end
    end

    # ------------------------------------------------------------------
    # (d0) The BOUNDS THEMSELVES are the exact no-overflow interval of `v*8`.
    #      Purely arithmetic and trajectory-independent — this is what catches
    #      an off-by-one in the front-end's `cld`/`fld`, which the runtime
    #      check in (d) cannot (the only operand value the single-insert Dict
    #      ever presents is 16, far from either boundary).
    # ------------------------------------------------------------------
    @testset "(d0) [-2^60, 2^60-1] is exactly the no-overflow set of v*8" begin
        @test _A70Z_LO == cld(typemin(Int64), 8)
        @test _A70Z_HI == fld(typemax(Int64), 8)
        probes = Int64[typemin(Int64), typemin(Int64) + 1,
                       _A70Z_LO - 1, _A70Z_LO, _A70Z_LO + 1,
                       -3, -1, 0, 1, 3, 16,
                       _A70Z_HI - 1, _A70Z_HI, _A70Z_HI + 1,
                       typemax(Int64) - 1, typemax(Int64)]
        append!(probes, rand(Int64, 256))
        for v in probes
            @test ((v < _A70Z_LO) | (v > _A70Z_HI)) ==
                  Base.Checked.mul_with_overflow(v, Int64(8))[2]
        end
        # The bounds are TIGHT on both sides (not merely sound): the extreme
        # admitted values do not overflow, the adjacent rejected ones do.
        @test !Base.Checked.mul_with_overflow(_A70Z_LO, Int64(8))[2]
        @test !Base.Checked.mul_with_overflow(_A70Z_HI, Int64(8))[2]
        @test Base.Checked.mul_with_overflow(_A70Z_LO - 1, Int64(8))[2]
        @test Base.Checked.mul_with_overflow(_A70Z_HI + 1, Int64(8))[2]
    end

    # ------------------------------------------------------------------
    # (d) RUNTIME SEMANTICS of the a70z overflow bit — the cross-repo crux.
    # ------------------------------------------------------------------
    @testset "(d) runtime: the a70z interval test == Julia's checked multiply" begin
        vmins = [i for b in _A70Z_PROG.blocks for i in b.instructions]
        vmlos = Set(i for i in vmins if i isa _BVa.Define && i.op === :slt && i.rhs == _A70Z_LO)
        vmhis = Set(i for i in vmins if i isa _BVa.Define && i.op === :sgt && i.rhs == _A70Z_HI)
        lotgts = Set(i.target for i in vmlos)
        hitgts = Set(i.target for i in vmhis)
        vmors = Set(i for i in vmins if i isa _BVa.Define && i.op === :or && i.width == 1 &&
                    i.lhs isa Symbol && i.lhs in lotgts &&
                    i.rhs isa Symbol && i.rhs in hitgts)
        watched = union(vmlos, vmhis, vmors)

        entry_args = first(_A70Z_SET).second.args
        inputs = Dict(n => v for ((n, _w), v) in zip(entry_args, (Int64(3), Int64(7))))
        mc = _BVa.compute_must_cache(_A70Z_PROG)
        rs = _BVa.initial_state(_A70Z_PROG, inputs)

        # Walk the trajectory; for each EXECUTED watched Define capture the
        # pre-step operand values and the post-step result. Reading the pc's
        # instruction before stepping keeps the record frame-exact — `__vN` SSA
        # names are per-body and DO collide across the four bodies, so a
        # name-only scan of `active_locals` would attribute a foreign frame's
        # value to an a70z site.
        recs = NamedTuple[]
        nstep = 0
        while !_BVa.is_halted(rs)
            instr = _BVa._instruction_at(_A70Z_PROG, rs.current.pc)
            hit = instr isa _BVa.Define && instr in watched
            pre = hit ? copy(_BVa.active_locals(rs.current)) : nothing
            _BVa.step!(rs, _A70Z_PROG; checkpoint_interval = 32, must_cache_set = mc)
            if hit
                lv = instr.lhs isa Symbol ? get(pre, instr.lhs, nothing) : instr.lhs
                rv = instr.rhs isa Symbol ? get(pre, instr.rhs, nothing) : instr.rhs
                push!(recs, (op = instr.op, lv = lv, rv = rv,
                             val = _BVa.active_locals(rs.current)[instr.target]))
            end
            nstep += 1
            nstep <= 200_000 || error("a70z fdict64 forward exceeded 200000 steps")
        end
        @test _BVa.is_halted(rs)

        slts = filter(r -> r.op === :slt, recs)
        sgts = filter(r -> r.op === :sgt, recs)
        fused = filter(r -> r.op === :or, recs)

        # NON-VACUITY: the a70z sites are really on the executed path.
        @test !isempty(slts)
        @test !isempty(sgts)
        @test !isempty(fused)

        # EXECUTION ORDER: the sites fire as whole (lo, hi, fuse) triples, and
        # the two halves of a triple compare the SAME operand value at run time
        # (the dynamic counterpart of (a)'s static pairing-identity check).
        @test length(recs) % 3 == 0
        triples = [recs[i:i+2] for i in 1:3:length(recs)]
        @test all(t -> (t[1].op, t[2].op, t[3].op) === (:slt, :sgt, :or), triples)
        @test all(t -> t[1].lv == t[2].lv, triples)
        @test all(t -> t[3].lv == t[1].val && t[3].rv == t[2].val, triples)

        # Operands resolved (a `nothing` here would mean a dead/uncaptured SSA
        # read, i.e. the record — and the checks below — would be meaningless).
        @test all(r -> r.lv isa Int64 && r.rv isa Int64, recs)

        # Each comparison computes its own predicate ...
        @test all(r -> r.val == Int64(r.lv < _A70Z_LO), slts)
        @test all(r -> r.val == Int64(r.lv > _A70Z_HI), sgts)
        # ... the fuse is a width-1 OR of its two operands ...
        @test all(r -> r.val == ((r.lv | r.rv) & 1), fused)
        # ... and — THE CONTRACT — the interval test agrees, on every operand
        # value actually observed, with Julia's own checked `v * 8`.
        @test all(r -> ((r.lv < _A70Z_LO) | (r.lv > _A70Z_HI)) ==
                       Base.Checked.mul_with_overflow(r.lv, Int64(8))[2], slts)
        # The observed operand is `%value_phi` = the Dict slot count = 16 (the
        # `Dict{Int64,Int64}()` initial capacity). Pinned as a known value
        # (Rule 4) and as the honest scope of the runtime check: it exercises
        # the no-overflow arm only; (d0) pins the boundary arithmetic.
        @test all(r -> r.lv == 16, slts)
        @test all(r -> r.lv == 16, sgts)

        # On a single-insert Dict no site can overflow (see the honest-boundary
        # note in this file's header): every fused bit is 0, so the surviving
        # Dict control flow is the no-overflow arm.
        @test all(r -> r.val == 0, fused)
    end

    # ------------------------------------------------------------------
    # (e) PER-STEP INVERSE over the full fdict64(3,7) trajectory.
    # ------------------------------------------------------------------
    @testset "(e) per-step inverse over the fdict64 trajectory" begin
        entry_args = first(_A70Z_SET).second.args
        inputs = Dict(n => v for ((n, _w), v) in zip(entry_args, (Int64(3), Int64(7))))
        mc = _BVa.compute_must_cache(_A70Z_PROG)
        rs = _BVa.initial_state(_A70Z_PROG, inputs)
        init = deepcopy(rs.current)
        snaps = _BVa.IState[]
        while !_BVa.is_halted(rs)
            _BVa.step!(rs, _A70Z_PROG; checkpoint_interval = 32, must_cache_set = mc)
            push!(snaps, deepcopy(rs.current))
            length(snaps) <= 200_000 ||
                error("a70z fdict64 forward exceeded 200000 steps")
        end
        @test !isempty(snaps)
        ok = true
        while rs.step_count > 0
            _BVa.unstep!(rs, _A70Z_PROG)
            expected = rs.step_count > 0 ? snaps[rs.step_count] : init
            if rs.current != expected
                ok = false
                break
            end
        end
        @test ok
        @test rs.step_count == 0
        @test rs.current == init
    end
end
