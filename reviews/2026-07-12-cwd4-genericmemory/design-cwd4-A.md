# Design — CW-D4 (bennettvm-9n3y): faithful reversible GenericMemory model + ONE cell-granularity convention

Proposer A. DESIGN ONLY — no source changes. All file:line refs verified live
this session against Bennett.jl @ fd4afea and BennettVM.jl @ e410599, plus the
fdict `.ll` dumps in `scratchpad/{root,callee_*}.ll` and the two scout reports.

Goal: the 4-function `fdict_d1b(a,b) = (d=Dict{Int8,Int8}(); d[a]=b; d[a])` set
runs to `7` (for a=3,b=7) with a clean round-trip to empty history, instead of
falling into the dead `:__unreachable__` sink.

---

## 0. Ground truth (what the extractor actually emits — verified, not guessed)

Julia lowers **every** aggregate access as a **byte-offset `i8` GEP** or a
`{i64,ptr}` header GEP. From `callee_setindex!.ll` / `root.ll`:

| access | LLVM shape | front-end arm | IRPtrOffset emitted | VM cell today |
|---|---|---|---|---|
| Dict field (slots/keys/vals/…) | `getelementptr i8, ptr %h, i32 8/16/24/…` | Case A const-index int (`instructions.jl:3262`) | `IRPtrOffset(off, ew=8)` | `off ÷ 1 = off` → **byte-granular** ✓ |
| Memory `length` (field 0) | `getelementptr {i64,ptr}, ptr %m, i32 0, i32 0` | ptr_cells struct arm (`instructions.jl:3408`) | `IRPtrOffset(0, ew=64)` | `0 ÷ 8 = 0` |
| Memory `data-ptr` (field 1) **element path** | `getelementptr {i64,ptr}, ptr %m, i32 0, i32 1` | ptr_cells struct arm (`3408`) | `IRPtrOffset(8, ew=64)` | `8 ÷ 8 = 1` → **word-granular** ✗ |
| Memory `data-ptr` (field 1) **memset/fill! path** | `getelementptr i8, ptr %m, i32 8` (`.ptr_ptr`) | Case A const-index int | `IRPtrOffset(8, ew=8)` | `8 ÷ 1 = 8` → **byte-granular** |
| Memory element `keys[i]` / `vals[i]` | `gc_loaded(mem,data)` → `getelementptr i8, ptr %d, i64 %bo` where `%bo = mul %off, elsz` | IRVarGEP (`instructions.jl:3283`) / eln6 split (`_gc_loaded_dst_elem_ref`) | `IRVarGEP(off/bo, ew)` | `VarGEP(stride=1)` (`ingest_body.jl:225`) → cell/element |

`jl_alloc_genericmemory_unchecked` declared `(ptr ptls, i64 nbytes, ptr typ)`
(`callee_rehash!.ll:1100`); the size arg is **data bytes** = `smul(nelems,
elsz)` (`callee_rehash!.ll` `%163 = smul(%value_phi,1)`, `%164 = extractvalue`),
i.e. it EXCLUDES the 16-byte header. The **length** field IS written by the
front-end (`store i64 %value_phi, ptr {i64,ptr}#0`, `callee_rehash!.ll:737`);
the **data-ptr** field is NEVER stored — the native allocator sets it, and the
VM's bare `IntrinsicGCAlloc` writes nothing (the scout's primary defect).

**The two data-ptr access shapes disagree by cell** — element path → cell +1
(word), memset/fill! path → cell +8 (byte). BOTH are live. This is the "no
single convention" defect, and it is the crux of this bead.

**Decisive tie-breaker — the shipped empty-Memory singleton already picked
byte-granular.** `scout-jlglobal-census.md:156,281-282`: each singleton is a
"zeroed **16-byte header** (length@0, **data-ptr@8**)", and it is read via
`IRPtrOffset(.ptr_ptr, base, offset_bytes=8)` — the **byte** shape, cell +8.
So `data-ptr@cell+8` is ALREADY the committed on-disk convention (416r.13). The
fresh-Memory element path reading data-ptr @ cell +1 is inconsistent WITH THE
SINGLETONS. Byte-granular is not a free choice — it is forced by an already-
merged model.

---

