"""
    DeltaEntry{T<:Instruction} <: AbstractHistoryEntry  (M7.2)

The L2 reversibility-tape entry — the "delta with min-cut selection"
layer of PRD v4 §3.3's three-layer history scheme. A `DeltaEntry`
records *exactly enough* state to invert one non-injective forward
step: the instruction that ran, the minimal information (the `payload`
NamedTuple) the per-instruction `inverse` will consume beyond
current state, and the step index at which the entry was pushed.

This file defines the *type only* (M7.2, bead `bennettvm-c4m`). The
per-instruction `make_delta` constructors and the matching
`inverse(::T, s, payload::NamedTuple)` specialisations land at M7.3
(`bennettvm-vk8`) and M7.4 (`bennettvm-bk5`) respectively. M7.6
(`bennettvm-7e7`) is where `step!` actually pushes a `DeltaEntry`
onto `s.history` at the existing push site.

# Where this sits in the three-layer history scheme

PRD v4 §3.3 ("History mechanism") prescribes three layers, applied in
**order of preference**:

  1. **L1 — no log** (M6.1, M6.2, file `src/history/Injective.jl`).
     Injective instructions and reversible jumps push *nothing*.
     The `is_injective` trait gates this path; when the trait returns
     `true`, no `AbstractHistoryEntry` is constructed at all.
  2. **L2 — delta entries with min-cut selection** — *this file*.
     For non-injective ops in deterministic regions, the entry
     carries the minimal information required to invert the step
     (Enzyme-style cache analysis, Moses–Churavy 2020 NeurIPS §2
     "Cache", ported to BennettVM's RSSA IR per ADR 0002). The
     payload is a `NamedTuple` whose schema is per-instruction-type
     and documented in ADR 0002 §DeltaEntry payload schema.
  3. **L3 — periodic full-state checkpoints + deterministic replay**
     (M4.1, file `src/history/CheckpointEntry.jl`). The safety-net
     layer; kept active per PRD v4 §3.3 lines 461–465 ("a safety net
     for long-running regions").

PRD v4 §3.3 lines 455–460 are this layer's binding mandate:

> Layer 2 — delta entries with min-cut selection. For non-injective
> ops in deterministic regions, the history payload is the minimal
> information required to invert the step (Enzyme-style cache
> analysis, Moses–Churavy 2020). [...]

ADR 0002 §DeltaEntry payload schema locks the exact shape; this file
codes it.

# Why parametric on `T<:Instruction` (ADR 0002 Design Decision 1)

The dispatch story for L2 inversion is per-instruction-type: each
non-injective concrete `Instruction` subtype gets a specialised
`make_delta(::T, s_pre, step)` (M7.3) and
`inverse(::T, s, payload::NamedTuple)` (M7.4). Carrying the
instruction type at the entry level lets that dispatch happen
without `Any`-routing:

```julia
# M7.4 sketch — the per-T inverse specialisation reads payload as a
# NamedTuple of known shape:
function inverse(instr::MyInstr, s::IState, payload::NamedTuple)
    # payload.x, payload.y, ... are known fields per the M7.3 schema.
end
```

The parametric struct costs one method-table per concrete `T`, but
the twelve `T`s are sealed-by-convention (`src/ir/instructions.jl`
§"Sealed by convention"), so the cost is bounded. This mirrors
Julia's idiomatic compiler-friendly pattern for type-tagged carriers
and is the pattern the Phase-2 PRD §3.3 anticipates by saying the
history is *polymorphic across layers*.

(Note: `CheckpointEntry` is *not* parametric — it carries an
`IState` snapshot, which has only one type, so no per-T dispatch is
needed. The parametric design is justified specifically for
`DeltaEntry` because the inverse method specialises on `T`.)

# Why `NamedTuple` for `payload` (ADR 0002 Design Decision 2)

The payload is the minimal information beyond current state that the
inverse needs. Options considered, with the ADR's rationale:

  * **Per-T struct** (e.g., `MemAssignDelta`, `ArithAssignDelta`).
    Rejected: ADR 0002 §DeltaEntry payload schema finds that under
    the *current* IR, every non-injective instruction has an
    **empty** payload (the M2.6 modop set `{:xor, :add, :sub}`
    combined with `dual_modop` means the inverse reads current
    state alone). Defining twelve empty struct types just to satisfy
    the parametric signature would be ceremonial.
  * **`Dict{Symbol,Any}`**. Rejected: heap-allocated, not value-type,
    breaks structural equality unless we override `==`/`hash`
    manually.
  * **`Any`** (or no payload field at all). Rejected: gives up the
    type information the M7.4 `inverse` specialisation will rely
    on once a future Phase-2.x instruction introduces a non-empty
    payload.

NamedTuple wins on every axis: value-type (stack-allocated,
zero-sized for `NamedTuple()`), structurally hashable, structurally
`==`-comparable (Julia's default reflects field equality), and
extensible (adding a field doesn't change the type at the
`DeltaEntry{T}` level). The empty NamedTuple — `NamedTuple()`, type
`NamedTuple{(),Tuple{}}` — is the dominant case at this milestone
and costs zero bytes plus an eight-byte type tag.

# Why `step::Int` (ADR 0002 reviewer item 9 — mirror CheckpointEntry)

`CheckpointEntry.step` (`src/history/CheckpointEntry.jl:264-273`)
carries the post-increment step index at which the snapshot was
captured. Replay.jl's polymorphic search-for-nearest entry walks
`s.history` looking at `entry.step` uniformly — the loop does not
type-dispatch on which AbstractHistoryEntry subtype it is reading.
Giving `DeltaEntry` the same field name and shape means a future
Replay.jl variant that consults L2 entries can use the same field
access without further plumbing. The cross-layer uniformity is the
binding reason; the field name is not negotiable.

`Int` (not `UInt`) for parity with `IState.pc::Int`, `RState.step_count
::Int`, `run!`'s `max_steps::Int`, and `CheckpointEntry.step::Int`.
Mixing widths would force conversions in the polymorphic Replay walk.
The constructor accepts any `Integer` and coerces via `Int(...)` so
callers carrying `Int32` / `UInt32` upstream are not forced to wrap
their call sites.

# What this file does NOT do

  * **Per-instruction `make_delta` methods land in the instruction's
    own file** (`src/ir/<instr>.jl`), NOT here, per ADR 0002 Design
    Decision 3 (co-located with `forward`/`inverse` per Rule 11).
    M7.3 (`bennettvm-vk8`) adds the per-T methods; this file carries
    only the abstract generic fallback (defined at the bottom — see
    `make_delta(instr::Instruction, ...)`) whose sole job is the
    Rule-1 fail-loud raise for instruction types that lack a
    specialisation. A bare convenience constructor
    `DeltaEntry(instruction, payload, step)` is provided here for
    type-inference convenience and for the tests; per-T factories
    land at M7.3.
  * **No `inverse(::T, s, payload::NamedTuple)` methods.** M7.4
    (`bennettvm-bk5`) extends the existing `inverse(instr, s, prev)`
    signature with a `payload::NamedTuple` specialisation — strictly
    additive per ADR 0002 Design Decision 4. This file defines no
    `inverse` methods.
  * **No `step!` push integration.** M7.6 (`bennettvm-7e7`) wires
    `make_delta` calls into the existing push site in
    `src/interpreter/Interpreter.jl`. The composition rule with
    M6.1's `is_injective` gate and M4.2's checkpoint gate is locked
    in ADR 0002 §Composition with M6.
  * **No export.** Following the M6.1 pattern, the type is internal-
    only (`BennettVM.DeltaEntry`) until M7.6 settles on the public-
    API surface.

# Why `Base.==` and `Base.hash` are overridden explicitly

The same precedent as `CheckpointEntry`'s overrides
(`src/history/CheckpointEntry.jl:281-293`) and `IState`'s
(`src/ir/IState.jl`, M2.2). Two reasons:

  1. **Same-T equality.** Julia's default `==` on a parametric struct
     reduces to field-by-field `==`. For `DeltaEntry{T}`'s three
     fields (`instruction::T`, `payload::NamedTuple`, `step::Int`),
     the default *would* do the right thing — but per the
     `CheckpointEntry` precedent and `RState.jl:175-177` ("Heading
     the trap off now costs one line; finding it later costs an
     interpreter-debugging session"), we write the override out so
     a reader who searches for `==` in this file finds the explicit
     declaration alongside its rationale. The `hash` override is
     genuinely necessary to preserve `a == b ⟹ hash(a) == hash(b)`
     for the `Set{DeltaEntry}`-style round-trip tests in M7.x.
  2. **Cross-T inequality** is handled by the *absence* of a method,
     not by a second method declaration. `DeltaEntry{Foo}(...) !=
     DeltaEntry{Bar}(...)` even when their (`payload`, `step`)
     tuples are bitwise identical, because the entries describe
     inversions of *different* instruction types. Julia's
     `==(x::Any, y::Any) = x === y` fallback (Base) gives `false`
     for a `DeltaEntry{Foo}` and a `DeltaEntry{Bar}` (distinct
     object identities), which is the correct cross-T answer.

     A first draft of this file declared an explicit
     `Base.:(==)(::DeltaEntry, ::DeltaEntry) = false` to make the
     cross-T contract visually explicit. **It was removed**: on
     Julia 1.12, the unparameterised method is treated as
     *equally specific* to the same-T `where T` method (both
     match the same set of concrete `DeltaEntry{T1, T2}` pairs
     when `T1 == T2`), and the latter-declared method wins. With
     both methods present, the unparameterised one shadows the
     same-T one and `DeltaEntry{Foo}(...)  == DeltaEntry{Foo}(...)`
     returns `false`, breaking the structural-equality contract.
     The remedy is to declare ONLY the same-T method; Julia's
     `Any`-fallback handles the cross-T case correctly. This
     comment exists so a future agent re-adding the cross-T
     method finds the explanation before re-introducing the bug.

This differs from `CheckpointEntry`'s equality: `CheckpointEntry` is
non-parametric, so there is no cross-type case to handle. The
cross-T behaviour here is delegated to Julia's `Any`-fallback by
design, with the `hash(T, h)` mix-in in the `hash` override
preserving the `a == b ⟹ hash(a) == hash(b)` invariant on the
cross-T side (different `T`s hash to probabilistically-different
values; the `Any`-fallback returns `false` for `==`).

# Ref

  * `bennettvm_prd.md` (PRD v4) §3.3 lines 455-460 — L2's binding
    mandate (delta entries with min-cut selection; Enzyme-style cache
    analysis).
  * `bennettvm_prd.md` (PRD v4) §3.3 lines 461-465 — L3 fallback
    semantics; preserved as safety net under M7's composition rule.
  * `docs/adr/0002-enzyme-min-cut-mapping.md` §DeltaEntry payload
    schema — the binding schema this file codes.
  * `docs/adr/0002-enzyme-min-cut-mapping.md` §Design Decisions 1–4
    — parametric T, NamedTuple payload, per-instruction-file
    `make_delta`, additive `inverse` signature.
  * `src/history/CheckpointEntry.jl` (M4.1) — the structural model
    this file mirrors (`step::Int`, explicit `==`/`hash`, `<:
    AbstractHistoryEntry`).
  * `src/history/Injective.jl` (M6.1) — the L1 gate consulted before
    L2 in M7.6's composition rule.
  * `src/ir/RState.jl:209` — `AbstractHistoryEntry`, the supertype.
  * `src/ir/instructions.jl:79` — `Instruction`, the abstract parent
    of `T` in `DeltaEntry{T<:Instruction}`.
  * Bead `bennettvm-c4m` (M7.2) — this file's bead.
  * Bead `bennettvm-vk8` (M7.3) — the downstream bead that adds
    per-instruction `make_delta` methods.
  * Bead `bennettvm-bk5` (M7.4) — the downstream bead that adds the
    `inverse(::T, s, payload::NamedTuple)` specialisations.
  * Bead `bennettvm-7e7` (M7.6) — the downstream bead that wires
    `DeltaEntry` into `step!`'s push site.
  * Bead `bennettvm-ack` — the open follow-up that would broaden
    M6.1's `ArithmeticAssignment` injectivity to all three modops,
    at which point this file's M7 pushes for those instructions
    collapse into M6 no-pushes.
"""

