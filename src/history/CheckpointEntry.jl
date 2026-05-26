"""
    CheckpointEntry (M4.1)

The L3 reversibility-tape entry: a *periodic* full-state `IState`
snapshot tagged with the step index at which the snapshot was captured.
This is the first (and, at M4.1, only) concrete subtype of
`AbstractHistoryEntry` (defined at `src/ir/RState.jl:135`); subsequent
milestones M6.x (L1 — injective / no-log) and M7.x (L2 — delta min-cut)
introduce their own subtypes alongside this one.

# Where this sits in the three-layer history scheme

PRD v4 §3.3 ("History mechanism") prescribes three layers, applied in
**order of preference**:

  1. **L1 — no log.** Injective instructions and reversible jumps
     (§3.2) push nothing. Lands at M6.x.
  2. **L2 — delta entries with min-cut selection.** For non-injective
     ops in deterministic regions, the history payload is the minimal
     information required to invert the step (Enzyme-style cache
     analysis, Moses–Churavy 2020). Lands at M7.x.
  3. **L3 — periodic full-state checkpoints + deterministic replay.**
     For long-running regions and as a safety net. **This is what
     `CheckpointEntry` carries.** Backward execution between
     checkpoints is performed by deterministic forward replay from
     the prior checkpoint.

Layers are tried L1 → L2 → L3; `CheckpointEntry` is the *fallback*
the lowering pipeline reaches when L1/L2 cannot reconstruct the
pre-step state. It is also the safety net during M4.x bring-up,
before M6/M7 exist: at M4.x every non-injective step that needs
reversibility pushes a `CheckpointEntry` (via M4.2's modified
`step!`), and M4.3's `unstep!` finds the nearest checkpoint and
replays forward.

# Why "periodic" matters — the §3.3 prohibition

PRD v4 §3.3 makes one mechanism explicitly forbidden:

> Full per-step `IState` snapshots (the Phase-0 mechanism) MUST NOT
> appear in Phase 2.

The Phase-0 spike pushed a full `IState` snapshot on every
non-injective step (`spike/RETROSPECTIVE.md` Q2.5 / Q4 §"Anti-patterns")
and quantified the cost: ~5000 retained heap objects for
`countdown(1000)`. The spike retrospective Q4 §"Anti-patterns" line
"Full `deepcopy` snapshots per step. The worst point on the time-
space tradeoff curve" is the explicit prior-art point this milestone
must not regress to.

`CheckpointEntry` does NOT violate that prohibition. The distinction
is the word "periodic": M4.2 will configure `step!` to push a
checkpoint only every K steps (default K=64 per the §3.3 placeholder).
The L3 layer's space cost is therefore O(T/K) snapshots, not O(T).
The shape of *one* entry is the same as the spike's (a full `IState`),
but the *frequency* is the design property that brings it onto the
acceptable side of the time-space curve. M4.2's `step!` modification
is where the periodicity gate lives; this M4.1 file only defines the
entry type. Stripping the periodic gate would silently regress to
the prohibited spike mechanism, so M4.2 must be reviewed against
this paragraph.

# The rr architecture lesson

The L3 mechanism is the BennettVM analogue of the rr replay debugger's
core architecture (O'Callahan et al 2017 §2.1):

> Record nondeterminism, replay determinism.

rr's insight is that *most* of a program's execution is deterministic —
the rare nondeterministic events (system calls, signals, scheduling
decisions) are the only thing that needs to be logged; everything
else can be reconstructed by re-running from a checkpoint. BennettVM
is even friendlier to this scheme than rr: by construction the VM is
*fully* deterministic inside its boundary (no I/O, no concurrency, no
RDRAND — see `CLAUDE.md` "rr's lesson is record nondeterminism,
replay determinism"). So the L3 mechanism reduces to "checkpoint
state; replay forward". No nondeterminism log is needed at all.

# Why deep-copy in the constructor (the spike Q2.2 lesson)

`IState` is a `mutable struct` carrying two `Dict` fields
(`locals::Dict{Symbol,Int64}` and `memory::Dict{Int64,Int64}`,
`src/ir/IState.jl:134-138`). The spike retrospective Q2.1 documents
the load-bearing footgun: Julia's default field-by-field semantics on
a `mutable struct` reduce to **identity** (`===`) on Dict fields, not
**content** equality. The spike caught this for `IState.==` and fixed
it with an override; M2.2 ported that fix here.

For *snapshotting*, the same shape of bug appears one level up. If
M4.2's `step!` captures the running `IState` *by reference* —

    push!(s.history, CheckpointEntry(s.current, step))   # WRONG

— every subsequent mutation to `s.current.locals` would also mutate
every previously-captured `CheckpointEntry`'s snapshot, because all
of them would be aliases for the same live `Dict`. Every checkpoint
on the history vector would silently track the latest live state.
Backward replay from any of them would replay from the wrong
starting point. The round-trip invariant `unrun!(run!(s, prog)) ==
initial(s) && isempty(s.history)` (the load-bearing M4.5 test) would
fail in a way that looks like an off-by-one bug but is really an
aliasing bug — exactly the diagnosis category Rule 2 ("All bugs are
deep") warns against papering over.

The defense is to encapsulate `deepcopy` in **the constructor** so
the caller cannot forget. Every `CheckpointEntry(state, step)` call
copies `state` (recursively, including the `Dict` fields and any
future-added containers); the caller's `state` and the captured
snapshot are then independent objects. The mutation-proof test in
`test/test_checkpoint_entry.jl` exercises this: it mutates the
source `IState` after constructing the entry and asserts the
captured snapshot is undisturbed.

This is a **mandatory** part of the type's contract, not a
defensive nicety. M4.2 / M4.3 / M4.4 will all rely on the
constructor having done the copy; if the contract is ever
silently relaxed, the round-trip test would catch it, but the
defense-in-depth design pinpoints the violation at construction
rather than at a downstream replay step.

(Note: `deepcopy` is acknowledged-expensive on hot paths. M4.2 only
pays this cost every K steps (K=64 default), so the amortized
per-step cost is small. The spike's per-step `deepcopy` was the
problem; the per-checkpoint `deepcopy` is the considered solution.
See `spike/RETROSPECTIVE.md` Q4 §"Surprises about Julia idioms in
this domain".)

# Why `struct` (immutable), not `mutable struct`

`step` is a bookkeeping label assigned once at construction (the
step index `step!` is at when the checkpoint was pushed). `snapshot`
is also assigned once at construction (the deep-copied `IState` at
that step). The natural lifecycle is:

    construct → push! onto s.history → … → pop! and read → done.

Nothing in this lifecycle mutates a `CheckpointEntry` in place. M4.3's
`unstep!` reads `entry.snapshot` and `entry.step`, may copy the
snapshot to seed a forward replay, but never writes back to the
entry. Immutability — `struct`, not `mutable struct` — therefore
matches the access pattern, lets the compiler stack-allocate where
possible, and prevents an accidental future caller from mutating a
captured snapshot in place (which would be the same Q2.2 trap from a
different direction).

Contrast `RState`, which IS `mutable struct` (`src/ir/RState.jl:151`):
`RState` is the running trajectory and `step!` rebinds its `current`
field every iteration. `RState` and `CheckpointEntry` sit on opposite
sides of the mutation boundary, and their declarations record that.

# Field-by-field rationale

  - `snapshot::IState`. The captured state at the checkpoint. **NOT
    `RState`** — that would be self-referential. `RState` *owns* the
    `history::Vector{AbstractHistoryEntry}` containing the entries
    themselves (`src/ir/RState.jl:153`); a `CheckpointEntry` inside
    that vector containing the whole `RState` would contain itself
    transitively. Even ignoring the cycle, replay semantics demand
    *just* the snapshot of executable state (pc, locals, status,
    memory) without the history of how we got there — that history
    is what we're replaying forward FROM the checkpoint, not into it.
    `IState` is exactly the unit `step!` consumes, so M4.3's replay
    loop can construct a fresh `RState(deepcopy(entry.snapshot),
    AbstractHistoryEntry[])` and step forward.

  - `step::Int`. The 0-indexed step count at which the checkpoint was
    pushed. `Int`, not `UInt`, for two reasons. First, parity with
    `IState.pc::Int` (`src/ir/IState.jl:135` — Julia's natural integer
    width for indexing; the field rationale there applies verbatim).
    Second, parity with `run!`'s `max_steps::Int` (`src/interpreter/
    Interpreter.jl` — the same loop counter `step` indexes into).
    Mixing `Int` and `UInt` in the M4.3 nearest-checkpoint search
    would force conversions or comparison-warning lints; keeping
    every step index in `Int` keeps the arithmetic uniform. The
    constructor accepts any `Integer` and coerces via `Int(...)`
    so a caller working with `Int32` or `UInt32` at the boundary
    isn't forced to wrap their call sites in casts — see the
    constructor's docstring below.

# Why `Base.==` and `Base.hash` are overridden explicitly

The same M2.2 / M2.3 precedent applies here: Julia's default `==` on
a `struct` (immutable) reduces to field-by-field `==`, and on
`Int`-vs-`Int` and `IState`-vs-`IState` the field-level `==` is
already content-comparing (the latter because `IState` overrode `==`
at M2.2). So the default would, technically, already do the right
thing for two `CheckpointEntry` values.

We override anyway, for the reason `RState.jl:182-190` states
verbatim: **be explicit about content equality when one field is a
Dict-bearing mutable type.** The `Dict`-identity trap (Q2.1) does not
literally fire on `CheckpointEntry` because the indirection through
`IState`'s overridden `==` neutralises it; but the precedent on
every other `==`-supporting type in this codebase (`IState`, `RState`)
is to write the override out so a reader who searches for `==` in
this file finds the explicit declaration alongside its rationale,
rather than having to chase through to the field types to confirm
the behaviour is as intended. Per `RState.jl:175-177`: "Heading the
trap off now costs one line; finding it later costs an interpreter-
debugging session." Also, the hash override is genuinely necessary
to maintain the `a == b ⟹ hash(a) == hash(b)` contract — the
`Set{CheckpointEntry}` round-trip test in `test_checkpoint_entry.jl`
exercises that explicitly.

# Cross-references

  - PRD v4 §3.3 ("History mechanism"): three-layer scheme; L3 is
    periodic full-state checkpoints + deterministic forward replay;
    full per-step snapshots are prohibited.
  - `references/reverse-debugging/ocallahan-2017-rr-deployability.pdf`
    §2.1 (p. 2): the rr "record nondeterminism, replay determinism"
    architecture this layer is the BennettVM specialisation of.
  - `CLAUDE.md` "rr's lesson is 'record nondeterminism, replay
    determinism'" hallucination-callout: the VM is fully
    deterministic, so the L3 mechanism degenerates to checkpoint +
    forward replay with no nondeterminism log.
  - `spike/RETROSPECTIVE.md` Q2.2: the deep-copy / snapshot-aliasing
    contract that motivates the constructor's mandatory `deepcopy`
    (mutating the source `IState` after capture must not alter the
    snapshot). The related Dict-identity-on-`==` trap is Q2.1, cited
    above at the `Base.==` / `Base.hash` override rationale.
  - `spike/RETROSPECTIVE.md` Q4 §"Anti-patterns": the full-snapshot-
    per-step anti-pattern this layer must NOT regress to.
  - `src/ir/IState.jl`: the underlying snapshot type (M2.1).
  - `src/ir/RState.jl:135`: `AbstractHistoryEntry`, the supertype.
  - `src/ir/RState.jl:182-190`: the `==`/`hash` precedent this file
    mirrors.
  - `docs/impl-plan/phase2-impl-plan.md` "M4 — History layer 3":
    M4.2 (push every K), M4.3 (`unstep!` find-nearest-and-replay),
    M4.4 (`unrun!`), M4.5 (round-trip countdown test) all build on
    this entry shape.
"""

