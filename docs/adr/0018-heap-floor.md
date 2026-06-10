# ADR 0018 — Reversible heap floor (CW-A): malloc arena + intrinsic boundary

> **Status: ACCEPTED 2026-06-10 (hostile review ACCEPT-WITH-CHANGES; all 8 changes applied; review archived in session transcript).** Bead `bennettvm-416r.2` (CW-A1).
> Implements **ADR 0017 §Decision items 3 (heap floor) and 4 (intrinsic
> boundary)**, constrained by items 1–2 (closed-world IR acquisition; reversible
> call/return — designed separately in CW-B). **Extends** the existing
> store-level memory floor (ADR 0013 §D-2, ADR 0014) — it does **not** replace
> it. Consumer of record: `test/reference/c/hashtable.O0.ll` (the CW-C fixture;
> `test/reference/c/BUILD.md`).

## Context

ADR 0017 §Decision 3 mandates "a deterministic arena allocator: the VM owns its
virtual address space, so allocation addresses are deterministic by
construction. At the correctness floor, `free`/GC is a no-op… `realloc` = alloc
+ copy; globals = initialized memory segments." Item 4 adds the bounded
intrinsic whitelist (`malloc`/`calloc`/`realloc`/`free`,
`memcpy`/`memmove`/`memset`, …); everything outside fails loud.

The existing floor already covers `alloca` (static via the bump cursor in
`_lower_alloca!`, dynamic-N via `DynAlloca` + the `heap_top` runtime offset, the
**`uil` keystone**), `load`/`store` (`MemoryStore`/`MemoryLoad`,
`src/ir/memory_floor.jl`), and addressing (`VarGEP` runtime GEP +
`IRPtrOffset`-as-cell-index static GEP). What is missing is the heap *arena* the
C fixture's `malloc`/`free` calls and `llvm.memset` require — a third
address-space tier sitting beside alloca-stack and (CW-A3) globals.

The cell-addressed model (`IState.memory::Dict{Int64,Int64}`, **one Int64 per
cell, not per byte**; `src/ir/array_index.jl` §"Stride is in CELLS") is the
load-bearing invariant the arena must extend coherently: malloc's *byte* size
and the struct-GEP *byte* offsets both reduce to whole cells for the fixture
(`%struct.ht = type { ptr, ptr, i64, i64 }`, fields at bytes 0/8/16/24 = cells
0/1/2/3; element width 64 = 8 bytes), exactly as the existing `IRPtrOffset` arm
already requires (`offset_bytes % ew_bytes == 0`, `src/ir/ingest.jl:559`).

Ground truth read for this design (page = PDF page):

- `references/reversible-languages/AxelsenGluck2013_reversible_heap.pdf` §3
  (p. 4–5): the reversible-machine heap is *"the edge of the heap is given by
  the heap pointer… Below the heap pointer is an area of (zero-cleared) free
  space, into which the heap can grow"*. **Our arena IS this heap pointer** —
  a monotone bump cursor over zero-cleared (absent=0) space.
- Same, §4.1 (p. 6): allocation comes *"from either the free list or by growing
  the heap"* [verbatim]; the free-list pop-vs-grow choice requires a reversible
  orthogonalization pattern [paraphrase]. The floor takes **only the grow path**
  and omits the free list (justified under §F).
- `references/reversible-isa/vieri-1995-pendulum-ms.pdf` (p. 22): *"By combining
  load and store into a single symmetric and reversible operation, exchange,
  the information is merely moved from one place to another rather than
  erased… Exchange must be used to access all architecturally visible memory
  elements in a reversible processor."* The hallucination-callout (CLAUDE.md):
  a load that doesn't store back is not reversible. The floor honours this at L3
  (snapshot) today; L1 Exchange is the deferred optimization (bead `uom`).
- `references/reversible-languages/Mogensen2018_reversible_gc.pdf` (p. 4,
  NO-SHARING paragraph): *"A list of unused heap nodes is maintained, and
  allocation uses the first node on this free list."* Same page (SIMPLE-SHARING
  paragraph): reclaiming under pointer sharing is more complex — a reference
  count must be maintained, or some other mechanism [paraphrase]. This is
  **why free=no-op** at the floor (§F): correct reclamation needs linearity or
  refcounts we do not have.

