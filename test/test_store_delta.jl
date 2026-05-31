# test/test_store_delta.jl — indexed lossy store + (addr, old_value) L2 delta
# (SC9 Case A Unit 2; ADR 0009 Decision 2b/4.4; bead `bennettvm-ekc`).
#
# # What this file pins
#
# Unit 2 gives the `MemoryStore` instruction (`src/ir/memory_floor.jl`) an
# **L2 `(addr, old_value, was_present)` delta** so that a marked store
# reverses via the cheap M7.4 delta fast-path
# (`src/history/Replay.jl` `unstep!`) instead of an L3 full-state
# `CheckpointEntry`. This is the FIRST L2 delta in BennettVM that needs
# PRE-`forward()` state: the inverse must restore the cell value that the
# store overwrote, and that value is gone the instant `forward()` runs. So
# Unit 2 also lands a `step!` change — `predelta_payload(instr, s_pre)` —
# that captures the minimal pre-state for an L2 delta that needs it, WITHOUT
# deep-copying the whole `IState` (a full deepcopy per step is the L3 cost
# that defeats L2's space win).
#
# # The three things this file proves (Rule 4 — invariants, not "didn't throw")
#
#   1. **L2 path actually fires.** With a `must_cache_set` that marks ONLY
#      the `MemoryStore` body slots, a forward run leaves >= (number of
#      marked stores) `DeltaEntry`s on `rs.history` AND zero
#      `CheckpointEntry`s. Asserting the absence of L3 is what proves L2
#      fired — a round-trip that "happens to work via L3" would NOT satisfy
#      this (the mutation-proofs below confirm the L2 inverse is exercised).
#
#   2. **Round-trip.** `run!` then `unrun!` → `rs.current == rs.initial`,
#      `isempty(rs.history)`, `rs.step_count == 0`. The Bennett-1973
#      Stage-3 retrace, here driven through the L2 delta fast-path.
#
#   3. **Absent-cell handling is load-bearing.** A store to a cell never
#      written before is the missing-sentinel trap (ADR 0008 Dict; the same
#      issue `IState.==` has on memory): `IState.memory` uses the absent=0
#      convention (`get(s.memory, a, 0)`), but `Base.:(==)(::IState, ::IState)`
#      compares `a.memory == b.memory` by Dict CONTENT — so `{addr=>0}` is
#      NOT equal to the initial `{}`. If the store's inverse wrote `0` back
#      into a previously-absent cell, the key would persist and round-trip
#      equality would FAIL. The delta therefore captures `was_present`, and
#      the inverse `delete!`s the cell when it was absent. Test (3) and the
#      first mutation-proof below pin this.
#
# # Why an EXPLICIT must_cache_set, not `compute_must_cache(vm)` (report item (e))
#
# `compute_must_cache(vm)` (`src/analysis/liveness.jl`) is the conservative
# stub: it marks EVERY non-injective body slot. The lowered array program's
# body is `Define, VarGEP, MemoryStore, VarGEP, MemoryStore, VarGEP,
# MemoryLoad` (verified this session) — all seven non-injective. Routing
# `Define` / `VarGEP` / `MemoryLoad` through L2 would call their `make_delta`,
# which (correctly, this milestone) RAISES — those remain L3-only (the brief:
# "Leave MemoryLoad L3-only"). So Unit 2 marks ONLY the `MemoryStore` slots
# via an explicit set built by scanning `vm.blocks` for `MemoryStore`. The
# non-store non-injective instructions fall through to L3 (K-multiple) — the
# trichotomy at the push site (`src/interpreter/Interpreter.jl`). To keep the
# "zero CheckpointEntry" assertion meaningful we run with K = typemax(Int)
# (L3 suppressed), so the only pushes are the store DeltaEntries.
#
# # Mutation-proof (Rule 5) — performed manually, reverted, NOT in tree
#
# Two perturbations of `src/ir/memory_floor.jl`, each confirmed RED then
# restored (see report item (c) for the captured evidence):
#
#   (i) Inverse always `setindex!` (drop the `was_present`→`delete!` branch:
#       `s.memory[p.addr] = p.old_value` unconditionally). The absent-cell
#       round-trip (testset 3) goes RED: the inverse leaves `{addr=>0}` where
#       the initial had no key, so `rs.current.memory != rs.initial.memory`
#       and `rs.current != rs.initial`.
#
#   (ii) `predelta_payload(::MemoryStore, s)` made to return `nothing` so the
#       push gate falls back to `make_delta(instr, s.current, step)`. Because
#       `MemoryStore` has NO `make_delta` method, this hits the generic
#       RAISING fallback (delta.jl) at push time — testsets (1)/(2) ERROR out
#       RED. (The point this pins: the pre-state hook is the SOLE L2 path for
#       MemoryStore; there is no empty-payload path that could silently
#       capture the wrong old_value.)
#
# # Ref
#
#   * `docs/adr/0009-dynamic-size-memory.md` Decision 2b/4.4 — the indexed
#     store + (addr, old_value) L2 delta mandate; per-write O(1) delta over
#     L3 whole-state snapshots (PRD §3.3 forbids full snapshots).
#   * `src/ir/memory_floor.jl` — `MemoryStore`, `predelta_payload`, the L2
#     `inverse(::MemoryStore, s, ::NamedTuple)`, and the retained raising
#     `inverse(::MemoryStore, s, ::Any)` catch-all (the L3 deferral).
#   * `src/interpreter/Interpreter.jl` — the `step!` pre-state capture
#     mechanism (`predelta_payload`) and the push gate.
#   * `src/history/Replay.jl` (M7.4) — the `unstep!` delta fast-path that
#     pops a `DeltaEntry` and calls `inverse(instr, s.current, payload)`.
#   * `test/test_array_floor.jl` (Unit 1) — the sibling whose hand-built
#     array `ParsedIR` shape this file reuses.
#   * `test/test_delta_push.jl` (M7.6) — how DeltaEntry-in-history is asserted
#     and how `must_cache_set` is passed to `run!` / `step!`.
#   * `test/test_per_step_inverse.jl` — the `per_step_inverse_check` scaffold.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known-correct invariants),
#     Rule 5 (mutation-proof), Rule 11 (literate).

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# Build the hand-built array ParsedIR and lower it. Two indexed stores to
# the array's first two cells, then a runtime-index gep + load + ret. The
# stores write to cells that are ABSENT before the store (the bump
# allocator reserves without populating) — so they exercise the absent-cell
# branch of the L2 inverse.
function _store_delta_vm()
    gep(dest, k) = Bennett.IRVarGEP(dest, Bennett.SSAOperand(:__arr),
                                    Bennett.ConstOperand(k), 32)
    block = Bennett.IRBasicBlock(
        :entry,
        Bennett.IRInst[
            Bennett.IRAlloca(:__arr, 32, Bennett.ConstOperand(4)),
            gep(:__p0, 0),
            Bennett.IRStore(Bennett.SSAOperand(:__p0), Bennett.ConstOperand(10), 32),
            gep(:__p1, 1),
            Bennett.IRStore(Bennett.SSAOperand(:__p1), Bennett.ConstOperand(20), 32),
            Bennett.IRVarGEP(:__p, Bennett.SSAOperand(:__arr),
                             Bennett.SSAOperand(:__idx), 32),
            Bennett.IRLoad(:__r, Bennett.SSAOperand(:__p), 32),
        ],
        Bennett.IRRet(Bennett.SSAOperand(:__r), 32),
    )
    parsed = Bennett.ParsedIR(32, [(:__idx, 32)], [block], [32])
    return lower_vm(parsed; opts=:store_delta)
