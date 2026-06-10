# test/test_fp_roundtrip.jl — SC10 Float64 round-trip gate, hand-built
# (M_FP.2; bead `bennettvm-8ox`; ADR 0011 §D1).
#
# # What this gate is, and why it is the milestone's reason to exist
#
# ADR 0011 §D4 names the SC10 gate
# `reversible_compile(x -> x*x + 3x + 1, Float64; target=:reversible_vm)`:
# a Float64 program that the circuit backend cannot represent, executed
# reversibly under BennettVM. This file proves it TWO ways: (i) a HAND-BUILT
# back-edge-loop `VMProgram` of `SoftCall` nodes (the discriminating L3
# exercise — reused dests across iterations), and (ii) the REAL END-TO-END
# path — `reversible_compile(f, Float64; target=:reversible_vm)` through
# Bennett.jl's FP wrapper → IR extraction → `IRCall` → `SoftCall` ingest →
# `lower_vm` (the literal SC10 gate of ADR 0011 §D4). Both drive the
# `SoftCall` instruction (`src/ir/softcall_instruction.jl`) — the lowering
# target for LLVM `IRCall` to a `soft_f*` callee — through the FULL
# interpreter loop (`run!` forward, `unrun!` backward), asserting BOTH:
#
#   (a) **Forward correctness** against the NATIVE Julia oracle
#       `reinterpret(UInt64, x*x + 3x + 1)`, bit-for-bit (Rule 4 — assert a
#       known-correct value, not "didn't throw"). BennettVM inherits
#       Bennett.jl's bit-exact SoftFloat dispatch (ADR 0011 D1); the
#       round-trip's forward leg must reproduce native IEEE-754 `Float64`
#       arithmetic to the bit, because the SoftFloat primitives ARE
#       bit-exact against hardware f64.
#
#   (b) The load-bearing **round-trip invariant**
#       `unrun!(run!(s,prog)) == initial(s) && isempty(s.history) &&
#       step_count == 0` (PRD v4 §6 SC10; Phase-0 gating P0.6).
#
# # Float64 as UInt64 bit-patterns (ADR 0011 §D1) — the representation
#
# A Float64 program arrives at BennettVM as an INTEGER program over UInt64
# bit-patterns: every FP op is an `IRCall` to a `soft_f*` callee, and the
# value `2.0` travels as `reinterpret(UInt64, 2.0) == 0x4000000000000000`.
# The VM's `locals` are `Int64`, so the bit-pattern is carried as
# `reinterpret(Int64, x)` (which may be NEGATIVE for any double with its
# sign bit set — e.g. a negative input); `SoftCall.forward` reinterprets it
# back to the unsigned width the soft function wants and back again. The
# oracle and the inputs below all use `reinterpret` to move between the
# `Float64` view and the `Int64`-carried `UInt64` bit-pattern.
#
# # Why a back-edge LOOP, not a straight line — the L3 path must be HIT
#
# A single straight-line `SoftCall` would reverse via the `s.initial` L3
# fallback in `Replay.jl` (the 3-step program pushes no K-checkpoint), which
# is BLIND to whether the per-instruction reverse works — the M8.2 blind
# spot. `SoftCall` is reversed L3-ONLY (it is NOT l2-capable — no
# `make_delta`, no `predelta_payload`), so the discriminating exercise is a
# loop that RE-DEFINES the same `SoftCall` dest across iterations: the
# cross-iteration crux (ADR 0012). The hand-built CFG below is a genuine
# back-edge counting loop (modelled on `test_revmap_roundtrip.jl` Part B /
# the collatz CFG): each iteration recomputes the WHOLE polynomial on the
# loop-invariant input `x` into the RE-DEFINED SoftCall dests `:sq`, `:t3x`,
# `:s1`, `:poly`, so on every pass those names OVERWRITE the prior
# iteration's value. The L3 checkpoint-replay must restore each overwritten
# bit-pattern for the round-trip to reach empty history — the `per_step_
# inverse_check` scaffold (M8.2) walks `unstep!` one step at a time so a
# broken intermediate reverse is caught, not masked by the aggregate
# `rs.current == rs.initial` (the `s.initial` L3 fallback would otherwise
# paper over it).
#
# The polynomial RESULT is the same every iteration (input is invariant), so
# `poly` after the final iteration equals the oracle — the loop count only
# multiplies how many times the reused dests are overwritten (the property
# under test), it does not change the answer. A `must_cache_set` is passed
# AND empty-set both: SoftCall takes L3 in BOTH regimes (it has no L2 path),
# so the two regimes differ only in the Define-built counter's reversal, and
# both must round-trip to empty history.
#
# # Mutation-proof (Rule 5) — performed manually, reverted, NOT in tree;
# # captured in the orchestration report
#
# Perturbing `SoftCall.forward` (`src/ir/softcall_instruction.jl`) to SWAP
# the op — e.g. call `soft_fadd` where the instruction says `soft_fmul`, or
# reverse the arg order on the `soft_fsub` — makes the FORWARD oracle
# assertion go RED (the bit-pattern no longer equals
# `reinterpret(UInt64, x*x+3x+1)`); perturbing it to drop the result write
# (`BennettVM.active_locals(s)[dest]` unset) makes the round-trip / per-step check go RED.
# Confirmed RED-then-GREEN; see the report. (The op-level guarantees are
# additionally pinned in `test_softcall.jl`.)
#
# # Ref
#
#   * `docs/adr/0011-fp-inheritance.md` §D1 (inherit SoftFloat wholesale;
#     Float64 as UInt64 bit-patterns), §D4 (the SC10 gate program).
#   * `src/ir/softcall_instruction.jl` — the `SoftCall` op under integration
#     test (forward bit-pattern reinterpret; L3-only reversal).
#   * `src/history/Injective.jl` — `is_injective(SoftCall) == false`.
#   * `test/test_revmap_roundtrip.jl` / `test/test_collatz_roundtrip.jl` —
#     the back-edge-loop VMProgram CFG templates this mirrors.
#   * `test/test_per_step_inverse.jl` — the M8.2 `per_step_inverse_check`
#     scaffold this gate consumes (re-include-guarded).
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known-correct invariants),
#     Rule 5 (mutation-proof), Rule 11 (literate).

