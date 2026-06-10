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

# ============================================================================
# M7.3 — make_delta per-instruction (`bennettvm-vk8`)
# ============================================================================
#
# # Why these tests exist
#
# M7.3 adds `make_delta(instr::T, s_pre::IState, step::Integer)::DeltaEntry`
# in each non-injective instruction's own file (ADR 0002 §Design Decision
# 3 — co-located with `forward`/`inverse`), plus a generic abstract
# fallback in `src/history/delta.jl` that errors loudly per Rule 1.
#
# Each testset below pins one ADR 0002 finding or one Rule 1 error path.
#
# # Mutation-proof intent (Rule 5 "port-and-verify")
#
# Each testset corresponds to a specific source-file mutation that would
# break a real downstream consumer:
#
#   - Change `ArithmeticAssignment`'s `make_delta` body to capture
#     `BennettVM.active_locals(s_pre)[instr.source]` (the "capture pre-target value"
#     pre-ADR thinking the bead text suggested): the empty-payload
#     testsets below turn RED because `payload` is no longer
#     `NamedTuple()`.
#   - Drop the `ArithmeticAssignment` `make_delta` method entirely:
#     the construction testsets call the abstract fallback, which
#     errors with the "no specialisation" message — those testsets
#     turn RED.
#   - Soften `CallInstruction`'s `make_delta` to return an empty-payload
#     entry (matching the pre-ADR draft): the error-raise testset
#     turns RED.
#   - Drop the abstract fallback in `delta.jl`: the dummy-instruction
#     testset fails with a `MethodError` instead of the descriptive
#     "no specialisation" message — message-content assertion turns RED.
#   - Change `ArithmeticAssignment`'s `make_delta` to use a non-empty
#     NamedTuple (e.g., `(unused = 0,)`): the `payload === NamedTuple()`
#     identity check turns RED (different type parameter `NamedTuple{(:unused,),
#     Tuple{Int64}}` vs `NamedTuple{(),Tuple{}}`).
#
# Ref: src/ir/arithmetic_assignment.jl (the make_delta site),
#      src/ir/memory_instructions.jl (the make_delta site),
#      src/ir/call_instruction.jl (the error-raise make_delta),
#      src/history/delta.jl (the abstract fallback).
# Ref: docs/adr/0002-enzyme-min-cut-mapping.md §DeltaEntry payload
#      schema (the empty-payload finding); §Open Questions item 4
#      (CallInstruction deferred to v5); §Design Decision 3
#      (per-instruction file location).
# Ref: bd `bennettvm-vk8` — the M7.3 bead. Note: the bead's
#      DESCRIPTION says "capture pre-target value", which CONTRADICTS
#      the ADR's source-cross-check finding. These tests follow the
#      ADR (empty payload), not the bead text.

