# test/test_injective.jl — M6.1 unit tests for the `is_injective`
# trait (bd `bennettvm-9hf`).
#
# # What this file pins
#
# `src/history/Injective.jl` defines the L1 "no-log" trait per
# PRD v4 §3.3 layer 1: the type-level / value-level predicate that
# tells the rest of the VM whether an instruction needs a history
# entry. M6.1 is the trait-only bead — it does NOT modify `step!`,
# `inverse`, or the round-trip path; M6.2/M6.3/M6.4 are the
# consumers (interpreter integration / golden-master regression /
# per-instruction `unstep!` short-circuit).
#
# The tests below pin (Rule 4 — every @test pins a specific value):
#
#   1. **Default fallback** — both the type-level method on an
#      out-of-taxonomy `Instruction` subtype AND the value-level
#      fallback on its instance return `false`. This is the
#      conservative "sealed-by-convention" expression of L1 (any
#      unrecognised instruction forces M6.2's `step!` to push a
#      history entry, per CLAUDE.md Rule 1).
#   2. **Type-level `true`** for the eight invariant injective
#      cases: `SwapInstruction`, `BeginInstruction`,
#      `EndInstruction`, `UnconditionalEntry`, `UnconditionalExit`,
#      `ConditionalEntry`, `ConditionalExit`, `MemoryInterchange`,
#      `MemorySwap`. Both the type-level method (`is_injective(T)`)
#      and the value-level fallback (`is_injective(inst::T)`) must
#      return `true` for a concrete constructed instance.
#   3. **Type-level `false`** for the three non-type-level-injective
#      cases: `ArithmeticAssignment` (per-instance discrimination
#      via the `modop` field — type-level stays `false`),
#      `MemoryAssignment`, `CallInstruction`. Both the type-level
#      method and a default-instance value-level call (for a modop
#      other than `:xor` on `ArithmeticAssignment`) return `false`.
#   4. **Value-level `ArithmeticAssignment` discrimination** —
#      construct three `ArithmeticAssignment`s with `modop` in
#      `{:xor, :add, :sub}` and assert `is_injective` returns
#      `true` only for the `:xor` instance. This is the load-
#      bearing PRD v4 §3.2 partial classification — conservative
#      on `:xor` only per the bead, even though §3.2 nominally
#      lists all three modops as injective (broadening to
#      `:add`/`:sub` is a separate follow-up bead).
#
# # What this file deliberately does NOT do
#
# Per the M6.1 hard constraints (this file is a trait-only test):
#
#   * **No `step!` / `inverse` / `unstep!` calls.** Per-instruction
#     inverse integration is M6.2's job. Mixing those here would
#     blur the M6.1/M6.2 milestone boundary and would also exercise
#     the interpreter's history machinery — the very surface this
#     bead leaves untouched.
#   * **No round-trip property test.** Round-trip integration lives
#     in `test_roundtrip.jl` (M4.5) and the M6 milestone's golden-
#     master regression (M6.3). M6.1 is the trait surface only.
#
# # Ref
#
#   * `src/history/Injective.jl` (the implementation; full rationale
#     in its top-of-module docstring — especially the "Which
#     instructions are injective" section listing the eight
#     type-level `true` cases, the "Value-level discrimination for
#     `ArithmeticAssignment`" section, and the "Why these three are
#     not type-level-injective" section).
#   * `bennettvm_prd.md` (PRD v4) §3.2 ("Instruction classes") —
#     the "Injective primitives" list.
#   * `bennettvm_prd.md` (PRD v4) §3.3 ("History mechanism") layer
#     1 ("No log").
#   * `docs/adr/0001-rc3-rvm-smoke.md` §Observations Structural-
#     Pattern points 1 and 2 — Mogensen-RSSA paired entry/exit and
#     φ-nodes on splits AND joins (the conceptual grounding for the
#     control-flow injectivity).
#   * CLAUDE.md Rule 1 (conservative default — `false` keeps the
#     history push alive when uncertain); Rule 4 (every @test pins a
#     specific value).

using Test
using BennettVM

# An out-of-taxonomy Instruction subtype, used only to probe the
# default `false` fallback. The "sealed-by-convention" model from
# M2.4 (`src/ir/instructions.jl`) allows this declaration; the
# default trait method below catches it.
struct DummyNonInjective <: BennettVM.Instruction end

@testset "is_injective default fallback (M6.1)" begin
    # Type-level default: any out-of-taxonomy Instruction subtype
    # inherits `false` (CLAUDE.md Rule 1 — fail safe / push the
    # history entry when uncertain).
    @test BennettVM.is_injective(DummyNonInjective) === false
    # Value-level fallback delegates to the type-level method.
    @test BennettVM.is_injective(DummyNonInjective()) === false
end

@testset "is_injective type-level true: SwapInstruction (M6.1)" begin
    # M2.7 — register-register exchange. Canonical injective.
    @test BennettVM.is_injective(BennettVM.SwapInstruction) === true
    inst = BennettVM.SwapInstruction(:x, :y, :z, :w)
    @test BennettVM.is_injective(inst) === true
end

@testset "is_injective type-level true: BeginInstruction (M6.1)" begin
    # M2.8 — subroutine entry marker; pc-only at this layer.
    @test BennettVM.is_injective(BennettVM.BeginInstruction) === true
    inst = BennettVM.BeginInstruction(:my_routine, [:p, :q])
    @test BennettVM.is_injective(inst) === true
end

@testset "is_injective type-level true: EndInstruction (M6.1)" begin
    # M2.8 — subroutine exit marker; pc-only at this layer.
    @test BennettVM.is_injective(BennettVM.EndInstruction) === true
    inst = BennettVM.EndInstruction(:my_routine, [:r])
    @test BennettVM.is_injective(inst) === true