## D1 — THE CELL CONVENTION: byte-granular for the Julia closed-world tier; word-granular (÷8) UNCHANGED for the C/malloc tier

**Decision.** Keep the VM cell-addressed (one `Int64` per cell). Establish
**byte-granular addressing (1 cell ≙ 1 byte of the object's address space) for
the Julia closed-world tier** — the tier whose IR is *entirely* `i8`/`{i64,ptr}`
byte-offset GEPs. Leave the **C/clang tier byte-identical**: it is word-granular
(one cell ≙ one 8-byte element, recovered by `IRPtrOffset ÷ elem_width` and
`malloc ÷ 8`), and its SWAR `memset` + wide-load semantics depend on it.

Concretely the Julia tier already IS byte-granular for `i8` GEPs (`÷1`). Three
things make it byte-granular *uniformly*:

1. **Julia allocations reserve `nbytes` cells, not `nbytes ÷ 8`** — so a
   64-byte Dict reserves 64 cells and its byte-offset fields (0,8,…,56) fit
   without the next allocation landing on `Dict.keys@+8`. (`IntrinsicGCAlloc`
   and the new `IntrinsicGenericMemoryAlloc` are Julia-only intrinsics; the C
   `IntrinsicMalloc/Calloc/Realloc` keep `÷8`.)
2. **The `{i64,ptr}` GenericMemory-header GEP is lowered byte-granular** (data-ptr
   → cell +8, matching the `i8`-byte-8 shape AND the singleton), reconciling the
   two data-ptr read shapes onto ONE cell.
3. The element `IRVarGEP` stays `stride=1` (it already consumes an *element*
   index for Int8, and byteoffset==index for elsz=1); no change needed for the
   fdict Int8 case (see D-note-1 for the non-Int8 follow-up).

**Why this granularity, per the brief's constraint ("keep every existing fixture
byte-identical OR argue precisely which behaviors legitimately change"):**
the C tier is 100% untouched (word-granular), so every C/Rust fixture and the
scalar memory-floor tests stay byte-identical. Only Julia-heap fixtures change,
and the ONLY pre-existing one (`test_416r12`) pins the *broken* model — it
legitimately flips (§ blast-radius table). There is no live Julia-heap round-trip
fixture to preserve; fdict is the first, and it is currently red.

### Rejected alternatives

- **A1: Global byte-granular (`CELL_BYTES=1` everywhere).** Cleanest "one
  convention" and needs no front-end change (drop the `IRPtrOffset ÷`, set
  `VarGEP stride = ew÷8`, `_cell_count = identity`). **REJECTED**: it breaks the
  C tier's **SWAR `memset` + wide-load** (`_cell_pattern` smears a byte across
  an 8-byte cell so a `memset(p,0xAB,8)` then `load i64 p` reads
  `0xABAB…AB`; under 1-byte cells a wide load reads a single byte → miscompile,
  and the VM has no sub-cell byte packing). It also churns every C-tier
  `arena_top`/relative-address assertion (`test_arena_roundtrip:103,138`,
  `test_416r12:124`). Larger blast radius AND a real correctness regression for
  C. Byte-granular is right for Julia (no memset-then-wide-read there) but wrong
  as a global default.

- **A2: Keep word-granular; VM dual-writes the data-ptr at cell +1 AND cell +8.**
  VM-only, no extractor change. **REJECTED**: (a) it does not deliver "ONE
  consistent convention" (the header field lives at two cells); (b) it puts the
  fresh-Memory data-ptr@+1, which **contradicts the shipped singleton's
  data-ptr@+8** — any code that treats a fresh Memory and a singleton uniformly
  (e.g. a future `length`/`isempty` shared helper) would read the wrong cell;
  (c) fragile against any third access shape. Correct-by-accident, not
  correct-by-construction (Rule 1/10).

- **A3: Per-allocation elem-width record consulted by GEP lowering at runtime.**
  A region→granularity map so a shared GEP arm divides per base. **REJECTED**:
  GEPs resolve their base only at run time, so this needs a runtime region
  lookup on every address computation — heavier, and a new silent-miscompile
  surface (stale/missing region entry → wrong divisor). A set-level track
  distinction is strictly simpler and closed-world-sound.

