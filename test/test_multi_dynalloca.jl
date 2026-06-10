# test/test_multi_dynalloca.jl — ≥2 dynamic-N allocas via the runtime bump
# pointer (`IState.heap_top`); bead `bennettvm-uil`, ADR 0009 Decision 2a
# multi-array refinement. THE GATE for Case B (a Dict = keys + vals = two
# dynamic GenericMemory backings, exceeding the pre-`uil` single-dynamic-array
# floor).
#
# # What this file pins, and why it is the keystone
#
# Before `uil`, `DynAlloca.forward` materialised its pointer at a FROZEN
# compile-time `instr.base`, and ingest FAILED LOUD on ANY alloca after a
# dynamic one — there was no runtime allocator state to place a second region
# disjointly. `uil` adds `IState.heap_top` (a runtime bump OFFSET, default 0)
# and computes the region base as `base = instr.base + s.heap_top`, advancing
# `s.heap_top += n` per alloca and retracting `s.heap_top -= n` on reverse. Two
# DISTINCT dynamic allocas (distinct dests) therefore own DISJOINT offset
# windows `[instr.base + offset_k, instr.base + offset_k + n_k)` and coexist.
#
# # The hand-built two-array program (Rule 4 — known values, not "didn't throw")
#
# A single block with TWO dynamic-N allocas (`arrA` size n1, `arrB` size n2,
# both anchored at the SAME frozen base — the runtime offset distinguishes
# them), writes to A[0], A[2], B[0], B[1] via `VarGEP` element pointers, and
# reads A[0] / B[0] back. With n1=3, n2=2 and the frozen base 1:
#
#   arrA base = 1 + 0  = 1   window [1, 3]   (A[0]=cell 1, A[2]=cell 3)
#   arrB base = 1 + 3  = 4   window [4, 5]   (B[0]=cell 4, B[1]=cell 5)
#   heap_top after both = 5  = n1 + n2
#
# The windows [1,3] and [4,5] are DISJOINT — a write to A and a write to B land
# in different cells (no aliasing / clobber), and the read-back returns exactly
# what was written. This is the distinctness/disjointness the single-array
# floor could not provide.
#
# # The mutation-proof (Rule 5)
#
# Removing the `s.heap_top += n` advance in `DynAlloca.forward` makes arrB
# anchor at the SAME base as arrA (offset stays 0) — the second alloca ALIASES
# the first. Testset 5 reproduces that scenario via a re-implemented forward
# WITHOUT the advance and asserts the regions then COLLIDE (B's write clobbers
# A's cell), the RED evidence that the advance is load-bearing. The live
# `DynAlloca.forward` is never mutated (a test-local function reproduces the
# defect), per the `test_mutation_proof.jl` discipline.
#
# # Tests
#
#   1. Distinct non-overlapping regions: two pointers differ; windows disjoint;
#      A-write and B-write land in different cells; read-back is uncorrupted.
#   2. Round-trip: run! → unrun! → current == initial, empty history, count 0,
#      heap_top == 0 (restored). Distinct runtime sizes n1 ≠ n2.
#   3. heap_top accounting: after both allocas, heap_top == n1 + n2; after
#      reversing one (the LIFO-last), heap_top == n1.
#   4. Per-step inverse (the M8.2 load-bearing pattern): catches a mid-stream
#      heap_top bug the aggregate round-trip can mask.
#   5. Mutation-proof: forward WITHOUT the heap_top advance ALIASES the two
#      regions (RED); the live advance prevents it (GREEN).
#   6. Single-array unchanged: a single DynAlloca still bases at instr.base
#      (heap_top = 0 → offset 0 → byte-identical to pre-`uil`).
#
# # Ref
#
#   * `docs/adr/0009-dynamic-size-memory.md` Decision 2a (multi-array offset
#     refinement) — the `heap_top` runtime bump pointer; in-loop + static-after-
#     dynamic deferred.
#   * `src/ir/IState.jl` — the `heap_top::Int64` field (==/hash/deepcopy
#     participation) and the 6-arg constructor.
#   * `src/ir/alloca.jl` — `DynAlloca.forward` (`base + heap_top`; `heap_top +=
#     n`), `predelta_payload` (captures the runtime base), the L2 `inverse`
#     (`heap_top -= n`).
#   * `src/ir/ingest.jl` — `_lower_alloca!` (dynamic-after-dynamic admitted;
#     static-after-dynamic still fails loud).
#   * `test/test_alloca_delta.jl` / `test/test_dyn_roundtrip.jl` — the single-
#     DynAlloca unit / e2e gates this generalises (must stay green BYTE-
#     IDENTICALLY: heap_top = 0 → base = instr.base).
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known values), Rule 5 (mutation-
#     proof), Rule 11 (literate).

using Test
using BennettVM
import Bennett

const _BV = BennettVM

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# A single-block VMProgram with TWO dynamic-N allocas, writes to A[0]/A[2] and
# B[0]/B[1] via VarGEP element pointers, and reads A[0]/B[0] back. Both allocas
# anchor at the SAME frozen base (1) — the runtime heap_top offset places them
# disjointly. The routine returns A[0]. n1/n2 are the runtime sizes (args).
function _two_dyn_alloca_vm()
    body = _BV.Instruction[
        _BV.DynAlloca(:arrA, :n1, Int64(1)),       # frozen base 1, runtime n1
        _BV.DynAlloca(:arrB, :n2, Int64(1)),       # SAME frozen base 1, runtime n2
        # A[0] := 100 ; A[2] := 102 (requires n1 >= 3)
        _BV.VarGEP(:pA0, :arrA, Int64(0), Int64(1)),
        _BV.MemoryStore(:pA0, Int64(100)),
        _BV.VarGEP(:pA2, :arrA, Int64(2), Int64(1)),
        _BV.MemoryStore(:pA2, Int64(102)),
        # B[0] := 200 ; B[1] := 201 (requires n2 >= 2)
        _BV.VarGEP(:pB0, :arrB, Int64(0), Int64(1)),
        _BV.MemoryStore(:pB0, Int64(200)),
        _BV.VarGEP(:pB1, :arrB, Int64(1), Int64(1)),
        _BV.MemoryStore(:pB1, Int64(201)),
        # read A[0] and B[0] back (oracle: 100 and 200, no clobber)
        _BV.MemoryLoad(:rA0, :pA0),
        _BV.MemoryLoad(:rB0, :pB0),
    ]
    bb = _BV.BasicBlock(:m, _BV.BeginInstruction(:m, [:n1, :n2]),
                        body, _BV.EndInstruction(:m, [:rA0]))
    return _BV.VMProgram([bb], _BV.LabelTable([bb]), :m, [64, 64], [64])
end

# The L2-capable must_cache set: ONLY DynAlloca + MemoryStore slots (the others
# — VarGEP / MemoryLoad — are L3-only this milestone; see test_alloca_delta.jl).
function _multi_dyn_l2_slots(vm)
    set = Set{Tuple{Symbol,Int}}()
    for b in vm.blocks
        for (i, instr) in enumerate(b.instructions)
            (instr isa _BV.DynAlloca || instr isa _BV.MemoryStore) &&
                push!(set, (b.label, i))
        end
    end
    return set
end

@testset "multi-dynalloca (≥2 dynamic-N allocas; runtime heap_top; bead uil)" begin

    # ------------------------------------------------------------------
    # (1) Distinct non-overlapping regions; no aliasing / clobber.
    # ------------------------------------------------------------------
    @testset "distinct disjoint regions; writes do not clobber" begin
        vm = _two_dyn_alloca_vm()
        mcs = _multi_dyn_l2_slots(vm)
        n1, n2 = Int64(3), Int64(2)
        rs = initial_state(vm, Dict(:n1 => n1, :n2 => n2))
        run!(rs, vm; checkpoint_interval = typemax(Int), must_cache_set = mcs)
        @test is_halted(rs)
        c = rs.current

        baseA = BennettVM.active_locals(c)[:arrA]
        baseB = BennettVM.active_locals(c)[:arrB]
        # The two pointers DIFFER (the keystone: distinct regions).
        @test baseA == 1                 # frozen base + offset 0
        @test baseB == 4                 # frozen base + offset n1 (= 1 + 3)
        @test baseA != baseB

        # The windows [baseA, baseA+n1-1] and [baseB, baseB+n2-1] are DISJOINT.
        winA = baseA:(baseA + n1 - 1)    # 1:3
        winB = baseB:(baseB + n2 - 1)    # 4:5
        @test isempty(intersect(winA, winB))
        @test last(winA) < first(winB)   # A's window ends strictly before B's

        # A-write (cell baseA = A[0]) and B-write (cell baseB = B[0]) are in
        # DIFFERENT cells — no aliasing.
        @test c.memory[baseA] == 100     # A[0]
        @test c.memory[baseA + 2] == 102 # A[2]
        @test c.memory[baseB] == 200     # B[0]
        @test c.memory[baseB + 1] == 201 # B[1]

        # Read-back returns exactly what was written (no clobber across arrays).
        @test BennettVM.active_locals(c)[:rA0] == 100      # A[0] survived the B writes
        @test BennettVM.active_locals(c)[:rB0] == 200      # B[0] survived the A writes
        @test result(rs)[:rA0] == 100
    end

    # ------------------------------------------------------------------
    # (2) Round-trip to start: empty history, heap_top restored to 0.
    #     Distinct runtime sizes n1 ≠ n2 across several pairs.
    # ------------------------------------------------------------------
    @testset "round-trip → initial, empty history, heap_top == 0" begin
        vm = _two_dyn_alloca_vm()
        mcs = _multi_dyn_l2_slots(vm)
        for (n1, n2) in ((Int64(3), Int64(2)), (Int64(5), Int64(4)),
                         (Int64(3), Int64(7)))
            rs = initial_state(vm, Dict(:n1 => n1, :n2 => n2))
            initial_snap = deepcopy(rs.initial)
            @test rs.initial.heap_top == 0       # starts at 0

            run!(rs, vm; checkpoint_interval = typemax(Int), must_cache_set = mcs)
            @test is_halted(rs)
            @test result(rs)[:rA0] == 100

            unrun!(rs, vm)
            @test rs.current == rs.initial       # reversed to start
            @test isempty(rs.history)            # history drained
            @test rs.step_count == 0             # step counter reset
            @test rs.current.heap_top == 0       # bump cursor restored
            @test rs.initial == initial_snap     # initial never mutated
        end
    end

    # ------------------------------------------------------------------
    # (3) heap_top accounting at the instruction level: after both allocas
    #     forward, heap_top == n1 + n2; after reversing the LIFO-last alloca,
    #     heap_top == n1. Driven directly on IState (isolated from step!).
    # ------------------------------------------------------------------
    @testset "heap_top accounting (n1+n2 forward; n1 after reversing one)" begin
        IS = _BV.IState
        n1, n2 = Int64(3), Int64(2)
        s = IS(1, Dict(:n1 => n1, :n2 => n2), :running, Dict{Int64,Int64}())
        @test s.heap_top == 0

        A = _BV.DynAlloca(:arrA, :n1, Int64(1))
        B = _BV.DynAlloca(:arrB, :n2, Int64(1))

        pA = _BV.predelta_payload(A, s)
        @test pA.base == 1 && pA.n == n1          # runtime base = 1 + 0
        _BV.forward(A, s)
        @test BennettVM.active_locals(s)[:arrA] == 1
        @test s.heap_top == n1                    # advanced by n1

        pB = _BV.predelta_payload(B, s)
        @test pB.base == 1 + n1 && pB.n == n2     # runtime base = 1 + heap_top
        _BV.forward(B, s)
        @test BennettVM.active_locals(s)[:arrB] == 1 + n1           # offset window
        @test s.heap_top == n1 + n2               # full total

        # Reverse the LIFO-last alloca (B) → heap_top retracts to n1.
        _BV.inverse(B, s, pB)
        @test s.heap_top == n1
        @test !haskey(BennettVM.active_locals(s), :arrB)

        # Reverse A → heap_top back to 0 (round-trips 0 → … → 0).
        _BV.inverse(A, s, pA)
        @test s.heap_top == 0
        @test !haskey(BennettVM.active_locals(s), :arrA)
    end

    # ------------------------------------------------------------------
    # (4) Per-step (mid-instruction) inverse — catches a mid-stream heap_top
    #     bug the aggregate round-trip masks. Both L2-dense (K=1) and K=4.
    # ------------------------------------------------------------------
    @testset "per-step inverse at K ∈ {1, 4}" begin
        vm = _two_dyn_alloca_vm()
        mcs = _multi_dyn_l2_slots(vm)
        for K in (1, 4)
            @test per_step_inverse_check(
                vm, Dict(:n1 => Int64(3), :n2 => Int64(2));
                checkpoint_interval = K,
                must_cache_set = mcs,
                label = "multi_dynalloca/K=$K") === nothing
        end
    end

    # ------------------------------------------------------------------
    # (5) Mutation-proof (Rule 5): forward WITHOUT the `heap_top += n` advance
    #     makes arrB ALIAS arrA (both at the frozen base) — the regions COLLIDE
    #     and the B-write clobbers A's cell. The live advance prevents it.
    #
    #     We reproduce the defect with a test-local `_forward_no_advance!` (the
    #     live `DynAlloca.forward` is never mutated — the `test_mutation_proof.jl`
    #     discipline) and assert the RED evidence: with the advance removed, the
    #     two bases COINCIDE and a B[0] write lands on A[0].
    # ------------------------------------------------------------------
    @testset "mutation-proof: removing heap_top advance ALIASES the regions" begin
        IS = _BV.IState

        # The BUGGY forward: materialise at base + heap_top but DO NOT advance
        # heap_top (the exact mutation the bead asks us to prove RED).
        function _forward_no_advance!(instr::_BV.DynAlloca, s)
            BennettVM.active_locals(s)[instr.dest] = instr.base + s.heap_top
            # (omitted on purpose) s.heap_top += BennettVM.active_locals(s)[instr.n_operand]
            s.pc += 1
            return s
        end

        n1, n2 = Int64(3), Int64(2)

        # --- RED: buggy forward → arrB aliases arrA; B[0] clobbers A[0]. ---
        sbug = IS(1, Dict(:n1 => n1, :n2 => n2), :running, Dict{Int64,Int64}())
        A = _BV.DynAlloca(:arrA, :n1, Int64(1))
        B = _BV.DynAlloca(:arrB, :n2, Int64(1))
        _forward_no_advance!(A, sbug)
        _forward_no_advance!(B, sbug)
        @test BennettVM.active_locals(sbug)[:arrA] == BennettVM.active_locals(sbug)[:arrB]   # ALIAS — same base!
        # A[0] := 100 then B[0] := 200 land on the SAME cell → clobber.
        sbug.memory[BennettVM.active_locals(sbug)[:arrA]] = Int64(100)     # A[0]
        sbug.memory[BennettVM.active_locals(sbug)[:arrB]] = Int64(200)     # B[0] (== A[0] cell!)
        @test sbug.memory[BennettVM.active_locals(sbug)[:arrA]] == 200     # A[0] was CLOBBERED

        # --- GREEN: the LIVE forward advances heap_top → disjoint bases. ---
        sok = IS(1, Dict(:n1 => n1, :n2 => n2), :running, Dict{Int64,Int64}())
        _BV.forward(A, sok)
        _BV.forward(B, sok)
        @test BennettVM.active_locals(sok)[:arrA] != BennettVM.active_locals(sok)[:arrB]     # DISTINCT bases
        sok.memory[BennettVM.active_locals(sok)[:arrA]] = Int64(100)       # A[0]
        sok.memory[BennettVM.active_locals(sok)[:arrB]] = Int64(200)       # B[0] (different cell)
        @test sok.memory[BennettVM.active_locals(sok)[:arrA]] == 100       # A[0] survives — no clobber
        @test sok.memory[BennettVM.active_locals(sok)[:arrB]] == 200
    end

    # ------------------------------------------------------------------
    # (6) Single-array unchanged: ONE DynAlloca still bases at instr.base
    #     (heap_top = 0 → offset 0 → byte-identical to pre-`uil`). This is the
    #     no-churn guarantee the existing single-array tests rely on.
    # ------------------------------------------------------------------
    @testset "single-array: base == instr.base (heap_top = 0)" begin
        IS = _BV.IState
        s = IS(1, Dict(:n => Int64(4)), :running, Dict{Int64,Int64}())
        @test s.heap_top == 0
        instr = _BV.DynAlloca(:arr, :n, Int64(7))
        p = _BV.predelta_payload(instr, s)
        @test p.base == 7                  # == instr.base (offset 0)
        _BV.forward(instr, s)
        @test BennettVM.active_locals(s)[:arr] == 7          # base == instr.base exactly
        @test s.heap_top == 4              # advanced (but no second alloca reads it)
        _BV.inverse(instr, s, p)
        @test !haskey(BennettVM.active_locals(s), :arr)
        @test s.heap_top == 0              # retracted
    end
end