end

@testset "is_injective type-level true: UnconditionalEntry (M6.1)" begin
    # M2.9 — basic-block entry. Mogensen-RSSA paired entry/exit.
    @test BennettVM.is_injective(BennettVM.UnconditionalEntry) === true
    inst = BennettVM.UnconditionalEntry(:L1, [:x, :y])
    @test BennettVM.is_injective(inst) === true
end

@testset "is_injective type-level true: UnconditionalExit (M6.1)" begin
    # M2.9 — basic-block exit. Mogensen-RSSA paired entry/exit.
    @test BennettVM.is_injective(BennettVM.UnconditionalExit) === true
    inst = BennettVM.UnconditionalExit(:L_next, [:a, :b])
    @test BennettVM.is_injective(inst) === true
end

@testset "is_injective type-level true: ConditionalEntry (M6.1)" begin
    # M2.10 — conditional block entry. φ-on-splits-AND-joins
    # (live-predicate mechanism).
    @test BennettVM.is_injective(BennettVM.ConditionalEntry) === true
    inst = BennettVM.ConditionalEntry(:Lj, [:x], :Lt, :Lf, :c)
    @test BennettVM.is_injective(inst) === true
end

@testset "is_injective type-level true: ConditionalExit (M6.1)" begin
    # M2.10 — conditional block exit. φ-on-splits-AND-joins
    # (live-predicate mechanism).
    @test BennettVM.is_injective(BennettVM.ConditionalExit) === true
    inst = BennettVM.ConditionalExit(:c, :Lt, :Lf, [:y])
    @test BennettVM.is_injective(inst) === true
end

@testset "is_injective type-level true: MemoryInterchange (M6.1)" begin
    # M2.12 — Pendulum-style register↔memory exchange. Self-inverse
    # via target↔source swap (Vieri 1995 §4.2.1).
    @test BennettVM.is_injective(BennettVM.MemoryInterchange) === true
    inst = BennettVM.MemoryInterchange(:x, :y, :z)
    @test BennettVM.is_injective(inst) === true
end

@testset "is_injective type-level true: MemorySwap (M6.1)" begin
    # M2.13 — memory↔memory exchange. Self-inverse.
    @test BennettVM.is_injective(BennettVM.MemorySwap) === true
    inst = BennettVM.MemorySwap(Int64(50), Int64(60))
    @test BennettVM.is_injective(inst) === true
end

@testset "is_injective type-level false: MemoryAssignment (M6.1)" begin
    # M2.11 — `M[addr] ⊕= (lhs op rhs)`. The M6.1 bead conservatively
    # leaves MemoryAssignment at the default `false` even though
    # PRD v4 §3.2 nominally classifies it among the injective
    # primitives — broadening here is a separate follow-up bead.
    @test BennettVM.is_injective(BennettVM.MemoryAssignment) === false
    inst = BennettVM.MemoryAssignment(:addr, :xor, :a, :and, :b)
    @test BennettVM.is_injective(inst) === false
end

@testset "is_injective type-level false: CallInstruction (M6.1)" begin
    # M2.14 — `(x,...) := call/uncall l(y,...)`. The body of the
    # callee may contain non-injective ops; call-aware history-
    # budget analysis lives at M7's min-cut layer, not M6.1.
    @test BennettVM.is_injective(BennettVM.CallInstruction) === false
    inst = BennettVM.CallInstruction([:x], :foo, [:y], :call)
    @test BennettVM.is_injective(inst) === false
end

@testset "is_injective type-level false: ArithmeticAssignment (M6.1)" begin
    # M2.6 — injectivity depends on the per-instance `modop` field,
    # so the type-level method stays at `false`. The value-level
    # discrimination is exercised in the next testset; here we
    # confirm only that the type-level method returns `false` and
    # that a non-`:xor`-modop instance also returns `false` via the
    # value-level fallback to the type-level method.
    @test BennettVM.is_injective(BennettVM.ArithmeticAssignment) === false
    # A default-instance with a modop OTHER than `:xor` (so the
    # value-level method below does not return `true`). The value-
    # level method DOES override the fallback, so this assertion
    # exercises the `modop === :xor` discrimination — `:add` falls
    # through to `false`.
    inst = BennettVM.ArithmeticAssignment(:x, :y, :add, :u, :mul, :v)
    @test BennettVM.is_injective(inst) === false
end

@testset "is_injective value-level: ArithmeticAssignment modop discrimination (M6.1)" begin
    # PRD v4 §3.2 classifies all three modops `{:add, :sub, :xor}`
    # as injective primitives, but the M6.1 bead is *intentionally
    # conservative* on `:xor` only. The other two modops fall
    # through to the type-level `false`; broadening to `:add` /
    # `:sub` is a separate follow-up bead (not yet filed). This
    # testset pins the conservative reading: only `:xor` flips to
    # `true`.
    xor_inst = BennettVM.ArithmeticAssignment(:x, :y, :xor, :u, :and, :v)
    add_inst = BennettVM.ArithmeticAssignment(:x, :y, :add, :u, :mul, :v)
    sub_inst = BennettVM.ArithmeticAssignment(:x, :y, :sub, :u, :mul, :v)

    @test BennettVM.is_injective(xor_inst) === true
    @test BennettVM.is_injective(add_inst) === false
    @test BennettVM.is_injective(sub_inst) === false

    # Cross-check: the type-level method is `false` regardless of
    # which instance we read — the type-level fallback CANNOT see
    # the per-instance `modop` field. The value-level method is
    # where the discrimination lives.
    @test BennettVM.is_injective(BennettVM.ArithmeticAssignment) === false
end