"""
    DeltaEntry{T<:Instruction}(instruction::T, payload::NamedTuple, step::Integer)

Construct an L2 history entry recording the instruction that just ran
forward, the minimal payload needed to invert it, and the step index
at which the entry was pushed.

Unlike `CheckpointEntry`'s constructor, this constructor does **not**
`deepcopy` its arguments:

  * `instruction::T` is an immutable `Instruction` subtype (all twelve
    concrete subtypes are declared `struct`, not `mutable struct` —
    see `src/ir/instructions.jl` §"Sealed by convention" and each
    M2.6-M2.14 concrete file). Sharing the reference is safe: the
    instruction value cannot be mutated after construction.
  * `payload::NamedTuple` is a value-type by Julia's semantics —
    NamedTuples are immutable and stack-allocatable. Sharing a
    NamedTuple reference is structurally equivalent to copying it;
    there is no aliasing trap analogous to the `Dict`-on-`IState`
    one that motivated `CheckpointEntry`'s deepcopy
    (`spike/RETROSPECTIVE.md` Q2.2).
  * `step::Integer` is coerced to `Int` via `Int(...)`, mirroring
    `CheckpointEntry`'s coercion convention exactly.

A non-`Integer` `step` (e.g., `Float64`, `Symbol`) raises `MethodError`
at construction time — the Rule 1 fail-loud shape for what is
clearly a programming error.

# Arguments

  * `instruction::T` — the (non-injective) instruction whose forward
    just ran. Stored as-is.
  * `payload::NamedTuple` — the minimal extra information the inverse
    needs beyond current state. Empty NamedTuple (`NamedTuple()`) is
    the dominant case at this milestone per ADR 0002.
  * `step::Integer` — the post-increment `step_count` at which the
    entry was pushed. Coerced to `Int`.
"""
struct DeltaEntry{T<:Instruction} <: AbstractHistoryEntry
    instruction::T
    payload::NamedTuple
    step::Int

    function DeltaEntry{T}(instruction::T, payload::NamedTuple,
                           step::Integer) where T<:Instruction
        # No deepcopy of `instruction` or `payload` — both are
        # value-shaped (immutable struct / NamedTuple). The only
        # boundary that matters is the `step` coercion, parallel to
        # `CheckpointEntry`'s constructor.
        new{T}(instruction, payload, Int(step))
    end
