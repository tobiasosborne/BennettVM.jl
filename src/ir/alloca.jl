"""
    DynAlloca — runtime-sized allocation create + (base, n) L2 delta (ADR 0009)

The dynamic-size allocation rung of BennettVM's memory floor. It lifts the
static bump allocator (ADR 0014 §D1: `IRAlloca(n_elems = ConstOperand(N))`
reserves `base … base+N-1` at lowering time and materialises the pointer via a
`Define(dest, base, :add, 0)`) to the **dynamic-N** case (ADR 0009 Decision 2a;
SC9 Case A's actual need): an `IRAlloca` whose `n_elems` operand is an
`SSAOperand` (a C VLA `int a[n]`, a Julia `Vector{T}(undef, n)`). The element
count `n` is unknown at lowering time, so the region cannot be reserved by a
compile-time cursor advance the way a static alloca is.

    DynAlloca(dest, n_operand, base)  →  forward
        s.locals[dest] = base; s.pc += 1

A *pointer* in this model is just an `Int64` cell address living in `s.locals`
(the ADR 0014 §D1 model). `DynAlloca` materialises that pointer at a **frozen
compile-time `base`** (the bump cursor at ingest — see "Single-dynamic-array
fixed base" below) and bumps `pc`. It does **NOT** zero the region: cells stay
ABSENT and read as `0` by the floor's absent=0 convention
(`get(s.memory, a, 0)`, `MemoryLoad.forward` / `IState.memory`). This matches
LLVM `alloca`'s uninitialised semantics and keeps the heap sparse — the ADR
0014 §D1 zero-init convention ("cells default to 0 by the zero-init convention",
§D1:46) the static path already follows; the heap is materialised lazily (the
"does not pre-populate `s.memory`" phrasing is `src/ir/ingest.jl:317`'s, NOT
§D1's words — Law 1). (ADR 0009 Decision 2a §2(a)'s "zero-clears the
reserved cells" wording is a loose description of the same net effect: under
absent=0 a deleted cell and a zeroed cell read identically forward, but only
*deletion* preserves the `IState.==`-by-Dict-content round-trip invariant — see
the L2 inverse below and the missing-sentinel trap that `MemoryStore` documents.)

# Single-dynamic-array fixed base (the runtime-allocator-state finding)

`IState` carries NO runtime allocator state — there is no live bump pointer to
advance by a runtime `n` and retract on reverse. So the region's base is the
COMPILE-TIME bump cursor at ingest (`_lower_alloca!`, `src/ir/ingest.jl`),
frozen into `DynAlloca.base`. This is sound for **one** dynamic array per
routine: the frozen base owns the open-ended tail of the address space
`[base, ∞)` exclusively. A SECOND allocation after a dynamic one cannot be
admitted — the static cursor cannot step past a runtime-sized region, so a
second region would ALIAS the frozen base. Ingest therefore FAILS LOUD (Rule 1)
on any alloca after a dynamic one. Threading a runtime bump pointer through
`IState` for multi-dynamic-array support is a deferred bead (see §Consequences
in ADR 0009 / the bead filed at impl).

# is_injective = false (L2 via predelta_payload, not L1) — load-bearing

`DynAlloca` is a non-injective region create: it materialises a pointer (a
re-definition in a loop may overwrite a prior `dest`, the cross-iteration crux
shared with `Define` / `MemoryLoad` / `VarGEP`) AND it opens a region whose
later element writes must be undone on reverse. The static type-level trait
cannot see runtime freshness, so per Rule 1 ("fail safe — push when in doubt")
it is conservatively `false` (`src/history/Injective.jl`), forcing the
M6.2/M7.6 push gate to record a history entry. Unlike `VarGEP` / `MemoryLoad`
(L3-only, no `make_delta`), `DynAlloca` carries an L2 `(base, n)` delta captured
PRE-`forward()` (the `predelta_payload` hook, like `MemoryStore`'s
`(addr, old_value)`): the size `n` is read from `s.locals[n_operand]` before
`forward()` runs, and the inverse needs it to know how big a region to retract.

# The unconditional-delete soundness lemma (the load-bearing claim)

On reverse, the L2 inverse UNCONDITIONALLY deletes the WHOLE region
`base … base+n-1` and removes the pointer. This restores the EXACT pre-alloca
heap REGARDLESS of whether the region's element stores were tracked L2 (a
per-write `(addr, old_value)` delta — `MemoryStore`) or L3 (a whole-state
`CheckpointEntry`). Proof: the bump allocator (frozen base; single-dynamic-array
strategy) guarantees every address in `[base, base+n-1]` was ABSENT pre-alloca
and belongs EXCLUSIVELY to this allocation's lifetime. So:

  * Nothing OUTSIDE the region was touched *by the alloca* — the alloca only
    creates the pointer; element writes are separate `MemoryStore` instructions
    with their own history entries, reversed before the alloca's inverse runs
    (history is a LIFO stack; the alloca was pushed first, popped last).
  * Nothing INSIDE the region pre-existed — every cell was absent pre-alloca.

Therefore deleting the whole region is the exact inverse of the net effect "open
this region (+ whatever was written into it that has *already* been reversed by
the time we get here)". When element stores reverse via their OWN L2 deltas
first, the region is already empty by the time the alloca's inverse runs, and
the delete is a no-op on absent cells (harmless). When they reverse via L3
replay, the L3 restore + forward replay already rebuilds and re-empties state up
to the alloca; the alloca's L2 fast-path then runs at the boundary. The delete
is unconditional precisely because it must be correct in BOTH orderings without
inspecting which one occurred — it cannot leave a phantom `{addr=>0}` (the
`IState.==`-by-Dict-content trap `MemoryStore` documents) because it removes the
KEY, never writes `0`. The `n <= 0` case (an empty / degenerate runtime size)
makes the loop empty — only the pointer is undone, which is still correct.

# Why the prev (Any) inverse raises

`DynAlloca` reverses EXCLUSIVELY via its L2 `(base, n)` delta payload — the
NamedTuple `inverse` below. The `prev::Any` catch-all (the L3-checkpoint-replay
path's signature, never taken for an L2-delta'd instruction) RAISES
descriptively (Rule 1), mirroring `MemoryStore`'s raising `inverse(::MemoryStore,
s, ::Any)` catch-all: reaching it means `unstep!` tried the wrong path, and a
silent no-op would falsely report a successful reverse while the region went
un-retracted (reversibility corruption). There is NO `make_delta` — the sole L2
path is `predelta_payload` (the pre-`forward()` capture, like `MemoryStore`).

# pc convention

`forward` sets `s.pc += 1`; the L2 `inverse` decrements `s.pc -= 1` (the M7.4
fast-path does NOT adjust pc itself), mirroring `MemoryStore` /
`ArithmeticAssignment.inverse` and the ±1 per-step symmetry.

# Operand kinds

`dest` is the pointer SSA name created; `n_operand` is the SSA name holding the
runtime element count (an `IRAlloca` with an `SSAOperand` n_elems names its size
operand here); `base` is the frozen compile-time `Int64` base. `n_operand`
MUST be defined in `s.locals` before the alloca — `predelta_payload` fails loud
(Rule 1) if it is absent, since a VLA's size is computed before the allocation.

# Ref

  * `docs/adr/0009-dynamic-size-memory.md` Decision 2a (+ the 2026-05-31
    bead-0zn impl refinement) — the (base, n) L2 delta, the single-dynamic-array
    fixed-base strategy, the unconditional-delete soundness lemma.
  * `docs/adr/0013-reversible-memory-architecture.md` §D-2 — the dynamic-N
    `alloca` row ("as above + record (base, n)"; No; L2 delta).
  * `docs/adr/0014-memory-floor-lowering.md` §D1 (bump allocator; pointer =
    Int64 base; "cells default to 0 by the zero-init convention", §D1:46),
    §D4 (dynamic-N deferred — this file lifts it). The "does not pre-populate
    `s.memory`" wording is `src/ir/ingest.jl:317`'s, not §D1's (Law 1).
  * `src/ir/memory_floor.jl` — `MemoryStore`, the L2-via-`predelta_payload`
    template (pre-`forward()` capture + NamedTuple inverse + raising Any
    catch-all) this file mirrors; the absent=0 / missing-sentinel convention.
  * `src/ir/ingest.jl` — `_lower_alloca!`'s dynamic-N dispatch that emits this
    instruction + the fail-loud single-dynamic-array guard.
  * `src/history/Injective.jl` — where `is_injective(::Type{DynAlloca}) = false`
    is wired.
  * CLAUDE.md Rule 1 (fail loud), Rule 2 (reuse `MemoryStore`'s L2 template),
    Rule 11 (literate).
"""

