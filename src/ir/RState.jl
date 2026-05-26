"""
    RState

History-bearing reversible-execution wrapper around `IState`.

# What RState is

`IState` (see `src/ir/IState.jl`) is the *snapshot* — everything one
instruction is allowed to read or write at a single moment. `RState` is
the *trajectory-so-far*: the live snapshot plus the tape that lets the
interpreter walk backward through every instruction it has already
executed. The reversible-execution loop pivots on `RState`, not `IState`:

  - `step!(s::RState, prog)` reads `s.current`, computes the next
    snapshot, mutates `s.current` in place, and (when the instruction
    is non-injective) appends an `AbstractHistoryEntry` to `s.history`.
  - `unstep!(s::RState, prog)` pops the most recent `AbstractHistoryEntry`
    (when present) and uses it to roll `s.current` back to its prior
    value.
  - `run!` / `unrun!` iterate the two until halt / empty-history.

The load-bearing invariant established here is the one M3.x will
exercise: `unrun!(run!(s, prog)) == initial(s) && isempty(s.history)`.
Both pieces — equality of `current`, emptiness of `history` — live on
this struct.

# Why a separate type (rather than fields-on-IState)

PRD v4 §3.9 carves `IState` and `RState` apart deliberately, and the
spike retrospective (`spike/RETROSPECTIVE.md` Q4 §"Naming conventions
worth keeping") confirms the split survived hostile review. The
rationale is twofold:

  1. **`forward` dispatch stays clean.** The generic
     `forward(instr, s::IState) :: IState` signature in PRD v4 §3.9 is
     deliberately innocent of history machinery. A per-instruction
     `forward` method computes "what does the next snapshot look like"
     — nothing else. Pushing the resulting delta / snapshot / no-op
     onto the tape is the `step!` wrapper's job, performed against an
     `RState`. Keeping the two types separate keeps `forward`'s
     contract narrow enough that the M3.x dispatch is the single
     pivot for every Phase-2 instruction kind without dragging
     history-strategy choices into per-instruction code.
  2. **History strategy is pluggable, semantics are not.** §3.3
     introduces three history layers (see `AbstractHistoryEntry`
     below); each layer chooses what an entry contains, but none of
     them changes what an `IState` *is*. Bolting the history field on
     at the `RState` wrapper level means M4 / M6 / M7 can introduce
     concrete entry types without touching `IState.jl`, and the M3.x
     forward-dispatch surface stays identical across layers.

# Why mutable

Declared `mutable struct` for the same reason `IState` is mutable
(`spike/RETROSPECTIVE.md` Q1, ratified as PRD v4 §3.9 normative): the
interpreter's tight inner loop mutates state in place. `step!` rebinds
`s.current` to the new snapshot and `push!`es onto `s.history`;
`unstep!` mutates `s.current` back and `pop!`s `s.history`. Both
patterns require a `mutable struct` so the per-step rebinding does not
force the caller to thread a fresh `RState` through every call site.
Per PRD v4 §3.9: "RState — reversible wrapper. MUST be declared
mutable struct."

# AbstractHistoryEntry as a polymorphism point

`history::Vector{AbstractHistoryEntry}` is typed against the supertype
so that the three layers PRD v4 §3.3 prescribes can coexist:

  - **L1 — injective / no-log** (lands at M6.x). Injective instructions
    and reversible jumps push *nothing* (§3.2). The "entry" type is
    really a marker for compile-time classification; the runtime tape
    sees no push.
  - **L2 — delta min-cut** (lands at M7.x). For non-injective ops in
    deterministic regions, the entry carries only the destroyed
    value(s), selected by Enzyme-style min-cut analysis
    (Moses–Churavy 2020). Not a full snapshot.
  - **L3 — checkpoint + replay** (lands at M4.x). Periodic full-state
    checkpoints; backward execution between checkpoints is via
    deterministic forward replay from the prior checkpoint (rr-style;
    O'Callahan et al 2017 §2.1).

The choice of *which* layer applies at a given program point is a
per-program *lowering* decision, not a runtime mode flip. The
interpreter never inspects `typeof(entry)` to decide what to do; the
per-instruction `inverse` method knows which entry shape its
corresponding `forward` produced. This is the design lesson PRD v4
§3.3 pulls from RC3 (no history field at all — RSSA is reversible-by-
construction) crossed with the Phase-0 retrospective (full snapshots
are the worst point on the time-space curve and exist in the spike
specifically so v4 could refute them).

# Cross-references

- PRD v4 §3.9 ("API and naming conventions"): `RState` MUST be declared
  `mutable struct` and MUST contain `current::IState` plus
  `history::Vector{T}` for an implementation-defined entry type `T`.
- PRD v4 §3.3 ("History mechanism"): three history layers; this file
  defines the supertype they all share.
- `spike/RETROSPECTIVE.md` Q1 ("`RState` must be `mutable struct`,
  not the immutable struct PRD v3 §5.3 wrote") — the source of the
  mutability requirement.
- `docs/adr/0001-rc3-rvm-smoke.md` §Observations: RC3 has no history
  field at all because Janus is reversible-by-construction (RSSA);
  BennettVM's history field is the Phase-2-specific addition driven
  by the irreversible Julia source language. The decision-table row
  "History field" makes the contrast explicit.
- `src/ir/IState.jl`: the underlying snapshot type. Loaded before this
  file in `src/BennettVM.jl` because `RState` references `IState`.
"""

