# test/test_arena_roundtrip.jl — the reversible malloc-arena floor (CW-A2;
# ADR 0018; bead `bennettvm-416r.3`).
#
# # What this file pins (Rule 4 — invariants, not "didn't throw")
#
# The heap-intrinsic family (`src/ir/intrinsics.jl`) over hand-built IR:
#
#   1. malloc → store → load → free round-trip: `malloc(32)` returns
#      `ARENA_BASE` (4 cells), stores/loads through the pointer, free is a
#      no-op; `unrun!` → `arena_top == 0`, memory `{}`, history empty.
#   2. realloc = malloc + memcpy composite: the old region's cells are copied
#      into the new region; round-trip restores both.
#   3. calloc reads-as-0: a freshly calloc'd cell reads `0` (absent=0) with NO
#      explicit zeroing — identical reversal to malloc.
#   4. memset runtime-length over MIXED present/absent cells: the per-cell
#      `was_present` branch restores present cells to their old value and
#      `delete!`s absent cells (the missing-sentinel trap).
#   5. per-step inverse (spike lesson 4): aggregate round-trip alone masks a
#      middle-instruction bug; `per_step_inverse_check` catches it at K∈{1,4}.
#   6. arena_top restored to 0 after full `unrun!`.
#   7. ==/hash sensitivity: mutating `arena_top` alone makes two IStates
#      unequal (and hash-distinct) — the ADR 0018 §H anti-spurious-pass guard.
#   8. fail-loud (§E): free of a bad pointer, non-cell-divisible / negative
#      size, overlapping memcpy, out-of-whitelist callee.
#
# # The L2 must_cache set
#
# Marks the six non-injective intrinsics (everything except `IntrinsicFree`,
# which is L1 injective). With K = typemax(Int) (L3 suppressed) the only pushes
# are the intrinsic DeltaEntries, so "round-trip works" means the L2 inverse
# fired (not an accidental L3 rescue).
#
# # Ref
#
#   * `docs/adr/0018-heap-floor.md` §B (semantics/history), §D (pseudocode),
#     §E (failure modes), §G (this test plan).
#   * `src/ir/intrinsics.jl` — the instructions under test.
#   * `test/test_multi_dynalloca.jl` — the hand-built-VMProgram + per-step
#     idiom this file mirrors.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known values), Rule 5
#     (mutation-proof, performed separately), Rule 11 (literate).

using Test
using BennettVM
import Bennett

const _BV = BennettVM
const _AB = BennettVM.ARENA_BASE

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# L2 set: every non-injective heap intrinsic body slot (NOT IntrinsicFree).
function _arena_l2_slots(vm)
    set = Set{Tuple{Symbol,Int}}()
    for b in vm.blocks, (i, instr) in enumerate(b.instructions)
        is_alloc = instr isa _BV.IntrinsicMalloc || instr isa _BV.IntrinsicCalloc ||
                   instr isa _BV.IntrinsicRealloc || instr isa _BV.IntrinsicMemset ||
                   instr isa _BV.IntrinsicMemcpy || instr isa _BV.IntrinsicMemmove ||
                   instr isa _BV.MemoryStore || instr isa _BV.DynAlloca
        is_alloc && push!(set, (b.label, i))
    end
    return set
end

_mkvm(body, params, ret, ws) = begin
    bb = _BV.BasicBlock(:m, _BV.BeginInstruction(:m, params), body,
                        _BV.EndInstruction(:m, ret))
    _BV.VMProgram([bb], _BV.LabelTable([bb]), :m,
                  collect(Int, ws[1]), collect(Int, ws[2]))
end

