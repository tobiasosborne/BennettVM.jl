"""
    is_injective — the L1 "no-log" trait (M6.1)

The single-bit instruction-level predicate that tells the rest of the
VM whether an instruction needs a history entry. This is the type-
classification primitive at the heart of layer 1 — the "No log" layer
— of the PRD v4 §3.3 three-layer history scheme.

# Where this sits in the three-layer history scheme

PRD v4 §3.3 ("History mechanism") prescribes three layers, applied in
**order of preference**:

  1. **L1 — no log.** Injective instructions (PRD v4 §3.2 "Injective
     primitives") and reversible jumps push **nothing** to the history
     tape. The inverse is recoverable from current state alone — no
     destroyed value has to be cached because the forward step lost no
     information. This file's `is_injective` trait is the predicate
     that gates L1: `is_injective(instr) == true` ⟹ `step!` (M6.2)
     pushes nothing.
  2. **L2 — delta entries with min-cut selection.** For non-injective
     ops in deterministic regions, the history payload is the minimal
     information required to invert the step (Enzyme-style cache
     analysis, Moses–Churavy 2020 NeurIPS §2 "Cache"). Lands at M7.x.
  3. **L3 — periodic full-state checkpoints + deterministic replay.**
     The safety-net layer, currently the only history layer wired up
     (`src/history/CheckpointEntry.jl`, M4.1). Lands at M4.2.

The PRD's wording is binding: "Injective instructions and reversible
jumps (§3.2) push nothing." This file defines the trait that
operationalises that sentence; M6.2 is the bead that wires
`is_injective` into `step!` to actually skip the history push when the
trait returns `true`. **This bead (M6.1) defines the trait only — it
does NOT modify `step!`, `inverse`, or the round-trip path.** The
consumers are M6.2 (interpreter integration), M6.3 (golden-master
regression test against the M4.5 round-trip baseline), and M6.4
(per-instruction `unstep!` short-circuit for the injective class).

# What an "injective instruction" is, formally

An instruction is *injective* iff its forward semantics define a
bijection on the relevant slice of `IState` it touches. Equivalently:
no information is destroyed by the forward step, so the inverse can
be reconstructed from the post-state alone without consulting any
history record. The mathematical content of "injective" here matches
Vieri's Pendulum usage (Vieri 1995 §4.2.1, "Exchange-as-injective"):
register / memory exchanges are bijective on the (register, cell)
pair because they permute existing values rather than overwriting
them with computed values that depend on the prior contents.

The same property applies — for a structurally different reason —
to RSSA control-flow markers. Per Mogensen 2016 §3, RSSA's paired
entry/exit pattern (φ-nodes on splits AND joins) is invertible
*without* a history record because the predicate that selected the
branch is **live in locals at the moment of every transition**. The
join "remembers" its predecessor implicitly through the surviving
predicate symbol, so backward dispatch can recover the source label
structurally. This is the conceptual grounding for treating
`UnconditionalEntry`/`Exit` and `ConditionalEntry`/`Exit` as
injective at this layer — see ADR 0001 §Observations Structural-
Pattern point 1 ("Mogensen-RSSA paired entry/exit") and point 2
("φ-nodes appear at BOTH splits AND joins"). The subroutine markers
`BeginInstruction`/`EndInstruction` are injective trivially: they
touch no `locals` state at all (M2.8 docstring: "structurally
injective — but injective by virtue of having no state to corrupt,
not by virtue of being a non-trivial bijection").

# Which instructions are injective (the M6.1 lock-in)

Per the bead `bennettvm-9hf` description, the M6.1 trait returns
**`true`** at the *type* level for nine of the twelve concrete RSSA
instruction subtypes:

  * `SwapInstruction` (M2.7) — the canonical injective: a register-
    register bijection on the (target, source) pair (RC3 four-field
    form `x, y := z, w`).
  * `BeginInstruction`, `EndInstruction` (M2.8) — subroutine markers;
    pc-only at this layer, no `locals` touched. Injective trivially.
  * `UnconditionalEntry`, `UnconditionalExit` (M2.9) — basic-block
    entry/exit. Injective via Mogensen-RSSA paired entry/exit (ADR
    0001 Structural-Pattern point 1); pc-only at this layer.
  * `ConditionalEntry`, `ConditionalExit` (M2.10) — conditional
    basic-block entry/exit. Injective via the live-predicate
    mechanism (ADR 0001 Structural-Pattern point 2 — φ-nodes on
    splits AND joins; the predicate symbol survives in `locals` so
    backward dispatch recovers the source label structurally).
  * `MemoryInterchange` (M2.12) — Pendulum-style register↔memory
    exchange (Vieri 1995 §4.2.1). Self-inverse via target↔source
    swap; no history needed because the pair (register slot, cell
    slot) is permuted bijectively. The canonical "PISA memory access
    is always an exchange" instruction (CLAUDE.md hallucination-risk
    callout).
  * `MemorySwap` (M2.13) — memory↔memory exchange. Self-inverse;
    permutes two cells without creating or destroying any SSA name.

The remaining three concrete subtypes — `ArithmeticAssignment` (M2.6),
`MemoryAssignment` (M2.11), `CallInstruction` (M2.14) — are NOT
injective at the type level. See "Why these three are not
type-level-injective" below for the per-type rationale.

# Value-level discrimination for `ArithmeticAssignment`

`ArithmeticAssignment`'s injectivity depends on a **per-instance
field** — `modop` — rather than on the type. Per PRD v4 §3.2, the
modop set `{:add, :sub, :xor}` is the "injective primitives" set:
`AddMod`/`SubMod`/`XorMod` are listed by name as "fixed-width…
self-inverse or has a fixed paired inverse". The structural
reversibility of `ArithmeticAssignment` *is* established by the
modop set being closed under `dual_modop` — see
`src/ir/arithmetic_assignment.jl`'s `dual_modop` function (XOR ↔ XOR
self-inverse, ADD ↔ SUB paired inverse) — and the
`ArithmeticAssignment.inverse` method documents `prev` as unused
because the form is structurally reversible.

That said, this bead (`bennettvm-9hf`) is **intentionally
conservative** on the modop classification: only `modop === :xor`
returns `true` from the value-level `is_injective` method. The
broader PRD v4 §3.2 reading — that `:add` and `:sub` are also
injective in the no-log sense — is *not* yet wired into this
trait. The conservative choice keeps the M6.1 surface narrow: the
canonical self-inverse modop (`:xor`) flips to `true`; the
paired-inverse modops (`:add`/`:sub`) keep the default `false` and
continue to push a (currently L3-only, M4.2) history entry through
M6.2's `step!`. Broadening to `:add`/`:sub` is a separate
follow-up bead (not yet filed); the orchestrator may file one at
M6.x close.

The mechanism is two-method:

  * `is_injective(::Type{ArithmeticAssignment})::Bool = false` —
    the type-level fallback is `false`, because injectivity depends
    on the per-instance `modop` field, not the type.
  * `is_injective(x::ArithmeticAssignment)::Bool` — the value-level
    specialisation: returns `true` iff `x.modop === :xor`.

A future M6.x bead that broadens this — or a separate value-level
trait that classifies the *inner* `op` for the non-injective binop
cases (`:udiv`, `:srem`, shifts) — would extend the second method
without changing the first.

# Why these three are not type-level-injective

  * `ArithmeticAssignment` (M2.6) — see the previous section; the
    decision is per-instance, not per-type.

  * `MemoryAssignment` (M2.11) — the `M[addr] ⊕= (lhs op rhs)`
    in-place update destroys the pre-update value of `M[addr]` (for
    `:add`/`:sub` modops, recoverable via `dual_modop`; same
    aspirational-but-conservative point as `ArithmeticAssignment`).
    But: per PRD v4 §3.2 the modop set on memory assignments is the
    same `{:xor, :add, :sub}` and the structural reversibility is
    the same; the M6.1 conservative reading defers a value-level
    `:xor`-specialisation for `MemoryAssignment` to a later bead so
    M6.1 ships only one value-level method (the `ArithmeticAssignment`
    one). Future bead `bennettvm-?` could specialise.

  * `CallInstruction` (M2.14) — the body of the callee subroutine
    may contain non-injective ops; the call site itself is the entry
    point for a sub-execution whose history budget depends on what
    the body does. M6.1 deliberately leaves `CallInstruction` at the
    `false` default; a call-aware history-budget analysis is the
    natural home for any "is this call injective?" predicate, and
    that lives at the M7 min-cut layer, not here.

# What this bead does NOT touch

  * **`step!` (M3.3)** — not modified. The M6.2 bead is what wires
    `is_injective` into `step!` so that an injective instruction
    pushes no history entry. M6.1 only defines the trait.
  * **`inverse` methods** — already documented as `prev`-unused on
    each injective instruction's file (see e.g.
    `src/ir/swap_instruction.jl:166-178`). No method body is
    changed by this bead.
  * **`is_injective` export** — deliberately NOT exported from
    `BennettVM` yet. M6.2 will decide on the public-API surface
    when it wires the trait into the interpreter. Until then,
    callers access it as `BennettVM.is_injective(...)`.

# Default fallback (the "sealed by convention" expression of L1)

The type-level default for `Instruction` is `false`. Any
out-of-taxonomy `Instruction` subtype a future agent (or downstream
caller) might write will therefore inherit the conservative
`is_injective(::ThatType) == false`, forcing M6.2's `step!` to push
a history entry rather than silently skip the push and corrupt the
inverse. This is the same "sealed by convention" pattern as the
M2.4 `forward` / `inverse` fallbacks (`src/ir/instructions.jl`),
expressing CLAUDE.md Rule 1 ("fail safe — push the history entry
when in doubt, don't silently skip it") at the trait layer.

The value-level fallback `is_injective(x::Instruction) =
is_injective(typeof(x))` lets every type-level specialisation
propagate transparently to values, so the consumer at M6.2's
`step!` can write `is_injective(instr)` (value-level) without
caring which mechanism — type-level for the eight invariant cases
or value-level for `ArithmeticAssignment` — drives the answer.

# Ref

  * `bennettvm_prd.md` (PRD v4) §3.2 ("Instruction classes") — the
    "Injective primitives" list and the "Push nothing to history"
    sentence. The single most load-bearing PRD sentence for this
    file.
  * `bennettvm_prd.md` (PRD v4) §3.3 ("History mechanism") layer 1
    ("No log") — the prescription this trait operationalises.
  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations Structural-Pattern
    points 1 and 2 — the Mogensen-RSSA paired entry/exit pattern
    (point 1) and the φ-nodes-on-splits-AND-joins lesson (point 2)
    that ground the control-flow injectivity.
  * Vieri, *Pendulum: A Reversible Computer Architecture* (1995),
    §4.2.1 — the Exchange-as-injective pattern that makes register
    /memory swaps the canonical no-log instructions.
  * Mogensen, *RSSA: A Reversible SSA Form* (2016), §3 — the paired
    entry/exit / φ-on-splits-AND-joins pattern that grounds the
    control-flow markers as no-log.
  * `src/ir/swap_instruction.jl` (M2.7) — the prototypical injective
    instruction; its own top-of-module docstring already says
    "`is_injective` (wired in M6.1) returns `true` for this type".
    THIS file is that wiring.
  * `src/ir/memory_instructions.jl` (M2.12, M2.13) — the
    `MemoryInterchange` and `MemorySwap` files explicitly anticipate
    `is_injective(MemoryInterchange) = true` / `(MemorySwap) =
    true`; M6.1 is the file that delivers those.
  * `src/history/CheckpointEntry.jl` (M4.1) — the L3 (currently only
    wired) layer. Its top-of-module docstring lists L1 / L2 / L3
    layers and notes "L1 — no log… Lands at M6.x." THIS file is the
    M6.1 portion of that "M6.x".
  * CLAUDE.md Rule 11 (literate exposition); Rule 1 (fail safe —
    the conservative `false` default keeps the L3 push alive when
    the trait is uncertain).
"""

