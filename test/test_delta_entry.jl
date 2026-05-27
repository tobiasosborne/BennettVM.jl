# test/test_delta_entry.jl — M7.2 unit tests for `DeltaEntry{T}`
# (bd `bennettvm-c4m`).
#
# # Why these tests exist
#
# `src/history/delta.jl` introduces the L2 concrete subtype of
# `AbstractHistoryEntry` per ADR 0002 §DeltaEntry payload schema. Per
# Rule 4 ("'Runs without errors' is not a passing test"), every `@test`
# below pins one specific invariant against a known-correct value. The
# load-bearing tests in this file are:
#
#   - The **polymorphic-storage** test: `DeltaEntry{...}` and
#     `CheckpointEntry` must coexist in a `Vector{AbstractHistoryEntry}`
#     because that is exactly the shape of `RState.history`
#     (`src/ir/RState.jl:209`). If `DeltaEntry` regressed to not subtyping
#     `AbstractHistoryEntry`, M7.6's `step!` push would error at the call
#     site rather than at construction; this test catches the regression
#     at the type level.
#   - The **cross-T inequality** test: pins the ADR 0002 contract that
#     `DeltaEntry`'s identity is `(T, payload, step)`, not just
#     `(payload, step)`. This is the parametric analogue of
#     `CheckpointEntry`'s structural equality test (M4.1).
#
# # Mutation-proof intent
#
# Per CLAUDE.md Rule 5 ("Port-and-verify"), each test below corresponds
# to a specific mutation of the source file that would break a real
# downstream consumer:
#
#   - Change `payload::NamedTuple` to `payload::Any` in the struct →
#     the construction test (#1) still passes (`Any` accepts NamedTuple)
#     BUT the `==`/`hash` tests would still pass too, so this specific
#     mutation is not caught at runtime by these tests. The contract is
#     caught at *type-system* level by the `fieldtype` test in #1a.
#   - Drop the `Int(step)` coercion → integer-coercion test (#2) turns
#     RED.
#   - Drop the same-T `Base.==` override (relying on Julia's default
#     field-by-field) → the test still passes for the same-T case
#     (default does the right thing for these field types); but the
#     hash test would turn RED because no `hash` override is co-located
#     with the `==` override (the convention pinned in the source file
#     docstring).
#   - Drop the cross-T `Base.==` fallback → cross-T inequality test (#4)
#     turns RED with the default field-by-field comparing across types
#     (Julia would raise on the instruction `==`-across-types or fall
#     through to `===`).
#   - Drop the `<: AbstractHistoryEntry` declaration → subtype /
#     polymorphic-storage tests (#5, #6) turn RED.
#
# Ref: src/history/delta.jl (the type under test; full rationale in its
#      file-level docstring).
# Ref: docs/adr/0002-enzyme-min-cut-mapping.md §DeltaEntry payload schema,
#      §Design Decisions 1-2 (parametric T, NamedTuple payload).
# Ref: src/history/CheckpointEntry.jl (M4.1) — the structural model this
#      type mirrors; test_checkpoint_entry.jl is the test pattern.
# Ref: CLAUDE.md Rule 4 (every @test asserts a specific value),
#      Rule 1 (fail loud), Rule 11 (literate test docstrings).

using Test
using BennettVM

