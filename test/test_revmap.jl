# test/test_revmap.jl — RevMap reversible-map ADT + IRMap* ops
# (SC9 Case B; ADR 0008; bead `bennettvm-jrc`).
#
# # What this file pins (Rule 4 — invariants against known values, NOT "didn't throw")
#
# This is the BennettVM-side, Bennett.jl-independent unit gate for Case B
# (a reversible `Dict`). It exercises the three `IRMap*` ops
# (`src/ir/revmap.jl`) at the OP LEVEL — `forward`, `predelta_payload`,
# the L2 NamedTuple `inverse`, the raising catch-alls, the `is_injective`
# pins — plus the `IState.revmap` integration that makes the round-trip
# invariant SEE the map (ADR 0008 Finding 3). It does NOT build a
# hand-built `VMProgram` round-trip through `run!`/`unrun!`; that is the
# SEPARATE bead `bennettvm-l49`. The unit-level forward+inverse exercise
# here mirrors testset (0) of `test/test_store_delta.jl` (the `MemoryStore`
# `predelta_payload` + L2 inverse unit test).
#
# # Coverage map (brief points 1–6)
#
#   1. Each op's `forward` against known map/locals content.
#   2. IRMapInsert / IRMapDelete round-trip via predelta_payload →
#      DeltaEntry → inverse(::NamedTuple), INCLUDING the absent-key /
#      missing-sentinel cases (insert over absent → inverse deletes, no
#      phantom {k=>0}; delete of absent → inverse no-ops). Asserts full
#      IState.== to a pre-snapshot.
#   3. The catch-all inverse(..., prev::Any) RAISES for all three.
#   4. is_injective(::Type{...}) == false for all three.
#   5. IState integration (ADR 0008 Finding 3): two IStates differing ONLY
#      in revmap content are != and hash differently; equal-content
#      revmaps (distinct Dict objects) are ==; deepcopy copies the revmap
#      independently.
#   6. Mutation-proof notes (performed manually, reverted, NOT in tree):
#      see the §"Mutation-proof" block below.
#
# # Mutation-proof (Rule 5) — performed manually, reverted, NOT in tree
#
# Two perturbations, each confirmed RED then restored (captured in the
# agent report):
#
#   (i) `Base.:(==)(::IState, ::IState)`: drop the `a.revmap == b.revmap`
#       clause (`src/ir/IState.jl`). Testset 5's "==-sees-revmap" assertion
#       (two states differing only in revmap content asserted `!=`) goes
#       RED — without the clause the states compare EQUAL, exactly the
#       spurious-pass Finding 3(a) warns of.
#
#   (ii) `inverse(::IRMapInsert, s, p::NamedTuple)` (`src/ir/revmap.jl`):
#        break the missing-sentinel branch — `s.revmap[p.key] = p.prior`
#        UNCONDITIONALLY (drop the `prior === missing → delete!`). Testset
#        2's absent-key insert round-trip goes RED: the inverse tries
#        `s.revmap[k] = missing`, which fails the `Dict{Int64,Int64}`
#        value-type (or, if the type allowed it, leaves a phantom
#        `{k=>0}`), so `s != pre`.
#
# # Ref
#
#   * `docs/adr/0008-dict-reversibility.md` Decisions 1–6, Findings 3–5.
#   * `src/ir/revmap.jl` — the three ops under test.
#   * `src/ir/IState.jl` — the `revmap` field + `==`/`hash` overrides.
#   * `test/test_store_delta.jl` testset (0) — the MemoryStore L2 unit
#     pattern this file mirrors.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known-correct invariants),
#     Rule 5 (mutation-proof), Rule 11 (literate).

using Test
using BennettVM

const IS  = BennettVM.IState
const Ins = BennettVM.IRMapInsert
const Del = BennettVM.IRMapDelete
const Get = BennettVM.IRMapGet