## Decision

### A. Address-space layout (determinism is a correctness invariant)

One deterministic virtual address space, partitioned into three monotone,
non-overlapping segments by frozen compile-time base constants assigned at
ingest. Determinism is **stated as a correctness invariant** (ADR 0017
Corollary): the same program on the same inputs allocates the same addresses on
every run, so address-dependent hashing (`ptrtoint`, splitmix64 over a pointer)
is reproducible inside the VM and the C fixture's GOLDEN.txt is recoverable
(`BUILD.md` §"House-style notes").

| segment | base | cursor / enforcement |
|---|---|---|
| **alloca / stack** | `0` upward | compile-time bump cursor `next_addr` (`_lower_alloca!`) + runtime `s.heap_top` offset for dyn-N (`uil`). **Unchanged.** |
| **malloc arena** | `ARENA_BASE` (a large frozen constant, e.g. `2^40`, disjoint from stack growth) | **new** runtime bump pointer `s.arena_top::Int64` in `IState`, starting at `0` (an OFFSET, mirroring `heap_top`). Region base = `ARENA_BASE + s.arena_top`. |
| **globals (CW-A3)** | `GLOBAL_BASE` (frozen, disjoint) | initialized segments materialized at `initial_state`; out of CW-A1 scope, reserved here so it does not collide. |

What enforces determinism: the arena bump pointer is the **sole** allocator —
no host pointer ever enters the VM. Each `malloc` returns `ARENA_BASE +
s.arena_top` and advances `s.arena_top` by the cell count. This is the same
frozen-base-plus-runtime-offset discipline `DynAlloca` already uses for
`heap_top`, applied to a second, disjoint segment.

**Reuse:** Axelsen–Glück 2013 §3 (p. 4) the heap-pointer-over-zero-cleared-space
model; the existing `heap_top` offset machinery (`src/ir/alloca.jl`,
`src/ir/IState.jl`). *New for this project — why:* a *second* offset cursor
(`arena_top`) for a disjoint segment is new; the alternative (reusing one
`heap_top` for both alloca-dyn-N and malloc) would alias the two and break the
static-after-dynamic guard. Separate cursors keep the segments independent.

### B. Reversible semantics + history-layer assignment per intrinsic

The arena bump allocator makes `malloc` reverse the way `DynAlloca` already
does — an **L2 `(base, n)` delta** captured pre-`forward` (the `predelta_payload`
hook), inverse unconditionally retracts the region + cursor. Soundness reuses
`src/ir/alloca.jl`'s "unconditional-delete soundness lemma" verbatim: every cell
in `[base, base+n)` was absent pre-alloc and belongs exclusively to this
allocation (disjoint offset windows), so deleting the whole region is the exact
inverse regardless of how element stores reversed.

| intrinsic | forward | injective? | history | logged |
|---|---|---|---|---|
| `malloc(nbytes)` | `dest := ARENA_BASE + s.arena_top`; `s.arena_top += cells`; cells stay **absent** (read 0) | No¹ | **L2** | `(base, cells)` pre-`forward` (like `DynAlloca`) |
| `calloc(n, sz)` | identical to malloc — cells already read 0 (absent=0), so **no separate zeroing needed** | No | **L2** | `(base, cells)` |
| `free(p)` | **no-op** (cursor not retracted forward) | trivially | **L1** | nothing pushed forward; but see ¹ |
| `realloc(p, n)` | = `malloc(n)` + copy old cells (a `memcpy`); old region leaked (free=no-op) | No | L2 (malloc) + memcpy's L2 | malloc `(base,cells)` + memcpy deltas |
| `memset(p, b, n)` runtime n | for `i in 0:cells-1`: `M[p+i] := bytefill(b)` | No | **L2** | per-cell `(addr, old, was_present)` — like `MemoryStore` |
| `memcpy`/`memmove(d, s, n)` | for `i`: `M[d+i] := M[s+i]` | No | **L2** | per-cell `(addr, old, was_present)` for the **dest** range only |