# --- DynAlloca: s.locals[dest] := base (runtime-sized region create) ---

struct DynAlloca <: Instruction
    dest::Symbol         # pointer SSA name created — holds the Int64 base addr
    n_operand::Symbol    # SSA name holding the runtime element count n
    base::Int64          # frozen compile-time region base address

    function DynAlloca(dest::Symbol, n_operand::Symbol, base::Int64)
        dest === n_operand &&
            error("DynAlloca: SSA single-assignment violation — dest ",
                  "$(dest) also names the n_operand; an SSA name cannot be ",
                  "both defined (the pointer) and read (the runtime size) by ",
                  "the same instruction (RSSA: every name has exactly one ",
                  "defining instruction).")
        return new(dest, n_operand, base)
    end
end

"""
    forward(instr::DynAlloca, s::IState) -> IState

Materialise the pointer `dest := base` in `s.locals` and bump `pc`. The region
`base … base+n-1` is NOT zeroed — cells stay absent and read as `0` by the
floor's absent=0 convention (LLVM `alloca`'s uninitialised semantics; the ADR
0014 §D1 zero-init convention, "cells default to 0", §D1:46 — the heap is
materialised lazily, `src/ir/ingest.jl:317`). `n_operand` is READ (it is not
needed at forward time — only at reverse, where `predelta_payload` captured it),
matching how a `getelementptr` / `Define` reads operands without consuming them.

# Single-execution precondition (Rule 1 guard — what MAKES the lemma sound)

`dest` MUST be absent when this runs. The frozen-base strategy reserves the
region `[base, ∞)` ONCE, and the L2 `inverse` retracts the region + pointer
UNCONDITIONALLY (delete, not restore). A `dest` already live means this alloca
is RE-executing under a frozen base — a back-edge / loop reaches it — so a
second allocation would ALIAS the first, and reversing it would corrupt the
prior region. That is the deferred multi-execution / runtime-bump-pointer case
(`bennettvm-…`), NOT something to miscompile silently: we `error()` loudly
(Rule 1). This guard ENFORCES, rather than assumes, the "region fresh / `dest`
absent pre-alloca" premise the unconditional-delete soundness lemma rests on —
without it, the lemma is merely a hope about the input. (This is also why the
sibling creates `Define` / `VarGEP` / `MemoryLoad` refuse an L2 inverse and go
L3-only: they cannot enforce single-execution and so cannot safely
unconditional-delete. `DynAlloca` can, because re-execution under a frozen base
is unsupported by construction and is caught here.)
"""
function forward(instr::DynAlloca, s::IState)::IState
    haskey(s.locals, instr.dest) &&
        error("DynAlloca.forward: pointer :", instr.dest, " is already defined ",
              "in s.locals (= ", s.locals[instr.dest], "). A dynamic-N alloca ",
              "re-executing under the single-dynamic-array frozen-base strategy ",
              "(a loop / back-edge reaches it) would alias its region; the L2 ",
              "(base, n) inverse retracts that region UNCONDITIONALLY, so ",
              "reversing the second allocation would corrupt the first. ",
              "Multi-execution needs a runtime bump pointer threaded through ",
              "IState (deferred bead). Rule 1 fail-loud — do not miscompile. ",
              "n_operand=", instr.n_operand, ", base=", instr.base, ", pc=", s.pc, ".")
    s.locals[instr.dest] = instr.base
    s.pc += 1
    return s
