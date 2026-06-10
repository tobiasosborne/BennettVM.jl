"""
    MemoryStore / MemoryLoad — the scalar reversible-memory floor (ADR 0014)

The two plain heap primitives BennettVM lowers LLVM `store` / `load` to at
the L3 baseline: `MemoryStore` writes a value into a memory cell, and
`MemoryLoad` reads a cell into a fresh SSA local. They are the missing rung
that lets BennettVM round-trip *any* LLVM emitter's raw scalar heap traffic
— the executable proof of emitter-agnosticism (ADR 0013 §D-1): a C function
compiled with `clang-18 -O0` flows through Bennett's language-agnostic
`extract_parsed_ir_from_ll` into a `ParsedIR` whose body is exactly
`alloca / store / load / binop / store / load / ret` (verified this
session; see `test/test_memory_floor_cll.jl`), and these two instructions
are what `lower_vm` was missing to run it.

    MemoryStore(ptr, value)  →  forward  s.memory[resolve_ptr(ptr)] = resolve(value)
    MemoryLoad(dest, ptr)    →  forward  active_locals(s)[dest]            = get(s.memory, resolve_ptr(ptr), 0)

A *pointer* in this model is just an `Int64` address living in `active_locals(s)`,
materialised by the bump allocator at lowering time (ADR 0014 §D1):
`IRAlloca(dest, …)` emits a `Define(dest, base, :add, 0)` so the pointer SSA
value `dest` holds its base address. `resolve_ptr` therefore reads that
`Int64` out of `active_locals(s)` (the `ptr` operand is an `SSAOperand` naming the
alloca dest) — it is exactly `_resolve` specialised to "this operand is an
address", reused per Law 2.

# Why dedicated `MemoryStore` / `MemoryLoad` rather than reusing the
# existing memory instructions (ADR 0014 §D3, Law 2)

The Reuse Map (Law 2) requires evaluating the three memory instructions
already in `src/ir/memory_instructions.jl` before adding new ones:

  * `MemoryAssignment` — `M[a] ⊕= (lhs op rhs)`, an in-place *modop* update.
    Its forward semantics combine the old cell value with a computed
    expression via `{:xor,:add,:sub}`; it does not express a *plain
    overwrite* `M[a] = v` (which discards the old value rather than
    combining with it), nor a *plain read* into a local.
  * `MemoryInterchange` — `x := M[y] := z`, a Pendulum-style *exchange*
    (Vieri 1995 §4.2.1). Its forward DESTROYS the source local `z` and
    CREATES the target local `x` with the old cell value. An LLVM `store`
    does not consume its value operand (the SSA value survives for later
    uses), and an LLVM `load` does not write back into memory — so the
    exchange's bijective register↔cell permutation does not match the
    plain, non-injective read/overwrite the LLVM ops denote.
  * `MemorySwap` — `M[a] ↔ M[b]`, a memory↔memory exchange. Not a
    register/memory transfer at all.

None matches a *plain* L3 load/store cleanly: the exchange forms are
injective (no information lost, no history), whereas a plain LLVM
`store`/`load` is NON-injective — a store overwrites (and so loses) the
prior cell value, and a load overwrites (and so loses) any prior value of
its destination SSA name across loop re-definitions. Per ADR 0014 §D3 we
therefore add dedicated `MemoryStore`/`MemoryLoad` following the
`Define`/`CastInstruction` L3 template (`src/ir/define_instruction.jl`,
`src/ir/cast_instruction.jl`): forward-correct, `is_injective = false`,
per-instruction `inverse()` DEFERRED (raises descriptively), reversed
exclusively via L3 checkpoint-replay.

The L1 Exchange optimization (PRD §3.7 / ADR 0013 §D-2: lower `load`/
`store` to `MemoryInterchange` with a zero-ancilla so the heap reverses
with NO history) is where `MemoryInterchange` becomes the natural reuse —
but that is the *optimization*, deferred (ADR 0014 §D2, bead
`bennettvm-uom`), exactly as collatz shipped L3-trace-tape-correct first
with the pebble game deferred to M9.

# is_injective = false (the L3 baseline) — load-bearing

Both instructions are non-injective and are reversed ONLY via the L3
checkpoint-replay layer (`src/history/Replay.jl`). `IState.memory` IS in
the snapshot and in `Base.==` / `Base.hash` (`src/ir/IState.jl`), so the
periodic full-state checkpoints capture every overwritten cell and every
overwritten local automatically; `unstep!` restores the nearest snapshot
and replays forward, never calling these instructions' per-instruction
`inverse()`.

  * `MemoryStore` destroys the prior contents of `M[addr]` — an overwrite
    is not a bijection on the cell, so it cannot be inverted from the
    post-state alone.
  * `MemoryLoad` destroys the prior value of its destination SSA name on a
    loop re-definition (the same cross-iteration crux as `Define` /
    `CastInstruction`, ADR 0012 §"cross-iteration reversibility crux"); the
    static type-level trait cannot see runtime freshness, so per Rule 1
    ("fail safe — push when in doubt") it is conservatively `false`.

The trait is wired in `src/history/Injective.jl`; the M6.2/M7.6 push gate
emits L3 `CheckpointEntry`s around every store/load.

# Why `inverse` raises rather than implementing an L1/L2 inverse

Because both are reversed exclusively via L3, their per-instruction
`inverse()` is NOT on any live code path at this milestone. A store's
overwritten cell value and a load's overwritten prior destination value are
genuinely not recoverable from the post-state alone, so this is a true
deferral (ADR 0014 §D2), not a missing convenience. Per Rule 1 we raise
descriptively rather than silently no-op (which would falsely report a
successful reverse while the lost information went unrestored — silent
reversibility corruption). This mirrors the `Define` / `SelectInstruction`
/ `CastInstruction` / `CallInstruction` pattern.

# Zero-init convention

A `MemoryLoad` of an address never written returns `Int64(0)`
(`get(s.memory, addr, Int64(0))`) — the same "absent key = 0" convention
codified by `IState.memory` and the existing memory instructions
(`src/ir/IState.jl`, `MemoryAssignment.forward`). The bump allocator
(ADR 0014 §D1) reserves cells without pre-populating them, so the first
read of a freshly-allocated cell that was never stored reads as `0` (the
LLVM `alloca`-then-`load`-uninitialised case).

# Width masking deferred (ADR 0014 §D4, ADR 0012 R1)

`IState.locals` / `IState.memory` are `Int64`; this lowering does NOT mask
the stored/loaded value to the IRInst `width`. Oracle agreement holds for
inputs whose values fit the source width; the round-trip invariant is
width-independent (L3 snapshots the raw `Int64` either way). Per-width
masking is a follow-up bead (ADR 0014 §D4).

# pc symmetry

`forward` sets `s.pc += 1`, matching every other M2.x instruction. There is
no symmetric `inverse` pc decrement — the inverse is the L3 replay path, not
a per-step `inverse()` call; the deferred `inverse` raises before touching
`pc`.

# Operand kinds

`MemoryStore.value` is `Union{Symbol,Int64}` (an SSA ref or a literal —
LLVM `store i32 1, ptr %p` stores a constant), resolved via the reused
`_resolve` (Law 2). The pointer operand on both is a `Symbol` naming the
alloca dest (a pointer is an SSA value in `locals`), resolved via
`resolve_ptr` (a thin `_resolve` wrapper that asserts an `Int64` address).

# Ref

  * `docs/adr/0014-memory-floor-lowering.md` §D1 (bump allocator; pointer =
    Int64 base), §D2 (L3 baseline; deferred L1 Exchange + deferred
    per-instruction inverse), §D3 (reuse evaluation → dedicated load/store),
    §D4 (v1 scope; width masking deferred).
  * `docs/adr/0013-reversible-memory-architecture.md` §D-1 (emitter-
    agnosticism), §D-2 (the store-level floor + PRD Exchange mandate).
  * `src/ir/define_instruction.jl`, `src/ir/cast_instruction.jl` — the
    non-injective L3-create template this file mirrors.
  * `src/ir/memory_instructions.jl` — `MemoryAssignment` / `MemoryInterchange`
    / `MemorySwap`, the existing memory ops evaluated for reuse (§D3).
  * `src/ir/arithmetic_assignment.jl` — `_resolve`, reused here (Law 2).
  * `src/ir/IState.jl` — `memory::Dict{Int64,Int64}` model + zero-init
    convention + the `==`/`hash` participation that makes L3 reverse memory.
  * `src/history/Injective.jl` — where `is_injective(::Type{MemoryStore}) =
    false` / `(::Type{MemoryLoad}) = false` is wired.
  * `src/history/Replay.jl` — the L3 checkpoint-replay `unstep!` that
    actually reverses a store/load.
  * CLAUDE.md Rule 1 (fail loud), Rule 2 (reuse), Rule 11 (literate).
"""