end

"""
    DeltaEntry(instruction, payload, step)

Convenience constructor that infers the type parameter `T` from
`instruction`. Equivalent to `DeltaEntry{typeof(instruction)}(...)`.
"""
DeltaEntry(instruction::T, payload::NamedTuple, step::Integer) where T<:Instruction =
    DeltaEntry{T}(instruction, payload, step)

"""
    Base.:(==)(a::DeltaEntry{T}, b::DeltaEntry{T}) where T -> Bool

Structural (content) equality for same-T entries: equal iff their
`step`, `instruction`, and `payload` fields are pairwise `==`.

See the file-level docstring "Why `Base.==` and `Base.hash` are
overridden explicitly" for why this is written out rather than
relying on the auto-generated method.
"""
function Base.:(==)(a::DeltaEntry{T}, b::DeltaEntry{T}) where T
    a.step == b.step && a.instruction == b.instruction && a.payload == b.payload
end

# NOTE: no `Base.:(==)(::DeltaEntry, ::DeltaEntry)` cross-T method.
# On Julia 1.12 the unparameterised method shadows the same-T method
# above, breaking same-T equality. See the file-level docstring "Why
# `Base.==` and `Base.hash` are overridden explicitly" point 2 for
# the full rationale. Cross-T inequality is delivered by Julia's
# `==(x::Any, y::Any) = x === y` Base fallback, which returns `false`
# for two distinct `DeltaEntry`-typed objects regardless of T1/T2.