---

## D2 — THE GENERICMEMORY MODEL: dedicated `IntrinsicGenericMemoryAlloc` that materializes a byte-granular {length, data-ptr, inline data} object and initialises the data-ptr in its forward

**Decision.** Split `jl_alloc_genericmemory_unchecked` off `IntrinsicGCAlloc`
into a dedicated `IntrinsicGenericMemoryAlloc(dest, nbytes_data_operand,
type_tag)` (tag = metadata, structurally unread — ADR 0021 D3). It models a real
Julia `GenericMemory`:

```
base = ARENA_BASE + arena_top                 # deterministic (ADR 0018/0021 floor)
reserve  HEADER_CELLS(=16) + cell_count_bytes(nbytes_data)  cells   # header ⧺ inline data
M[base + 8] = base + 16                        # DATA-PTR field (byte-granular +8) := inline data base
arena_top += HEADER_CELLS + nbytes_data_cells
# length (M[base+0]) is written by the front-end's own `store i64 nelems` (unchanged)
```

- **HEADER_CELLS = 16**, byte-granular, mirroring native (`length@byte0→cell0`,
  `data-ptr@byte8→cell8`, inline data at `byte16→cell16`). This is the SAME
  layout the empty-Memory singleton already uses (census §"16-byte header"),
  so fresh Memories and singletons share one layout.
- **data-ptr VALUE = base + 16** — points at the inline data region reserved in
  the same allocation, so `gc_loaded(mem, data-ptr)` → `VarGEP(+byteoffset)`
  lands element `i` at `base+16+i` (Int8, one cell/element), disjoint from every
  other Memory's data. keys and vals now occupy **different** regions → the
  value-7 store no longer clobbers the key-3 store → read-back matches.

**Argument semantics (verified):** the 2nd arg is **data bytes** = `nelems*elsz`
(the `smul` product), NOT nelems and NOT including the header. Element size for
the Int8 Dict is 1 byte for slots/keys/vals, so `nbytes_data = nelems`.

**The header write stays reversible via the EXISTING L2 (base, cells) delta — no
new history machinery.** `IntrinsicGenericMemoryAlloc` reuses the `_ArenaAlloc`
`predelta_payload` `(base, cells)` and `inverse` (unconditional region delete,
`intrinsics.jl:244-252`). The data-ptr cell (`base+8`) is inside `[base,
base+cells)`, was **absent** pre-alloc (fresh region — the disjoint-window
invariant), written in `forward`, and **deleted** by the region-delete inverse →
restored to absent. This is exactly the `IntrinsicCalloc` precedent (an alloc
that touches its cells and still reverses via the region delete), and the
`alloca.jl` unconditional-delete lemma applies verbatim. Round-trips
`arena_top 0→…→0` and `memory {}→…→{}`.

