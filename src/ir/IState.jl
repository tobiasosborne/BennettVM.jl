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
end