@testset "make_delta (M7.3)" begin
    # Canonical IState for the s_pre argument. The make_delta methods
    # implemented in M7.3 do not actually consult `s_pre` (the empty-
    # payload finding makes it unused), but the dispatch signature
    # requires it, and a well-formed IState is what any future
    # non-empty-payload specialisation would consume. Use a state
    # with non-trivial locals/memory to pin that the implementation
    # ignores them by construction, not by accident.
    s_pre = BennettVM.IState(
        0,
        Dict{Symbol,Int64}(:n0 => Int64(5), :a => Int64(7)),
        :running,
    )
    s_pre.memory[Int64(42)] = Int64(99)

    @testset "ArithmeticAssignment :add and :sub — empty payload" begin
        # ADR 0002 §DeltaEntry payload schema row 1: payload is
        # `NamedTuple()` for ALL three modops. `:add` and `:sub` are
        # the M6.1-conservative-non-injective cases that DO reach
        # make_delta under the current M7.6 push gate.
        instr_add = BennettVM.ArithmeticAssignment(:n1, :n0, :add,
                                                   Int64(1), :and, Int64(1))
        instr_sub = BennettVM.ArithmeticAssignment(:n1, :n0, :sub,
                                                   Int64(1), :and, Int64(1))

        d_add = BennettVM.make_delta(instr_add, s_pre, 3)
        d_sub = BennettVM.make_delta(instr_sub, s_pre, 7)

        # Payload is the empty NamedTuple — pinned at the type level
        # (NamedTuple{(),Tuple{}}) AND at the value level (==
        # NamedTuple()).
        @test d_add.payload === NamedTuple()
        @test d_sub.payload === NamedTuple()
        @test d_add.payload isa NamedTuple{(),Tuple{}}
        @test d_sub.payload isa NamedTuple{(),Tuple{}}

        # Step is preserved (coerced to Int).
        @test d_add.step === 3
        @test d_sub.step === 7

        # Instruction is the SAME reference (immutable struct, no
        # defensive copy needed — mirrors DeltaEntry's constructor
        # contract).
        @test d_add.instruction === instr_add
        @test d_sub.instruction === instr_sub

        # Resulting type parameter is correct.
        @test d_add isa
              BennettVM.DeltaEntry{BennettVM.ArithmeticAssignment}
        @test d_sub isa
              BennettVM.DeltaEntry{BennettVM.ArithmeticAssignment}
    end

    @testset "ArithmeticAssignment :xor — empty payload (contract pin)" begin
        # M6.1 classifies `:xor` ArithmeticAssignment as injective, so
        # M7.6's push gate will skip make_delta on this case and the
        # method is unreachable from the interpreter. The METHOD MUST
        # STILL EXIST AND DISPATCH CORRECTLY so that any out-of-band
        # caller (tests, future M7.5 cost analysis, REPL probes) can
        # rely on the contract. This test pins the contract.
        instr_xor = BennettVM.ArithmeticAssignment(:n1, :n0, :xor,
                                                   Int64(1), :and, Int64(1))
        d_xor = BennettVM.make_delta(instr_xor, s_pre, 2)
        @test d_xor.payload === NamedTuple()
        @test d_xor.payload isa NamedTuple{(),Tuple{}}
        @test d_xor.step === 2
        @test d_xor.instruction === instr_xor
        @test d_xor isa
              BennettVM.DeltaEntry{BennettVM.ArithmeticAssignment}
    end

    @testset "MemoryAssignment — empty payload (all three modops)" begin
        # ADR 0002 §DeltaEntry payload schema row 2: same as
        # ArithmeticAssignment — empty NamedTuple payload for all
        # three modops. Per ADR 0002 §Open Questions item 3, M6.1
        # does NOT specialise `is_injective` for MemoryAssignment on
        # `:xor`, so ALL three modops currently reach this method
        # under M7.6.
        instr_xor = BennettVM.MemoryAssignment(:addr, :xor,
                                               Int64(1), :and, Int64(1))
        instr_add = BennettVM.MemoryAssignment(:addr, :add,
                                               Int64(1), :and, Int64(1))
        instr_sub = BennettVM.MemoryAssignment(:addr, :sub,
                                               Int64(1), :and, Int64(1))

        d_xor = BennettVM.make_delta(instr_xor, s_pre, 1)
        d_add = BennettVM.make_delta(instr_add, s_pre, 2)
        d_sub = BennettVM.make_delta(instr_sub, s_pre, 3)

        @test d_xor.payload === NamedTuple()
        @test d_add.payload === NamedTuple()
        @test d_sub.payload === NamedTuple()
        @test d_xor.payload isa NamedTuple{(),Tuple{}}
        @test d_add.payload isa NamedTuple{(),Tuple{}}
        @test d_sub.payload isa NamedTuple{(),Tuple{}}

        @test d_xor.step === 1
        @test d_add.step === 2
        @test d_sub.step === 3

        @test d_xor.instruction === instr_xor
        @test d_add.instruction === instr_add
        @test d_sub.instruction === instr_sub

        @test d_xor isa
              BennettVM.DeltaEntry{BennettVM.MemoryAssignment}
        @test d_add isa
              BennettVM.DeltaEntry{BennettVM.MemoryAssignment}
        @test d_sub isa
              BennettVM.DeltaEntry{BennettVM.MemoryAssignment}
    end

    @testset "CallInstruction — deferred to v5, errors loudly" begin
        # ADR 0002 §Open Questions item 4: CallInstruction delta
        # semantics are deferred to v5. The method exists (so the
        # M7.6 push site can call it unconditionally on non-injective
        # instructions) but ALWAYS raises ErrorException with a
        # descriptive message naming v5 / ADR 0002.
        instr_call = BennettVM.CallInstruction(
            Symbol[:y],            # targets (created)
            :my_callee,            # callee label
            Symbol[:x],            # args (destroyed)
            :call,                 # direction
        )

        # The raise itself.
        @test_throws ErrorException BennettVM.make_delta(
            instr_call, s_pre, 5,
        )

        # Pin the message content — the user-facing diagnostic MUST
        # name v5 and ADR 0002 so a future agent stumbling on this
        # error has the right pointers.
        msg = try
            BennettVM.make_delta(instr_call, s_pre, 5)
            ""  # unreachable
        catch e
            sprint(showerror, e)
        end
        @test occursin("deferred to v5", msg)
        @test occursin("ADR 0002", msg)
        @test occursin("CallInstruction", msg)
        @test occursin("step 5", msg)        # the step number is in the message
    end

    @testset "generic fallback — fail loud on unknown instruction" begin
        # CLAUDE.md Rule 1: an instruction type that lacks a
        # specialised make_delta MUST surface descriptively, not
        # silently return a wrong-shape entry. Construct a dummy
        # Instruction subtype and confirm the abstract fallback in
        # `src/history/delta.jl` raises with the "no specialisation"
        # message.
        @eval struct DummyMissingMakeDelta <: BennettVM.Instruction end
        dummy = DummyMissingMakeDelta()

        @test_throws ErrorException BennettVM.make_delta(
            dummy, s_pre, 11,
        )

        msg = try
            BennettVM.make_delta(dummy, s_pre, 11)
            ""  # unreachable
        catch e
            sprint(showerror, e)
        end
        # Message content must point the developer to the per-
        # instruction-file location (ADR 0002 §Design Decision 3) and
        # name the missing type.
        @test occursin("no specialisation", msg)
        @test occursin("make_delta", msg)
        @test occursin("DummyMissingMakeDelta", msg)
        @test occursin("ADR 0002", msg)
        @test occursin("step=11", msg)
    end
end