**Only ONE thing differs from the `_ArenaAlloc` union**: a `forward` override
that (a) reserves header+data and (b) writes the one data-ptr cell. `predelta`
and `inverse` are the union's, provided `_alloc_cells(::IntrinsicGenericMemoryAlloc)
= HEADER_CELLS + cell_count_bytes(nbytes_data)`.

### Rejected alternatives

- **Emit the data-ptr init as a separate `MemoryStore` at ingest** (so L2/L3
  handles it). **REJECTED**: the data-ptr write has no LLVM store site (the
  native allocator does it), so there is no `IRStore` to lower; synthesising a
  standalone `MemoryStore` means a second history entry and an ordering contract
  (must precede the first element access) that the single-instruction forward
  gives for free. Folding it into `forward` (undone by the region delete) is
  fewer moving parts and matches how `IntrinsicRealloc` bundles its copy-half.

- **Reuse `IntrinsicGCAlloc` and just make it write a data-ptr.** **REJECTED**:
  `gc_alloc_obj` allocates plain structs (Dict, boxes) with NO {length,ptr}
  header — writing a data-ptr into a Dict would corrupt `Dict.keys@+8`. The two
  need different forwards; a dedicated type is cleaner than a tag-switch.

---

## D3 — INTERACTION with the singleton headers: no change; fresh Memories now MATCH the singleton layout

The empty-Memory singletons are 16 zeroed byte-cells at `GLOBAL_BASE+off`
(length@+0=0, data-ptr@+8=0/inert; `test_jlglobal_singleton (a)` asserts 16
cells `GB+0..GB+15`). Under D1/D2 a **fresh** Memory has the identical
byte-granular header (length@+0, data-ptr@+8) — just in the arena tier with a
non-zero data-ptr and non-empty data. **No singleton change is needed**, and the
convention is now uniform across GLOBAL-tier singletons and ARENA-tier fresh
Memories. (Before this bead the element path read data-ptr@+1, i.e. it would
have MISREAD even a singleton's data-ptr had the singleton ever been
element-accessed — it never is, being empty. D1 closes that latent gap.)

---

## D4 — Touch list (verified file:line)

### BennettVM.jl (VM — primary)

1. `src/ir/intrinsics.jl`
   - `~194`: add `struct IntrinsicGenericMemoryAlloc <: Instruction` (`dest`,
     `nbytes_data_operand::Union{Symbol,Int64}`, `type_tag::Union{Symbol,Int64}`).
   - `102`: add `const HEADER_CELLS = Int64(16)` (byte-granular header); keep
     `CELL_BYTES=8` for the C tier.
   - `~128`: add a byte-granular helper `_cell_count_bytes(nbytes) = nbytes`
     (with the `nbytes>=0` fail-loud kept; drop the `%8` divisibility check for
     the Julia path — byte cells have no sub-cell case). Keep `_cell_count`
     (÷8) for the C tier.
   - `209-210`: `_alloc_cells(::IntrinsicGCAlloc)` → `_cell_count_bytes(nbytes)`
     (Julia struct byte-granular reservation; Julia-only intrinsic).
   - add `_alloc_cells(::IntrinsicGenericMemoryAlloc) = HEADER_CELLS +
     _cell_count_bytes(nbytes_data)`.
   - `212`: add `IntrinsicGenericMemoryAlloc` to the `_ArenaAlloc` union (inherit
     `predelta_payload`/`inverse`); add a dedicated `forward` (bump + write
     `M[base+8] = base+HEADER_CELLS`) OVERRIDING the union forward for this type.
2. `src/ir/ingest_call.jl:64-72`: route `:jl_alloc_genericmemory_unchecked` to
   `IntrinsicGenericMemoryAlloc(inst.dest, _lower_operand(a[2]), _lower_operand(a[3]))`
   (drop `a[1]=ptls`, as today).
3. `src/history/Injective.jl`: add `is_injective(::Type{IntrinsicGenericMemoryAlloc})`
   row (same as `_ArenaAlloc`: reversed via L2, `false`).
4. `src/history/delta.jl`: add `is_l2_capable(::Type{IntrinsicGenericMemoryAlloc}) = true`.
5. `src/BennettVM.jl` / `src/ir/IState.jl`: `==`/hash already cover `arena_top`
   + `memory`; no change beyond exporting the new type if the tests reference it.

### Bennett.jl (front-end — REQUIRED, scoped; Rule 2 core-extractor → 3+1 agents)

6. `src/extract/instructions.jl` ptr_cells struct-GEP arm (`~3408`, the
   `return IRPtrOffset(dest, ssa(names[base.ref]), offset_bytes, 64)`):
   when `src_type_gep` is the **GenericMemory header** — a 2-element StructType
   `{ i64, ptr }` (reuse the element test from `_is_memdata_field1_gep`,
   `instructions.jl:206-220`) — emit `IRPtrOffset(dest, base, offset_bytes, 8)`
   (byte-granular; VM `÷1` → cell = offsetof). C `%struct.T` (named / ≠`{i64,ptr}`)
   keeps `elem_width=64` (word-granular) → byte-identical. **Scope guard**: gate
   on the memdata provenance (base traces via `_memdata_root` to a
   load-of-`{i64,ptr}`-field-1 / gc_loaded chain), so a *C* anonymous `{i64,ptr}`
   struct never trips it (see Risk 1).

### Tests

7. `test/test_x3t0_multikey_return.jl` (f) (`~343-350`): FLIP — delete
   `@test rthrew` / `@test occursin("__unreachable__", rmsg)`; assert
   `_BV.result(rs)[<ret>] == 7`, `isempty(rs.history)`, `rs.current == init`,
   for representative + edge Int8 (a,b) pairs.
8. `test/test_jlglobal_singleton.jl` (e) (`178-179`): FLIP the same way (drop
   `occursin("__unreachable__")`; keep `!occursin("jl_global")`; add full
   fdict==b round-trip).
9. `test/test_416r12_jl_alloc_genericmemory.jl` (`123-127`): update to the new
   model — `arena_top == HEADER_CELLS + nbytes_data` (was `nbytes÷8`); assert
   `M[base+8] == base+16` (data-ptr written); keep the unrun→`arena_top==0` /
   `memory=={}` round-trip.
10. NEW `test/test_9n3y_genericmemory_model.jl`: (a) unit — one
    `IntrinsicGenericMemoryAlloc`, assert header/data-ptr cells + per-step
    `unstep!` inverse + round-trip to empty; (b) fdict e2e via
    `extract_parsed_ir_set_from_julia` → `lower_vm` → `run!`, assert `==b` over
    a sweep of Int8 (a,b) incl. edges (0, ±1, 127, -128, a==b, collisions), each
    with `verify` (ancilla-zero / history-empty).

---

## D5 — Memory-layout contract (cell map for the fdict a=3,b=7 run, byte-granular)

Arena bump order = slots, keys, vals (rehash!), Dict allocated first
(`d=Dict()`). `A ≙ ARENA_BASE = 2^40`. Exact bases depend on alloc order; the
INVARIANT is disjoint data regions.

```
Dict h        @ A+0    gc_alloc_obj 64 B → 64 cells [A+0 .. A+64)
  A+0   slots memoryref  → &slotsMem
  A+8   keys  memoryref  → &keysMem          (was clobbered by MemA.length; now fits)
  A+16  vals  memoryref  → &valsMem
  A+24 ndel  A+32 count  A+40 age  A+48 idxfloor  A+56 maxprobe
  (A+1..7, +9..15, … absent)