# --- MemoryStore: M[addr] := value (plain overwrite, non-injective) ---

struct MemoryStore <: Instruction
    ptr::Symbol                     # pointer SSA name (alloca dest) → Int64 addr
    value::Union{Symbol,Int64}     # value to store (SSA ref or literal)

    function MemoryStore(ptr::Symbol, value::Union{Symbol,Int64})
        # No SSA single-assignment check: MemoryStore produces NO SSA value
        # (LLVM `store` is void), so there is no `target` to collide with
        # `ptr`/`value`. The aliasing guard (ptr vs value referencing the
        # same cell across multi-store ops) is deferred (ADR 0014 §D4 — no
        # aliasing in scalar v1; RC3 AliasingAnalysisPass port lands with GEP).
        return new(ptr, value)
    end
end

# --- MemoryLoad: dest := M[addr] (plain read into a fresh local, non-injective) ---

struct MemoryLoad <: Instruction
    dest::Symbol                    # SSA name created — receives the cell value
    ptr::Symbol                     # pointer SSA name (alloca dest) → Int64 addr

    function MemoryLoad(dest::Symbol, ptr::Symbol)
        dest === ptr &&
            error("MemoryLoad: SSA single-assignment violation — dest ",
                  "$(dest) also names the pointer operand; an SSA name ",
                  "cannot be both defined and read as the address by the ",
                  "same instruction (RSSA: every name has exactly one ",
                  "defining instruction).")
        return new(dest, ptr)
    end
