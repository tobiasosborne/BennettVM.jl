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
        n = s.locals[n_operand]
        s.locals[dest] = base + s.heap_top; s.heap_top += n; s.pc += 1

A *pointer* in this model is just an `Int64` cell address living in `s.locals`
(the ADR 0014 §D1 model). `DynAlloca` materialises that pointer at a **frozen
compile-time `base` PLUS the runtime bump offset `s.heap_top`** (the cells
allocated by earlier dynamic allocas — see "Frozen base + runtime heap_top
offset" below) and bumps `pc`. It does **NOT** zero the region: cells stay
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

# Frozen base + runtime heap_top offset (the runtime-allocator-state lift)

`DynAlloca.base` is the COMPILE-TIME bump cursor at ingest (`_lower_alloca!`,
`src/ir/ingest.jl`), frozen. But the region's RUNTIME base is `base +
s.heap_top`, where `s.heap_top` (the `IState` field added by bead
`bennettvm-uil`) is the running total of dynamic cells allocated by EARLIER
dynamic allocas — an OFFSET starting at 0. `forward` reads `n =
s.locals[n_operand]`, materialises `s.locals[dest] = base + s.heap_top`, and
advances `s.heap_top += n`; the L2 `(base, n)` inverse retracts `s.heap_top -=
n`. So `heap_top` round-trips `0 → … → 0`.

This lifts the floor from ONE dynamic array per routine to **≥2** (the gate for
Case B's Dict, which has two `GenericMemory` backings — keys + vals). The k-th
dynamic alloca owns the disjoint window `[base_k + offset_k, base_k + offset_k +
n_k)` where `offset_k = heap_top` at its alloc time, and these windows are
disjoint by construction (each `heap_top` advance steps past the previous
region) and each absent pre-alloca. For a SINGLE dynamic alloca `heap_top == 0`
throughout, so `base + 0 == base` — byte-identical to the pre-`uil` frozen-base
behaviour (no `VMProgram` / `initial_state` change; no test churn).

Two cases stay deferred (ADR 0009 §Consequences; follow-up beads): (a) a STATIC
alloca after a dynamic one — the COMPILE-TIME cursor is frozen at the first
dynamic region's base and cannot step past a runtime-sized region, so a static
alloca there would alias; ingest FAILS LOUD (Rule 1). (b) a dynamic alloca
RE-executed under the same dest (in-loop / back-edge) — `forward`'s `haskey`
guard rejects it (LIFO heap_top retraction for re-execution is not yet
implemented). Both are fail-loud, not miscompiled.

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
`base … base+n-1` (the RUNTIME base `instr.base + heap_top`, captured by
`predelta_payload`) and removes the pointer. This restores the EXACT pre-alloca
heap REGARDLESS of whether the region's element stores were tracked L2 (a
per-write `(addr, old_value)` delta — `MemoryStore`) or L3 (a whole-state
`CheckpointEntry`). Proof: the bump allocator (frozen base + monotone
`heap_top` offset) guarantees every address in `[base, base+n-1]` was ABSENT
pre-alloca and belongs EXCLUSIVELY to this allocation's lifetime — distinct
dynamic allocas occupy DISJOINT offset windows. So:

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
    bead-0zn impl refinement, + the 2026-06-04 bead-uil multi-array
    refinement) — the (base, n) L2 delta, the frozen-base + runtime
    `heap_top` offset strategy, the unconditional-delete soundness lemma.
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
    instruction + the fail-loud static-after-dynamic guard (≥2 dynamic allocas
    admitted via the runtime `heap_top` offset; bead `bennettvm-uil`).
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

Materialise the pointer `dest := base + s.heap_top` in `s.locals` (the runtime
region base = frozen compile-time base + the running bump offset), advance the
cursor `s.heap_top += n`, and bump `pc`. The region `base … base+n-1` is NOT
zeroed — cells stay absent and read as `0` by the floor's absent=0 convention
(LLVM `alloca`'s uninitialised semantics; the ADR 0014 §D1 zero-init convention,
"cells default to 0", §D1:46 — the heap is materialised lazily,
`src/ir/ingest.jl:317`). `n_operand` is READ (to get `n` for the cursor advance;
`predelta_payload` already captured the same `n` for the reverse), matching how
a `getelementptr` / `Define` reads operands without consuming them.

# Single-execution precondition (Rule 1 guard — what MAKES the lemma sound)

`dest` MUST be absent when this runs. The L2 `inverse` retracts the region +
pointer + cursor UNCONDITIONALLY (delete + `heap_top -= n`, not restore). A
`dest` already live means this alloca is RE-executing under the SAME dest — a
back-edge / loop reaches it — so a second allocation would ALIAS the first, and
reversing it would corrupt the prior region. The runtime `heap_top` offset (bead
`bennettvm-uil`) lets ≥2 DISTINCT dynamic allocas coexist (distinct dests →
distinct offset windows → each passes this guard), but in-loop RE-execution of
the SAME dest needs LIFO `heap_top` retraction not yet implemented — that is the
deferred case, NOT something to miscompile silently: we `error()` loudly (Rule
1). This guard ENFORCES, rather than assumes, the "region fresh / `dest` absent
pre-alloca" premise the unconditional-delete soundness lemma rests on — without
it, the lemma is merely a hope about the input. (This is also why the sibling
creates `Define` / `VarGEP` / `MemoryLoad` refuse an L2 inverse and go L3-only:
they cannot enforce single-execution and so cannot safely unconditional-delete.
`DynAlloca` can, because re-execution under the same dest is caught here.)
"""
function forward(instr::DynAlloca, s::IState)::IState
    haskey(s.locals, instr.dest) &&
        error("DynAlloca.forward: pointer :", instr.dest, " is already defined ",
              "in s.locals (= ", s.locals[instr.dest], "). A dynamic-N alloca ",
              "re-executing (a loop / back-edge reaches it under the SAME dest) ",
              "would alias its region; the L2 (base, n) inverse retracts that ",
              "region UNCONDITIONALLY, so reversing the second allocation would ",
              "corrupt the first. The runtime bump pointer (`s.heap_top`, bead ",
              "`bennettvm-uil`) distinguishes ≥2 DISTINCT dynamic allocas (they ",
              "have distinct dests, so each passes this guard), but in-loop ",
              "RE-execution of the SAME dest needs LIFO heap_top retraction not ",
              "yet implemented (deferred bead). Rule 1 fail-loud — do not ",
              "miscompile. n_operand=", instr.n_operand, ", base=", instr.base,
              ", heap_top=", s.heap_top, ", pc=", s.pc, ".")
    # Runtime region base = frozen compile-time base + the running bump offset
    # (`s.heap_top`, the cells allocated by EARLIER dynamic allocas). For the
    # first dynamic alloca heap_top==0, so base==instr.base (byte-identical to
    # pre-uil). Advance the cursor by this region's runtime size `n` so the NEXT
    # dynamic alloca starts past this one — the disjointness that lets ≥2
    # dynamic arrays coexist (bead `bennettvm-uil`; ADR 0009 Decision 2a multi-
    # array refinement). `n` is read from s.locals[n_operand] (the same value
    # `predelta_payload` captured pre-forward into the (base, n) L2 delta).
    n = s.locals[instr.n_operand]
    s.locals[instr.dest] = instr.base + s.heap_top
    s.heap_top += n
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
retract, and `base` (= the RUNTIME base `instr.base + s.heap_top`, captured
BEFORE `forward` advances the cursor) to know where it starts. For a SINGLE
dynamic alloca `heap_top == 0` so `base == instr.base` (byte-identical to
pre-`uil`); a later dynamic alloca captures its own offset window's base (bead
`bennettvm-uil`). O(1) capture (a 2-tuple, no `deepcopy(s.current)`), preserving
L2's per-allocation space win.
"""
function predelta_payload(instr::DynAlloca, s::IState)
    haskey(s.locals, instr.n_operand) ||
        error("DynAlloca.predelta_payload: runtime element count operand :",
              instr.n_operand, " is not defined in s.locals (locals: ",
              collect(keys(s.locals)), ") — a VLA / dynamic-N alloca's size ",
              "MUST be computed before the allocation (Rule 1 fail-loud). ",
              "dest=", instr.dest, ", base=", instr.base, ", pc=", s.pc, ".")
    n = s.locals[instr.n_operand]
    # n < 0 corrupts the bump cursor (forward `heap_top += n` would DECREASE it;
    # the inverse `heap_top -= n` would INCREASE it, leaving heap_top permanently
    # wrong on round-trip — and a negative-width window aliases below the base).
    # A negative runtime size is malformed IR (a length is non-negative); fail
    # loud (Rule 1). n == 0 (an empty dynamic array, e.g. `Vector{T}(undef, 0)`)
    # is allowed and harmless: the offset is unchanged and the retract loop is
    # empty (the inverse docstring's `n <= 0` case), so the round-trip is exact.
    n >= 0 ||
        error("DynAlloca.predelta_payload: runtime element count n=", n,
              " (operand :", instr.n_operand, ") is NEGATIVE — a dynamic-array ",
              "size must be >= 0. A negative n corrupts the bump cursor on ",
              "round-trip (heap_top would not restore) and aliases below the ",
              "base (Rule 1 fail-loud). dest=", instr.dest, ", pc=", s.pc, ".")
    # The captured `base` is the RUNTIME region base = frozen compile-time base
    # + the running bump offset BEFORE `forward()` advances it (predelta runs
    # pre-forward). For the first dynamic alloca heap_top==0 → base==instr.base
    # (byte-identical to pre-uil); a later dynamic alloca captures its OFFSET
    # window base, so the inverse deletes exactly THIS region's cells (bead
    # `bennettvm-uil`). This must match `forward`'s `instr.base + s.heap_top`.
    return (base = instr.base + s.heap_top, n = n)
end

"""
    inverse(instr::DynAlloca, s::IState, p::NamedTuple) -> IState

L2 reverse of a `DynAlloca` using the `(base, n)` payload captured by
`predelta_payload` BEFORE `forward()` ran. UNCONDITIONALLY deletes the whole
fresh region `p.base … p.base + p.n - 1` from `s.memory` (`p.base` is the
RUNTIME offset base), removes the pointer `dest` from `s.locals`, retracts the
runtime bump cursor `s.heap_top -= p.n` (the exact inverse of forward's
`heap_top += n`; bead `bennettvm-uil`), then decrements `pc`. See this file's
top-of-module "unconditional-delete soundness lemma": deleting the whole region
restores the exact pre-alloca heap regardless of whether the region's element
stores reversed via L2 or L3, because the bump allocator (frozen base + monotone
`heap_top` offset) guarantees those addresses were absent pre-alloca and belong
exclusively to this allocation (distinct dynamic allocas → disjoint offset
windows). The delete removes KEYS (never writes `0`), so it cannot leave a
phantom `{addr=>0}` (the `IState.==`-by-Dict-content trap `MemoryStore`
documents). `p.n <= 0` makes the loop empty — only the pointer + cursor are
undone, still correct.

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
    # Retract the runtime bump cursor by this region's size (the exact inverse
    # of forward's `s.heap_top += n`). LIFO history (the alloca pushed first,
    # pops last among its region's writes) means later dynamic allocas — pushed
    # AFTER this one — have already retracted their own `n` from heap_top by the
    # time we get here, so this subtraction lands the cursor back at the value it
    # held when THIS alloca ran; the full chain round-trips heap_top to 0 (bead
    # `bennettvm-uil`; ADR 0009 Decision 2a multi-array refinement).
    s.heap_top -= p.n
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
