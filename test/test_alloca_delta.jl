# test/test_alloca_delta.jl — dynamic-N alloca + (base, n) L2 delta
# (SC9 Case A; ADR 0009 Decision 2a [bead-0zn refinement]; bead `bennettvm-0zn`).
#
# # What this file pins
#
# The `DynAlloca` instruction (`src/ir/alloca.jl`) is the runtime-sized
# allocation rung of the memory floor: an `IRAlloca` whose `n_elems` operand
# is an `SSAOperand` (a VLA / `Vector{T}(undef, n)`) cannot reserve its region
# at lowering time — the size `n` is only known at runtime. `DynAlloca` defers
# the reservation to `forward()`:
#
#   forward(DynAlloca(dest, n_operand, base), s):  s.locals[dest] = base; pc += 1
#
# materialising the pointer at a FROZEN compile-time `base` (the bump cursor at
# ingest, NOT advanced — there is no runtime bump allocator state in `IState`).
# Cells stay ABSENT (read as 0 by the floor's absent=0 convention) — forward
# does NO zeroing. Reversal is via an L2 `(base, n)` delta captured PRE-forward
# (`predelta_payload` resolves `n = s.locals[n_operand]`), whose inverse
# UNCONDITIONALLY deletes the whole fresh region `base..base+n-1` and removes
# the pointer.
#
# # The soundness lemma (the load-bearing claim — testset 5)
#
# Deleting the WHOLE region `base..base+n-1` on reverse restores the exact
# pre-alloca heap REGARDLESS of whether the region's element stores were
# tracked L2 (per-write delta) or L3 (whole-state checkpoint). Proof: the bump
# allocator (frozen base; single-dynamic-array strategy) guarantees those
# addresses were ABSENT pre-alloca and belong EXCLUSIVELY to this allocation's
# lifetime, so deleting them is the exact inverse of the alloca-plus-any-writes
# net effect on that region — there is nothing outside the region this alloca
# could have touched, and nothing inside it that pre-existed. Testset 5 forces
# an L3 checkpoint between the alloca and a region store so the store reverses
# via L3 replay (NOT L2), and asserts the per-step inverse / round-trip STILL
# restores the region cells absent — exercising the lemma under L2/L3 interleave.
#
# # Tests (Rule 4 — invariants, not "didn't throw")
#
#   1. Unit: predelta_payload returns the right (base, n); inverse deletes
#      exactly base..base+n-1 and removes the pointer.
#   2. Ingest: a dynamic-N IRAlloca lowers to a DynAlloca with the right
#      base/n_operand (cursor NOT advanced); a SECOND alloca after it RAISES.
#   3. L2 fires: with a must_cache set including the alloca slot, the forward
#      run pushes a DeltaEntry (not a CheckpointEntry) for the alloca step.
#   4. Round-trip: run! then unrun! → initial, empty history, count 0.
#   5. SOUNDNESS: L3 checkpoint between alloca and a region store; per-step
#      inverse / round-trip STILL restores the region absent.
#   6. per_step_inverse at a couple of K values (mid-instruction inverse bugs).
#
# # Ref
#
#   * `docs/adr/0009-dynamic-size-memory.md` Decision 2a (+ the 2026-05-31
#     bead-0zn impl refinement) — the (base, n) L2 delta, single-dynamic-array
#     fixed-base strategy, the unconditional-delete soundness lemma.
#   * `src/ir/alloca.jl` — `DynAlloca`, `forward`, `predelta_payload`, the L2
#     `inverse(::DynAlloca, s, ::NamedTuple)`, the raising prev catch-all.
#   * `src/ir/ingest.jl` — `_lower_alloca!` dynamic-N dispatch + the
#     fail-loud-on-second-alloca guard.
#   * `test/test_store_delta.jl` — the sibling L2-delta test this mirrors.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (invariants), Rule 5 (mutation-proof).

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# A minimal dynamic-N alloca program:
#   __arr = alloca i32, n_elems = %__n      (dynamic-N → DynAlloca)
#   __p0  = gep __arr, 0                     (element-0 pointer)
#   store 7, __p0                            (a region store)
#   __r   = load __p0                        (read it back)
#   ret __r
# Oracle: result __r == 7 for any n >= 1.
function _dyn_alloca_vm()
    block = Bennett.IRBasicBlock(
        :entry,
        Bennett.IRInst[
            Bennett.IRAlloca(:__arr, 32, Bennett.SSAOperand(:__n)),  # dynamic-N
            Bennett.IRVarGEP(:__p0, Bennett.SSAOperand(:__arr),
                             Bennett.ConstOperand(0), 32),
            Bennett.IRStore(Bennett.SSAOperand(:__p0), Bennett.ConstOperand(7), 32),
            Bennett.IRLoad(:__r, Bennett.SSAOperand(:__p0), 32),
        ],
        Bennett.IRRet(Bennett.SSAOperand(:__r), 32),
    )
    parsed = Bennett.ParsedIR(32, [(:__n, 32)], [block], [32])
    return lower_vm(parsed; opts=:dyn_alloca)