end

"""
    resolve_ptr(ptr::Symbol, s::IState) -> Int64

Read the `Int64` address a pointer SSA name holds in `active_locals(s)`. A pointer
is just an `Int64` base address materialised by the bump allocator's
`Define(ptr, base, :add, 0)` at lowering time (ADR 0014 §D1). Reuses
`_resolve` (Law 2) and asserts the result is an `Int64` — a pointer must
have been defined before it is dereferenced; an absent name surfaces as a
`KeyError` from `_resolve`, a Rule-1-loud signal of malformed IR (a
load/store of an undefined pointer).
"""
resolve_ptr(ptr::Symbol, s::IState)::Int64 = _resolve(ptr, s)

"""
    forward(instr::MemoryStore, s::IState) -> IState

Execute `M[addr] := value` in-place on `s`. Resolves the pointer to its
`Int64` address via `resolve_ptr`, resolves the value via the reused
`_resolve` (a `Symbol` looked up in `active_locals(s)`, or the literal `Int64`),
writes the cell, and bumps `pc`. The value operand is **read, never
deleted** — an LLVM `store` does not consume its value SSA name. The prior
cell contents are **overwritten** without error; recovering them is the L3
checkpoint-replay layer's responsibility (this file's top-of-module
docstring "is_injective = false").
"""
function forward(instr::MemoryStore, s::IState)::IState
    a = resolve_ptr(instr.ptr, s)
    s.memory[a] = _resolve(instr.value, s)
    s.pc += 1
    return s
end

