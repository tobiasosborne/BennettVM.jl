"""
    IState

Per-step interpreter state for BennettVM's forward and inverse loops.
`IState` is the atom that `step!` and `unstep!` mutate; every other
runtime structure (history element, `RState` wrapper, output channel)
is built on top of it.

# What this is

An `IState` value names *everything the next instruction is allowed to
read or write*: the program counter, the register file, and the
running/halted/error status bit. The interpreter loop is, in pseudocode,
`while s.status === :running; step!(s, prog); end` — so `IState` is the
fixed-point of one `step!` iteration. Phase-2 milestone M2.1 lands the
struct only; `step!`/`unstep!` arrive later (M3.x), and `Base.==` /
`Base.hash` overrides are added in M2.2 (`bennettvm-6b4`).

# Field-by-field rationale

- `pc::Int`. Index into the *current basic block's* instruction vector,
  not a global program-wide counter. The RSSA-derived Phase-2 IR carries
  control flow at the block boundary (paired `Conditional{Entry,Exit}`
  dispatch, locked in `docs/adr/0001-rc3-rvm-smoke.md` §Observations
  decision table row "Φ-node placement"); within a block, `pc` is a flat
  index. `Int` rather than `Int32` because Julia's natural integer
  width matches `eachindex` semantics and no realistic block exceeds
  `typemax(Int32)` anyway.

- `locals::Dict{Symbol,Int64}`. The register file, keyed by the SSA
  variable name. The `Symbol` key type matches Bennett.jl's `IRInst`
  SSA-naming convention: every concrete `IRInst` subtype carries a
  `dest::Symbol` field naming the SSA value it produces (see
  `/home/tobias/Projects/Bennett.jl/src/ir_types.jl:56` for the
  abstract `IRInst`, and lines 58-72 / 74-87 for `IRBinOp` / `IRICmp`
  using `dest::Symbol`). Using the same key type means register
  lookups during lowering and during interpretation share a single
  identity space — no symbol-table indirection. The value type is
  `Int64` because at the spike level all registers were 64-bit
  (see `docs/adr/0001-rc3-rvm-smoke.md` §Observations, where the
  bit-width parametrization is flagged as future work). M2.x keeps
  the spike's choice; arbitrary-width / `Bool` typing arrives with
  a later milestone.

- `status::Symbol`. One of three legal values:
  * `:running` — the interpreter loop continues; `step!` will execute
    the instruction at `pc`.
  * `:halted` — normal termination (a `Halt` or `Return` instruction
    fired). `result(s)` is callable.
  * `:error` — abnormal termination (division by zero, overflow,
    unsupported instruction, …). `result(s)` is *not* callable; the
    state remains reversible via `unstep!` only if the erroring
    instruction had observable side effects on `pc` or `locals` (the
    discard-pop predicate, PRD v4 §3.12).
  Stored as `Symbol` rather than an `@enum` for cheap printability and
  to match the spike's choice that survived retrospective Q4 review.

- `memory::Dict{Int64,Int64}`. The addressable heap, as a sparse map
  from `Int64` address to `Int64` cell value. This is the Phase-2
  baseline memory model — the simplest thing that could possibly work
  to give the three memory instructions (`MemoryAssignment` M2.11,
  `MemoryExchange` M2.12, `MemorySwap` M2.13) a state to mutate.
  Default is an empty `Dict`; most M2.x instructions (`ArithmeticAssignment`,
  `SwapInstruction`, the six control-flow markers) don't touch it.

  Why a `Dict`, not a `Vector{Int64}`. The address space is sparse:
  in any realistic program — and certainly in the four motivating
  cases of PRD v4 §3.6.2 — only a small subset of addressable
  positions is ever written, often clustered far apart in the
  address range (heap-allocated objects at distinct upstream
  pointer bases, function locals spilled to the stack frame, etc.).
  A `Vector{Int64}` would force us either to allocate the whole
  reachable address range up front (`zeros(Int64, typemax(Int64))`
  is impossible; even `zeros(Int64, 2^32)` is 32 GiB) or to
  maintain a base-address bias and resize on every out-of-range
  write — and resize is exactly the operation a reversible heap
  cannot perform cleanly. The `Dict` sidesteps both: present keys
  carry written values, absent keys default to `0` (the zero-init
  convention, codified by the M2.11 memory instructions in their
  `forward`/`inverse` methods). The Bennett.jl `MemSSA` / `globals`
  model — a persistent-tree representation with snapshot semantics
  — is the richer target that informs a later milestone; for M2.11–
  M2.13 baseline we want the simplest representation that supports
  read-and-write-back-via-modop, and `Dict{Int64,Int64}` is exactly
  that.

  Why `Int64` keys (the address-width choice). Bennett.jl produces
  IR for an x86_64 LLVM target, where pointers are 64-bit. Matching
  the upstream pointer width here means an `IRLoad` / `IRStore`
  address lowered from Bennett.jl can be carried into BennettVM
  without truncation or sign-extension. Phase-2 does NOT yet
  parametrise the address width — narrower-pointer targets (32-bit,
  16-bit embedded) will arrive with a typed-pointer milestone in a
  later phase. Until then, every memory key is `Int64`, and that
  matches the source IR.

  Why `Int64` values. Same reason as the `locals` value type: every
  scalar in M2.x is 64-bit (ADR 0001 §Observations, future-work
  bit-width row). Cell-level typing — `Bool`, narrow int, FP via the
  M_FP SoftFloat dispatch — arrives with the same milestone that
  parametrises register widths.

  The empty-default rule (set via the inner 3-arg constructor below)
  matters for backwards compatibility: every existing `IState(pc,
  locals, status)` call site in M2.x test files and lowering code
  continues to compile and behave identically. Code that wants a
  populated heap calls the 4-arg constructor explicitly.

# Why mutable

Declared `mutable struct` because `step!` and `unstep!` mutate `pc`,
`locals`, and `status` in place during the interpreter's tight inner
loop. The Phase-0 retrospective (`spike/RETROSPECTIVE.md` Q1) identified
this as a PRD-level fix: the original v3 §5.3 template wrote
`struct IState` (immutable), but in practice an immutable `IState`
would force every `step!` call to allocate a fresh struct and rebind
the caller's variable, defeating the in-place mutation convention the
`run!` loop depends on and forcing a full `Dict` copy per step. PRD v4
§3.9 ratifies the mutable choice as binding.

# Cross-reference

- PRD v4 §3.9 ("API and naming conventions"): `IState` MUST contain at
  minimum `pc`, `locals`, and `status` (other fields permitted later).
- PRD v4 §3.10: `Base.==` / `Base.hash` overrides on `IState` are
  unconditional — arriving in M2.2.
- `docs/adr/0001-rc3-rvm-smoke.md` §Observations: RC3's analogue of a
  direction flag (`direction::Direction`) lives at the VM level (one
  per-VM enum flipped at run start), *not* at the IState level. The
  decision table row "Direction flag" makes this explicit. Do not be
  tempted to add a direction field here; it belongs on the `RState`-
  level wrapper that lands in a later bead.
"""
mutable struct IState
    pc::Int
    locals::Dict{Symbol,Int64}
    status::Symbol
    memory::Dict{Int64,Int64}

    # 3-arg constructor: preserves every existing call site (M2.1
    # through M2.10) — empty memory is the right default for any
    # instruction that doesn't touch the heap.
    IState(pc::Int, locals::Dict{Symbol,Int64}, status::Symbol) =
        new(pc, locals, status, Dict{Int64,Int64}())

    # 4-arg constructor: explicit memory. Used by M2.11+ tests and by
    # any lowering pass that materializes a heap snapshot up front.
    IState(pc::Int, locals::Dict{Symbol,Int64}, status::Symbol,
           memory::Dict{Int64,Int64}) =
        new(pc, locals, status, memory)