# Mutation-proof record (Rule 5, CW-A2 session 2026-06-10) — each perturbation
# was applied to the implementation, confirmed RED, restored, confirmed GREEN:
#   M1 drop `s.arena_top -= p.cells` in the arena-alloc inverse
#      → caught by "per-step inverse at K ∈ {1,4}" AND the aggregate
#        `rs.current == rs.initial` (arena_top participates in IState ==).
#   M2 flip the was_present branch in _restore_deltas! (always setindex!)
#      → caught by "memmove overlap-safe round-trip" (`!haskey` phantom check)
#        and "memset runtime-n over mixed present/absent cells".
#   M3 drop arena_top from Base.:(==)
#      → caught by "IState ==/hash see arena_top" (the ADR 0018 §H
#        spurious-pass guard; spike-retrospective lesson 2).
@testset "arena heap-intrinsic floor (CW-A2; ADR 0018)" begin

    # ------------------------------------------------------------------
    # (1) malloc → store → load → free round-trip.
    # ------------------------------------------------------------------
    @testset "malloc(32) → store/load → free round-trip" begin
        # p := malloc(32) [4 cells]; *(p+1) := 77; r := *(p+1); free(p); ret r
        body = _BV.Instruction[
            _BV.IntrinsicMalloc(:p, Int64(32)),
            _BV.Define(:p1, :p, :add, Int64(1)),     # p+1 (cell index 1)
            _BV.MemoryStore(:p1, Int64(77)),
            _BV.MemoryLoad(:r, :p1),
            _BV.IntrinsicFree(:p),
        ]
        vm = _mkvm(body, Symbol[], [:r], ([], [64]))
        mcs = _arena_l2_slots(vm)
        rs = initial_state(vm, Dict{Symbol,Int64}())
        run!(rs, vm; checkpoint_interval = typemax(Int), must_cache_set = mcs)
        @test is_halted(rs)
        @test BennettVM.active_locals(rs.current)[:p] == _AB         # first malloc → ARENA_BASE
        @test rs.current.arena_top == 4            # 32 bytes ÷ 8 = 4 cells
        @test result(rs)[:r] == 77

        initial_snap = deepcopy(rs.initial)
        unrun!(rs, vm)
        @test rs.current == rs.initial
        @test isempty(rs.history)
        @test rs.step_count == 0
        @test rs.current.arena_top == 0            # cursor restored
        @test isempty(rs.current.memory)           # region retracted, no phantom
        @test rs.initial == initial_snap
    end

    # ------------------------------------------------------------------
    # (2) realloc = malloc + memcpy composite.
    # ------------------------------------------------------------------
    @testset "realloc copies old cells; round-trips" begin
        # p := malloc(16) [2 cells]; *p := 11; *(p+1) := 22;
        # q := realloc(p, 32) [4 cells, copies 4 from p]; r := *(q+1); ret r
        body = _BV.Instruction[
            _BV.IntrinsicMalloc(:p, Int64(16)),
            _BV.MemoryStore(:p, Int64(11)),
            _BV.Define(:p1, :p, :add, Int64(1)),
            _BV.MemoryStore(:p1, Int64(22)),
            _BV.IntrinsicRealloc(:q, :p, Int64(32)),
            _BV.Define(:q1, :q, :add, Int64(1)),
            _BV.MemoryLoad(:r, :q1),
        ]
        vm = _mkvm(body, Symbol[], [:r], ([], [64]))
        mcs = _arena_l2_slots(vm)
        rs = initial_state(vm, Dict{Symbol,Int64}())
        run!(rs, vm; checkpoint_interval = typemax(Int), must_cache_set = mcs)
        @test is_halted(rs)
        @test BennettVM.active_locals(rs.current)[:p] == _AB
        @test BennettVM.active_locals(rs.current)[:q] == _AB + 2     # after the 2-cell malloc
        @test rs.current.memory[_AB + 2] == 11     # copied *p
        @test rs.current.memory[_AB + 3] == 22     # copied *(p+1)
        @test result(rs)[:r] == 22
        @test rs.current.arena_top == 6            # 2 (malloc) + 4 (realloc)

        unrun!(rs, vm)
        @test rs.current == rs.initial
        @test isempty(rs.history)
        @test rs.current.arena_top == 0
    end

    # ------------------------------------------------------------------
    # (3) calloc reads-as-0 (no explicit zeroing; absent=0).
    # ------------------------------------------------------------------
    @testset "calloc cells read 0; round-trips" begin
        # p := calloc(3, 8) [3 cells]; r := *(p+2); ret r  (oracle r == 0)
        body = _BV.Instruction[
            _BV.IntrinsicCalloc(:p, Int64(3), Int64(8)),
            _BV.Define(:p2, :p, :add, Int64(2)),
            _BV.MemoryLoad(:r, :p2),
        ]
        vm = _mkvm(body, Symbol[], [:r], ([], [64]))
        mcs = _arena_l2_slots(vm)
        rs = initial_state(vm, Dict{Symbol,Int64}())
        run!(rs, vm; checkpoint_interval = typemax(Int), must_cache_set = mcs)
        @test is_halted(rs)
        @test BennettVM.active_locals(rs.current)[:p] == _AB         # address determinism (ADR 0018 §A)
        @test result(rs)[:r] == 0                  # calloc zero-init via absent=0
        @test rs.current.arena_top == 3
        @test isempty(rs.current.memory)           # nothing materialised

        unrun!(rs, vm)
        @test rs.current == rs.initial
        @test rs.current.arena_top == 0
    end

    # ------------------------------------------------------------------
    # (4) memset runtime-n over MIXED present/absent cells.
    # ------------------------------------------------------------------
    @testset "memset runtime-n over mixed present/absent cells" begin
        # p := malloc(24) [3 cells]; *p := 5 (present); (p+1,p+2 absent);
        # memset(p, 0, n*8) [n cells]; r := *p (== 0 after memset); ret r
        body = _BV.Instruction[
            _BV.IntrinsicMalloc(:p, Int64(24)),
            _BV.MemoryStore(:p, Int64(5)),               # p[0] present
            _BV.Define(:len, :ncells, :mul, Int64(8)),    # nbytes = ncells*8
            _BV.IntrinsicMemset(:p, Int64(0), :len),
            _BV.MemoryLoad(:r, :p),
        ]
        vm = _mkvm(body, [:ncells], [:r], ([64], [64]))
        mcs = _arena_l2_slots(vm)
        for ncells in (Int64(1), Int64(3))   # 1 = only the present cell; 3 = mixed
            rs = initial_state(vm, Dict(:ncells => ncells))
            run!(rs, vm; checkpoint_interval = typemax(Int), must_cache_set = mcs)
            @test is_halted(rs)
            @test result(rs)[:r] == 0          # memset(0) overwrote the present 5
            unrun!(rs, vm)
            @test rs.current == rs.initial     # mixed-cell restore exact
            @test isempty(rs.history)
            @test rs.current.arena_top == 0
        end
    end

    # ------------------------------------------------------------------
    # (5) per-step inverse (the M8.2 load-bearing pattern) at K ∈ {1, 4}.
    # ------------------------------------------------------------------
    @testset "per-step inverse at K ∈ {1, 4}" begin
        body = _BV.Instruction[
            _BV.IntrinsicMalloc(:p, Int64(16)),
            _BV.MemoryStore(:p, Int64(9)),
            _BV.Define(:p1, :p, :add, Int64(1)),
            _BV.MemoryStore(:p1, Int64(8)),
            _BV.IntrinsicMemcpy(:p, :p, Int64(0)),  # 0-cell memcpy (no-op, disjoint-trivial)
            _BV.MemoryLoad(:r, :p),
            _BV.IntrinsicFree(:p),
        ]
        vm = _mkvm(body, Symbol[], [:r], ([], [64]))
        mcs = _arena_l2_slots(vm)
        for K in (1, 4)
            @test per_step_inverse_check(vm, Dict{Symbol,Int64}();
                checkpoint_interval = K, must_cache_set = mcs,
                label = "arena/K=$K") === nothing
        end
    end

    # ------------------------------------------------------------------
    # (6) memmove (overlap-permitted) instruction-level round-trip.
    # ------------------------------------------------------------------
    @testset "memmove overlap-safe round-trip (instruction level)" begin
        IS = _BV.IState
        s = IS(1, Dict(:d => _AB + 1, :sp => _AB), :running, Dict{Int64,Int64}())
        s.arena_top = 4
        s.memory[_AB] = Int64(100); s.memory[_AB + 1] = Int64(200)
        mm = _BV.IntrinsicMemmove(:d, :sp, Int64(16))   # 2 cells, overlapping
        p = _BV.predelta_payload(mm, s)
        _BV.forward(mm, s)
        @test s.memory[_AB + 1] == 100   # src[0] → dest[0]
        @test s.memory[_AB + 2] == 200   # src[1] → dest[1] (snapshot-safe)
        _BV.inverse(mm, s, p)
        @test s.memory[_AB] == 100 && s.memory[_AB + 1] == 200
        @test !haskey(s.memory, _AB + 2)  # absent cell delete!d, no phantom
    end

    # ------------------------------------------------------------------
    # (7) ==/hash sensitivity to arena_top (ADR 0018 §H).
    # ------------------------------------------------------------------
    @testset "IState ==/hash see arena_top" begin
        IS = _BV.IState
        a = IS(1, Dict(:x => Int64(1)), :running, Dict{Int64,Int64}())
        b = deepcopy(a)
        @test a == b
        @test hash(a) == hash(b)
        b.arena_top = 7              # mutate ONLY arena_top
        @test a != b                 # inequality detected (else round-trip spurious)
        @test hash(a) != hash(b)     # hash distinct (probabilistically; here exact)
    end

    # ------------------------------------------------------------------
    # (8) Fail-loud modes (Rule 1; ADR 0018 §E).
    # ------------------------------------------------------------------
    @testset "fail-loud: bad free / bad size / overlap / unknown callee" begin
        IS = _BV.IState

        # free of a pointer not in locals.
        s = IS(1, Dict{Symbol,Int64}(), :running, Dict{Int64,Int64}())
        @test_throws ErrorException _BV.forward(_BV.IntrinsicFree(:nope), s)

        # free of a value outside the arena and stack segments (negative addr).
        s2 = IS(1, Dict(:bad => Int64(-5)), :running, Dict{Int64,Int64}())
        @test_throws ErrorException _BV.forward(_BV.IntrinsicFree(:bad), s2)

        # free of an address ABOVE the live arena (in [ARENA_BASE+arena_top, ∞)):
        # caught only with the correct per-segment bounds — the segment-model
        # guard from the CW-A2 hostile review (dead-condition bug fix).
        s2b = IS(1, Dict(:hi => Int64(_AB + 7)), :running, Dict{Int64,Int64}())
        s2b.arena_top = 4                          # live arena = [_AB, _AB+4)
        @test_throws ErrorException _BV.forward(_BV.IntrinsicFree(:hi), s2b)

        # non-cell-divisible malloc size (30 bytes, not a multiple of 8).
        s3 = IS(1, Dict{Symbol,Int64}(), :running, Dict{Int64,Int64}())
        @test_throws ErrorException _BV.forward(_BV.IntrinsicMalloc(:p, Int64(30)), s3)

        # negative size.
        s4 = IS(1, Dict{Symbol,Int64}(), :running, Dict{Int64,Int64}())
        @test_throws ErrorException _BV.forward(_BV.IntrinsicMalloc(:p, Int64(-8)), s4)

        # overlapping memcpy (dest = src+1, 2 cells → overlap).
        s5 = IS(1, Dict(:d => _AB + 1, :sp => _AB), :running, Dict{Int64,Int64}())
        s5.arena_top = 4
        @test_throws ErrorException _BV.forward(
            _BV.IntrinsicMemcpy(:d, :sp, Int64(16)), s5)

        # out-of-whitelist callee fails loud at ingest (not in _HEAP_DISPATCH
        # nor _SOFT_DISPATCH → the SoftCall allowlist reject). `gensym`'s
        # `nameof` is :gensym — in none of the dispatch sets.
        bad_call = Bennett.IRCall(:__d, gensym, Bennett.IROperand[], Int[], 64)
        blk = Bennett.IRBasicBlock(:entry, Bennett.IRInst[bad_call],
                                   Bennett.IRRet(Bennett.SSAOperand(:__d), 64))
        parsed = Bennett.ParsedIR(64, [(:__x, 64)], [blk], [64])
        @test_throws ErrorException _BV.lower_vm(parsed)
    end
end