slotsMem      @ A+64   genericmemory nbytes=16 → 16+16 = 32 cells [A+64 .. A+96)
  A+64  length = 16          (front-end store)
  A+72  data-ptr = A+80      (ALLOC writes; +8 byte-granular)
  data  [A+80 .. A+96)       slots[i] occupancy tag (0x89 at the key's slot)

keysMem       @ A+96   genericmemory nbytes=16 → 32 cells [A+96 .. A+128)
  A+96  length = 16
  A+104 data-ptr = A+112
  data  [A+112 .. A+128)     keys[slot] = 3          ← survives

valsMem       @ A+128  genericmemory nbytes=16 → 32 cells [A+128 .. A+160)
  A+128 length = 16
  A+136 data-ptr = A+144
  data  [A+144 .. A+160)     vals[slot] = 7          ← DISJOINT from keys
```

Read-back `d[a]`: `getindex` reads `keys[slot]` at `A+112+slot = 3`, `3 == 3`
match → returns `vals[slot]` at `A+144+slot = 7`. No collapse onto one cell.
Reverse: element stores (L2) delete their data cells; length stores (L2) delete
`A+{64,96,128}`; the three genericmemory allocs delete their regions (incl. the
data-ptr cells `A+{72,104,136}`); the Dict alloc deletes `[A, A+64)`; `arena_top
→ 0`, `memory → {}`, history empty.

---

## D6 — RED-GREEN plan & wall-pin flips

RED first (write/adapt tests, watch fail), then GREEN (implement D4).

- **Wall-pins flip to full round-trip** (this is the acceptance signal):
  - `test_x3t0 (f)`: `rthrew=true`/`__unreachable__` → `result==7`,
    `isempty(history)`, `current==init`.
  - `test_jlglobal_singleton (e)`: `occursin("__unreachable__")` →
    fdict==b round-trip. (`!occursin("jl_global")` STAYS — that wall is already
    cleared and remains cleared.)
- **New RED tests** (`test_9n3y_*`): genericmemory unit round-trip + fdict e2e
  sweep with `verify`. Fail before D4 (data-ptr absent / regions collapse),
  pass after.
- **Regression guard**: `test_416r12` re-pins the NEW model; if a future change
  reverts D2, it fails loud.

---

## D7 — Per-fixture blast-radius table

| fixture | tier | verdict |
|---|---|---|
| `test_memory_floor.jl`, `test_memory_floor_cll.jl` | scalar (hand-built ptrs) | **byte-identical** — no `_cell_count`/GEP-granularity path |
| `test_memory_instructions.jl` | scalar (explicit addrs) | **byte-identical** — hand-built VMPrograms, no arena alloc |
| `test_arena_roundtrip.jl` | C/malloc | **byte-identical** — `IntrinsicMalloc` keeps `÷8`; asserts `arena_top==4`, `M[_AB+2..3]` untouched |
| `test_c_hashtable_e2e.jl` | C/clang | **byte-identical** — word-granular malloc + typed GEPs + SWAR memset all unchanged; asserts oracle + round-trip only (address-agnostic) |
| `test_cast/control/call/swap` | mixed | **byte-identical** — no genericmemory/gc_alloc |
| `test_6bu3_struct_agg_ingest.jl` | Julia gc_alloc | **verify**: if it asserts gc_alloc `arena_top`/addresses, they scale ÷8→×1 (legitimate); if oracle/round-trip only, byte-identical. Audit at implement time. |
| `test_416r12_jl_alloc_genericmemory.jl` | Julia genericmemory | **flips** (pins the OLD broken bare-bump model): `arena_top 8→16+nbytes`; add data-ptr assertion. Legitimate. |
| `test_x3t0 (f)`, `test_jlglobal_singleton (e)` | Julia fdict | **flip** to fdict==7 round-trip (the deliverable). |

Behaviors that legitimately change: (1) Julia `gc_alloc_obj` /
`genericmemory` `arena_top` and absolute arena addresses (byte-granular, ÷8→×1
+ header) — internal, oracle/round-trip preserved; (2) the Julia `{i64,ptr}`
data-ptr field moves from cell +1 to cell +8. Nothing in the C tier changes.

---

## D8 — Top-3 silent-miscompile risks + killing guards

1. **C anonymous `{i64,ptr}` struct misclassified as a GenericMemory header** →
   byte-granular applied to a word-granular C region → mis-addressed field, no
   crash. **Guard**: scope the D4.6 byte-granular treatment to memdata
   provenance (`_memdata_root` traces to a load-of-`{i64,ptr}`-field-1 → gc_loaded
   chain), NOT the bare `{i64,ptr}` shape; a plain C struct field never matches.
   Belt: fail loud if a `{i64,ptr}` GEP is byte-granularised but its base has no
   memdata root under `ptr_cells`.
2. **Wrong data-ptr VALUE / header size → element or memset traffic lands in the
   header or the next allocation** (the ORIGINAL bug class, silent aliasing).
   **Guard**: in `forward`, assert `M[base+8]` is ABSENT before writing (Rule 1
   — catches a granularity regression where a prior alloc's region overlaps),
   and assert `data-ptr == base + HEADER_CELLS` with `[data-ptr, data-ptr+nbytes)
   ⊆ reserved ∧ disjoint from [base, base+HEADER_CELLS)`. Killing test: the fdict
   e2e `verify` sweep — any residual/aliased cell fails the history-empty
   assertion.
3. **`memset(slots,0)` reading the data-ptr from the wrong cell** (the +1/+8
   split) → zeroes the stack `[0,nbytes)` silently. **Guard**: D1 reconciles the
   data-ptr to cell +8 for BOTH the element path and the `.ptr_ptr` memset path,
   so both read the same (correct) base. Belt: a `MemoryStore`/memset base of `0`
   inside the arena-tier program is almost certainly an uninitialised data-ptr →
   add a fail-loud "memset/store base is 0 under ptr_cells" assertion.

---

## D9 — Fail-loud completeness (what still can't be modeled → explicit reject)

- **Non-bitstype Memory elements** (boxed `Memory{String}`/`Memory{Any}`): the
  element cell would hold a pointer into an object graph the closed-world walk
  may not have allocated. Out of scope; the deep-object graph is future work.
  Add a loud reject where a Memory-data store's value is a pointer with no live
  `active_locals` allocation (best-effort; document the limit).
- **Element size > 8 bytes** (`Int128`, inline structs): byte-granular addresses
  them (2 `i64` stores at `bo`, `bo+8`), but UNVERIFIED. Keep a loud guard: a
  single element that spans a partial cell (elsz not a multiple of 8 in the
  wide-element path) → reject.
- **`realloc`/resize of a GenericMemory**: Julia grows by allocating a NEW
  Memory + copy (`jl_genericmemory_copy*`), not libc realloc. Such a callee is
  not in `_HEAP_DISPATCH` → already fails loud (unknown callee). Keep it that
  way; do NOT silently route it to `IntrinsicRealloc`.
- **Mixed `malloc` + `gc_alloc` in one set** (impossible under closed-world
  single-source, but defend it): the two granularities would alias in one arena.
  Add an ingest guard: if a set contains BOTH a C `IntrinsicMalloc/Calloc/Realloc`
  AND a Julia `IntrinsicGCAlloc/GenericMemoryAlloc`, fail loud.

---

## D10 — NEXT WALL prediction (after fdict==7 lands)

1. **Dict growth / rehash-on-resize** — a *second* insert past the initial
   capacity drives `rehash!` to allocate a larger Memory and **copy** old→new
   (element loop or `jl_genericmemory_copy`). fdict does a single insert into a
   fresh Dict (one initial rehash → the 3 allocs modelled here), so it's covered;
   a 2+-insert Dict is the next wall.
2. **Collision probing across the linear-probe wraparound + deletion**
   (tombstones via `ndel`/slot tags).
3. **Non-Int8 key/val types** — `Dict{Int64,Int64}` exercises the wide-element
   `VarGEP stride` path (byte-granular data at `+i*8`); `Dict{String,_}` hits the
   boxed-element / objectid-hash walls (D9 + the nondeterminism guard).
4. **`objectid`/identity hashing** for non-primitive keys → the existing
   `_NONDETERMINISTIC_CALLEES` reject (doubly-fatal for reversibility).

---

## D11 — Diff estimate

- BennettVM.jl: ~110–150 LOC (new intrinsic + `forward` + `_alloc_cells` +
  `_cell_count_bytes` + ingest route + 2 trait rows + literate docstring).
- Bennett.jl: ~10–15 LOC (scoped byte-granular `{i64,ptr}` header in the struct
  GEP arm + provenance guard). Rule 2 → 3+1 agents for the extractor edit.
- Tests: ~150–200 LOC (2 wall-pin flips, `test_416r12` update, new
  `test_9n3y_*` unit + fdict sweep).
- Total ≈ 300 LOC.

---

### Decision summary (10 lines)

1. Byte-granular addressing for the Julia closed-world tier; C/malloc tier stays word-granular (÷8) and byte-identical.
2. Byte-granular is FORCED, not chosen: the shipped empty-Memory singleton already uses a 16-byte-cell header with data-ptr@cell+8.
3. New `IntrinsicGenericMemoryAlloc` materializes {length@+0, data-ptr@+8, inline data@+16}; reserves HEADER(16)+nbytes_data cells.
4. Its `forward` writes the data-ptr (base+16); reversibility is the EXISTING `_ArenaAlloc` L2 (base,cells) region-delete — no new history machinery.
5. `IntrinsicGCAlloc` (Julia structs) reserves `nbytes` cells (not ÷8) so byte-offset Dict fields (0,8,…,56) fit — closes defect-b.
6. The `{i64,ptr}` header GEP is lowered byte-granular in Bennett.jl (data-ptr → cell+8), reconciling the element path (was cell+1) with the memset path and the singleton — this is the ONE consistent convention.
7. length is still written by the front-end store; data-ptr is the ONLY field the alloc synthesizes (native allocator's job).
8. C tier untouched → SWAR memset+wide-load preserved; global `CELL_BYTES=1` rejected for exactly that reason.
9. Wall-pins `test_x3t0 (f)` and `test_jlglobal_singleton (e)` flip from `__unreachable__` to fdict==7 full round-trip.
10. Next wall: Dict resize/rehash-copy on the 2nd insert; non-Int8 element widths; boxed keys/objectid.

Doc: `/home/tobias/Projects/BennettVM.jl/scratchpad/design-cwd4-A.md`