"""
    Base.hash(e::DeltaEntry{T}, h::UInt) where T -> UInt

Mix the type parameter `T` into the hash so that `DeltaEntry{Foo}`
and `DeltaEntry{Bar}` with otherwise-identical fields hash to
different values (probabilistically). Combined with the cross-T
`==` fallback above, this satisfies the `a == b ⟹ hash(a) == hash(b)`
contract on both the same-T and cross-T sides.
"""
function Base.hash(e::DeltaEntry{T}, h::UInt) where T
    h = hash(T, h)
    h = hash(e.step, h)
    h = hash(e.instruction, h)
    h = hash(e.payload, h)
    return h
end

"""
    make_delta(instr::Instruction, s_pre::IState, step::Integer) -> DeltaEntry

Per-instruction constructor that captures the minimum information
needed to reverse `forward(instr, s_pre)` without a full IState
snapshot. ADR 0002 §Design Decision 3: the per-instruction
specialisations live in the instruction's own file
(`src/ir/<instr>.jl`); this generic fallback catches forgotten
types and surfaces them loudly (CLAUDE.md Rule 1).

For the M7.1 ADR's key finding — `ArithmeticAssignment` and
`MemoryAssignment` are structurally injective via `dual_modop`, so
their deltas carry an EMPTY `NamedTuple` — see the per-instruction
specialisations in `src/ir/arithmetic_assignment.jl` and
`src/ir/memory_instructions.jl`.

# Why this is the abstract entry point

Two requirements from ADR 0002 collide here:

  * **Per-instruction `make_delta` lives in each instruction's own
    file** (Design Decision 3) — this means there is no single file
    that imports every concrete subtype's `make_delta` method, and
    therefore no "central registry" check for completeness.
  * **Rule 1 demands fail-loud on unknown instruction kinds** — if
    M7.6's push site calls `make_delta(some_new_instr, ...)` on a
    type whose `make_delta` was forgotten, the system MUST raise a
    descriptive error, not silently fall through to a NoMethodError
    or worse a wrong-dispatch path.

The generic abstract-typed fallback below satisfies both: it
exists in this file because the file already imports the abstract
`Instruction` supertype (`src/ir/instructions.jl:79`), and it
errors descriptively naming the missing-specialisation type and
the file the specialisation belongs in. Adding a new concrete
instruction without a paired `make_delta` causes the next M7.6
push to raise this error the first time the new instruction
executes non-injectively — exactly the Rule 1 failure mode the
ADR demands.

# Note on `CallInstruction`

`CallInstruction` does have a specialised `make_delta` method (in
`src/ir/call_instruction.jl`) but it ALSO errors loudly — per ADR
0002 §Open Questions item 4, cross-call deltas are deferred to v5.
The specialisation exists so that future v5 work can replace just
that method body without changing this fallback's contract.

# Ref

  * `docs/adr/0002-enzyme-min-cut-mapping.md` §Design Decision 3 —
    "per-instruction file" location rule.
  * `docs/adr/0002-enzyme-min-cut-mapping.md` §Open Questions item
    4 — CallInstruction deferred to v5.
  * `CLAUDE.md` Rule 1 — fail loud on unknown / unsupported cases.
  * Bead `bennettvm-vk8` (M7.3) — this method's bead.
"""
function make_delta(instr::Instruction, s_pre::IState, step::Integer)::DeltaEntry
    error("BennettVM.make_delta: no specialisation for instruction of type ",
          typeof(instr),
          ". This usually means a non-injective instruction kind was added ",
          "without a paired make_delta method. Add a method in the ",
          "instruction's own file (src/ir/<instr>.jl) — ADR 0002 §Design ",
          "Decision 3. Pre-state pc=", s_pre.pc, ", step=", step, ".")