"""
    forward(instr::MemoryLoad, s::IState) -> IState

Execute `dest := M[addr]` in-place on `s`. Resolves the pointer to its
`Int64` address via `resolve_ptr`, reads the cell with the zero-init
convention (`get(s.memory, addr, Int64(0))` — an address never written
reads as `0`), writes the result into `active_locals(s)[dest]`, and bumps `pc`. If
`dest` already exists in `active_locals(s)` (the loop / cross-iteration case), it is
**overwritten** without error; recovering the prior value is the L3
checkpoint-replay layer's responsibility.
"""
function forward(instr::MemoryLoad, s::IState)::IState
    a = resolve_ptr(instr.ptr, s)
    active_locals(s)[instr.dest] = get(s.memory, a, Int64(0))   # zero-init: absent = 0.
    s.pc += 1
    return s
end

"""
    inverse(instr::MemoryStore, s::IState, prev) -> IState

**Always raises `ErrorException`.** `MemoryStore`'s reverse is via the L3
checkpoint-replay layer (`src/history/Replay.jl`), which never calls
per-instruction `inverse()`. Direct L1/L2 inverse is deferred (ADR 0014
§D2): a plain overwrite loses the prior cell value, genuinely not
recoverable from the post-state alone. Reaching this method means `unstep!`
tried an L1/L2 path on a `MemoryStore`, which should not happen with an
empty `must_cache_set`. Mirrors the `Define` / `CastInstruction` deferral
pattern. Rule 1: fail loud rather than silently no-op (which would falsely
report a successful reverse while the overwritten cell went unrestored).
"""
function inverse(instr::MemoryStore, s::IState, prev)::IState
    error("MemoryStore reverse is via L3 checkpoint-replay at the memory ",
          "floor; direct L1/L2 inverse is deferred (ADR 0014 §D2) — a plain ",
          "overwrite loses the prior cell value. The L1 Exchange form ",
          "(MemoryInterchange, no-history) is the deferred optimization ",
          "(bead bennettvm-uom). Reaching this means unstep! tried an L1/L2 ",
          "path on a MemoryStore, which should not happen with empty ",
          "must_cache_set. State: pc=$(s.pc).")
end

# === M_DYN — L2 (addr, old_value) delta (ADR 0009 Decision 2b/4.4) ===
#
# `MemoryStore` is the FIRST BennettVM L2 delta that needs PRE-`forward()`
# state. The forward overwrites `M[addr]`, destroying the prior cell value;
# that value is unrecoverable from the post-state alone (the "is_injective =
# false" rationale at the top of this file). So instead of the L3 whole-state
# checkpoint, an L2 delta captures the ONE overwritten cell — `(addr,
# old_value, was_present)` — read BEFORE `forward()` runs, then restores it on
# reverse. Per-write O(1) (ADR 0009 Decision 2b; PRD §3.3 forbids full
# snapshots on the L2 path), versus the L3 `deepcopy(IState)`.

"""
    predelta_payload(instr::MemoryStore, s::IState)
        -> @NamedTuple{addr::Int64, old_value::Int64, was_present::Bool}

PRE-`forward()` capture for `MemoryStore`'s L2 delta (M_DYN, bd
`bennettvm-ekc`). Called by `step!` (step (3a)) BEFORE `forward()`
overwrites the target cell. Records:

  * `addr` — the resolved `Int64` cell address (`resolve_ptr`), so the
    inverse needs no live SSA pointer at reverse time.
  * `old_value` — `get(s.memory, addr, Int64(0))`, the prior cell
    contents under the absent=0 convention.
  * `was_present` — `haskey(s.memory, addr)`, the LOAD-BEARING bit (see
    the `inverse` below): distinguishes a cell that genuinely held `0`
    from a cell that was ABSENT (also reads as `0`).

This is the sole non-`nothing` `predelta_payload` specialisation at this
milestone (`src/history/delta.jl` defines the `nothing` default for every
pre-state-independent instruction).
"""
function predelta_payload(instr::MemoryStore, s::IState)
    a = resolve_ptr(instr.ptr, s)
    return (addr = a,
            old_value = get(s.memory, a, Int64(0)),
            was_present = haskey(s.memory, a))