end

# Scan a lowered VMProgram for the (block_label, body_idx) coordinates of
# every MemoryStore. This is the EXPLICIT must_cache_set that marks ONLY
# the stores (see the file docstring §"Why an EXPLICIT must_cache_set").
function _store_slots(vm)
    set = Set{Tuple{Symbol,Int}}()
    for b in vm.blocks
        for (i, instr) in enumerate(b.instructions)
            instr isa BennettVM.MemoryStore && push!(set, (b.label, i))
        end
    end
    return set
end

@testset "store-delta (MemoryStore L2 (addr,old_value) delta; ADR 0009 Unit 2)" begin

    # ------------------------------------------------------------------
    # (0) predelta_payload reads PRE-forward state; the L2 inverse
    #     restores / deletes the cell. Direct unit exercise of the new
    #     mechanism, isolated from the interpreter loop.
    # ------------------------------------------------------------------
    @testset "predelta_payload + L2 inverse (unit, isolated from step!)" begin
        IS = BennettVM.IState

        # Cell PRESENT before the store: old_value captured, was_present=true.
        # locals: ptr __p → addr 7; memory has 7 => 99 already.
        s = IS(1, Dict(:__p => Int64(7)), :running, Dict(Int64(7) => Int64(99)))
        instr = BennettVM.MemoryStore(:__p, Int64(123))
        p = BennettVM.predelta_payload(instr, s)
        @test p.addr == 7
        @test p.old_value == 99
        @test p.was_present == true
        # forward overwrites the cell; then the L2 inverse restores it.
        BennettVM.forward(instr, s)
        @test s.memory[7] == 123
        BennettVM.inverse(instr, s, p)         # NamedTuple dispatch (L2)
        @test s.memory[7] == 99                # restored
        @test s.pc == 1                        # forward bumped to 2; inverse → 1

        # Cell ABSENT before the store: old_value=0 (absent=0 convention),
        # was_present=false → inverse must DELETE, not write 0.
        s2 = IS(1, Dict(:__p => Int64(8)), :running, Dict{Int64,Int64}())
        instr2 = BennettVM.MemoryStore(:__p, Int64(456))
        p2 = BennettVM.predelta_payload(instr2, s2)
        @test p2.addr == 8
        @test p2.old_value == 0
        @test p2.was_present == false
        BennettVM.forward(instr2, s2)
        @test s2.memory[8] == 456
        BennettVM.inverse(instr2, s2, p2)
        @test !haskey(s2.memory, 8)            # DELETED, not left as {8=>0}
        @test isempty(s2.memory)               # back to the empty initial heap
    end

    # ------------------------------------------------------------------
    # (1) L2 path ACTUALLY fires (Rule 4: prove L2, not just round-trip).
    # ------------------------------------------------------------------
    @testset "L2 fires: DeltaEntry per marked store, NO CheckpointEntry" begin
        vm = _store_delta_vm()
        store_set = _store_slots(vm)
        @test length(store_set) == 2          # two indexed stores marked

        rs = initial_state(vm, Dict(:__idx => Int64(0)))
        # K = typemax(Int) suppresses L3 entirely; the non-store
        # non-injective instructions (Define / VarGEP / MemoryLoad) are
        # NOT in store_set so they take neither L2 nor L3 → no push. The
        # ONLY pushes are the two store DeltaEntries.
        run!(rs, vm; checkpoint_interval=typemax(Int), must_cache_set=store_set)

        @test is_halted(rs)
        @test result(rs)[:__r] == 10           # arr[0] == 10 (oracle)

        n_delta = count(e -> e isa BennettVM.DeltaEntry, rs.history)
        n_ckpt  = count(e -> e isa BennettVM.CheckpointEntry, rs.history)
        @test n_delta >= length(store_set)     # >= the marked-store count
        @test n_delta == 2                      # exactly the two stores
        @test n_ckpt == 0                       # L2 fired, NOT L3
        # Each DeltaEntry wraps a MemoryStore and carries the pre-state.
        @test all(e -> e.instruction isa BennettVM.MemoryStore,
                  filter(e -> e isa BennettVM.DeltaEntry, rs.history))
        @test all(e -> haskey(e.payload, :addr) &&
                       haskey(e.payload, :old_value) &&
                       haskey(e.payload, :was_present),
                  filter(e -> e isa BennettVM.DeltaEntry, rs.history))
    end

    # ------------------------------------------------------------------
    # (2) Round-trip: run! then unrun! → initial, empty history, count 0.
    # ------------------------------------------------------------------
    @testset "round-trip via L2 delta fast-path" begin
        vm = _store_delta_vm()
        store_set = _store_slots(vm)
        for idx in (Int64(0), Int64(1), Int64(2), Int64(3))
            rs = initial_state(vm, Dict(:__idx => idx))
            run!(rs, vm; checkpoint_interval=typemax(Int), must_cache_set=store_set)
            @test is_halted(rs)
            unrun!(rs, vm)
            @test rs.current == rs.initial
            @test isempty(rs.history)
            @test rs.step_count == 0
        end
    end

    # ------------------------------------------------------------------
    # (3) Absent-cell case (THE missing-sentinel trap, ADR 0008 Dict).
    #     Both stores write to cells absent before the store; the L2
    #     store-inverse must DELETE the cell, not leave {a=>0}.
    #
    #     IMPORTANT — why we step backward MANUALLY rather than just
    #     `unrun!` + assert. A bare `unrun!` then "cell absent?" assertion
    #     does NOT reliably catch mutation (i): at K=typemax the non-store
    #     steps (Define / VarGEP / MemoryLoad) push nothing, so the FINAL
    #     `unstep!`s fall through to the L3 `s.initial` restore
    #     (`src/history/Replay.jl` step (3)), which wholesale-replaces
    #     `rs.current` with the empty initial heap and MASKS any phantom
    #     `{a=>0}` the buggy store-inverse left. To pin the store-inverse's
    #     absent branch directly, we `unstep!` one step at a time and assert
    #     cell absence at the EXACT moment each store DeltaEntry is popped
    #     (before any later L3 restore can mask it). This is the assertion
    #     mutation (i) turns RED.
    # ------------------------------------------------------------------
    @testset "absent-cell: L2 store-inverse DELETEs the cell (no {a=>0})" begin
        vm = _store_delta_vm()
        store_set = _store_slots(vm)
        rs = initial_state(vm, Dict(:__idx => Int64(0)))

        # The initial heap is empty (no cell is present at step 0).
        @test isempty(rs.initial.memory)

        run!(rs, vm; checkpoint_interval=typemax(Int), must_cache_set=store_set)
        store_addrs = Set(e.payload.addr
                          for e in rs.history if e isa BennettVM.DeltaEntry)
        @test length(store_addrs) == 2
        for a in store_addrs
            @test haskey(rs.current.memory, a)   # present after forward
        end

        # Step backward one at a time. The instant a store DeltaEntry is on
        # top of history, the next `unstep!` invokes the L2 store-inverse;
        # because each store wrote a previously-ABSENT cell (was_present=
        # false), that cell MUST be gone from `rs.current.memory` right
        # after the unstep — NOT left as `{a=>0}`. Mutation (i)
        # (unconditional setindex!) leaves `{a=>0}` and trips this assert.
        n_store_inverses = 0
        while rs.step_count > 0
            # The top entry is a store DeltaEntry exactly when the M7.4
            # fast-path is about to invoke the L2 store-inverse. (When
            # history is empty / the top is from an earlier step, `unstep!`
            # falls through to the L3 `s.initial` replay — no store-inverse
            # fires that step.)
            top = isempty(rs.history) ? nothing : last(rs.history)
            is_store_delta = top isa BennettVM.DeltaEntry &&
                             top.instruction isa BennettVM.MemoryStore &&
                             BennettVM._entry_step(top) == rs.step_count
            target_addr = is_store_delta ? top.payload.addr : nothing
            unstep!(rs, vm)
            if is_store_delta
                # The store wrote an absent cell → after its inverse the
                # cell is ABSENT again (the was_present=false delete branch).
                @test !haskey(rs.current.memory, target_addr)
                n_store_inverses += 1
            end
        end
        # Both store-inverses fired via the L2 fast-path (not masked by L3).
        @test n_store_inverses == 2

        # And the aggregate round-trip invariants still hold.
        @test rs.current.memory == rs.initial.memory   # both empty
        @test rs.current == rs.initial
        @test isempty(rs.history)
        @test rs.step_count == 0
    end

    # ------------------------------------------------------------------
    # (4) per_step_inverse_check at K ∈ {1, 4} with the L2 store set.
    #     Catches a mid-program reversal bug the aggregate round-trip can
    #     mask. The store set drives the L2 fast-path on the store steps;
    #     the other non-injective steps fall through to L3 at K-multiples.
    # ------------------------------------------------------------------
    @testset "per-step inverse (mixed L2 store-delta + L3) at K ∈ {1,4}" begin
        vm = _store_delta_vm()
        store_set = _store_slots(vm)
        for K in (1, 4)
            @test per_step_inverse_check(
                vm, Dict(:__idx => Int64(2));
                checkpoint_interval = K,
                must_cache_set = store_set,
                label = "store_delta/K=$K") === nothing
        end
    end

    # ------------------------------------------------------------------
    # (5) Present-cell case: store to a cell that ALREADY holds a value.
    #     Exercises the was_present=true → setindex! restore branch through
    #     the full interpreter loop (a second store to the SAME pointer).
    # ------------------------------------------------------------------
    @testset "present-cell: overwrite-then-restore via L2 (was_present=true)" begin
        # arr[0] = 10 ; arr[0] = 99  — the second store overwrites a cell
        # that the first store already made present. The second store's
        # delta must capture old_value=10, was_present=true.
        gep0() = Bennett.IRVarGEP(:__p0, Bennett.SSAOperand(:__arr),
                                  Bennett.ConstOperand(0), 32)
        block = Bennett.IRBasicBlock(
            :entry,
            Bennett.IRInst[
                Bennett.IRAlloca(:__arr, 32, Bennett.ConstOperand(2)),
                gep0(),
                Bennett.IRStore(Bennett.SSAOperand(:__p0), Bennett.ConstOperand(10), 32),
                Bennett.IRStore(Bennett.SSAOperand(:__p0), Bennett.ConstOperand(99), 32),
                Bennett.IRLoad(:__r, Bennett.SSAOperand(:__p0), 32),
            ],
            Bennett.IRRet(Bennett.SSAOperand(:__r), 32),
        )
        parsed = Bennett.ParsedIR(32, [(:__idx, 32)], [block], [32])
        vm = lower_vm(parsed; opts=:store_delta_present)
        store_set = _store_slots(vm)
        @test length(store_set) == 2          # both stores marked

        rs = initial_state(vm, Dict(:__idx => Int64(0)))
        run!(rs, vm; checkpoint_interval=typemax(Int), must_cache_set=store_set)
        @test is_halted(rs)
        @test result(rs)[:__r] == 99           # last write wins

        # The second store's delta captured was_present=true, old_value=10.
        deltas = filter(e -> e isa BennettVM.DeltaEntry, rs.history)
        @test length(deltas) == 2
        # The two stores hit the SAME address; one captured was_present
        # false (the first, cell absent) and one true (the second).
        present_flags = sort([e.payload.was_present for e in deltas])
        @test present_flags == [false, true]

        unrun!(rs, vm)
        @test rs.current == rs.initial
        @test isempty(rs.history)
        @test rs.step_count == 0
    end
end