end

"""
    predelta_payload(instr::DynAlloca, s::IState)
        -> @NamedTuple{base::Int64, n::Int64}

PRE-`forward()` capture for `DynAlloca`'s L2 delta (ADR 0009 Decision 2a).
Called by `step!` BEFORE `forward()`. Resolves the runtime element count `n`
from `s.locals[n_operand]` (fail loud — Rule 1 — if absent: a VLA's size is
computed before the allocation, so an undefined size operand is malformed IR)
and records `(base, n)`: the inverse needs `n` to know how large a region to
retract, and `base` to know where it starts. O(1) capture (a 2-tuple, no
`deepcopy(s.current)`), preserving L2's per-allocation space win.
"""
function predelta_payload(instr::DynAlloca, s::IState)
    haskey(s.locals, instr.n_operand) ||
        error("DynAlloca.predelta_payload: runtime element count operand :",
              instr.n_operand, " is not defined in s.locals (locals: ",
              collect(keys(s.locals)), ") — a VLA / dynamic-N alloca's size ",
              "MUST be computed before the allocation (Rule 1 fail-loud). ",
              "dest=", instr.dest, ", base=", instr.base, ", pc=", s.pc, ".")
    n = s.locals[instr.n_operand]
    return (base = instr.base, n = n)
end