end

# A program with TWO allocas, the FIRST dynamic — used to prove the fail-loud
# single-dynamic-array guard (a static alloca after a dynamic one RAISES).
function _two_alloca_parsed()
    block = Bennett.IRBasicBlock(
        :entry,
        Bennett.IRInst[
            Bennett.IRAlloca(:__arr, 32, Bennett.SSAOperand(:__n)),       # dynamic
            Bennett.IRAlloca(:__arr2, 32, Bennett.ConstOperand(2)),       # static, AFTER
        ],
        Bennett.IRRet(Bennett.SSAOperand(:__n), 32),
    )
    return Bennett.ParsedIR(32, [(:__n, 32)], [block], [32])
end

# The (block_label, body_idx) of every Instruction of a given type in vm.
function _slots_of(vm, ::Type{T}) where {T}
    set = Set{Tuple{Symbol,Int}}()
    for b in vm.blocks
        for (i, instr) in enumerate(b.instructions)
            instr isa T && push!(set, (b.label, i))
        end
    end
    return set
end

# The L2-capable must_cache set: ONLY the slots whose instruction has a
# working L2 delta path — `DynAlloca` (predelta_payload → (base,n)) and
# `MemoryStore` (predelta_payload → (addr,old_value)). `VarGEP` / `MemoryLoad`
# are L3-only this milestone (no `make_delta` — routing them through L2 would
# hit the raising generic fallback, as `test_store_delta.jl`'s docstring §"Why
# an EXPLICIT must_cache_set" documents), so they are EXCLUDED and fall through
# to L3. This is the all-L2-where-possible set the round-trip / per-step tests
# use, distinct from `compute_must_cache` (which marks EVERY non-injective slot).
function _l2_slots(vm)
    set = Set{Tuple{Symbol,Int}}()
    for b in vm.blocks
        for (i, instr) in enumerate(b.instructions)
            (instr isa BennettVM.DynAlloca || instr isa BennettVM.MemoryStore) &&
                push!(set, (b.label, i))
        end
    end
    return set
end