¹ **`malloc`/`free` injectivity and what `free` logs.** `free` at the floor is a
no-op (ADR 0017 item 3: "leaked space is history cost"). Forward it pushes
nothing. But a *reversible* no-op must restore nothing incorrectly on `unstep!`:
since `free` mutates no state (cursor, memory, locals all unchanged) it is
classified **L1 injective** (`is_injective(::Type{IntrinsicFree}) = true`), so
the push gate emits no entry and `unstep!` is a clean `pc -= 1`. This is correct
**precisely because** the freed region is never re-allocated (arena cursor only
grows) — there is no aliasing for a later malloc to expose. `malloc` is
non-injective (a loop re-def overwrites `dest`; the region must be retracted) and
carries the L2 delta, exactly as `DynAlloca`.

**`ht_grow` multi-malloc and the same-dest guard.** The fixture's `ht_grow`
scenario (multiple `malloc` calls at distinct call sites → distinct SSA dest
names) passes the `haskey(s.locals, dest)` in-loop guard in `predelta_payload`
by construction: each call site uses a fresh SSA dest, so the guard never fires
on a well-formed first execution. Bead `9v84` (same-dest back-edge re-execution
— a loop that re-executes an instruction whose dest is already in `s.locals`) is
inherited from `DynAlloca` and remains fail-loud for `IntrinsicMalloc`; `ht_grow`
does not exercise that path.

**memset/memcpy: delta vs checkpoint.** Each overwrites a *runtime-length* range.
Per `compute_must_cache` (the Enzyme-style min-cut selector, `src/analysis/
liveness.jl`), a bounded contiguous overwrite is the textbook L2 case: log the
overwritten cells, not a whole-state L3 snapshot. The payload is a **vector of
per-cell `(addr, old_value, was_present)`** — the exact `MemoryStore` L2 schema
(`src/ir/memory_floor.jl`) repeated `cells` times, with the `was_present` bit
load-bearing to avoid the phantom `{addr=>0}` trap. For a freshly-malloc'd dest
(all absent) every entry is `was_present=false` → inverse `delete!`s, restoring
the absent region exactly. L3 would also be *sound* (memory is in the snapshot)
but pays `deepcopy(IState)` per step (PRD §3.3 forbids full snapshots on the L2
path). **Decision: L2, the bounded-delta path.**

**Reuse:** `DynAlloca`'s L2 `(base,n)` template + unconditional-delete lemma
(`src/ir/alloca.jl`); `MemoryStore`'s `(addr, old, was_present)` per-cell delta
(`src/ir/memory_floor.jl`). *New — why:* memset/memcpy carry a *vector* of
per-cell deltas (runtime length), where `MemoryStore` carries one; the schema
is the same, the cardinality is runtime.

### C. VMProgram representation — extend SoftCall, do not reuse it

A heap intrinsic appears as a **new `IntrinsicCall` instruction family**, NOT a
reuse of `SoftCall` and NOT the generic `IRCall`→host-call path. Justification
against the existing dispatch:

- `SoftCall` (`src/ir/softcall_instruction.jl`) is a *non-destructive scalar
  SSA-create over UInt bit-patterns*, reversed **L3-only** (FP ops are not
  locally invertible). Heap intrinsics are *not* L3-only (malloc/memset reverse
  by L2 delta) and *do* mutate `s.memory`/`s.arena_top`, not just `s.locals`.
  Forcing them through `SoftCall` would mis-classify their reversal and wrongly
  promise no memory effect.
- The generic `IRCall`→reversible-subroutine path is **CW-B's** territory
  (multi-function `VMProgram`, BobISA call/return). Painting intrinsics into
  that corner now would couple CW-A to CW-B. Instead, intrinsics are *leaf*
  primitives with hand-written reversible semantics — exactly ADR 0017 item 4's
  "small whitelist… gets hand-written reversible semantics, once."

