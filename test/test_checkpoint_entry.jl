# test/test_checkpoint_entry.jl — M4.1 unit tests for `CheckpointEntry`
# (bd `bennettvm-v1t`).
#
# # Why these tests exist
#
# `src/history/CheckpointEntry.jl` introduces the first concrete subtype
# of `AbstractHistoryEntry`, carrying a periodic full-state `IState`
# snapshot for the PRD v4 §3.3 L3 history mechanism. Per Rule 4
# ("'Runs without errors' is not a passing test"), every `@test` below
# pins one specific invariant against a known-correct value. The most
# load-bearing test in this file is the **deep-copy aliasing test**:
# without that invariant, M4.2's `step!` push of a `CheckpointEntry`
# would silently capture the running `IState` by reference, and every
# checkpoint on `s.history` would alias the same live state. The
# round-trip invariant M4.5 will exercise (`unrun!(run!(s, prog)) ==
# initial(s) && isempty(s.history)`) would fail in a way that looks
# like an off-by-one bug but is actually an aliasing bug — exactly the
# diagnosis category Rule 2 ("All bugs are deep") warns against papering
# over. Pinning the deep-copy contract HERE, at construction, means M4.2/
# M4.3/M4.4 can rely on it unconditionally.
#
# # Mutation-proof intent
#
# Per CLAUDE.md Rule 5 ("Port-and-verify"), each test below corresponds
# to a specific spike-Q2 mutation that would break a real downstream
# consumer if the test ever silently regressed. Two distinct spike
# lessons are exercised: Q2.2 (deep-copy / snapshot aliasing) for the
# constructor contract, and Q2.1 (Dict-identity on `==`/`hash`) for the
# equality overrides:
#
#   - Drop the `deepcopy` in the constructor → the aliasing test (#2)
#     turns RED. (spike Q2.2)
#   - Drop the `Base.==` override → the structural-equality test (#3)
#     and the Set round-trip (#4) turn RED. (spike Q2.1)
#   - Drop the `Base.hash` override → the Set round-trip (#4) turns RED.
#     (spike Q2.1)
#   - Forget `<: AbstractHistoryEntry` → the subtype test (#5) turns RED,
#     AND a future `Vector{AbstractHistoryEntry}` push! would error at
#     a downstream call site.
#   - Reject `Integer` other than `Int` → the integer-coercion test (#6)
#     turns RED.
#
# Ref: src/history/CheckpointEntry.jl (the type under test; full
#      rationale in its file-level docstring).
# Ref: bennettvm_prd.md §3.3 (three-layer history; L3 is checkpoint+replay).
# Ref: spike/RETROSPECTIVE.md Q2.2 (the deep-copy / snapshot-aliasing
#      contract that motivates the constructor's mandatory deepcopy);
#      spike/RETROSPECTIVE.md Q2.1 (the related Dict-identity trap on
#      `==`/`hash` that motivates the equality overrides).
# Ref: CLAUDE.md Rule 4 (every @test asserts a specific value),
#      Rule 1 (fail loud), Rule 11 (literate test docstrings).

using Test
using BennettVM

