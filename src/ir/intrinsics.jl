"""
    Heap intrinsics (CW-A) — the reversible malloc-arena floor (ADR 0018)

The leaf primitives BennettVM lowers the bounded libc/runtime heap whitelist
to: `malloc` / `calloc` / `realloc` / `free` (this file), and the bulk-memory
ops `memset` / `memcpy` / `memmove` (the sibling `src/ir/intrinsics_bulk.jl`,
split out for Rule 10 — ADR 0018 §H). They are the THIRD address-space tier of the
language-agnostic memory model (ADR 0017 §Decision 3–4): a deterministic
arena allocator sitting beside the alloca-stack (`heap_top`, ADR 0009) and
globals (CW-A3), so a C/Rust/Julia program's heap traffic round-trips
reversibly without any host pointer ever entering the VM.

    IntrinsicMalloc(dest, nbytes)        dest := ARENA_BASE + s.arena_top
                                         s.arena_top += cells   (region absent)
    IntrinsicCalloc(dest, n, sz)         identical (absent cells read 0)
    IntrinsicRealloc(dest, ptr, nbytes)  = malloc(nbytes) + memcpy(old → new)
    IntrinsicFree(ptr)                   no-op (leaked; ADR 0017 item 3)
    IntrinsicMemset(ptr, byte, nbytes)   M[p..] := cell_pattern(byte)
    IntrinsicMemcpy(dst, src, nbytes)    M[d..] := M[s..]  (disjoint; UB if not)
    IntrinsicMemmove(dst, src, nbytes)   M[d..] := M[s..]  (overlap-safe order)

# Ground truth (page = PDF page)

  * `references/reversible-languages/AxelsenGluck2013_reversible_heap.pdf` §3
    (p. 4–5): the reversible-machine heap is *"the edge of the heap is given
    by the heap pointer… Below the heap pointer is an area of (zero-cleared)
    free space, into which the heap can grow"*. The arena IS this heap
    pointer — a monotone bump cursor (`s.arena_top`, an OFFSET from a frozen
    `ARENA_BASE`) over zero-cleared (absent=0) space. §4.1 (p. 6): allocation
    is *"from either the free list or by growing the heap"*; the floor takes
    ONLY the grow path (no free list — `free` leaks).
  * `references/reversible-languages/Mogensen2018_reversible_gc.pdf` (p. 4,
    SIMPLE-SHARING): correct reclamation under pointer sharing needs a
    reference count or some other mechanism — *why* `free` is a no-op at the
    floor (correctness-first; ADR 0017 item 3, ADR 0018 §F).
  * `references/reversible-isa/vieri-1995-pendulum-ms.pdf` (p. 22): a load
    that doesn't store back is not reversible. The floor honours this at the
    L2/L3 history layer (the bulk overwrites carry per-cell `(addr, old,
    was_present)` deltas, the `MemoryStore` schema); L1 Exchange is deferred
    (bead `uom`).

# Reversibility (ADR 0018 §B) and history-layer assignment

  * `malloc` / `calloc` / `realloc-alloc-half` reverse the way `DynAlloca`
    does — an **L2 `(base, cells)` delta** captured PRE-`forward`, whose
    inverse UNCONDITIONALLY retracts the region + the `arena_top` cursor.
    Soundness reuses `src/ir/alloca.jl`'s unconditional-delete lemma verbatim:
    every cell in `[base, base+cells)` was absent pre-alloc and belongs
    exclusively to this allocation (disjoint offset windows), so deleting the
    whole region is the exact inverse regardless of how element stores
    reversed. The delete removes KEYS (never writes `0`) so it cannot leave a
    phantom `{addr=>0}` (the missing-sentinel trap `MemoryStore` documents).
  * `memset` / `memcpy` / `memmove` overwrite a runtime-length **dest** range:
    an **L2 vector of per-cell `(addr, old, was_present)`** (post-change-7:
    NO `fill` field — the inverse restores purely from the triples; each
    triple is independent so the inverse needs no `reverse()`), the
    `MemoryStore` per-cell schema repeated `cells` times.
  * `free` is a **no-op** and **L1 injective** (`is_injective(::Type{
    IntrinsicFree}) = true`): it mutates no state, so `unstep!` is a clean
    `pc -= 1` with nothing popped. Correct precisely because the arena cursor
    only grows — a freed region is never re-allocated, so there is no aliasing
    a later malloc could expose (ADR 0018 §B¹).

# Failure modes (Rule 1 — fail loud; ADR 0018 §E)

  * `free` of an unknown pointer (not in `active_locals(s)`, or outside the arena and
    stack segments) → fail loud (defends the segment model).
  * Non-cell-divisible / negative `nbytes` → `_cell_count` fails loud (the
    `IRPtrOffset` discipline; sub-cell packing is out of scope).
  * Overlapping `memcpy` → fail loud (C UB; never silently miscopy).
    `memmove` permits overlap and copies in the safe direction.
  * Out-of-whitelist callee → the ingest `_HEAP_DISPATCH` miss re-raises
    (`src/ir/ingest.jl`), not here.

# Ref

  * `docs/adr/0018-heap-floor.md` §A (address-space layout / `ARENA_BASE`),
    §B (per-intrinsic semantics + history layer), §D (forward + inverse
    pseudocode, post-change-7), §E (failure modes), §F (deliberately omitted:
    free list, L1 Exchange).
  * `src/ir/alloca.jl` — the `DynAlloca` L2 `(base, n)` template +
    unconditional-delete soundness lemma + the runtime-offset-cursor pattern
    (`arena_top` mirrors `heap_top`).
  * `src/ir/memory_floor.jl` — the `MemoryStore` `(addr, old, was_present)`
    per-cell delta + the missing-sentinel `was_present`→`delete!` guard.
  * `src/history/Injective.jl` (`is_injective` rows), `src/history/delta.jl`
    (`is_l2_capable` rows), `src/ir/IState.jl` (`arena_top` field + ==/hash).
  * CLAUDE.md Rule 1 (fail loud), Rule 2 (reuse DynAlloca / MemoryStore),
    Rule 11 (literate).
"""