end

"""
    predelta_payload(instr::Instruction, s_pre::IState)
        -> Union{Nothing,NamedTuple}

PRE-`forward()` L2-delta capture hook (M_DYN, bd `bennettvm-ekc`,
ADR 0009 Decision 2b). Returns the minimal pre-`forward()` state an
L2 `inverse` needs that `forward()` is about to DESTROY — or
`nothing` if the instruction's L2 delta is pre-state-independent
(the dominant case: the ADR 0002 §"DeltaEntry payload schema"
empty-payload finding).

# Why a separate hook (not just `make_delta` called pre-`forward()`)

`make_delta(instr, s_pre, step)` builds a complete `DeltaEntry`,
including the `step` field — but the step count is only finalised
AFTER `forward()` succeeds (`step!` increments `s.step_count` post-
forward, M4.2). `predelta_payload` separates the *pre-state capture*
(which MUST happen before `forward()`) from the *entry construction*
(which happens at the push gate, with the finalised step index). The
`step!` push gate (`src/interpreter/Interpreter.jl` step (3a)/(7))
wraps a non-`nothing` payload in `DeltaEntry(instr, payload, step)`;
a `nothing` return falls back to the post-`forward()`
`make_delta(instr, s.current, step)` path unchanged.

# The default is `nothing` (Rule 1 / backward-compat)

Every instruction whose L2 inverse recomputes from surviving post-
`forward()` state (every non-injective instruction shipped before
M_DYN — `ArithmeticAssignment(:add/:sub)`, `MemoryAssignment`, …)
inherits this `nothing` default, so the `step!` push gate's behaviour
for them is bit-for-bit identical to pre-M_DYN. Two instructions
specialise this to a non-`nothing` return: `MemoryStore`
(`src/ir/memory_floor.jl`) captures `(addr, old_value, was_present)` —
its overwrite destroys the prior cell value; and `DynAlloca`
(`src/ir/alloca.jl`) captures `(base, n)` — the runtime region size its
inverse needs to retract `base..base+n-1`. Neither is recoverable from
post-`forward()` state (the L2 contrast with the self-inverse /
paired-inverse instructions). The value-shaped
NamedTuple return keeps the capture O(1): no `deepcopy(s.current)`,
so L2's per-write space win (ADR 0009 Decision 2b; PRD §3.3 forbids
full snapshots on the L2 path) is preserved.

# Ref

  * `docs/adr/0009-dynamic-size-memory.md` Decision 2b/4.4 — the
    indexed-store (addr, old_value) delta + per-write O(1) mandate.
  * `docs/adr/0002-enzyme-min-cut-mapping.md` §"DeltaEntry payload
    schema" — the empty-payload finding that makes `nothing` the
    correct default for the pre-M_DYN instruction set; §Design
    Decision 3 — per-instruction-file location for the override.
  * `src/ir/memory_floor.jl` / `src/ir/alloca.jl` — the non-`nothing`
    specialisations (`MemoryStore` → `(addr, old_value, was_present)`;
    `DynAlloca` → `(base, n)`) and their matching L2
    `inverse(::T, s, ::NamedTuple)` methods.
  * `src/interpreter/Interpreter.jl` (M_DYN) — the `step!` push gate
    step (3a)/(7) that calls this hook before `forward()`.
  * `CLAUDE.md` Rule 1 (fail safe — the conservative `nothing`
    default keeps the empty-payload path alive when uncertain).
"""
predelta_payload(::Instruction, ::IState)::Union{Nothing,NamedTuple} = nothing