@testset "RevMap + IRMap* ops (SC9 Case B; ADR 0008)" begin

    # ------------------------------------------------------------------
    # (1) forward semantics against known map/locals content.
    # ------------------------------------------------------------------
    @testset "forward semantics (Rule 4: known-value asserts)" begin
        # IRMapInsert with literal key+value into an empty map.
        s = IS(1, Dict{Symbol,Int64}(), :running,
               Dict{Int64,Int64}(), Dict{Int64,Int64}())
        BennettVM.forward(Ins(Int64(3), Int64(7)), s)
        @test s.revmap == Dict(Int64(3) => Int64(7))
        @test s.pc == 2

        # IRMapInsert OVERWRITES an existing binding (non-injective).
        BennettVM.forward(Ins(Int64(3), Int64(99)), s)
        @test s.revmap[3] == 99
        @test length(s.revmap) == 1
        @test s.pc == 3

        # IRMapInsert with SSA-ref operands (resolved via _resolve).
        s2 = IS(1, Dict(:k => Int64(5), :v => Int64(50)), :running,
                Dict{Int64,Int64}(), Dict{Int64,Int64}())
        BennettVM.forward(Ins(:k, :v), s2)
        @test s2.revmap == Dict(Int64(5) => Int64(50))

        # IRMapGet reads a present key into a fresh local (the fdict shape:
        # insert k=>v then get k).
        sg = IS(1, Dict{Symbol,Int64}(), :running,
                Dict{Int64,Int64}(), Dict(Int64(3) => Int64(7)))
        BennettVM.forward(Get(:r, Int64(3)), sg)
        @test BennettVM.active_locals(sg)[:r] == 7        # the fdict(3,7) => 7 oracle, ADR 0008 l.633
        @test sg.pc == 2
        @test sg.revmap == Dict(Int64(3) => Int64(7))   # map UNCHANGED (read)

        # IRMapGet of an ABSENT key FAILS LOUD (Rule 1; ADR 0008 design
        # call — NOT zero-init like MemoryLoad).
        sga = IS(1, Dict{Symbol,Int64}(), :running,
                 Dict{Int64,Int64}(), Dict{Int64,Int64}())
        @test_throws ErrorException BennettVM.forward(Get(:r, Int64(42)), sga)

        # IRMapDelete removes a present binding.
        sd = IS(1, Dict{Symbol,Int64}(), :running,
                Dict{Int64,Int64}(), Dict(Int64(3) => Int64(7),
                                          Int64(4) => Int64(8)))
        BennettVM.forward(Del(Int64(3)), sd)
        @test sd.revmap == Dict(Int64(4) => Int64(8))
        @test sd.pc == 2

        # IRMapDelete of an ABSENT key is a no-op (Julia delete! semantics).
        BennettVM.forward(Del(Int64(99)), sd)
        @test sd.revmap == Dict(Int64(4) => Int64(8))   # unchanged
        @test sd.pc == 3
    end

    # ------------------------------------------------------------------
    # (2) Round-trip via predelta_payload → DeltaEntry → inverse(::NamedTuple),
    #     including the absent-key / missing-sentinel cases. Full IState.==
    #     to a pre-snapshot.
    # ------------------------------------------------------------------
    @testset "IRMapInsert round-trip (present + absent key)" begin
        # PRESENT key: insert over an existing binding → inverse restores it.
        s = IS(1, Dict{Symbol,Int64}(), :running,
               Dict{Int64,Int64}(), Dict(Int64(3) => Int64(7)))
        pre = deepcopy(s)
        instr = Ins(Int64(3), Int64(99))
        p = BennettVM.predelta_payload(instr, s)
        @test p.key == 3
        @test p.prior == 7            # captured the prior binding
        BennettVM.forward(instr, s)
        @test s.revmap[3] == 99       # overwritten
        # The DeltaEntry wraps instr + the captured NamedTuple payload.
        de = BennettVM.DeltaEntry(instr, p, 1)
        BennettVM.inverse(de.instruction, s, de.payload)
        @test s == pre                # FULL IState.== to the pre-snapshot
        @test s.revmap == Dict(Int64(3) => Int64(7))

        # ABSENT key: insert a brand-new key → inverse DELETES it (no {k=>0}).
        s2 = IS(1, Dict{Symbol,Int64}(), :running,
                Dict{Int64,Int64}(), Dict{Int64,Int64}())
        pre2 = deepcopy(s2)
        @test isempty(s2.revmap)
        instr2 = Ins(Int64(5), Int64(50))
        p2 = BennettVM.predelta_payload(instr2, s2)
        @test p2.key == 5
        @test p2.prior === missing    # the absent-key sentinel
        BennettVM.forward(instr2, s2)
        @test s2.revmap == Dict(Int64(5) => Int64(50))
        BennettVM.inverse(instr2, s2, p2)
        @test !haskey(s2.revmap, 5)   # DELETED, not left as {5=>0}
        @test isempty(s2.revmap)
        @test s2 == pre2              # FULL IState.== to the empty pre-state
    end

    @testset "IRMapDelete round-trip (present + absent key)" begin
        # PRESENT key: delete an existing binding → inverse restores it.
        s = IS(1, Dict{Symbol,Int64}(), :running,
               Dict{Int64,Int64}(), Dict(Int64(3) => Int64(7),
                                         Int64(4) => Int64(8)))
        pre = deepcopy(s)
        instr = Del(Int64(3))
        p = BennettVM.predelta_payload(instr, s)
        @test p.key == 3
        @test p.prior == 7
        BennettVM.forward(instr, s)
        @test !haskey(s.revmap, 3)
        BennettVM.inverse(instr, s, p)
        @test s == pre                # restored {3=>7, 4=>8}
        @test s.revmap == Dict(Int64(3) => Int64(7), Int64(4) => Int64(8))

        # ABSENT key: delete a key not in the map (forward no-op) → inverse
        # must ALSO be a no-op (the senior-grade hardening over ADR Finding 4;
        # a bare old_val payload would spuriously re-insert).
        s2 = IS(1, Dict{Symbol,Int64}(), :running,
                Dict{Int64,Int64}(), Dict(Int64(4) => Int64(8)))
        pre2 = deepcopy(s2)
        instr2 = Del(Int64(99))
        p2 = BennettVM.predelta_payload(instr2, s2)
        @test p2.key == 99
        @test p2.prior === missing    # absent → nothing to restore
        BennettVM.forward(instr2, s2)
        @test s2.revmap == Dict(Int64(4) => Int64(8))   # forward no-op
        BennettVM.inverse(instr2, s2, p2)
        @test s2 == pre2              # inverse no-op: NO spurious {99=>...}
        @test !haskey(s2.revmap, 99)
        @test s2.revmap == Dict(Int64(4) => Int64(8))
    end

    # ------------------------------------------------------------------
    # (3) The catch-all inverse(..., prev::Any) RAISES for all three.
    # ------------------------------------------------------------------
    @testset "prev::Any catch-all inverse RAISES (Rule 1, all three)" begin
        s = IS(1, Dict{Symbol,Int64}(), :running,
               Dict{Int64,Int64}(), Dict(Int64(3) => Int64(7)))
        @test_throws ErrorException BennettVM.inverse(Ins(Int64(3), Int64(7)), s, nothing)
        @test_throws ErrorException BennettVM.inverse(Del(Int64(3)), s, nothing)
        @test_throws ErrorException BennettVM.inverse(Get(:r, Int64(3)), s, nothing)
        # And an arbitrary non-NamedTuple `prev` value also routes to the raise.
        @test_throws ErrorException BennettVM.inverse(Ins(Int64(3), Int64(7)), s, 42)
        @test_throws ErrorException BennettVM.inverse(Get(:r, Int64(3)), s, :foo)
    end

    # ------------------------------------------------------------------
    # (4) is_injective(::Type{...}) == false for all three.
    # ------------------------------------------------------------------
    @testset "is_injective == false (the L3/L2 push gate)" begin
        @test BennettVM.is_injective(Ins) == false
        @test BennettVM.is_injective(Del) == false
        @test BennettVM.is_injective(Get) == false
        # Value-level fallback agrees with the type-level pin.
        @test BennettVM.is_injective(Ins(Int64(1), Int64(2))) == false
        @test BennettVM.is_injective(Del(Int64(1))) == false
        @test BennettVM.is_injective(Get(:r, Int64(1))) == false
        # The two mutating ops are L2-capable (predelta path); Get is NOT.
        @test BennettVM.is_l2_capable(Ins) == true
        @test BennettVM.is_l2_capable(Del) == true
        @test BennettVM.is_l2_capable(Get) == false
    end

    # ------------------------------------------------------------------
    # (5) IState integration (load-bearing, ADR 0008 Finding 3): the
    #     round-trip invariant must SEE the revmap. This is the test the
    #     `a.revmap == b.revmap` clause makes pass (mutation-proof (i)).
    # ------------------------------------------------------------------
    @testset "IState.== / hash SEE revmap (ADR 0008 Finding 3)" begin
        # Two IStates identical EXCEPT revmap content → != and hash differ.
        a = IS(1, Dict{Symbol,Int64}(), :running,
               Dict{Int64,Int64}(), Dict(Int64(3) => Int64(7)))
        b = IS(1, Dict{Symbol,Int64}(), :running,
               Dict{Int64,Int64}(), Dict(Int64(3) => Int64(8)))   # diff VALUE
        @test a != b
        @test hash(a) != hash(b)

        c = IS(1, Dict{Symbol,Int64}(), :running,
               Dict{Int64,Int64}(), Dict(Int64(4) => Int64(7)))   # diff KEY
        @test a != c
        @test hash(a) != hash(c)

        d = IS(1, Dict{Symbol,Int64}(), :running,
               Dict{Int64,Int64}(), Dict{Int64,Int64}())          # empty map
        @test a != d
        @test hash(a) != hash(d)

        # Equal-content revmaps in DISTINCT Dict objects compare == (the
        # spike Dict-identity trap: content equality, not objectid).
        m1 = Dict(Int64(3) => Int64(7), Int64(4) => Int64(8))
        m2 = Dict(Int64(4) => Int64(8), Int64(3) => Int64(7))     # diff insert order
        @test m1 !== m2                                            # distinct objects
        e1 = IS(1, Dict{Symbol,Int64}(), :running, Dict{Int64,Int64}(), m1)
        e2 = IS(1, Dict{Symbol,Int64}(), :running, Dict{Int64,Int64}(), m2)
        @test e1 == e2                                            # CONTENT-equal
        @test hash(e1) == hash(e2)                                # hash contract

        # The 3-arg / 4-arg constructors default revmap to an EMPTY map, so a
        # state built without a map equals one built with an explicit empty map.
        three_arg = IS(1, Dict{Symbol,Int64}(), :running)
        @test isempty(three_arg.revmap)
        @test three_arg == d                                      # both empty-map
    end

    @testset "deepcopy copies the revmap independently (L3-checkpoint safe)" begin
        s = IS(1, Dict{Symbol,Int64}(), :running,
               Dict{Int64,Int64}(), Dict(Int64(3) => Int64(7)))
        snap = deepcopy(s)
        @test s == snap
        @test s.revmap !== snap.revmap          # distinct Dict objects
        # Mutating the ORIGINAL's revmap must not touch the snapshot — this is
        # exactly what makes CheckpointEntry's deepcopy(IState) capture the map
        # (ADR 0008 Finding 3(b)).
        s.revmap[5] = 50
        @test snap.revmap == Dict(Int64(3) => Int64(7))   # snapshot untouched
        @test s.revmap == Dict(Int64(3) => Int64(7), Int64(5) => Int64(50))
        @test s != snap
        # And the reverse: mutating the COPY does not touch the original.
        snap2 = deepcopy(s)
        delete!(snap2.revmap, 3)
        @test haskey(s.revmap, 3)               # original untouched
    end
end