@testset "alloca-delta (DynAlloca + (base,n) L2 delta; ADR 0009 Decision 2a)" begin

    # ------------------------------------------------------------------
    # (1) Unit: predelta_payload + L2 inverse, isolated from step!.
    # ------------------------------------------------------------------
    @testset "predelta_payload + L2 inverse (unit)" begin
        IS = BennettVM.IState

        # n=3, base=5: forward creates the pointer; inverse deletes 5,6,7
        # and removes the pointer. Pre-fill EVERY cell of the region 5,6,7
        # (as later stores would) to prove the inverse deletes them all, not
        # just the touched ones — and crucially fill the LAST cell (base+n-1=7)
        # so an off-by-one delete range (base..base+n-2) leaves a phantom 7=>33
        # and trips the `isempty`/`!haskey(.,7)` asserts (mutation-proof (i)).
        s = IS(1, Dict(:__n => Int64(3)), :running,
               Dict(Int64(5) => Int64(11), Int64(6) => Int64(22),
                    Int64(7) => Int64(33)))
        instr = BennettVM.DynAlloca(:__arr, :__n, Int64(5))
        p = BennettVM.predelta_payload(instr, s)
        @test p.base == 5
        @test p.n == 3

        BennettVM.forward(instr, s)
        @test s.locals[:__arr] == 5            # pointer materialised at base
        @test s.pc == 2                        # forward bumped pc

        BennettVM.inverse(instr, s, p)         # NamedTuple dispatch (L2)
        @test !haskey(s.memory, 5)             # whole region deleted...
        @test !haskey(s.memory, 6)
        @test !haskey(s.memory, 7)             # ...including the LAST cell
        @test isempty(s.memory)                # ...unconditionally
        @test !haskey(s.locals, :__arr)        # pointer removed
        @test s.pc == 1                        # pc decremented back

        # n=0 edge case: empty region, just undo the pointer.
        s0 = IS(1, Dict(:__n => Int64(0)), :running, Dict{Int64,Int64}())
        instr0 = BennettVM.DynAlloca(:__arr, :__n, Int64(9))
        p0 = BennettVM.predelta_payload(instr0, s0)
        @test p0.n == 0
        BennettVM.forward(instr0, s0)
        @test s0.locals[:__arr] == 9
        BennettVM.inverse(instr0, s0, p0)
        @test !haskey(s0.locals, :__arr)
        @test isempty(s0.memory)

        # Fail-loud: predelta_payload with an undefined n_operand.
        sbad = IS(1, Dict{Symbol,Int64}(), :running)
        instrbad = BennettVM.DynAlloca(:__arr, :__n, Int64(1))
        @test_throws ErrorException BennettVM.predelta_payload(instrbad, sbad)

        # The Any-catch-all inverse (L3-prev path) RAISES descriptively.
        sx = IS(1, Dict(:__n => Int64(1)), :running)
        @test_throws ErrorException BennettVM.inverse(
            BennettVM.DynAlloca(:__arr, :__n, Int64(1)), sx, nothing)
    end

    # ------------------------------------------------------------------
    # (1b) Rule-1 guard (hostile-review fix): a DynAlloca RE-executing under
    #      the frozen base (a loop / back-edge would reach it) fails loud at
    #      forward. The L2 inverse retracts the region + pointer
    #      UNCONDITIONALLY (delete, not restore), so a second aliasing
    #      allocation cannot be silently miscompiled — the guard ENFORCES the
    #      single-execution premise the soundness lemma rests on. (The earlier
    #      docstring claim "overwritten without error; recovering the prior
    #      value is the L2 delta's job" was FALSE — the L2 delta deletes.)
    # ------------------------------------------------------------------
    @testset "Rule-1: re-execution under frozen base fails loud" begin
        IS = BennettVM.IState
        instr = BennettVM.DynAlloca(:__arr, :__n, Int64(1))
        s = IS(1, Dict(:__n => Int64(3)), :running, Dict{Int64,Int64}())
        BennettVM.forward(instr, s)              # first execution: OK
        @test s.locals[:__arr] == 1              # pointer materialised
        # Re-execution: dest already live → loud error, NOT a silent overwrite
        # (which would orphan the prior region for the unconditional-delete
        # inverse to corrupt). This is the per-step / loop hole the hostile
        # review surfaced; the guard converts silent corruption into a raise.
        @test_throws ErrorException BennettVM.forward(instr, s)
    end

    # ------------------------------------------------------------------
    # (2) Ingest: dynamic-N IRAlloca → DynAlloca; second alloca RAISES.
    # ------------------------------------------------------------------
    @testset "ingest: dynamic-N → DynAlloca; second alloca fails loud" begin
        vm = _dyn_alloca_vm()
        # The lowered entry block's body begins with a DynAlloca whose
        # n_operand is :__n and base is the (frozen) bump cursor (1, the
        # first alloca address — see _lower_alloca!).
        entry = first(vm.blocks)
        dynallocas = filter(i -> i isa BennettVM.DynAlloca, entry.instructions)
        @test length(dynallocas) == 1
        da = dynallocas[1]
        @test da.dest == :__arr
        @test da.n_operand == :__n
        @test da.base == 1                     # frozen compile-time base

        # A SECOND alloca (here a static one) AFTER a dynamic alloca must
        # fail loud — the frozen-base single-dynamic-array strategy cannot
        # admit a second region (it would alias the frozen base).
        @test_throws ErrorException lower_vm(_two_alloca_parsed(); opts=:two_alloca)
    end

    # ------------------------------------------------------------------
    # (3) L2 fires: DeltaEntry for the alloca step, NOT a CheckpointEntry.
    # ------------------------------------------------------------------
    @testset "L2 fires for the alloca: DeltaEntry, NO CheckpointEntry" begin
        vm = _dyn_alloca_vm()
        alloca_set = _slots_of(vm, BennettVM.DynAlloca)
        @test length(alloca_set) == 1          # the one dynamic alloca

        rs = initial_state(vm, Dict(:__n => Int64(3)))
        # K = typemax suppresses L3; only the alloca slot is marked, so the
        # ONLY push is the alloca DeltaEntry (the gep / store / load are not
        # in the set → no push at K=typemax).
        run!(rs, vm; checkpoint_interval=typemax(Int), must_cache_set=alloca_set)

        @test is_halted(rs)
        @test result(rs)[:__r] == 7            # arr[0] == 7 (oracle)

        deltas = filter(e -> e isa BennettVM.DeltaEntry, rs.history)
        ckpts  = filter(e -> e isa BennettVM.CheckpointEntry, rs.history)
        @test length(ckpts) == 0               # L2 fired, NOT L3
        alloca_deltas = filter(e -> e.instruction isa BennettVM.DynAlloca, deltas)
        @test length(alloca_deltas) == 1
        ad = alloca_deltas[1]
        @test haskey(ad.payload, :base) && haskey(ad.payload, :n)
        @test ad.payload.base == 1
        @test ad.payload.n == 3
    end

    # ------------------------------------------------------------------
    # (4) Round-trip: run! then unrun! → initial, empty history, count 0.
    #     Run with the L2-capable set so the alloca AND the store take L2 (a
    #     mixed all-L2 stack); the L3-only VarGEP/MemoryLoad fall through to
    #     L3 at K-multiples (here suppressed by K=typemax → they push nothing).
    #     n varies.
    # ------------------------------------------------------------------
    @testset "round-trip via L2 (alloca + store both delta'd)" begin
        vm = _dyn_alloca_vm()
        mcs = _l2_slots(vm)            # ONLY DynAlloca + MemoryStore (L2-capable)
        for n in (Int64(1), Int64(2), Int64(5))
            rs = initial_state(vm, Dict(:__n => n))
            run!(rs, vm; checkpoint_interval=typemax(Int), must_cache_set=mcs)
            @test is_halted(rs)
            @test result(rs)[:__r] == 7
            unrun!(rs, vm)
            @test rs.current == rs.initial
            @test isempty(rs.history)
            @test rs.step_count == 0
        end
    end

    # ------------------------------------------------------------------
    # (5) SOUNDNESS LEMMA: region store reversed via L3 (NOT L2), the
    #     alloca via L2 — the per-step inverse / round-trip STILL restores
    #     the region cells ABSENT (unconditional delete proves correct
    #     under L2/L3 interleave).
    #
    #     Forcing the mix: mark ONLY the DynAlloca slot in must_cache (so the
    #     alloca takes L2). Set checkpoint_interval = 1, so EVERY non-marked
    #     non-injective step (the gep, the store, the load) pushes an L3
    #     CheckpointEntry. The region store therefore reverses via L3 replay,
    #     while the alloca reverses via its L2 (base, n) delta. The assertion:
    #     after a full backward walk the region cell is absent and the heap
    #     matches the (empty) initial — i.e. the L2 delete and the L3 replay
    #     compose to the exact pre-alloca heap.
    # ------------------------------------------------------------------
    @testset "soundness: alloca L2 + region store L3 interleave" begin
        vm = _dyn_alloca_vm()
        alloca_set = _slots_of(vm, BennettVM.DynAlloca)   # ONLY the alloca → L2
        n = Int64(4)

        # Confirm the mix actually occurs: with K=1 the store/gep/load push
        # L3 CheckpointEntrys and the alloca pushes an L2 DeltaEntry.
        rs = initial_state(vm, Dict(:__n => n))
        run!(rs, vm; checkpoint_interval=1, must_cache_set=alloca_set)
        @test is_halted(rs)
        @test result(rs)[:__r] == 7
        n_delta = count(e -> e isa BennettVM.DeltaEntry, rs.history)
        n_ckpt  = count(e -> e isa BennettVM.CheckpointEntry, rs.history)
        @test n_delta >= 1                     # the alloca's L2 (base,n) delta
        @test n_ckpt  >= 1                     # the store reversed via L3
        # The region cell base+0 is present after the forward store.
        @test haskey(rs.current.memory, Int64(1))   # base=1, element 0

        # Full backward walk restores the region absent + empty initial heap.
        unrun!(rs, vm)
        @test !haskey(rs.current.memory, Int64(1))   # region cell deleted
        @test isempty(rs.current.memory)             # exact pre-alloca heap
        @test rs.current == rs.initial
        @test isempty(rs.history)
        @test rs.step_count == 0

        # And per-step (mid-instruction) inverse holds under the SAME mix.
        @test per_step_inverse_check(
            vm, Dict(:__n => n);
            checkpoint_interval = 1,
            must_cache_set = alloca_set,
            label = "dyn_alloca/soundness-mix") === nothing
    end

    # ------------------------------------------------------------------
    # (6) per_step_inverse at K ∈ {1, 4} with the all-L2 set (mid-program
    #     inverse bugs the aggregate round-trip can mask).
    # ------------------------------------------------------------------
    @testset "per-step inverse at K ∈ {1,4}" begin
        vm = _dyn_alloca_vm()
        mcs = _l2_slots(vm)            # DynAlloca + MemoryStore → L2; rest → L3
        for K in (1, 4)
            @test per_step_inverse_check(
                vm, Dict(:__n => Int64(3));
                checkpoint_interval = K,
                must_cache_set = mcs,
                label = "dyn_alloca/K=$K") === nothing
        end
    end
end