"""
    is_injective(::Type{<:Instruction}) -> Bool

Type-level predicate: does an instruction of this type need a
history entry under PRD v4 §3.3 layer 1 ("No log")? Returns `true`
iff the instruction's forward semantics define a bijection on the
slice of `IState` it touches, so the inverse is recoverable from
current state alone.

The default (this method) is `false` — a conservative fallback that
forces M6.2's `step!` to push a history entry rather than silently
skip the push on an unrecognised instruction type. Concrete
specialisations below flip the result to `true` for the
type-level-injective cases.
"""
is_injective(::Type{<:Instruction})::Bool = false

"""
    is_injective(x::Instruction) -> Bool

Value-level fallback: dispatches to `is_injective(typeof(x))`.
Lets type-level specialisations propagate transparently to values
so callers (M6.2's `step!`) can write `is_injective(instr)`
uniformly. The `ArithmeticAssignment` value-level specialisation
below overrides this fallback so per-instance `modop` discrimination
takes precedence over the type-level `false`.
"""
is_injective(x::Instruction)::Bool = is_injective(typeof(x))

# -----------------------------------------------------------------------------
# Type-level `true` specialisations — the eight invariant injective cases.
# -----------------------------------------------------------------------------

# M2.7 — register-register exchange (RC3 four-field `x, y := z, w`).
# Self-inverse via target↔source swap. See
# `src/ir/swap_instruction.jl`'s top-of-module docstring.
is_injective(::Type{SwapInstruction})::Bool = true