end

"""
    inverse(instr::MemoryStore, s::IState, p::NamedTuple) -> IState

L2 reverse of a `MemoryStore` using the `(addr, old_value, was_present)`
payload captured by `predelta_payload` BEFORE `forward()` ran. This
NamedTuple method is MORE SPECIFIC than the raising
`inverse(::MemoryStore, s, ::Any)` catch-all above, so the M7.4 `unstep!`
fast-path (`src/history/Replay.jl`, which calls `inverse(entry.instruction,
s.current, entry.payload::NamedTuple)`) dispatches HERE; the catch-all
stays for the (never-reached) L3 path.

# ABSENT-CELL is load-bearing (the missing-sentinel trap, ADR 0008 Dict)

`IState.memory` uses absent=0 (`forward`/`MemoryLoad` read `get(.., 0)`),
but `Base.:(==)(::IState, ::IState)` compares `a.memory == b.memory` by
Dict CONTENT — so `{addr=>0}` is NOT equal to the initial `{}`. Restoring
`old_value=0` into a cell that was ABSENT before the store would therefore
leave a phantom `{addr=>0}` key and break round-trip equality. The fix is
the `was_present` branch: when the cell was absent, `delete!` it (do NOT
write `0` back); when present, `setindex!` the captured `old_value`. This
is the same missing-sentinel issue ADR 0008 documents for the Dict ADT.

# pc convention

Decrements `s.pc -= 1`, mirroring `ArithmeticAssignment.inverse` and the
±1 per-step symmetry every NamedTuple inverse follows
(`src/ir/arithmetic_assignment.jl`). The M7.4 fast-path does NOT adjust pc
itself, so the per-instruction inverse owns the decrement.

# Ref

  * `docs/adr/0009-dynamic-size-memory.md` Decision 2b/4.4 — the
    (addr, old_value) delta + per-write O(1) mandate.
  * `docs/adr/0008-*.md` — the Dict missing-sentinel issue the
    `was_present`→`delete!` branch mirrors.
  * `src/history/Replay.jl` (M7.4) — the unstep! fast-path call site.
  * `src/ir/arithmetic_assignment.jl` — the NamedTuple-inverse / pc-±1
    convention this method follows.
"""
function inverse(instr::MemoryStore, s::IState, p::NamedTuple)::IState
    if p.was_present
        s.memory[p.addr] = p.old_value      # cell held a value → restore it
    else
        delete!(s.memory, p.addr)           # cell was ABSENT → delete, NOT {a=>0}
    end
    s.pc -= 1
    return s
end

"""
    inverse(instr::MemoryLoad, s::IState, prev) -> IState

**Always raises `ErrorException`.** `MemoryLoad`'s reverse is via the L3
checkpoint-replay layer, which never calls per-instruction `inverse()`.
Direct L1/L2 inverse is deferred (ADR 0014 §D2): a loop re-definition loses
the overwritten prior value of `dest` (the same cross-iteration crux as
`Define` / `CastInstruction`). Reaching this method means `unstep!` tried an
L1/L2 path on a `MemoryLoad`, which should not happen with an empty
`must_cache_set`. Mirrors the `Define` / `CastInstruction` deferral pattern.
Rule 1: fail loud rather than silently no-op.
"""
function inverse(instr::MemoryLoad, s::IState, prev)::IState
    error("MemoryLoad reverse is via L3 checkpoint-replay at the memory ",
          "floor; direct L1/L2 inverse is deferred (ADR 0014 §D2) — a loop ",
          "re-definition loses the overwritten prior dest value. The L1 ",
          "Exchange form (MemoryInterchange, no-history) is the deferred ",
          "optimization (bead bennettvm-uom). Reaching this means unstep! ",
          "tried an L1/L2 path on a MemoryLoad, which should not happen with ",
          "empty must_cache_set. State: pc=$(s.pc).")
end