"""
    is_l2_capable(::Type{<:Instruction}) -> Bool

The L2 "can this non-injective instruction be reversed by an L2
`DeltaEntry`?" trait (bd `bennettvm-5pp`). Returns `true` iff the
instruction type has a *working* L2 delta path: a non-raising
`make_delta` **or** a non-`nothing` `predelta_payload`, AND a matching
`inverse(::T, s, payload::NamedTuple)` specialisation that the M7.4
`unstep!` fast-path (`src/history/Replay.jl`) can dispatch to. The
default is **`false`** — the fail-safe analogue of `is_injective`'s
conservative `false` default.

# Why this trait exists (the bug `bennettvm-5pp` fixes)

`compute_must_cache` (`src/analysis/liveness.jl`) marks the slots whose
forward step should push a `DeltaEntry` (the L2 path) rather than fall
through to an L3 `CheckpointEntry`. The M7.5 stub marked **every**
non-injective body slot. But that is unsound for the L3-only creates:
`Define` / `VarGEP` / `MemoryLoad` / `CastInstruction` /
`SelectInstruction` have NO working L2 path — their `make_delta`
inherits the RAISING generic fallback (`make_delta(::Instruction, …)`
above), and their `predelta_payload` inherits the `nothing` default.
`CallInstruction` is the same shape (its specialised `make_delta`
*also* raises — cross-call deltas are v5-deferred, ADR 0002 §Open
Questions item 4). Routing any of them through the L2 push gate
(`src/interpreter/Interpreter.jl` step (7): `pre_payload === nothing ?
make_delta(instr, s.current, step) : DeltaEntry(...)`) hits the raising
`make_delta` fallback. Consequently `compute_must_cache(vm)` could NOT
be passed as the global `must_cache_set` for any program containing
such an instruction — it raised the moment that instruction executed
non-injectively (which is why the dynamic-array tests in
`test/test_alloca_delta.jl` / `test/test_store_delta.jl` had to
hand-build L2 sets that EXCLUDE the L3-only creates). frtN (SC9 Case A)
needs the automatic `compute_must_cache(vm)` path to work, so this
trait lets `compute_must_cache` mark a slot iff it is BOTH
non-injective AND L2-capable; a non-injective-but-not-L2-capable
instruction is left out of the set and falls through to L3 (sound).

# The fail-safe default (Rule 1)

Defaulting to `false` means a future non-injective instruction added
WITHOUT an L2 path is automatically routed to L3 (the safety net),
never to the raising L2 path — the same "push the safe entry when in
doubt" discipline `is_injective`'s `false` default expresses for L1.
Marking a type `true` is therefore a deliberate assertion that its L2
machinery exists; the four specialisations below were each verified
against the live source (Rule 3) — see the per-specialisation comments.

# Why this lives in `delta.jl` (not `Injective.jl`)

`is_l2_capable` is an L2-layer concept: it asserts the presence of the
very machinery this file defines — `make_delta` (the generic raising
fallback above), `predelta_payload` (the `nothing` default above), and
the `DeltaEntry` the push gate builds. Co-locating the trait with the
generic methods it abstracts over keeps the "what makes an instruction
L2-capable" definition next to the methods that *are* L2-capability.
`Injective.jl` is the L1 trait's home; this is its L2 sibling, and
`compute_must_cache` consumes the two together (`is_injective`
short-circuits to L1; `is_l2_capable` gates L2 vs L3). `delta.jl` is
included after every per-instruction file and before
`analysis/liveness.jl`, so the four specialisations can name their
types and `compute_must_cache` can call the trait.

# Ref

  * Bead `bennettvm-5pp` — this trait's bead; the `compute_must_cache`
    soundness fix it enables.
  * `src/history/delta.jl` (this file) — the raising `make_delta`
    fallback and the `nothing` `predelta_payload` default that the
    L3-only creates inherit (the reason routing them through L2 raises).
  * `src/history/Injective.jl` (M6.1) — the L1 sibling trait whose
    `false`-default / explicit-`true`-specialisation pattern this
    mirrors.
  * `src/analysis/liveness.jl` (M7.5, this bead) — the sole consumer:
    `compute_must_cache` now marks a slot iff `!is_injective(instr) &&
    is_l2_capable(typeof(instr))`.
  * CLAUDE.md Rule 1 (fail safe — L3 not the raising L2 path when in
    doubt), Rule 2 (the trait records which instructions have a real
    L2 path vs deferred to L3 / v5), Rule 11 (literate).
"""
is_l2_capable(::Type{<:Instruction})::Bool = false