@testset "CheckpointEntry (M4.1)" begin
    # ---- Test 1: construction sets fields correctly ----
    # Sanity check before the more interesting tests. The captured
    # snapshot must be content-equal to the source (deepcopy preserves
    # content, IState.== compares content per M2.2); the step must be
    # the integer we passed in.
    src_state = BennettVM.IState(3, Dict(:x => Int64(7), :y => Int64(11)),
                                 :running)
    entry = BennettVM.CheckpointEntry(src_state, 42)
    @test entry.snapshot == src_state
    @test entry.step == 42

    # ---- Test 2: deep-copy invariant (THE load-bearing test) ----
    # The Q2.2 aliasing trap, simulated. Mutate the source IState AFTER
    # constructing the entry; the captured snapshot must NOT see the
    # mutation. If the constructor ever silently drops the deepcopy
    # (e.g., switches to a shallow copy because deepcopy "feels
    # expensive" — see spike/RETROSPECTIVE.md Q4 §"Surprises about
    # Julia idioms"), this test turns RED before the M4.2/M4.3 round-
    # trip tests would.
    src2 = BennettVM.IState(0, Dict(:x => Int64(1)), :running,
                            Dict{Int64,Int64}(7 => Int64(70)))
    entry2 = BennettVM.CheckpointEntry(src2, 0)
    # Mutate the source locals dict.
    src2.locals[:x] = Int64(99)
    src2.locals[:newkey] = Int64(123)
    src2.pc = 999
    src2.status = :halted
    # Mutate the source memory dict — symmetric to the locals mutations
    # above. `memory` is a `Dict{Int64,Int64}` field on `IState`
    # (`src/ir/IState.jl:138`); the same aliasing trap applies. If the
    # constructor's `deepcopy` did not recurse into the memory dict,
    # these mutations would leak into the captured snapshot.
    src2.memory[7] = Int64(999)         # overwrite existing key.
    src2.memory[42] = Int64(420)        # add new key.
    # The captured snapshot is undisturbed.
    @test entry2.snapshot.locals[:x] == Int64(1)
    @test !haskey(entry2.snapshot.locals, :newkey)
    @test entry2.snapshot.pc == 0
    @test entry2.snapshot.status === :running
    @test entry2.snapshot.memory[7] == Int64(70)
    @test !haskey(entry2.snapshot.memory, 42)
    # Belt-and-braces: the Dict instances inside the snapshot are
    # different objects from the source's Dicts. If they were `===`,
    # the mutations above would have been visible. (This pins the
    # *mechanism* — deepcopy did its job — independently of the
    # content checks above pinning the *outcome*.)
    @test entry2.snapshot.locals !== src2.locals
    @test entry2.snapshot.memory !== src2.memory

    # ---- Test 3: structural equality across distinct constructions ----
    # Two entries built from independently-constructed equal IStates
    # must compare ==. This is the mirror of test_rstate.jl's
    # "structural equality" testset: it would silently fail if either
    # the IState.== override (M2.2) or the CheckpointEntry.== override
    # (M4.1) regressed. We assert the underlying Dicts are NOT === so
    # the == check is load-bearing (the spike Q2.1 trap target).
    a = BennettVM.CheckpointEntry(
        BennettVM.IState(1, Dict(:a => Int64(5)), :running), 10)
    b = BennettVM.CheckpointEntry(
        BennettVM.IState(1, Dict(:a => Int64(5)), :running), 10)
    @test a.snapshot.locals !== b.snapshot.locals   # distinct Dict objects.
    @test a == b
    @test hash(a) == hash(b)

    # ---- Test 3b: mutation-proof — perturb each field, confirm RED ----
    # step differs.
    c = BennettVM.CheckpointEntry(
        BennettVM.IState(1, Dict(:a => Int64(5)), :running), 11)
    @test a != c
    # snapshot differs (locals value).
    d = BennettVM.CheckpointEntry(
        BennettVM.IState(1, Dict(:a => Int64(99)), :running), 10)
    @test a != d
    # snapshot differs (pc).
    e = BennettVM.CheckpointEntry(
        BennettVM.IState(2, Dict(:a => Int64(5)), :running), 10)
    @test a != e
    # snapshot differs (status).
    f = BennettVM.CheckpointEntry(
        BennettVM.IState(1, Dict(:a => Int64(5)), :halted), 10)
    @test a != f

    # ---- Test 4: Set{CheckpointEntry} round-trip (==/hash contract) ----
    # `==` and `hash` must agree on content: a == b ⟹ hash(a) == hash(b).
    # Inserting `a` into a Set and probing with the independently-
    # constructed (but content-equal) `b` must find it. This is the
    # canonical check that the override is internally consistent — the
    # M2.2 IState test (test_istate.jl) pinned the same property at
    # one level down, with the haskey(d, equivalent_state) probe.
    s = Set{BennettVM.CheckpointEntry}()
    push!(s, a)
    @test b in s
    @test length(s) == 1
    push!(s, b)   # should be a no-op — b == a.
    @test length(s) == 1
    push!(s, c)   # c.step differs, so this DOES add.
    @test length(s) == 2

    # ---- Test 5: subtype of AbstractHistoryEntry ----
    # The polymorphism point. `RState.history::Vector{AbstractHistoryEntry}`
    # (src/ir/RState.jl:153) is typed against the supertype; a missing
    # `<: AbstractHistoryEntry` would silently make every M4.2 `push!`
    # error at the call site with a subtle "no method matching" rather
    # than a clean type error. Pin the relationship here.
    @test BennettVM.CheckpointEntry <: BennettVM.AbstractHistoryEntry
    @test entry isa BennettVM.AbstractHistoryEntry
    # And the entry slots into a Vector{AbstractHistoryEntry} cleanly.
    v = BennettVM.AbstractHistoryEntry[]
    push!(v, entry)
    @test length(v) == 1
    @test v[1] === entry

    # ---- Test 6: Integer coercion for `step` ----
    # Decision pinned by the brief and the constructor docstring:
    # ACCEPT any `Integer`, coerce to `Int` via `Int(step)`. Rationale:
    # callers carrying `Int32`/`UInt32` step counters from upstream
    # shouldn't need to wrap their call sites in casts, but the
    # downstream interpreter expects a uniform `Int` step index (parity
    # with `IState.pc::Int` and `run!`'s `max_steps::Int`). Coercion
    # happens once, here, and the field is `::Int` thereafter. A non-
    # Integer (e.g., `Float64`, `Symbol`) raises MethodError — the
    # right Rule 1 failure for a programming error.
    g = BennettVM.CheckpointEntry(src_state, Int32(7))
    @test g.step === 7                  # `===` here pins the type is Int (Int64 on 64-bit).
    @test g.step isa Int

    h_entry = BennettVM.CheckpointEntry(src_state, UInt32(99))
    @test h_entry.step === 99
    @test h_entry.step isa Int

    # Non-Integer rejected at construction.
    @test_throws MethodError BennettVM.CheckpointEntry(src_state, 1.5)
    @test_throws MethodError BennettVM.CheckpointEntry(src_state, :step)
end