# --- ADR 0018 §A: address-space layout constants -----------------------------
#
# `ARENA_BASE` is a large frozen compile-time constant disjoint from stack
# growth (`heap_top` over `_lower_alloca!`'s cursor) and from globals
# (CW-A3). `2^40` is the value ADR 0018 §"Open questions" (1) fixes — far
# above any realistic alloca-stack footprint, so the arena never collides
# with the stack segment. `CELL_BYTES = 8`: the VM is CELL-addressed, one
# `Int64` per cell (`IState.memory`), and the fixture's struct fields /
# elements are all 8 bytes (ADR 0018 §Context: "element width 64 = 8 bytes").
const ARENA_BASE = Int64(1) << 40
const CELL_BYTES = Int64(8)

"""
    _cell_count(nbytes::Int64) -> Int64

Byte count → whole-cell count, fail-loud (Rule 1) on a negative or
non-cell-divisible size — the `IRPtrOffset` cell-index discipline
(`src/ir/ingest.jl`; sub-cell struct packing is out of scope, ADR 0018 §E).
A negative size corrupts the bump cursor (the `DynAlloca.predelta_payload`
negative-n argument); a non-multiple means the byte size addresses a partial
cell the cell-addressed VM cannot represent.
"""
function _cell_count(nbytes::Int64)::Int64
    nbytes >= 0 ||
        error("heap intrinsic: nbytes=", nbytes, " is NEGATIVE — an ",
              "allocation / bulk size must be >= 0 (a negative size corrupts ",
              "the arena bump cursor on round-trip). Rule 1 fail-loud.")
    nbytes % CELL_BYTES == 0 ||
        error("heap intrinsic: nbytes=", nbytes, " is not a whole multiple ",
              "of the cell byte width ", CELL_BYTES, " — the cell-addressed VM ",
              "(one Int64 per cell) addresses whole cells only; a sub-cell ",
              "byte size is out of scope (ADR 0018 §E). Rule 1 fail-loud.")
    return nbytes ÷ CELL_BYTES