# -----------------------------------------------------------------------------
# The four `true` specialisations — instructions with a verified L2 path.
# Each was checked against the live per-instruction source (Rule 3); the
# others (Define / VarGEP / MemoryLoad / CastInstruction / SelectInstruction /
# CallInstruction) keep the `false` default → fall through to L3.
# -----------------------------------------------------------------------------

# `ArithmeticAssignment` — non-raising `make_delta` returns an empty-payload
# `DeltaEntry` (`src/ir/arithmetic_assignment.jl`, the `make_delta` method),
# with the matching `inverse(::ArithmeticAssignment, s, ::NamedTuple)` (same
# file). L2 path verified. (Reached only for `:add` / `:sub`; `:xor` is L1 per
# M6.1's value-level `is_injective`, so `compute_must_cache` never routes it
# here anyway.)
is_l2_capable(::Type{ArithmeticAssignment})::Bool = true

# `MemoryAssignment` — non-raising `make_delta` (empty payload) +
# `inverse(::MemoryAssignment, s, ::NamedTuple)` (`src/ir/memory_instructions.jl`).
# L2 path verified.
is_l2_capable(::Type{MemoryAssignment})::Bool = true

# `MemoryStore` — has NO `make_delta` (would hit the raising fallback) but a
# non-`nothing` `predelta_payload` returning `(addr, old_value, was_present)`
# (`src/ir/memory_floor.jl`) + `inverse(::MemoryStore, s, ::NamedTuple)` (same
# file). The push gate's `pre_payload !== nothing` branch builds the DeltaEntry
# directly, so the raising `make_delta` is never reached. L2 path verified.
is_l2_capable(::Type{MemoryStore})::Bool = true

# `DynAlloca` — same shape as `MemoryStore`: NO `make_delta`, but a
# non-`nothing` `predelta_payload` returning `(base, n)` (`src/ir/alloca.jl`)
# + `inverse(::DynAlloca, s, ::NamedTuple)` (same file). L2 path verified.
is_l2_capable(::Type{DynAlloca})::Bool = true

# `IRMapInsert` / `IRMapDelete` (reversible-map ADT, ADR 0008; `src/ir/
# revmap.jl`) — same shape as `MemoryStore`: NO `make_delta` (would hit the
# raising fallback), but a non-`nothing` `predelta_payload` returning
# `(key, prior=value-or-missing)` + a matching `inverse(::T, s, ::NamedTuple)`
# (same file). The push gate's `pre_payload !== nothing` branch builds the
# DeltaEntry directly, so the raising `make_delta` is never reached. L2 path
# verified against `src/ir/revmap.jl`. (`IRMapGet` is NOT L2-capable — it has
# no `predelta_payload` and is L3-only, like `MemoryLoad`, so it keeps the
# `false` default above.)
is_l2_capable(::Type{IRMapInsert})::Bool = true
is_l2_capable(::Type{IRMapDelete})::Bool = true