@testset "DeltaEntry (M7.2)" begin
    # Two concrete Instruction subtypes to exercise the parametric T
    # machinery. ArithmeticAssignment with :sub modop is canonically
    # non-injective per M6.1 (the conservative reading; see
    # `src/history/Injective.jl`). MemoryAssignment with :sub is also
    # non-injective. These are the two T's the ADR Worked Example
    # builds DeltaEntries against.
    arith = BennettVM.ArithmeticAssignment(:n1, :n0, :sub,
                                           Int64(1), :and, Int64(1))
    memw  = BennettVM.MemoryAssignment(:addr, :sub,
                                       Int64(1), :and, Int64(1))

    # ---- Test 1: construction sets fields correctly ----
    # Sanity check before the more interesting tests. The fields must
    # be the values we passed in; `payload` is shared by reference
    # (NamedTuple is an immutable value type — no deepcopy is needed,
    # unlike CheckpointEntry's IState snapshot, which lives in a
    # mutable struct with Dict fields).
    pl = (foo = 1, bar = :baz)
    e1 = BennettVM.DeltaEntry(arith, pl, 5)
    @test e1.instruction === arith            # same reference (immutable struct).
    @test e1.payload == pl                    # content-equal — `===` may or may
                                              # not hold for NamedTuples depending
                                              # on internal interning.
    @test e1.step === 5                       # `===` here pins Int (Int64 on 64-bit).
    @test e1.step isa Int

    # ---- Test 1a: type parameter inferred from instruction ----
    # The convenience constructor `DeltaEntry(instr, payload, step)`
    # infers T == typeof(instruction). This is the path M7.3's
    # make_delta will use.
    @test e1 isa BennettVM.DeltaEntry{BennettVM.ArithmeticAssignment}

    # Explicit-T construction must also work.
    e1b = BennettVM.DeltaEntry{BennettVM.ArithmeticAssignment}(arith, pl, 5)
    @test e1b == e1
    @test typeof(e1b) === typeof(e1)

    # ---- Test 1b: payload field type is NamedTuple ----
    # ADR 0002 Design Decision 2: `payload::NamedTuple`, NOT `Any` and
    # NOT a per-T struct. Pin the field type at the type-system level
    # so a future coder who relaxes it to `Any` (perhaps to "support
    # Dict payloads" without reading the ADR) turns this test RED.
    @test fieldtype(BennettVM.DeltaEntry{BennettVM.ArithmeticAssignment},
                    :payload) === NamedTuple
    @test fieldtype(BennettVM.DeltaEntry{BennettVM.ArithmeticAssignment},
                    :step) === Int

    # ---- Test 2: Integer coercion for `step` ----
    # Decision pinned by the brief and the constructor docstring,
    # mirroring CheckpointEntry's coercion: accept any `Integer`,
    # coerce to `Int` via `Int(step)`. A non-Integer raises MethodError
    # — the Rule 1 failure for a programming error.
    e2 = BennettVM.DeltaEntry(arith, NamedTuple(), Int32(7))
    @test e2.step === 7
    @test e2.step isa Int

    e2b = BennettVM.DeltaEntry(arith, NamedTuple(), UInt32(99))
    @test e2b.step === 99
    @test e2b.step isa Int

    # Non-Integer rejected.
    @test_throws MethodError BennettVM.DeltaEntry(arith, NamedTuple(), 1.5)
    @test_throws MethodError BennettVM.DeltaEntry(arith, NamedTuple(), :step)

    # ---- Test 3: structural equality (same T) ----
    # Two entries with the same instruction, same payload, same step
    # but different identities compare ==. Pin the field-perturbation
    # cases that drive != as well.
    a = BennettVM.DeltaEntry(arith, (x = 1,), 10)
    b = BennettVM.DeltaEntry(arith, (x = 1,), 10)
    @test a == b
    @test hash(a) == hash(b)

    # step differs.
    c = BennettVM.DeltaEntry(arith, (x = 1,), 11)
    @test a != c

    # payload differs (value).
    d = BennettVM.DeltaEntry(arith, (x = 2,), 10)
    @test a != d

    # payload differs (shape — same value, different field name).
    d2 = BennettVM.DeltaEntry(arith, (y = 1,), 10)
    @test a != d2

    # instruction differs (different ArithmeticAssignment of same T).
    arith_other = BennettVM.ArithmeticAssignment(:n2, :n1, :sub,
                                                 Int64(1), :and, Int64(1))
    f = BennettVM.DeltaEntry(arith_other, (x = 1,), 10)
    @test a != f

    # ---- Test 4: cross-T inequality ----
    # ADR 0002 contract: `DeltaEntry{Foo}(...) != DeltaEntry{Bar}(...)`
    # even when (payload, step) are bitwise identical. The two entries
    # describe inversions of different instruction types. The cross-T
    # case is handled in `src/history/delta.jl` by the *absence* of a
    # cross-T `==` method (see that file's "Why `Base.==` ... overridden
    # explicitly" point 2 for why an explicit cross-T method would
    # actually *break* same-T equality on Julia 1.12): Julia's
    # `==(::Any, ::Any) = ===` Base fallback returns `false` for two
    # distinct `DeltaEntry`-typed objects.
    a_arith = BennettVM.DeltaEntry(arith, NamedTuple(), 5)
    a_mem   = BennettVM.DeltaEntry(memw,  NamedTuple(), 5)
    @test a_arith != a_mem
    # Hash distinction is probabilistic but the `hash(T, h)` mix-in
    # makes it highly likely. If this test ever flakes, the type
    # parameter is no longer participating in the hash and the
    # `==`/hash invariant on cross-T entries is broken.
    @test hash(a_arith) != hash(a_mem)

    # ---- Test 5: subtype of AbstractHistoryEntry ----
    # The polymorphism point. `RState.history::Vector{AbstractHistoryEntry}`
    # (src/ir/RState.jl:209) is typed against the supertype; a missing
    # `<: AbstractHistoryEntry` declaration would silently make every
    # M7.6 `push!` error at the call site with a subtle "no method
    # matching" rather than a clean type error.
    @test BennettVM.DeltaEntry{BennettVM.ArithmeticAssignment} <:
          BennettVM.AbstractHistoryEntry
    @test BennettVM.DeltaEntry{BennettVM.MemoryAssignment} <:
          BennettVM.AbstractHistoryEntry
    @test e1 isa BennettVM.AbstractHistoryEntry

    # ---- Test 6: polymorphic storage with CheckpointEntry ----
    # Load-bearing: M7.6 will push a `DeltaEntry` onto the same
    # `s.history::Vector{AbstractHistoryEntry}` that already accepts
    # `CheckpointEntry`s (M4.2). Pin that the two concrete subtypes
    # coexist in one vector. If this test ever turns RED, the M7
    # integration is fundamentally blocked — a serious abstraction
    # problem.
    src_state = BennettVM.IState(0, Dict(:x => Int64(7)), :running)
    chk = BennettVM.CheckpointEntry(src_state, 4)
    delta = BennettVM.DeltaEntry(arith, NamedTuple(), 5)

    v = BennettVM.AbstractHistoryEntry[]
    push!(v, chk)
    push!(v, delta)
    @test length(v) == 2
    @test v[1] === chk
    @test v[2] === delta
    # Iterate; both must be reachable through the supertype.
    seen_chk = false
    seen_delta = false
    for entry in v
        if entry isa BennettVM.CheckpointEntry
            seen_chk = true
        elseif entry isa BennettVM.DeltaEntry
            seen_delta = true
        end
    end
    @test seen_chk
    @test seen_delta

    # ---- Test 7: empty NamedTuple payload (the dominant case) ----
    # ADR 0002 §DeltaEntry payload schema finds that EVERY non-injective
    # instruction in the current M2.6-locked modop set carries an empty
    # payload. The empty NamedTuple `NamedTuple()` has type
    # `NamedTuple{(),Tuple{}}` — zero-sized value plus eight-byte type
    # tag. Pin that construction, equality, and hashing all work on it.
    empty = NamedTuple()
    e_empty = BennettVM.DeltaEntry(arith, empty, 1)
    @test e_empty.payload == NamedTuple()
    @test e_empty.payload isa NamedTuple
    # Two empty-payload entries built independently are equal.
    e_empty2 = BennettVM.DeltaEntry(arith, NamedTuple(), 1)
    @test e_empty == e_empty2
    @test hash(e_empty) == hash(e_empty2)
    # Different step → unequal.
    e_empty3 = BennettVM.DeltaEntry(arith, NamedTuple(), 2)
    @test e_empty != e_empty3
end