using Test
using BennettVM
import Bennett

# Re-include-guarded (runtests.jl loads it earlier; keeps the single-file
# `julia test/test_fp_roundtrip.jl` invocation self-contained — the same
# pattern test_revmap_roundtrip.jl uses).
include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

const _BVF = BennettVM

# The native Julia oracle: x*x + 3x + 1, returned as the UInt64 bit-pattern
# (Rule 4 golden master, bit-for-bit). BennettVM's SoftFloat dispatch is
# bit-exact against this hardware f64 evaluation (ADR 0011 D1).
fp_poly_ref(x::Float64)::UInt64 = reinterpret(UInt64, x * x + 3.0 * x + 1.0)

# Bit-pattern constants (as Int64, the locals carrier) for the literals the
# polynomial needs: 3.0 and 1.0. `:c3` and `:c1` are loop-invariant block
# params threaded unchanged through the loop.
const _BITS_3 = reinterpret(Int64, 3.0)
const _BITS_1 = reinterpret(Int64, 1.0)

# Hand-built back-edge loop VMProgram computing `x*x + 3x + 1` on a
# loop-invariant Float64 input `x` (carried as a UInt64 bit-pattern), N
# times, where N is an Int64 trip count. Four blocks (the collatz /
# revmap-Part-B shape):
#
#   :entry  Begin(:fppoly, [:x, :n0, :c3, :c1])
#           Define(:i0, :n0, :sub, :n0)            # i0 := 0 (n0 preserved)
#           -> UncondExit(:hdr, [:x, :n0, :c3, :c1, :i0])
#
#   :hdr    CondEntry(:hdr, [:x_h,:n,:c3_h,:c1_h,:i], preds={:entry,:body},
#                     cond=:cond)
#           Define(:cond, :i, :slt, :n)            # cond := (i < n)
#           CondExit(:cond, :body, :done, [:x_h,:n,:c3_h,:c1_h,:i])
#
#   :body   CondEntry(:body, [:x_b,:n_b,:c3_b,:c1_b,:i_b], preds={:hdr,_},
#                     cond=:cond)
#           SoftCall(:sq,   :soft_fmul, [:x_b, :x_b])     # sq   := x*x   (RE-DEF)
#           SoftCall(:t3x,  :soft_fmul, [:c3_b, :x_b])    # t3x  := 3*x   (RE-DEF)
#           SoftCall(:s1,   :soft_fadd, [:sq, :t3x])      # s1   := x*x+3x(RE-DEF)
#           SoftCall(:poly, :soft_fadd, [:s1, :c1_b])     # poly := …+1   (RE-DEF)
#           Define(:i_next, :i_b, :add, 1)                # i_next := i+1
#           -> UncondExit(:hdr, [:x_b,:n_b,:c3_b,:c1_b,:i_next])   # BACK-EDGE
#
#   :done   CondEntry(:done, [:x_f,:n_f,:c3_f,:c1_f,:i_f], preds={:hdr,_},
#                     cond=:cond)
#           End(:fppoly, [:poly])                  # return the last poly
#
# `:sq`, `:t3x`, `:s1`, `:poly`, `:cond`, `:i_next` are RE-DEFINED every
# pass — the four SoftCall dests are the cross-iteration name reuse that
# forces the L3 checkpoint-replay layer (SoftCall is L3-only). For N>=1 the
# final `poly` equals the oracle; for N==0 the body never runs (no `:poly`).
function _fp_poly_vm()
    entry = _BVF.BasicBlock(
        :entry,
        _BVF.BeginInstruction(:fppoly, [:x, :n0, :c3, :c1]),
        _BVF.Instruction[
            _BVF.Define(:i0, :n0, :sub, :n0),    # i0 = 0; n0 preserved
        ],
        _BVF.UnconditionalExit(:hdr, [:x, :n0, :c3, :c1, :i0]),
    )
    hdr = _BVF.BasicBlock(
        :hdr,
        _BVF.ConditionalEntry(:hdr, [:x_h, :n, :c3_h, :c1_h, :i],
                              :entry, :body, :cond),
        _BVF.Instruction[
            _BVF.Define(:cond, :i, :slt, :n),    # cond = (i < n)
        ],
        _BVF.ConditionalExit(:cond, :body, :done,
                             [:x_h, :n, :c3_h, :c1_h, :i]),
    )
    body = _BVF.BasicBlock(
        :body,
        _BVF.ConditionalEntry(:body, [:x_b, :n_b, :c3_b, :c1_b, :i_b],
                              :hdr, :nonexistent_b, :cond),
        _BVF.Instruction[
            _BVF.SoftCall(:sq,   :soft_fmul,
                          Union{Symbol,Int64}[:x_b, :x_b], [64, 64], 64),
            _BVF.SoftCall(:t3x,  :soft_fmul,
                          Union{Symbol,Int64}[:c3_b, :x_b], [64, 64], 64),
            _BVF.SoftCall(:s1,   :soft_fadd,
                          Union{Symbol,Int64}[:sq, :t3x], [64, 64], 64),
            _BVF.SoftCall(:poly, :soft_fadd,
                          Union{Symbol,Int64}[:s1, :c1_b], [64, 64], 64),
            _BVF.Define(:i_next, :i_b, :add, Int64(1)),
        ],
        _BVF.UnconditionalExit(:hdr, [:x_b, :n_b, :c3_b, :c1_b, :i_next]),
    )
    done = _BVF.BasicBlock(
        :done,
        _BVF.ConditionalEntry(:done, [:x_f, :n_f, :c3_f, :c1_f, :i_f],
                              :hdr, :nonexistent_d, :cond),
        _BVF.Instruction[],
        _BVF.EndInstruction(:fppoly, [:poly]),
    )
    blocks = [entry, hdr, body, done]
    return VMProgram(blocks, _BVF.LabelTable(blocks), :entry,
                     [64, 64, 64, 64], [64])