"""
    inverse(instr::DynAlloca, s::IState, p::NamedTuple) -> IState

L2 reverse of a `DynAlloca` using the `(base, n)` payload captured by
`predelta_payload` BEFORE `forward()` ran. UNCONDITIONALLY deletes the whole
fresh region `p.base … p.base + p.n - 1` from `s.memory`, then removes the
pointer `dest` from `s.locals`, then decrements `pc`. See this file's
top-of-module "unconditional-delete soundness lemma": deleting the whole region
restores the exact pre-alloca heap regardless of whether the region's element
stores reversed via L2 or L3, because the bump allocator guarantees those
addresses were absent pre-alloca and belong exclusively to this allocation. The
delete removes KEYS (never writes `0`), so it cannot leave a phantom `{addr=>0}`
(the `IState.==`-by-Dict-content trap `MemoryStore` documents). `p.n <= 0` makes
the loop empty — only the pointer is undone, still correct.

This NamedTuple method is MORE SPECIFIC than the raising
`inverse(::DynAlloca, s, ::Any)` catch-all below, so the M7.4 `unstep!`
fast-path (`src/history/Replay.jl`, which calls `inverse(entry.instruction,
s.current, entry.payload::NamedTuple)`) dispatches HERE.
"""
function inverse(instr::DynAlloca, s::IState, p::NamedTuple)::IState
    # Unconditional region retract: delete every cell base … base+n-1. Sound
    # under L2/L3 store interleave (see the lemma); a no-op on already-absent
    # cells; removes KEYS so no phantom {addr=>0} survives. `p.n <= 0` → empty.
    for a in p.base:(p.base + p.n - 1)
        delete!(s.memory, a)
    end
    # Remove the pointer this alloca created (forward set s.locals[dest]).
    delete!(s.locals, instr.dest)
    s.pc -= 1
    return s
end

"""
    inverse(instr::DynAlloca, s::IState, prev) -> IState

**Always raises `ErrorException`.** `DynAlloca` reverses via its L2 `(base, n)`
delta payload (the NamedTuple `inverse` above), NOT the L3-checkpoint-replay
`prev` path. Reaching this means `unstep!` tried an L3/prev path on a
`DynAlloca`, which should not happen — the alloca always carries an L2 delta
(it has a non-`nothing` `predelta_payload`). Mirrors `MemoryStore`'s raising
catch-all. Rule 1: fail loud rather than silently no-op (which would falsely
report a successful reverse while the region went un-retracted).
"""
function inverse(instr::DynAlloca, s::IState, prev)::IState
    error("DynAlloca reverses via its L2 (base, n) delta payload, not the ",
          "L3-checkpoint-replay prev path (ADR 0009 Decision 2a). Reaching ",
          "this means unstep! dispatched the prev::Any inverse on a DynAlloca ",
          "— but a DynAlloca always carries an L2 delta (non-nothing ",
          "predelta_payload), so it should pop a DeltaEntry and dispatch the ",
          "NamedTuple inverse. dest=", instr.dest, ", n_operand=",
          instr.n_operand, ", base=", instr.base, ", pc=", s.pc, ".")
end