end

# A cell whose every byte holds `byte` (the C `memset` fill): the low 8 bits of
# `byte` smeared across all 8 cell bytes via the SWAR constant 0x0101…01.
_cell_pattern(byte::Int64)::Int64 =
    Int64((UInt64(byte & 0xff) * 0x0101010101010101) % UInt64 % Int64)

# Per-cell pre-overwrite delta triples for a dest range `base .. base+cells-1`
# (the `MemoryStore` `(addr, old, was_present)` schema, repeated). Each triple
# is independent — the inverse restores them in any order (no `reverse()`).
_range_deltas(s::IState, base::Int64, cells::Int64) =
    [(a, get(s.memory, a, Int64(0)), haskey(s.memory, a))
     for a in base:(base + cells - 1)]

# Restore a captured vector of `(addr, old, was_present)` triples — the
# missing-sentinel guard (`MemoryStore.inverse`): a cell ABSENT pre-overwrite
# is `delete!`d (NOT written `0`, which would leave a phantom `{addr=>0}` and
# break IState `==`-by-Dict-content); a present cell gets its `old` restored.
function _restore_deltas!(s::IState, deltas)
    for (a, old, was) in deltas
        was ? (s.memory[a] = old) : delete!(s.memory, a)
    end
    return s
end

# ===========================================================================
# IntrinsicMalloc / IntrinsicCalloc — region create + L2 (base, cells) delta.
# ===========================================================================

struct IntrinsicMalloc <: Instruction
    dest::Symbol                    # pointer SSA name created — Int64 arena addr
    nbytes_operand::Union{Symbol,Int64}   # allocation size in BYTES
end

# calloc(n, sz): allocate n*sz bytes. Cells already read 0 (absent=0), so NO
# separate zeroing — identical reversal to malloc (ADR 0018 §B). We carry both
# count + size operands and multiply at forward/predelta time.
struct IntrinsicCalloc <: Instruction
    dest::Symbol
    n_operand::Union{Symbol,Int64}        # element COUNT
    size_operand::Union{Symbol,Int64}     # element SIZE in bytes
end

# gc_alloc_obj(size, tag): the Julia typed-GC allocation cluster the closed-world
# VM ingests under CW-D3 (Bennett-iwo9 consensus decision 5; ADR 0021 D3 floor).
# Semantically IDENTICAL to `IntrinsicMalloc` — a deterministic arena bump alloc
# of `nbytes_operand` bytes returning `ARENA_BASE + arena_top` — EXCEPT it also
# carries the Julia type tag as METADATA ONLY. `type_tag` is STRUCTURALLY UNREAD
# by every state transition: it is never consulted by `_alloc_cells`,
# `predelta_payload`, `forward`, or `inverse` (which read only `dest` /
# `nbytes_operand`). The ADR 0021 D3 floor: a type tag must never influence VM
# state, so no nondeterministic JIT type-tag address can leak into a reversible
# computation. Membership in the `_ArenaAlloc` union below inherits the malloc
# arena machinery verbatim; the third field is the only structural difference and
# it is inert by construction. (CW-D3 Lever 3, bead `bennettvm-416r.12`.)
struct IntrinsicGCAlloc <: Instruction
    dest::Symbol                          # pointer SSA name created — Int64 arena addr
    nbytes_operand::Union{Symbol,Int64}   # allocation size in BYTES
    type_tag::Union{Symbol,Int64}         # ADR 0021 D3: METADATA ONLY — never
                                          # read by forward/inverse/_alloc_cells.
end

# Resolve a malloc/calloc allocation to its cell count (the shared bytes→cells
# step). `IntrinsicCalloc`'s byte size is `n * sz` (the C contract).
_alloc_cells(instr::IntrinsicMalloc, s::IState)::Int64 =
    _cell_count(_resolve(instr.nbytes_operand, s))
_alloc_cells(instr::IntrinsicCalloc, s::IState)::Int64 =
    _cell_count(_resolve(instr.n_operand, s) * _resolve(instr.size_operand, s))