# M2.8 — subroutine markers (RC3 `begin l(x,...)` / `end l(y,...)`).
# pc-only at this dispatch layer; `locals` untouched. See
# `src/ir/control_instructions.jl` M2.8 block docstring.
is_injective(::Type{BeginInstruction})::Bool = true
is_injective(::Type{EndInstruction})::Bool   = true

# M2.9 — basic-block entry/exit (RC3 `l(x,...) <-` / `-> l(y,...)`).
# Mogensen-RSSA paired entry/exit (ADR 0001 §Observations
# Structural-Pattern point 1); pc-only at this dispatch layer.
is_injective(::Type{UnconditionalEntry})::Bool = true
is_injective(::Type{UnconditionalExit})::Bool  = true

# M2.10 — conditional basic-block entry/exit (RC3
# `l1(x,...)l2 <- c` / `c -> l1(y,...)l2`). Injective via the
# live-predicate mechanism — φ-nodes on splits AND joins
# (Mogensen 2016 §3 / ADR 0001 Structural-Pattern point 2). The
# predicate symbol survives in `locals` so backward dispatch
# recovers the source label structurally.
is_injective(::Type{ConditionalEntry})::Bool = true
is_injective(::Type{ConditionalExit})::Bool  = true

# M2.12 — register↔memory exchange (Pendulum-style; Vieri 1995
# §4.2.1). Self-inverse via target↔source swap. See
# `src/ir/memory_instructions.jl` M2.12 block docstring.
is_injective(::Type{MemoryInterchange})::Bool = true

