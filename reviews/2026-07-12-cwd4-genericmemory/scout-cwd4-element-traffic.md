# Scout report — CW-D4 "stored key not found on read-back" (bead bennettvm-9n3y)

Machine: WSL2 / Julia 1.12. Date 2026-07-12. All evidence produced live this
session by stepping the real fdict VMProgram one instruction at a time and
dumping IState.memory / active_locals / the lowered VMProgram. Probe scripts:
`scratchpad/trace.jl` (full store/load trace) and `scratchpad/trace2.jl`
(addr-13 provenance + block listings + final memory dump). No source edited.

Repro (test_jlglobal_singleton.jl testset (e) / test_x3t0_multikey_return.jl (f)):
```julia
fdict_d1b(a::Int8,b::Int8) = (d = Dict{Int8,Int8}(); d[a]=b; d[a])
set  = Bennett.extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8}; ptr_cells=true)
prog = BennettVM.lower_vm(set; entry=first(set).first)
rs   = BennettVM.initial_state(prog, Dict(:a=>3,:b=>7)); BennettVM.run!(rs,prog)  # → __unreachable__
```

Address key: arena base `ARENA_BASE = 2^40 = 1099511627776`; `GLOBAL_BASE = 2^48`;
`TLS_BASE = 2^56`. `CELL_BYTES = 8` (one Int64 per cell).

---

## TOP-LINE VERDICT

**Root cause is ARCHITECTURAL (missing modeling capability), not one mechanical
bug. The single most specific culprit: the VM never initializes the
`GenericMemory` data-pointer field of a `jl_alloc_genericmemory_unchecked`
allocation. `jl_alloc_genericmemory_unchecked` lowers to a bare
`IntrinsicGCAlloc` bump allocation (`src/ir/ingest_call.jl:64-72`) whose
`forward` (`src/ir/intrinsics.jl:233-239`) returns an address and bumps
`arena_top` but writes NOTHING into the allocated cells — in particular it never
sets the Memory's `ptr` field (header cell +1) to point at its backing store.
The front-end faithfully READS that field on every element access
(`memory_data_ptr = memoryref_mem + 1; memoryref_data = load[memory_data_ptr]`),
so every read returns the zero-init absent cell → data-pointer = 0 for the
`slots`, `keys` AND `vals` arrays. All three arrays therefore address element `i`
as `0 + i`, collapsing onto ONE shared cell. In this run key-slot index = 13, so
`slots[13]`, `keys[13]`, `vals[13]` are all cell 13: `setindex!` writes key 3
then value 7 to cell 13 (value overwrites key), and the read-back's `keys[13]`
load returns 7 ≠ search-key 3 → not-found → the dead `__unreachable__` throw
sink.**

A SECOND, independent defect compounds it: a cell-size CONVENTION MISMATCH —
the arena allocator is 8-byte-cell-granular (`_cell_count = nbytes ÷ 8`) while
the Dict struct-field GEPs are BYTE-granular (`h::Dict + 8/+16/+24/…`). A
64-byte Dict reserves only 8 cells but addresses its own fields across cells
+0…+56, so the Memory backing arrays allocated next (at +8, +10, +12) land
INSIDE the Dict's field footprint and clobber/alias the headers.

Either defect alone is fatal. Fixing "stored key round-trips" needs BOTH a
faithful GenericMemory object model (header + data-pointer init) and ONE
consistent cell-size convention across alloc / struct-GEP / memoryref lowering.

---

## Q1 — WHERE setindex!'s writes land

**VERDICT: `slots[13] = 137`, `keys[13] = 3`, `vals[13] = 7` — all three at the
SAME stack cell 13, because each array's data-pointer base resolves to 0.**