# IntrinsicGCAlloc resolves to its cell count from `nbytes_operand` ALONE — the
# `type_tag` field is NOT referenced here (ADR 0021 D3 floor: tag is metadata).
_alloc_cells(instr::IntrinsicGCAlloc, s::IState)::Int64 =
    _cell_count(_resolve(instr.nbytes_operand, s))

const _ArenaAlloc = Union{IntrinsicMalloc,IntrinsicCalloc,IntrinsicGCAlloc}

"""
    predelta_payload(instr::_ArenaAlloc, s::IState) -> @NamedTuple{base, cells}

PRE-`forward` L2 capture (the `DynAlloca` template): the runtime region base
`ARENA_BASE + s.arena_top` (captured BEFORE `forward` advances the cursor) and
the cell count, so the inverse knows where the region starts and how big it is.
Fail loud (Rule 1) if `dest` is already live — a re-exec under the same dest
would alias (the `DynAlloca` same-dest guard; the in-loop case is bead `9v84`).
"""
function predelta_payload(instr::_ArenaAlloc, s::IState)
    haskey(active_locals(s), instr.dest) &&
        error(typeof(instr), ".predelta_payload: pointer :", instr.dest,
              " is already defined (re-exec under the same dest would alias ",
              "the arena region; the L2 (base, cells) inverse retracts it ",
              "UNCONDITIONALLY). In-loop same-dest re-exec is the deferred ",
              "bead 9v84 — Rule 1 fail-loud, do not miscompile.")
    return (base = ARENA_BASE + s.arena_top, cells = _alloc_cells(instr, s))
end

function forward(instr::_ArenaAlloc, s::IState)::IState
    cells = _alloc_cells(instr, s)
    active_locals(s)[instr.dest] = ARENA_BASE + s.arena_top   # deterministic address
    s.arena_top += cells                              # bump; region stays absent
    s.pc += 1
    return s
end

# L2 reverse: UNCONDITIONALLY delete the whole region (sound under L2/L3 store
# interleave — the unconditional-delete lemma, `src/ir/alloca.jl`), remove the
# pointer, retract the arena cursor. Round-trips arena_top 0 → … → 0.
function inverse(instr::_ArenaAlloc, s::IState, p::NamedTuple)::IState
    for a in p.base:(p.base + p.cells - 1)
        delete!(s.memory, a)
    end
    delete!(active_locals(s), instr.dest)
    s.arena_top -= p.cells
    s.pc -= 1
    return s
end

# Raising L3-prev catch-all (the never-taken path; mirrors DynAlloca, Rule 1).
inverse(instr::_ArenaAlloc, s::IState, prev)::IState =
    error(typeof(instr), " reverses via its L2 (base, cells) delta, not the ",
          "L3-prev path (ADR 0018 §B). Reaching this means unstep! dispatched ",
          "the prev::Any inverse on an arena allocation — Rule 1 fail-loud.")

# ===========================================================================
# IntrinsicFree — no-op, L1 injective (ADR 0018 §B¹).
# ===========================================================================

struct IntrinsicFree <: Instruction
    ptr_operand::Symbol             # pointer SSA name to free (an arena addr)
end

# free is a no-op forward (leaked; ADR 0017 item 3), but it FAILS LOUD on a
# malformed pointer (Rule 1, ADR 0018 §E): the ptr SSA value must exist, and
# its address must lie in the arena segment OR the stack segment (a value in
# neither is not a pointer this VM produced). pc bumps so it has a clean
# `pc -= 1` inverse under the L1 no-push gate.
function forward(instr::IntrinsicFree, s::IState)::IState
    haskey(active_locals(s), instr.ptr_operand) ||
        error("IntrinsicFree.forward: ptr :", instr.ptr_operand,
              " is not defined in active_locals(s) — free of an SSA value that no ",
              "malloc / alloca produced is malformed IR (Rule 1 fail-loud).")
    a = active_locals(s)[instr.ptr_operand]
    (a >= 0 && a < ARENA_BASE) ||
        (a >= ARENA_BASE && a < ARENA_BASE + s.arena_top) ||
        error("IntrinsicFree.forward: ptr :", instr.ptr_operand, " = ", a,
              " is outside both the stack segment [0, ", ARENA_BASE,
              ") and the live arena [", ARENA_BASE, ", ",
              ARENA_BASE + s.arena_top, ") — not a pointer this VM produced ",
              "(ADR 0018 §E; Rule 1 fail-loud — defends the segment model).")
    s.pc += 1
    return s