"""
    AbstractHistoryEntry

Supertype for the three concrete reversibility-tape entry variants
introduced by PRD v4 §3.3. **No concrete subtype is defined here** —
that violates the M2.x → M{4,6,7} milestone ordering. Subtypes land in:

  - **M6.x** — L1 injective / no-log entries (effectively a marker
    type; injective instructions push nothing at runtime).
  - **M7.x** — L2 delta min-cut entries carrying the minimal payload
    needed to invert a non-injective step (Enzyme-style cache
    analysis ported to BennettVM's RSSA IR).
  - **M4.x** — L3 checkpoint + replay entries pinning a full `IState`
    snapshot at a configurable interval, with backward execution
    between checkpoints performed by deterministic forward replay
    (rr-style).

Methods on `AbstractHistoryEntry` (none yet — `inverse(instr, s, prev)`
in §3.9 takes the entry as the third argument; per-instruction-kind
methods dispatch on `prev`'s concrete type) appear alongside their
introducing subtype.

Ref: `bennettvm_prd.md` §3.3, §3.9.
"""
abstract type AbstractHistoryEntry end

"""
    RState(current::IState, history::Vector{AbstractHistoryEntry})

See the top-of-file docstring for the full rationale. Two fields:

  - `current::IState` — the live snapshot the next `step!` / `unstep!`
    will operate on.
  - `history::Vector{AbstractHistoryEntry}` — the reversibility tape;
    concrete entries are appended forward by `step!` and consumed
    backward by `unstep!`. Empty after a full `unrun!`.

`mutable struct` — see top-of-file "Why mutable" and `spike/
RETROSPECTIVE.md` Q1.
"""
mutable struct RState
    current::IState
    history::Vector{AbstractHistoryEntry}
end

"""
    Base.:(==)(a::RState, b::RState) -> Bool

Structural equality on `RState`: defined field-by-field, delegating
to the `IState` `==` override (M2.2, `src/ir/IState.jl`) for `current`
and to `Base.:(==)(::AbstractVector, ::AbstractVector)` for `history`.

# Why this exists at M2.3 rather than later

Rule 1 ("Fail fast, fail loud") plus the M2.2 precedent. The Phase-0
retrospective Q2.1 documents the Dict-identity trap that silently
broke round-trip equality on `IState` until an explicit override was
added; the *same* trap applies one level up on `RState`, because
Julia's default `==` for a `mutable struct` reduces to `===` on every
field — and on the `history::Vector` field that becomes identity on
the underlying array object, not content equality of entries. Without
this override, a future round-trip test of the form
`unrun!(run!(s, prog)) == initial_rstate(prog)` would silently never
hold (the two `RState`s would have distinct `Vector` instances, even
when both are empty), exactly the failure mode M2.2 closes for
`IState`. Heading the trap off now costs one line; finding it later
costs an interpreter-debugging session.

Ref: `spike/RETROSPECTIVE.md` Q2.1.
Ref: `src/ir/IState.jl` (the M2.2 override this mirrors).
"""
function Base.:(==)(a::RState, b::RState)
    a.current == b.current && a.history == b.history
end

function Base.hash(s::RState, h::UInt)
    h = hash(s.current, h)
    h = hash(s.history, h)
    return h
end