Live trace (`trace.jl`, block `setindex!#L24`):
```
step=260 STORE addr=13 val=137   # slots[i]  (slot tag 0x89)
step=280 STORE addr=13 val=3     # keys[i]   (key::Int8 = 3)
step=300 STORE addr=13 val=7     # vals[i]   (v0::Int8 = 7)  ← overwrites key 3
```
Final `IState.memory` after the whole run (`trace2.jl`):
```
addr=13 [stack]            val=7          ← keys/vals/slots collapsed here; holds the VALUE
addr=2^40+0   val=2^40+8    (Dict.slots memoryref)
addr=2^40+8   val=2^40+10   (Dict.keys  memoryref)   ← ALSO Memory-A length cell (collision, Q-note)
addr=2^40+16  val=2^40+12   (Dict.vals  memoryref)
addr=2^40+10  val=16        (keys Memory length)
addr=2^40+12  val=16        (vals Memory length)
addr=2^40+24=0 ndel  +32=1 count  +40=2 age  +48=1 idxfloor  +56=0
```
The provenance of cell 13 for the keys store (`trace2.jl` block listing,
`setindex!#L24`):
```
[51] Define(h::Dict.keys_ptr41, h::Dict, :add, 8)      # Dict.keys field  @ byte 8
[52] MemoryLoad(memoryref_mem50, h::Dict.keys_ptr41)   # = 2^40+10  (keys memoryref)
[53] Define(memory_data_ptr42, memoryref_mem50, :add, 1)  # = 2^40+11  (ptr FIELD, cell +1)
[54] MemoryLoad(memoryref_data44, memory_data_ptr42)   # load[2^40+11] = 0  ← ABSENT, never written
[69] VarGEP(memoryref_data52, __v37(=memoryref_data44=0), memoryref_byteoffset47(=13), 1)  # = 0+13 = 13
[70] MemoryStore(memoryref_data52, key::Int8)          # keys[13] := 3
```
`rehash!` wrote the length (16) at each Memory header cell (+0) and stored the
three memoryref pointers into the Dict fields, but NEVER wrote any data-pointer
(header cell +1). `load[2^40+11]` (keys), `load[2^40+13]` (vals), `load[2^40+9]`
(slots) are all absent → 0. So all three element bases are 0.

---

## Q2 — WHERE the root's read-back reads

**VERDICT: the exact SAME cell 13 — the read path recomputes the identical
broken base-0 + index-13 address, so it reads what the LAST writer (vals=7)
left, NOT the stored key 3.**

Live trace, root inlined getindex probe:
```
step=412  LOAD addr=13 val=7   blk=fdict_d1b#L49  (ptr memoryref_data24)
step=435  LOAD addr=13 val=7   blk=fdict_d1b#L59  (ptr memoryref_data35)
```
Block `fdict_d1b#L59` listing shows the compare:
```
[17] Define(__v77, memoryref_data27, :add, 0)               # keys data ptr (=0, same absent read)
[18] VarGEP(memoryref_data35, __v77, memoryref_byteoffset30, 1)  # 0 + 13 = 13
[19] MemoryLoad(__v78, memoryref_data35)                    # keys[13] = 7
[20] Define(__v79, __v63, :eq, __v78, 8)                    # (search key __v63==3) == (7) → FALSE
[21] Define(__v80, __v79, :xor, 1)                          # negate → keep probing / not-found
```
So it reads the SAME cells `setindex!` wrote — but those cells were aliased and
last-written by `vals`, so `keys[slot]` reads 7. It is NOT reading a stale
singleton header at GLOBAL_BASE; the divergence is the base-0 aliasing of
keys/vals/slots, caused by the uninitialized Memory data pointer (Q1). This is
the byte-cell vs data-pointer-launder failure the brief flagged: the
`memoryref_mem + 1` data-ptr field is read but never seeded.

---

## Q3 — WHY not-found (the arithmetic)

**VERDICT: the probe loads `keys[slot]` and compares to the search key. Because
`keys[slot]` and `vals[slot]` alias to cell 13 and `vals` wrote last, the load
returns 7. `7 == 3` is false → the probe's key-match fails → getindex concludes
the key is absent → the inlined `KeyError` path is the provably-dead
`fdict_d1b#__unreachable__` block (pc≈233 in the flat stream), reached
deterministically at step 457.**

The exact instruction where semantics diverge from native Julia: block
`fdict_d1b#L59` instruction `[19] MemoryLoad(__v78, memoryref_data35)` reading
cell **13** — it should read the keys backing array (value 3), but cell 13 holds
7 because `memoryref_data35`'s base is 0 (Q1) and collides with the vals store.
The upstream first cause is `[17]…[18]` computing base 0 from the absent
data-pointer field; the ultimate cause is the allocation that never wrote it.

(Whether the returned slot index is literally negative or the equality simply
fails, the observable is identical: keys-array element read returns the wrong
byte, so no slot ever matches and getindex throws.)

---

## Q4 — WHICH layer (single most-specific culprit)

**VERDICT: (b) BVM ingest/lowering + (a) BVM interpreter — the GenericMemory
allocation model. NOT (c) Bennett.jl extraction (it faithfully reads the
data-ptr field at +1) and NOT (d) the zeroed-singleton header model (that wall
is already cleared; the singletons are inert here).**

Two concrete, proven defects:

1. **Missing data-pointer initialization (primary, fatal on its own).**
   `src/ir/ingest_call.jl:64-72` lowers `jl_alloc_genericmemory_unchecked` to a
   plain `IntrinsicGCAlloc(dest, size, tag)`. `IntrinsicGCAlloc.forward`
   (`src/ir/intrinsics.jl:233-239`) does `dest := ARENA_BASE + arena_top;
   arena_top += cells` and writes NO header. In real Julia the runtime sets
   `mem.ptr` to the backing store; the VM model omits it. Every
   `memory_data_ptr = memoryref_mem + 1` load therefore returns absent=0, so
   `slots`/`keys`/`vals` share element base 0 and collapse to one cell. This is
   the direct cause of "stored key not found".

2. **Cell-size convention mismatch (compounding, corrupts headers).**
   `_cell_count = nbytes ÷ CELL_BYTES(8)` (`src/ir/intrinsics.jl:128-139`) makes
   the arena allocator 8-byte-cell-granular, but the Dict struct-field GEPs are
   emitted BYTE-granular by the front-end (`Define(h::Dict, :add, 8/16/24/32/…)`
   — Bennett.jl IRPtrOffset with `elem_width = 8 bits ⇒ ew_bytes = 1 ⇒ cell =
   byte offset`). A 64-byte Dict reserves 8 cells `[2^40, 2^40+8)` but writes its
   own fields into cells +0…+56, so the Memory arrays allocated at +8/+10/+12
   overlap. Proof: cell `2^40+8` is simultaneously the Dict.keys field and
   Memory-A(slots).length field (final memory shows the Dict.keys write, 2^40+10,
   surviving — the slots length was clobbered). The `memoryref_mem + 1`
   data-ptr field (cell-granular, +1) is a THIRD, inconsistent convention. No
   single cell-size holds across alloc / struct-GEP / memoryref lowering.

Ancillary note: the front-end (Bennett.jl) is a co-owner of defect 2 — its Dict
struct-field GEP lowering is byte-granular while its own memoryref-header
lowering is cell-granular. But the "key not found" symptom is driven by defect 1,
which is squarely a VM-side allocation-model gap.

---

## Q5 — SCALE and touch points

**VERDICT: ARCHITECTURAL — a missing modeling capability (a faithful
`GenericMemory` object: header layout + data-pointer init + one consistent
cell-size), not a bounded one-line fix. Two interlocking defects must land
together, plus a decision on the canonical cell size.**

Touch points:
- `src/ir/ingest_call.jl:64-72` — `jl_alloc_genericmemory_unchecked` must lower
  to a Memory-AWARE allocation that reserves header+data cells and records that
  it needs a data-pointer, rather than a bare `IntrinsicGCAlloc`.
- `src/ir/intrinsics.jl:194-252` (`IntrinsicGCAlloc` or a new
  `IntrinsicGenericMemoryAlloc`) — `forward` must write `header[+0] = length`
  and `header[+1] = base + header_cells` (inline backing base); `inverse` must
  retract those header cells too (reversibility — the round-trip invariant).
- `src/ir/intrinsics.jl:128-139` (`_cell_count`) vs the Bennett.jl front-end
  IRPtrOffset / memoryref lowering — reconcile to ONE cell-size convention so
  struct-field byte offsets and arena bump sizes agree (either make everything
  byte-granular: `_cell_count = nbytes` and memoryref data-ptr field at +8; or
  make struct-field GEPs cell-granular: Dict.keys at +1, vals at +2, …).
- Bennett.jl `src/extract/instructions.jl` (`_gc_loaded_dst_elem_ref` / the
  memoryref data-ptr chain, `memory_data_ptr = memoryref_mem + 1`) and the Dict
  struct-field IRPtrOffset emission — must match whatever cell-size the VM adopts.

Once a Memory alloc initializes distinct data pointers for slots/keys/vals AND
the cell-size is consistent, `keys[slot]` and `vals[slot]` land in different
backing regions, key 3 survives the value-7 write, the read-back matches, and
the run leaves the `__unreachable__` sink.

---

## Surprises / notes

- The wall is NOT in the singleton/global model (that wall is cleared): the
  singletons here are inert. The `jl_global` GLOBAL_BASE cells never participate
  in the element traffic; the whole failure is in freshly-allocated arena
  Memory whose header is never populated.
- `IntrinsicGCAlloc`'s doc comment ("IntrinsicGCAlloc-shaped deterministic arena
  bump → reverses for free") is technically true for reversibility but hides the
  correctness gap: it models the ALLOCATION but not the OBJECT — a Julia
  `GenericMemory` is a self-describing `{length, ptr}` whose ptr the runtime
  sets, and the VM drops that.
- The `arena_top` collision (defect 2) means even the Memory LENGTH fields are
  corrupted (slots length clobbered by Dict.keys), so a fix that only adds the
  data-pointer without fixing granularity would still read garbage lengths.
```