end

# NOTE: the bulk-memory ops (`IntrinsicMemset` / `IntrinsicMemcpy` /
# `IntrinsicMemmove`) live in the sibling file `src/ir/intrinsics_bulk.jl`
# (Rule 10 — the arena allocs + bulk ops together exceeded the ~200 LOC cap;
# ADR 0018 §H anticipated the split). They share this file's helpers
# (`_cell_count`, `_cell_pattern`, `_range_deltas`, `_restore_deltas!`) and are
# `include`d immediately AFTER this file.

# ===========================================================================
# IntrinsicRealloc — = malloc(nbytes) + memcpy(old → new); old region leaked.
# ===========================================================================
#
# realloc reverses as the composite it is: the malloc-half carries the L2
# (base, cells) delta; the copy-half carries the dest-range delta. Modelled as
# a SINGLE instruction whose payload bundles BOTH halves, so it pushes ONE
# DeltaEntry and reverses in one inverse call (the copy is undone, then the
# region is retracted). The OLD region is leaked (free = no-op), exactly as the
# C contract under the no-free arena (ADR 0018 §B).

struct IntrinsicRealloc <: Instruction
    dest::Symbol                    # new pointer SSA name
    ptr_operand::Symbol             # old pointer SSA name (READ, copied from)
    nbytes_operand::Union{Symbol,Int64}  # new size in BYTES
end

function predelta_payload(instr::IntrinsicRealloc, s::IState)
    haskey(active_locals(s), instr.dest) &&
        error("IntrinsicRealloc.predelta_payload: dest :", instr.dest,
              " is already defined (re-exec under the same dest would alias ",
              "— deferred bead 9v84; Rule 1 fail-loud).")
    base = ARENA_BASE + s.arena_top
    cells = _cell_count(_resolve(instr.nbytes_operand, s))
    # The new region is freshly malloc'd (all absent), so the copy's dest-range
    # delta is all `was_present=false` — but we capture it explicitly for
    # symmetry with the bulk-copy path (and robustness if the arena model ever
    # admits pre-population). The malloc-half retract is (base, cells).
    return (base = base, cells = cells,
            deltas = [(base + i, Int64(0), false) for i in 0:(cells - 1)])
end

function forward(instr::IntrinsicRealloc, s::IState)::IState
    base = ARENA_BASE + s.arena_top
    cells = _cell_count(_resolve(instr.nbytes_operand, s))
    old = active_locals(s)[instr.ptr_operand]
    active_locals(s)[instr.dest] = base
    s.arena_top += cells
    # Copy min(old-window, new-window) cells from the old region. The old size
    # is unknown to realloc (C tracks it in the allocator header we don't
    # model), so the floor copies the FULL new range from the old base — the
    # old cells beyond the copied prefix are absent=0, matching realloc's
    # "contents preserved up to min(old,new)" where the tail is indeterminate.
    for i in 0:(cells - 1)
        v = get(s.memory, old + i, Int64(0))
        v == 0 ? delete!(s.memory, base + i) : (s.memory[base + i] = v)
    end
    s.pc += 1
    return s
end

function inverse(instr::IntrinsicRealloc, s::IState, p::NamedTuple)::IState
    _restore_deltas!(s, p.deltas)          # undo the copy into the new region
    delete!(active_locals(s), instr.dest)          # remove the new pointer
    s.arena_top -= p.cells                  # retract the malloc-half cursor
    s.pc -= 1
    return s
end

inverse(instr::IntrinsicRealloc, s::IState, prev)::IState =
    error("IntrinsicRealloc reverses via its L2 (base, cells, deltas) payload, ",
          "not the L3-prev path (ADR 0018 §B). Rule 1 fail-loud.")