Concrete shape: distinct structs per intrinsic (`IntrinsicMalloc(dest,
nbytes_operand)`, `IntrinsicFree(ptr_operand)`, `IntrinsicMemset(ptr, byte,
n_operand)`, `IntrinsicMemcpy(dest_ptr, src_ptr, n_operand)`), each `<:
Instruction`, each with its own `forward`/`predelta_payload`/`inverse` and
`is_injective` wiring (`src/history/Injective.jl`). The ingest `IRCall` arm
(`src/ir/ingest.jl:370`) dispatches on `callee_name` in this exact order:
(1) `_NONDETERMINISTIC_CALLEES` guard (fail loud on nondeterministic callees);
(2) `_HEAP_DISPATCH` check → emit `IntrinsicCall` family and return;
(3) Float32 width guard (SoftCall scalar path);
(4) `SoftCall` construction.
A heap intrinsic must never reach step (3) or (4) — `_HEAP_DISPATCH` must
precede the Float32 guard and the `SoftCall` constructor. A `_HEAP_DISPATCH`
miss falls through to the existing fail-loud (§E). The bit-width / cell
conversion (`nbytes ÷ (elem_bytes)`) follows the `IRPtrOffset` cell-index
discipline (`src/ir/ingest.jl:559`).

**Reuse:** the `_SOFT_DISPATCH` allowlist *pattern* (a name→handler registry as
the Rule-1 boundary); `MemoryStore`/`DynAlloca` forward/inverse templates.
*New — why:* a heap-intrinsic family is new; SoftCall is the wrong base
(L3-only, scalar-only).

### D. Forward + unstep! pseudocode (malloc, memset runtime-n)

```
# IntrinsicMalloc(dest, nbytes_operand) — cells = resolve(nbytes)/elem_bytes
predelta_payload(s):                      # pre-forward L2 capture
    haskey(s.locals, dest) && error(...)  # re-exec under same dest → fail loud
    cells = cell_count(s.locals[nbytes_operand])   # bytes→cells, must divide
    cells >= 0 || error(...)              # negative size malformed
    return (base = ARENA_BASE + s.arena_top, cells = cells)
forward(s):
    cells = cell_count(s.locals[nbytes_operand])
    s.locals[dest] = ARENA_BASE + s.arena_top    # deterministic address
    s.arena_top += cells                          # bump; region stays absent
    s.pc += 1
inverse(s, p::NamedTuple):                # L2 reverse
    for a in p.base : p.base+p.cells-1: delete!(s.memory, a)  # absent again
    delete!(s.locals, dest)               # remove the pointer
    s.arena_top -= p.cells                # exact inverse of the bump
    s.pc -= 1
# Round-trip: arena_top 0→…→0, locals/memory byte-identical, history empty.

# IntrinsicMemset(ptr, byte, n_operand) — runtime length
predelta_payload(s):
    base = s.locals[ptr]; cells = cell_count(s.locals[n_operand])
    deltas = [ (a, get(s.memory,a,0), haskey(s.memory,a))
               for a in base : base+cells-1 ]   # per-cell, BEFORE overwrite
    return (deltas = deltas,)
    # Note: fill = cell_pattern(byte) is intentionally NOT in the payload;
    # the inverse restores purely from (addr, old, was_present) triples —
    # fill is dead carried state and has been removed.
forward(s):
    base = s.locals[ptr]; cells = cell_count(s.locals[n_operand])
    for a in base : base+cells-1: s.memory[a] = cell_pattern(byte)
    s.pc += 1
inverse(s, p::NamedTuple):
    for (a, old, was) in p.deltas:    # order-independent per-cell restore (reverse() removed; each (addr,old,was_present) triple is independent)
        was ? (s.memory[a] = old) : delete!(s.memory, a)   # phantom-0 guard
    s.pc -= 1
```

### E. Failure modes (Rule 1 — fail loud)

- **Out-of-whitelist callee:** the existing `IRCall` fall-through already raises
  (`src/ir/ingest.jl`); the `_HEAP_DISPATCH` miss re-raises with the known set,
  the `_SOFT_DISPATCH` pattern.