# Heap intrinsics (CW-A, ADR 0018 §B; `src/ir/intrinsics.jl`) — same shape as
# `MemoryStore` / `DynAlloca`: NO `make_delta` (would hit the raising fallback)
# but a non-`nothing` `predelta_payload` (the arena allocs return `(base,
# cells)`; the bulk ops return a `(deltas,)` vector of per-cell triples;
# realloc bundles both) + a matching `inverse(::T, s, ::NamedTuple)` (same
# file). The push gate's `pre_payload !== nothing` branch builds the DeltaEntry
# directly, so the raising `make_delta` is never reached. L2 path verified
# against `src/ir/intrinsics.jl` (Rule 3). `IntrinsicFree` is NOT here — it is
# injective (L1, no history), so `compute_must_cache` never routes it to L2;
# it keeps the `false` default.
is_l2_capable(::Type{IntrinsicMalloc})::Bool  = true
is_l2_capable(::Type{IntrinsicCalloc})::Bool  = true
is_l2_capable(::Type{IntrinsicRealloc})::Bool = true
is_l2_capable(::Type{IntrinsicMemset})::Bool  = true
is_l2_capable(::Type{IntrinsicMemcpy})::Bool  = true
is_l2_capable(::Type{IntrinsicMemmove})::Bool = true
# `IntrinsicGCAlloc` (CW-D3 Lever 3; Bennett-iwo9 decision 5) inherits the arena
# L2 path verbatim via the `_ArenaAlloc` union: NO `make_delta`, a non-`nothing`
# `predelta_payload` returning `(base, cells)`, + the union `inverse(::T, s,
# ::NamedTuple)` (`src/ir/intrinsics.jl`). L2 path verified (Rule 3).
is_l2_capable(::Type{IntrinsicGCAlloc})::Bool = true

# CW-B2 (ADR 0019 §4 + hostile-review C2) — `ReturnExit`, the reversible
# return transition. Same shape as `IntrinsicMalloc`: NO `make_delta` (the
# raising fallback never reached), a non-`nothing` `predelta_payload`
# returning `(residual, fname, end_pc)` (`src/ir/call_transitions.jl`) + a
# matching `inverse(::ReturnExit, s, ::NamedTuple)` (same file). The push
# gate's `pre_payload !== nothing` branch builds the DeltaEntry directly.
# `CallEnter` is L1-injective (NOT L2 — explicit `false` per C2; the default
# would also give `false`, but the ADR pins it so the trichotomy is auditable
# at the definition site).
is_l2_capable(::Type{ReturnExit})::Bool = true
is_l2_capable(::Type{CallEnter})::Bool  = false

"""
    is_unconditional_l2(::Type{<:Instruction}) -> Bool

L2-push-UNCONDITIONALLY trait (CW-B2, ADR 0019 §4). An instruction marked
`true` here pushes its L2 `DeltaEntry` on EVERY non-replay forward step,
independent of the `must_cache` set — because its history entry is
load-bearing for BACKWARD CONTROL FLOW, not only for data recovery.

Default `false` (every existing L2 instruction): the push gate consults
`must_cache(must_cache_set, …)` and pushes only when the slot is selected
by `compute_must_cache`. `ReturnExit` is the sole `true`: under a flat pc,
the instruction before the post-call `link` is the `CallEnter`, so naive
`pc-1` backward stepping would re-enter the call; the `ReturnExit` delta is
the breadcrumb that routes the backward pass into the callee's `End`
instead (ADR 0019 §4 property 2). It is also the block's EXIT marker, not a
body slot, so `compute_must_cache` (which scans only `block.instructions`)
would never select it anyway — making the unconditional push the only way
its delta is ever recorded.

Consumed by `step!`'s push gate (`src/interpreter/Interpreter.jl`): the L2
branch fires when `is_unconditional_l2(typeof(instr)) || must_cache(…)`.
"""
is_unconditional_l2(::Type{<:Instruction})::Bool = false
is_unconditional_l2(::Type{ReturnExit})::Bool = true