"""
    CheckpointEntry(snapshot::IState, step::Integer)

Construct a periodic checkpoint entry capturing a **deep copy** of
`snapshot` tagged with `step`. The deep copy is mandatory and not
optional: see the file-level docstring "Why deep-copy in the
constructor" for the Q2.2 aliasing rationale.

`step` is coerced to `Int` (the canonical step-index width used
throughout the interpreter — see `IState.pc::Int` and
`run!`'s `max_steps::Int`). Accepting any `Integer` rather than
requiring `Int` at the call boundary spares callers a wrapping cast
in the common case where they have an `Int32` / `UInt32` step
counter from upstream; the coercion happens once, here, and every
downstream consumer sees a clean `Int`. A non-`Integer` argument
raises `MethodError` at construction time (the Rule 1 / fail-loud
shape), which is the right failure: passing a `Float64` or a
`Symbol` for "which step is this" is a programming error, not a
recoverable condition.

# Arguments

  - `snapshot::IState` — the live `IState` to capture. Will be
    `deepcopy`'d into the entry; the caller's `snapshot` may be
    mutated freely afterwards without disturbing the captured value.
  - `step::Integer` — the step index at which the snapshot was
    captured (the value of `run!`'s loop counter at the moment of
    capture). Coerced to `Int` via `Int(step)`.
"""
struct CheckpointEntry <: AbstractHistoryEntry
    snapshot::IState
    step::Int

    function CheckpointEntry(snapshot::IState, step::Integer)
        # Defense in depth: the deep-copy contract lives HERE, not in
        # the caller. See the file-level docstring "Why deep-copy in
        # the constructor" and spike/RETROSPECTIVE.md Q2.2.
        new(deepcopy(snapshot), Int(step))
    end
end

"""
    Base.:(==)(a::CheckpointEntry, b::CheckpointEntry) -> Bool

Structural (content) equality on `CheckpointEntry`: equal iff their
`step` indices match and their captured `snapshot`s are `IState`-
equal (M2.2 override). See the file-level docstring "Why `Base.==`
and `Base.hash` are overridden explicitly" for why this is written
out rather than relying on the autogenerated method.
"""
function Base.:(==)(a::CheckpointEntry, b::CheckpointEntry)
    a.step == b.step && a.snapshot == b.snapshot
end

function Base.hash(e::CheckpointEntry, h::UInt)
    h = hash(e.step, h)
    h = hash(e.snapshot, h)
    return h
end