end

"""
    Base.:(==)(a::IState, b::IState) -> Bool

Structural equality on `IState`: two states are equal iff their `pc`,
`status`, and (the *content of* their) `locals` agree.

# Why we override it

Julia's autogenerated `==` for a `mutable struct` falls back to
field-by-field `==`. For the scalar fields (`pc::Int`, `status::Symbol`)
that already does the right thing. For `locals::Dict`, however, the
*spike's* round-trip assertions only worked because we happened to be
asserting against the same `Dict` instance — see `spike/RETROSPECTIVE.md`
Q2.1: distinct `Dict` values with identical key/value content can
appear unequal under naive identity comparisons, which silently
breaks the load-bearing round-trip invariant
`unrun!(run!(s, prog)) == initial(s)`. M2.2 (`bennettvm-6b4`) closes
that trap by pinning `==` to *content* equality on every field.

# Why `a.locals == b.locals` is the right primitive

Julia's stdlib defines a content-comparing `==` for `Dict` (see the
`Base.:(==)(::AbstractDict, ::AbstractDict)` method shipped with
`base/abstractdict.jl`): two dicts are `==` iff they have the same
key set and each key maps to `==`-equal values, regardless of internal
slot layout or `objectid`. So at the field level the override is
literally "use `==` not `===`", and the *only* reason this method
must be written out is that without it Julia would not know to apply
the field-by-field rule we want for the `Dict` field specifically.
(One could rely on the autogenerated method here, but writing it
explicitly makes the intent — and the spike-Q2.1 rationale — visible
to any reader who searches for `==`.)

# Why `status` uses `===`

`Symbol` values in Julia are interned; `a.status === b.status` and
`a.status == b.status` always agree for `Symbol`s. Spelling it
`===` documents that we intend identity-of-interned-symbol semantics,
which is the natural intent for a small finite tag set
(`:running`, `:halted`, `:error`) — see the `status` field's
rationale in this file's top-of-module docstring.

# The hash contract

`Base.hash(::IState, ::UInt)` (below) is overridden in lock-step so
that the invariant `a == b ⟹ hash(a) == hash(b)` holds. This is what
makes `IState` safe to use as a `Dict` key or `Set` element, which
the test suite exercises explicitly via `haskey(d, equivalent_state)`.
Julia's `Dict` `hash` overload composes the content hashes of its
entries (commutatively, so insertion order is irrelevant), so the
`hash(s.locals, h)` line is the dict-side counterpart to the
`a.locals == b.locals` line above — content in, content hashed.

Ref: spike/RETROSPECTIVE.md Q2.1 (the Dict-identity trap that
     motivated this override).
Ref: bennettvm_prd.md §3.10 (`Base.==`/`Base.hash` overrides are
     unconditional on `IState`).
"""
function Base.:(==)(a::IState, b::IState)
    a.pc == b.pc &&
    a.status === b.status &&
    a.locals == b.locals &&  # Dict's overloaded ==, content-comparing.
    a.memory == b.memory     # M2.11: same content-comparing pattern.
end

function Base.hash(s::IState, h::UInt)
    h = hash(s.pc, h)
    h = hash(s.status, h)
    h = hash(s.locals, h)   # Dict's hash respects content.
    h = hash(s.memory, h)   # M2.11: heap content participates in hash.
    return h
end