# M2.13 — memory↔memory exchange. Self-inverse; permutes two cells
# without creating or destroying any SSA name. See
# `src/ir/memory_instructions.jl` M2.13 block docstring.
is_injective(::Type{MemorySwap})::Bool = true

# -----------------------------------------------------------------------------
# Value-level discrimination — `ArithmeticAssignment` per-instance modop.
# -----------------------------------------------------------------------------
#
# `ArithmeticAssignment`'s type-level method stays at the default
# `false`. The value-level method below returns `true` iff the
# instance's `modop` is `:xor` — the conservative reading of PRD
# v4 §3.2 documented at length in the file's top-of-module
# docstring. Broadening to `:add` / `:sub` is a separate follow-up
# (currently unfiled); see the docstring's "Value-level
# discrimination for `ArithmeticAssignment`" paragraph for the
# rationale.

# -----------------------------------------------------------------------------
# Type-level `false` pin — `Define` (M_UNBOUNDED, ADR 0012 §D1).
# -----------------------------------------------------------------------------
#
# `Define` (`src/ir/define_instruction.jl`) is the reversible SSA-create
# `target := lhs op rhs`. It would inherit `false` from the default
# `is_injective(::Type{<:Instruction})` fallback above, but the
# classification is **load-bearing and deliberate** (ADR 0012 §"The
# cross-iteration reversibility crux"), so it is pinned explicitly here
# at the same site as the rest of the taxonomy: in a loop the same SSA
# name is redefined each iteration, so a `Define` may OVERWRITE a prior
# value. The static type-level trait cannot see runtime freshness — it
# cannot tell a genuinely-fresh create (injective) from a re-definition
# that overwrites (non-injective) — so per Rule 1 ("fail safe — push
# when in doubt") it must be conservatively `false`. This forces the
# M6.2/M7.6 push gate to emit L3 `CheckpointEntry`s around every
# `Define`; `unstep!` then reverses it via checkpoint-replay
# (`src/history/Replay.jl`), which never calls `Define`'s deferred
# per-instruction `inverse()`. Tightening to recognise the
# never-overwritten injective case is deferred (ADR 0012 R3). Do NOT
# mark this `true`.
is_injective(::Type{Define})::Bool = false

"""
    is_injective(x::ArithmeticAssignment) -> Bool

Value-level specialisation: returns `true` iff `x.modop === :xor`.
The type-level method stays at the default `false` because
injectivity depends on the per-instance `modop` field, not the
type. See the file's top-of-module docstring "Value-level
discrimination for `ArithmeticAssignment`" for the conservative-on-
`:xor`-only rationale (PRD v4 §3.2 lists all three modops `:add`,
`:sub`, `:xor` as injective; this bead is intentionally
conservative on `:xor` only, broadening to `:add`/`:sub` is a
separate follow-up bead).
"""
is_injective(x::ArithmeticAssignment)::Bool = x.modop === :xor