- **`free` of an unknown pointer:** at the floor `free` is a no-op, so a bad
  pointer is *harmless forward* — but a pointer not produced by a malloc/alloca
  is malformed IR. `IntrinsicFree.forward` asserts `haskey(s.locals, ptr)` (the
  pointer SSA value exists); a value outside `[ARENA_BASE, ARENA_BASE+arena_top)`
  and outside the stack segment is a **fail-loud** (defends the segment model).
- **Load of a never-stored heap address:** defined as **0**, not poison. Justified
  against the fixture: the fixture initializes via explicit for-loop stores (O0)
  which clang idiom-recognizes as `llvm.memset` at O1; absent=0 is a safety net
  for those zero-init patterns, not load-bearing for the fixture by itself
  (`BUILD.md` item 4). `MemoryLoad`'s `get(s.memory, a, 0)` already does this.
  **Uninit-read decision:** any program that reads a never-stored malloc cell has
  undefined behavior under the C/LLVM model; absent=0 is not a correctness
  guarantee for such programs — it is a convenience for zero-init patterns and
  cannot mask a miscompile in a UB-free closed-world program.
- **Overlapping `memcpy`:** C says `memcpy` may not overlap (UB); `memmove` may.
  `IntrinsicMemcpy.forward` asserts dest/src ranges are disjoint (fail loud on
  overlap — never silently miscopy); `IntrinsicMemmove` permits overlap and
  copies in the safe direction. The fixture uses `llvm.memset` only (no memcpy),
  so memcpy/memmove are designed-and-tested but not fixture-exercised yet.
- **Negative / non-cell-divisible size:** `cell_count` fails loud if `nbytes`
  is negative or not a whole multiple of the element byte width (the
  `IRPtrOffset` discipline; sub-element struct-packing is out of scope).

### F. Deliberately NOT in the floor