end

# Initial-locals dict for input `x::Float64` and trip count `n::Int64`.
function _fp_inputs(x::Float64, n::Int64)
    return Dict(:x => reinterpret(Int64, x), :n0 => n,
                :c3 => _BITS_3, :c1 => _BITS_1)
end

@testset "SC10 Float64 round-trip — hand-built SoftCall (M_FP.2; 8ox)" begin
    vm = _fp_poly_vm()

    # The inputs under test: a spread of doubles incl. negatives (sign-bit-set
    # bit-pattern → negative Int64 carrier, exercising the mask-reinterpret
    # path), a fraction (non-trivial mantissa), and the SC10 headline integer.
    xs = (2.0, 3.0, -1.5, 0.25, 7.0, -4.0)

    @testset "forward correctness vs native oracle (bit-for-bit)" begin
        # N=1: one iteration computes the polynomial once. Assert the result
        # bit-pattern EQUALS the native Julia oracle, bit-for-bit (Rule 4).
        for x in xs
            rs = initial_state(vm, _fp_inputs(x, Int64(1)))
            run!(rs, vm; max_steps = 10_000, checkpoint_interval = 4)
            @test is_halted(rs)
            got = reinterpret(UInt64, result(rs)[:poly])   # poly is the f64 bits
            @test got == fp_poly_ref(x)                     # bit-exact golden master
            # And the decoded value matches native arithmetic (human-readable).
            @test reinterpret(Float64, result(rs)[:poly]) == x * x + 3.0 * x + 1.0
        end

        # SC10 headline (ADR 0011 §D4): x=2.0 → 2*2 + 3*2 + 1 == 11.0.
        rs = initial_state(vm, _fp_inputs(2.0, Int64(1)))
        run!(rs, vm; max_steps = 10_000, checkpoint_interval = 4)
        @test reinterpret(Float64, result(rs)[:poly]) == 11.0
        @test result(rs)[:poly] == reinterpret(Int64, 11.0)

        # Multi-iteration: the polynomial is invariant, so N iterations give
        # the SAME answer — the reused SoftCall dests are overwritten N times
        # (the L3 cross-iteration exercise) but the result is unchanged.
        for x in xs, n in (Int64(1), Int64(3), Int64(5))
            rs = initial_state(vm, _fp_inputs(x, n))
            run!(rs, vm; max_steps = 10_000, checkpoint_interval = 4)
            @test reinterpret(UInt64, result(rs)[:poly]) == fp_poly_ref(x)
        end
    end

    @testset "aggregate round-trip to empty history (P0.6 / SC10)" begin
        # Both regimes: empty must_cache (pure L3) and compute_must_cache
        # (the Define counter takes L2, the SoftCalls still L3 — a genuinely
        # MIXED stack). SoftCall has no L2 path, so it reverses L3 in BOTH.
        for (mode, mkmc) in (
                ("L3 (empty must_cache)", _ -> Set{Tuple{Symbol,Int}}()),
                ("L2 (compute_must_cache)", v -> _BVF.compute_must_cache(v)),
            )
            mc = mkmc(vm)
            for x in xs, n in (Int64(0), Int64(1), Int64(3), Int64(5))
                rs = initial_state(vm, _fp_inputs(x, n))
                initial_snap = deepcopy(rs.initial)

                run!(rs, vm; max_steps = 10_000, checkpoint_interval = 4,
                     must_cache_set = mc)
                @test is_halted(rs)
                if n == 0
                    @test !haskey(BennettVM.active_locals(rs.current), :poly)  # body never ran
                else
                    @test reinterpret(UInt64, BennettVM.active_locals(rs.current)[:poly]) ==
                          fp_poly_ref(x)
                end
                @test rs.step_count > 0

                unrun!(rs, vm)
                @test rs.current == rs.initial          # P0.6 — reversed to start
                @test isempty(rs.history)               # P0.6 — history drained
                @test rs.step_count == 0                # P0.6 — step counter reset
                @test rs.initial == initial_snap        # rs.initial never mutated
            end
        end
    end

    @testset "END-TO-END — Bennett.jl FP wrapper → lower_vm (SC10; ADR 0011 §D4)" begin
        # The REAL SC10 gate (ADR 0011 §D4): drive the polynomial through
        # Bennett.jl's Float64 wrapper (`reversible_compile(f, Float64; target=
        # :reversible_vm)`, `../Bennett.jl/src/softfloat_dispatch.jl:79`),
        # which wraps `f` in a UInt64 lambda, extracts integer IR with
        # `soft_f*` `IRCall`s, and dispatches to BennettVM's `lower_vm` (ADR
        # 0003). This exercises the FULL path — FP wrapper → extraction →
        # IRCall → SoftCall ingest → interpreter — NOT a hand-built ParsedIR.
        # `using BennettVM` (top of file) has run `__init__`, registering the
        # `:reversible_vm` backend, so the dispatch reaches `lower_vm` here.
        e2e_f = x -> x * x + 3x + 1
        vm_e2e = Bennett.reversible_compile(e2e_f, Float64;
                                            target = :reversible_vm)
        @test vm_e2e isa VMProgram

        # Derive the entry arg name (Begin params) and return name (End
        # returns) from the lowered program rather than hard-coding the
        # extractor's `x::UInt64` / `__v4` (robust to extraction renames).
        begin_inst = nothing
        end_inst = nothing
        for b in vm_e2e.blocks
            b.entry isa _BVF.BeginInstruction && (begin_inst = b.entry)
            b.exit isa _BVF.EndInstruction && (end_inst = b.exit)
        end
        @test begin_inst !== nothing && length(begin_inst.params) == 1
        @test end_inst !== nothing && length(end_inst.returns) == 1
        e2e_arg = begin_inst.params[1]
        e2e_ret = end_inst.returns[1]

        # Confirm the FP ops lowered to SoftCall nodes (the ingest worked).
        nsc = 0
        for b in vm_e2e.blocks, i in b.instructions
            i isa _BVF.SoftCall && (nsc += 1)
        end
        @test nsc == 4          # x*x, 3*x, (x*x)+(3*x), …+1

        # Forward bit-exact + round-trip, same inputs as the hand-built gate.
        for x in xs
            rs = initial_state(vm_e2e, Dict(e2e_arg => reinterpret(Int64, x)))
            run!(rs, vm_e2e; max_steps = 100_000, checkpoint_interval = 4)
            @test is_halted(rs)
            @test reinterpret(UInt64, result(rs)[e2e_ret]) == fp_poly_ref(x)
            @test reinterpret(Float64, result(rs)[e2e_ret]) ==
                  x * x + 3.0 * x + 1.0

            initial_snap = deepcopy(rs.initial)
            unrun!(rs, vm_e2e)
            @test rs.current == rs.initial          # P0.6 — reversed to start
            @test isempty(rs.history)               # P0.6 — history drained
            @test rs.step_count == 0                # P0.6 — step counter reset
            @test rs.initial == initial_snap
        end

        # SC10 headline (ADR 0011 §D4): x=2.0 → 11.0, end-to-end.
        rs = initial_state(vm_e2e, Dict(e2e_arg => reinterpret(Int64, 2.0)))
        run!(rs, vm_e2e; max_steps = 100_000, checkpoint_interval = 4)
        @test reinterpret(Float64, result(rs)[e2e_ret]) == 11.0
    end

    @testset "per-step inverse (L3-only SoftCall reversal; M8.2)" begin
        # The discriminating exercise: walk unstep! one step at a time so a
        # broken SoftCall reverse is caught at the exact step, not masked by
        # the aggregate s.initial L3 fallback. SoftCall is L3-only in BOTH
        # regimes; the Define counter exercises L2 under compute_must_cache.
        for K in (1, 4)
            for x in (2.0, -1.5, 0.25), n in (Int64(1), Int64(3), Int64(5))
                @test per_step_inverse_check(
                    vm, _fp_inputs(x, n);
                    checkpoint_interval = K,
                    label = "fppoly/x=$x/n=$n/L3/K=$K") === nothing
                @test per_step_inverse_check(
                    vm, _fp_inputs(x, n);
                    checkpoint_interval = K,
                    must_cache_set = _BVF.compute_must_cache(vm),
                    label = "fppoly/x=$x/n=$n/L2/K=$K") === nothing
            end
        end
    end
end