- **Reversible reclamation (free-list / GC).** Axelsen–Glück 2013 §4.1 (p. 6)
  needs the orthogonalizing pop-vs-grow trick and a free-list invariant;
  Mogensen 2018 (p. 4) shows correct reclamation needs *"a reference count… or
  some other mechanism"* under sharing. The arena floor takes only the grow
  path; `free` leaks (ADR 0017 item 3 accepts this — "leaked space is history
  cost"). **Forcing condition (Rule 9 deferred bead):** a program whose live
  arena footprint exceeds available `Int64` address space, OR a quantum-lowering
  pass that needs bounded space → port Axelsen–Glück §4.1 free-list +
  Mogensen reference counts. File as a follow-up bead.
- **Exchange-optimized (L1, no-history) loads/stores.** Vieri 1995 (p. 22; §4.2.1 Memory Access, p. 32)
  mandates exchange; the floor reverses memory by L2/L3 instead (bead `uom`,
  ADR 0014 §D2). **Forcing condition:** when history size dominates runtime cost
  on a long-running heap program → lower load/store to `MemoryInterchange` with
  a zero-ancilla (the `L1 Exchange` bead `uom`).

### G. Test plan for CW-A2

Hand-built-IR round-trip tests (Rule 5 port-and-verify: per-step inverse +
aggregate `run!`/`unrun!` + mutation-proof), using the existing
`per_step_inverse_check` scaffold (`test/test_per_step_inverse.jl`,
`test/test_property_roundtrip.jl`) and the array-floor test shape
(`test/test_array_floor.jl`):

1. **malloc round-trip** (`test/test_arena_roundtrip.jl`, new): `malloc(32)`
   → pointer = `ARENA_BASE`; store/load through it; `unrun!` → `arena_top==0`,
   memory `{}`, history empty. Oracle: an irreversible Julia function doing the
   same writes. Mutation-proof: perturb `arena_top -= cells` to `+= cells`,
   confirm RED.
2. **multi-malloc disjointness** (extends `test/test_multi_dynalloca.jl`'s shape):
   two mallocs get disjoint windows via `arena_top`; round-trip both.
3. **memset runtime-n** (new): `malloc(n*8)` then `memset(p, 0, n*8)` with `n`
   runtime; oracle zeroes; round-trip; mutation-proof by perturbing the
   per-cell `was_present` branch (drop the `delete!`) → RED via phantom `{a=>0}`.
4. **calloc == malloc+absent-0** and **realloc == malloc+memcpy** composite tests.
5. **fail-loud** tests: out-of-whitelist callee, `free` of bad pointer, negative
   size, overlapping memcpy — each `@test_throws ErrorException`.

### H. Impact list (Rule 10 — 200-LOC cap flags)

| file | current LOC | change | over cap? |
|---|---|---|---|
| `src/ir/intrinsics.jl` (**new**) | 0 | the `IntrinsicMalloc/Free/Memset/Memcpy/Memmove` structs + forward/inverse/predelta | split into 2–3 files if >200 |
| `src/ir/IState.jl` | 314 | add `arena_top::Int64` field + default-0 constructors | already >200² |
| `src/ir/IState.jl` | — | `arena_top` MUST be added to `Base.:(==)` AND `Base.hash` — omitting it would make round-trip tests pass spuriously when the cursor fails to restore (ADR 0008 Finding-3 / spike-retrospective lesson 2 failure mode: equality over a stale cursor would not detect the cursor regression) | already >200² |
| `src/ir/ingest.jl` | 1308 | `IRCall` arm: `_HEAP_DISPATCH` routing + cell conversion | **already 1308, bead `u110`**³ |
| `src/history/Injective.jl` | 532 | `is_injective` rows for the new intrinsics | already >200² |
| `src/analysis/liveness.jl` | — | ensure intrinsics are L2-selected by `compute_must_cache` | check |
| `test/test_arena_roundtrip.jl` (**new**) | 0 | the §G suite | — |
| **Compatibility check (CW-C2 trip-wire)** | — | Verify that `Bennett.jl extract_parsed_ir_from_ll` emits `IRStore`/`IRLoad` for `store ptr`/`load ptr` instructions (the O0 fixture has 100+ of them; a pointer value is an Int64 cell value in the VM model). If the extractor rejects pointer-typed loads/stores, a Bennett.jl bead must be filed before CW-C2 can proceed. | — |

² These files predate the Rule-10 split convention (docstring-heavy; the cap
counts code, not docstrings). Adding a field/row is additive; do not grow the
*code* body materially. ³ `ingest.jl` is the bead-`u110` Rule-10 split target;
CW-B will force it. CW-A2 should extract the `IRCall` dispatch into a helper
(`_lower_intrinsic_call`) to keep the arm small and pre-stage the split.

## Reuse (Law 2)

Reuse: Axelsen–Glück 2013 §3 (heap-pointer-over-zero-cleared-space arena model,
p. 4); the `DynAlloca` L2 `(base,n)` template + unconditional-delete soundness
lemma + `heap_top` runtime-offset cursor (`src/ir/alloca.jl`); the `MemoryStore`
`(addr,old,was_present)` per-cell delta + phantom-0 guard
(`src/ir/memory_floor.jl`); the `_SOFT_DISPATCH` allowlist pattern
(`src/ir/softcall_instruction.jl`); the `IRPtrOffset` byte→cell discipline
(`src/ir/ingest.jl`). **Why not reuse further:** the arena needs a *second*
disjoint offset cursor (`arena_top`) — one cursor would alias the segments;
the no-free arena is *deliberately simpler* than Axelsen–Glück §4.1's free list
(no reclamation) and Mogensen 2018's refcount GC (correctness-first floor,
ADR 0017 item 3).

## Open questions for the lead

None blocking. Two decisions made here (recorded for the hostile review, not
escalated): (1) `ARENA_BASE` is a frozen constant disjoint from stack growth —
the exact value (`2^40`) is an implementation detail CW-A2 fixes, not a design
fork. (2) memset/memcpy reverse by **L2 vector-delta**, not L3 — chosen over
the deferrable L3 because PRD §3.3 forbids full snapshots on bounded overwrites
and the `MemoryStore` schema already exists; if the per-cell vector proves a
space problem on very large runtime lengths, L3 remains a *sound* fallback
(memory is in the snapshot) — that is an optimization fork, not a correctness
one (correctness-first rule).
