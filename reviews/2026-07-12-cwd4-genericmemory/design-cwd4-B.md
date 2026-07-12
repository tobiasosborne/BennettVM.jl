# Design CW-D4 (Proposer B) — faithful reversible GenericMemory model + ONE cell convention

Bead **bennettvm-9n3y**. Goal: the 4-function fdict set (`d=Dict{Int8,Int8}();
d[a]=b; d[a]`) finds its stored key on read-back so `fdict(3,7) == 7`, and the
whole run round-trips to EMPTY history. DESIGN ONLY — no source edited. All
line refs verified live against Bennett.jl HEAD fd4afea / BennettVM HEAD e410599
and the `.ll` dumps in `scratchpad/{root,callee_setindex!,callee_rehash!}.ll`.

Independent of proposer A (did not read `design-cwd4-A.md`).

---

## TL;DR — the whole fix is VM-side, in the two ALLOCATION intrinsics. Zero
## Bennett.jl changes. Zero changes to IRPtrOffset / VarGEP / MemoryStore.

The scout named two defects. Both dissolve once the arena RESERVATION
granularity is made to match the WRITE granularity the front-end already emits,
and the GenericMemory allocation materialises the one field Julia never writes
(the data-pointer). Concretely:

1. `jl_alloc_genericmemory_unchecked` gets a dedicated
   `IntrinsicGenericMemoryAlloc` that reserves `2 (header) + nbytes (data)`
   cells and, in `forward`, writes `M[base+1] = base+2` (the data-ptr → data
   region base). Reversed for free by the existing `_ArenaAlloc` L2
   region-delete (base+1 ∈ region, absent pre-alloc → `delete!` restores).
2. `gc_alloc_obj` (`IntrinsicGCAlloc`) reservation changes from `nbytes÷8`
   (cell-granular) to `nbytes` (byte-granular), because Julia boxed-struct
   fields are byte-addressed `i8` GEPs.
3. `malloc`/`calloc`/`realloc` (the C tier) stay `nbytes÷8`. `IRPtrOffset`
   (`÷ ew_bytes`) and `VarGEP` (stride 1) are UNTOUCHED — they already produce
   the correct byte-granular deltas for Julia and cell-granular deltas for C.

Net: `keys[slot]` and `vals[slot]` land in disjoint backing regions, key 3
survives the value-7 write, read-back matches, getindex returns 7, run leaves
the `__unreachable__` sink. Pins (e)/(f) flip from asserting `__unreachable__`
to asserting `fdict==7` + exact reverse.

---

## GROUND TRUTH (verified this session)

### What Julia actually emits (from the `.ll` dumps)

| access | LLVM (verbatim) | extractor arm | BVM cell delta |
|---|---|---|---|
| Dict alloc | `julia.gc_alloc_obj(task, i64 64, tag)` `dereferenceable(64)` (root.ll:71) | `:gc_alloc_obj` → `IntrinsicGCAlloc` | reserves 64÷8=**8** (BUG) |
| Dict.keys field | `getelementptr inbounds i8, ptr %dict, i32 8` (root.ll:82) | i8 integer GEP, `off=8 ew=8` (instructions.jl:3247-3262) | `8÷1 = +8` (byte) |
| Dict.vals field | `getelementptr inbounds i8, ptr %dict, i32 16` (root.ll:85) | same | `+16` (byte) |
| Memory alloc | `jl_alloc_genericmemory_unchecked(ptls, i64 %164, tag)` `dereferenceable(16)`, `%164 = extractvalue smul(value_phi, 1)` (rehash!.ll:716,734) | `:jl_alloc_genericmemory_unchecked` → `IntrinsicGCAlloc` | reserves nbytes÷8, **no header write** (BUG) |
| Memory.length field | `getelementptr {i64,ptr}, ptr %mem, i32 0, i32 0` (rehash!.ll:736) | ptr_cells struct arm, `offsetof=0 ew=64` (instructions.jl:3381-3408) | `0÷8 = +0` (cell) |
| Memory.data-ptr field | `getelementptr {i64,ptr}, ptr %mem, i32 0, i32 1` (setindex!.ll:62) | ptr_cells struct arm, `offsetof=8 ew=64` | `8÷8 = +1` (cell) |
| Memory element i | `getelementptr i8, ptr %gc_loaded, i64 %memoryref_byteoffset` (setindex!.ll:78) | i8 VarGEP `ew=8` → `VarGEP stride 1` | `+byteoffset` (byte; == i for Int8) |
| data-ptr launder | `call @julia.gc_loaded(ptr %mem, ptr %memoryref_data)` (setindex!.ll:77) | `_BENIGN_CELL_DISPATCH` → `Define(dest, args[2], :add, 0)` (ingest_call.jl:229-242) | alias to loaded ptr value |

### Two decisive facts

* **`store i64 %value_phi, ptr {i64,ptr}#field0` (rehash!.ll:737)** — Julia
  DOES explicitly store the Memory **length**. So length@+0 is NOT the VM's
  responsibility; it arrives as a normal `MemoryStore`.
* **NO store to `{i64,ptr}` field 1 anywhere** — the **data-ptr** is set by the
  Julia *runtime* at alloc time and never by emitted IR. This is the single
  field the VM must materialise. (Confirms scout D-a.)

### The size argument

`%164 = extractvalue { i64, i1 } @llvm.smul.with.overflow(value_phi, elsize), 0`
= `nelems × elsize` = **DATA byte size**, NOT including the 16-byte header
(`dereferenceable(16)` is the header; the alloc arg is the data body).

### Existing self-consistency (why the suite passes today)

The C hashtable fixture (`test_c_hashtable_e2e`, `%struct.ht={ptr,ptr,i64,i64}`)
uses clang's **typed** struct GEPs → the `ptr_cells` struct arm → `offsetof÷8`
→ cell-granular (byte 8 → cell 1); `malloc(32)` → 4 cells; `arr[i]` →
`gep i64, ptr, i64 %i` with the INDEX as an element index → `VarGEP stride 1`.
Everything C is cell-granular AND consistent. Julia is the outlier: its struct
fields are **byte-granular** (`i8` GEPs) while `gc_alloc_obj` reserved
cell-granular (÷8) — the mismatch. No existing fixture mixed Julia byte-GEP
structs with multiple arena objects, so the bug never surfaced until fdict.

---

## DECISIONS

### D1 — THE CELL CONVENTION (the riskiest decision)

**Keep the existing per-GEP address rule verbatim (`IRPtrOffset` cell delta =
`offset_bytes ÷ ew_bytes`; `VarGEP` stride = 1). Make each ALLOCATION reserve
exactly the address span its object's front-end GEPs will write:**

* **C/malloc tier** (clang typed GEPs, cell-granular): reserve `nbytes ÷ 8`.
  UNCHANGED.
* **Julia boxed struct** (`gc_alloc_obj`, byte-granular `i8` field GEPs):
  reserve `nbytes` cells (byte-granular).
* **Julia GenericMemory** (`jl_alloc_genericmemory_unchecked`): reserve
  `2 (header, cell-granular) + nbytes (data, byte-granular)` cells.

**Rationale.** There is no single scalar "cell size" that is simultaneously
correct for a cell-granular `{i64,ptr}` header GEP (`÷8`) and a byte-granular
`i8` field/element GEP (`÷1`) — the front-end deliberately emits BOTH. The only
globally-true invariant is *"an object occupies exactly the byte-offset span its
own GEPs address, and objects are laid end-to-end without overlap."* We enforce
THAT, per allocation, instead of forcing one granularity. The address rule
`offset_bytes ÷ ew_bytes` is precisely "convert this GEP to the object's own
granularity", and it is already right at every site (table above). So the
convention is: **the arena reserves in the object's native write-granularity;
address arithmetic is unchanged.**

Why this keeps every existing fixture byte-identical: the address RULE does not
change, only the malloc-vs-gc_alloc_obj-vs-genericmemory reservation COUNT,
and only the two Julia arms move (malloc stays ÷8). The C tier — the only tier
with a large passing fixture (hashtable e2e) — is bit-identical.

**Rejected alt 1 — byte-granular EVERYTHING (CELL_BYTES=1, `VarGEP` stride =
ew_bytes, `IRPtrOffset` = raw bytes).** Correct and uniform, but flips the
`VarGEP stride=1` / "stride is in cells" invariant that `array_index.jl` and
every array-floor + C-hashtable test rely on. Element i of an i64 C array would
move from cell i to cell 8i; `malloc(32)` from 4 cells to 32. Enormous blast
radius on the ONE tier that has real coverage. Rejected: maximises risk on the
proven path to fix the unproven one.

**Rejected alt 2 — cell-granular EVERYTHING; teach the front-end to divide
Julia `i8` struct-field offsets by 8.** Requires the extractor to distinguish a
struct-field `i8` GEP (divide) from a `Memory{Int8}` element `i8` GEP (don't
divide) — structurally identical in opaque-pointer IR except addrspace(11) vs
addrspace(13). Fragile front-end heuristic, cross-repo change, and it still
can't make a Memory{Int8} of N elements fit in N÷8 cells (the VM gives each
element its own cell). Rejected: pushes complexity into the wrong repo and does
not actually solve the element-per-cell reservation.

**Rejected alt 3 — one uniform `2+nbytes` for BOTH Julia arms.** gc_alloc_obj
has no header, so `+2` would waste two cells and, worse, shift every Dict field
by +2, breaking the `Dict+8=keys` chain. Rejected.

### D2 — THE GENERICMEMORY MODEL

`jl_alloc_genericmemory_unchecked(ptls, nbytes, typ)` materialises a
**2-cell header + nbytes-cell data region** in ONE arena allocation:

```
cell base+0 : length      (written later by Julia's explicit store, rehash!.ll:737)
cell base+1 : data-ptr    (written by the alloc forward  →  = base+2)
cell base+2 : element 0   ┐
cell base+3 : element 1   ├ data region, byte-granular, [base+2, base+2+nbytes)
   ...                    ┘   (Int8 ⇒ one cell/element; wider ⇒ every elsize-th used)
```

* **nbytes semantics**: the smul product `nelems × elsize` (DATA bytes,
  header-exclusive). Verified rehash!.ll:716,734. Reservation = `2 + nbytes`.
* **data-ptr value = base + 2** (the data region base). Element access is
  `gc_loaded(data-ptr) + byteoffset` = `(base+2) + byteoffset`; for Int8,
  `byteoffset = i`, so element i is at `base+2+i`, inside the reservation.
* **Header write lives in `forward`** (not a separate ingest-time
  `MemoryStore`): the data-ptr VALUE (`base+2`) is a runtime allocation address
  unknown at ingest, so it cannot be a static `MemoryStore` operand. This
  mirrors native Julia, where the *runtime* sets `mem.ptr`. It is the
  `IntrinsicCalloc` precedent generalised — calloc's forward "produces" zeroed
  cells (absent=0); this forward produces one concrete header cell.
* **Length is NOT written by the alloc.** Julia's explicit
  `store i64 <len>, {i64,ptr}#0` (rehash!.ll:737) owns length@+0, and it
  always precedes any length read in the closed-world flow. Writing a
  best-effort length here would require `nelems` (we only have `nbytes`;
  `length = nbytes` is right for Int8 but a knowingly-wrong value for wider
  elements) and would be immediately overwritten — so per Rule 1 we do NOT
  materialise a possibly-wrong field. (See risk R2 for the guard.)

### D3 — REVERSIBILITY: header write rides the existing L2 region-delete

`IntrinsicGenericMemoryAlloc` joins the `_ArenaAlloc` union
(`intrinsics.jl:212`), inheriting `predelta_payload` (`(base, cells)`,
pre-forward) and `inverse` (unconditional `delete!` over
`[base, base+cells)`, intrinsics.jl:244-252) VERBATIM. The forward's extra
`M[base+1] = base+2` needs **no new predelta and no new inverse**: `base+1 ∈
[base, base+cells)` and was absent pre-alloc (the disjoint-window
unconditional-delete lemma, `alloca.jl`), so the region-delete restores it to
absent. Round-trip: `arena_top 0→…→0`, memory `{}`, history empty.

`unstep!` path: L2. Wire `is_injective(::Type{IntrinsicGenericMemoryAlloc}) =
false` (Injective.jl, beside :578) and `is_l2_capable(...) = true` (delta.jl,
beside :608) — same rows as `IntrinsicGCAlloc`. No `make_delta` (the
`_ArenaAlloc` `predelta_payload` is the non-`nothing` capture).

### D4 — SINGLETON INTERACTION (Q3): no change needed; note the reconciliation

The empty-Memory singleton stays 16 zeroed byte-cells at `GLOBAL_BASE`
(test_jlglobal_singleton (a): `length(globals.cells)==16`, all 0). It is used
ONLY on the `nelems==0` (`emptymem`) path — the initial empty `Dict{Int8,Int8}()`
whose slots/keys/vals point at it before the first `d[a]=b` triggers rehash!
to allocate real Memories. Because length@+0 == 0, no element access ever
occurs through the singleton, so its data-ptr@+1 == 0 is harmless. The 16-cell
byte-granular seeding and the front-end's cell-granular `+1` data-ptr read are
reconcilable ONLY because everything is zero + empty; a hypothetical non-empty
singleton would need the D2 layout. **Action: doc-only** — annotate the
singleton comment (`memory_floor.jl:255-260`) that the meaningful header cells
are `+0` (length) / `+1` (data-ptr) under the D2 cell layout, with `+2..+15`
inert zero padding. No behavioural change; (a)-(d) stay green.

### D5 — FAIL-LOUD COMPLETENESS (Q6)

Still-unmodelled, each an explicit loud reject (Rule 1):

* **Wide-element Memory reservation coincidence** — `nbytes` reservation is
  correct for ALL element sizes (data span = `nelems×elsize = nbytes`), so no
  reject needed here; but see R1 for the byteoffset==index coincidence that IS
  Int8-specific downstream.
* **Non-bitstype / boxed elements** (`Memory{String}`, `Memory{Any}`) — the
  element is a pointer requiring GC tracing; out of scope. The data-ptr model
  handles the header but boxed element stores are a distinct wall — keep the
  existing extractor/ingest rejects; add a genericmemory-specific note.
* **`realloc` of a GenericMemory** (Dict growth beyond capacity via a second
  `jl_alloc_genericmemory` + copy loop) — the alloc itself is fine; the
  rehash-grow COPY loop is the predicted next wall (Q7), not silently wrong.
* **`free`/GC of a Memory** — no-op (arena leaks), unchanged.

### D6 — INGEST DISPATCH

`ingest_call.jl:64-72`: `:jl_alloc_genericmemory_unchecked` arm now returns
`IntrinsicGenericMemoryAlloc(inst.dest, _lower_operand(a[2]),
_lower_operand(a[3]))` (drop `a[1]=ptls`; `a[2]=nbytes`; `a[3]=tag` metadata).
`:gc_alloc_obj` arm (56-63) UNCHANGED (still `IntrinsicGCAlloc`); only that
struct's `_alloc_cells` changes granularity. `_HEAP_DISPATCH` (153-161) keeps
both callee keys.

---

## MEMORY-LAYOUT CONTRACT (the fdict run, exact cells)

`ARENA_BASE = 2^40`. `d=Dict{Int8,Int8}(); d[3]=7; d[3]`. Assume slot index 13
(scout's observed hash slot) and grow-to-16 (`nbytes=16` for each Memory).

```
 Dict           gc_alloc_obj(64)          base D = 2^40+0    reserve 64  → arena_top 0→64
   D+0  slots-field   = S                 (ptr to slots Memory)
   D+8  keys-field    = K
   D+16 vals-field    = V
   D+24 ndel  D+32 count  D+40 age  D+48 idxfloor  D+56 maxprobe   (i64 fields, byte-granular)

 slots Memory   genericmemory(16)         base S = 2^40+64   reserve 2+16=18 → arena_top 64→82
   S+0  length   = 16          (Julia store)
   S+1  data-ptr = S+2         (ALLOC forward writes this)
   S+2 .. S+17   slot bytes    (slots[13] @ S+2+13 = S+15)

 keys Memory    genericmemory(16)         base K = 2^40+82   reserve 18 → arena_top 82→100
   K+0  length   = 16
   K+1  data-ptr = K+2 = 2^40+84
   K+2 .. K+17   key bytes     (keys[13]  @ K+2+13 = 2^40+97  ⇐ holds 3)

 vals Memory    genericmemory(16)         base V = 2^40+100  reserve 18 → arena_top 100→118
   V+0  length   = 16
   V+1  data-ptr = V+2 = 2^40+102
   V+2 .. V+17   val bytes     (vals[13]  @ V+2+13 = 2^40+115 ⇐ holds 7)
```

`keys[13] = 2^40+97 ≠ vals[13] = 2^40+115` (DISJOINT — the bug's cell 13
collapse is gone). setindex! writes key 3 @ 2^40+97 then value 7 @ 2^40+115.
getindex read-back: `keys[13]` @ 2^40+97 = 3 == search-key 3 → FOUND → returns
`vals[13]` @ 2^40+115 = 7. **fdict(3,7) = 7.** Every object's written cells lie
inside its reservation; reservations are end-to-end disjoint.

Contrast the BROKEN run (all data-ptrs absent=0 → keys/vals/slots share cell
13): value 7 overwrote key 3, read-back 7≠3, not-found, `__unreachable__`.

---

## EXACT TOUCH LIST (file:line, verified)

### BennettVM.jl (all changes here)

1. **`src/ir/intrinsics.jl`**
   * `:128-139` — add sibling `_byte_cells(nbytes)` helper (non-negative guard;
     returns `nbytes`) beside `_cell_count`. Doc the C(÷8)-vs-Julia(byte) split.
   * `:194-211` — change `_alloc_cells(::IntrinsicGCAlloc)` from
     `_cell_count(...)` to `_byte_cells(...)` (byte-granular Julia struct).
   * `:212` — add `IntrinsicGenericMemoryAlloc` to the `_ArenaAlloc` union.
   * **new struct** `IntrinsicGenericMemoryAlloc(dest, nbytes_operand,
     type_tag)` + `const _HEADER_CELLS = Int64(2)` +
     `_alloc_cells(::IntrinsicGenericMemoryAlloc) = _HEADER_CELLS +
     _byte_cells(_resolve(nbytes))` + a SPECIALISED
     `forward(::IntrinsicGenericMemoryAlloc, s)` (bump, set pointer, then
     `s.memory[base+1] = base + _HEADER_CELLS`). `predelta_payload` / `inverse`
     inherited via the union (NO new methods). ~35 LOC — if `intrinsics.jl`
     tops the ~200 Rule-10 cap, split the GenericMemory struct into
     `src/ir/intrinsics_genericmemory.jl` included right after.
2. **`src/ir/ingest_call.jl:64-72`** — emit `IntrinsicGenericMemoryAlloc`
   (was `IntrinsicGCAlloc`). One-line struct swap; args unchanged.
3. **`src/history/Injective.jl` (~:578)** —
   `is_injective(::Type{IntrinsicGenericMemoryAlloc}) = false`.
4. **`src/history/delta.jl` (~:608)** —
   `is_l2_capable(::Type{IntrinsicGenericMemoryAlloc}) = true`.
5. **`src/ir/memory_floor.jl:255-260`** — doc-only singleton annotation (D4).
6. **`src/analysis/liveness.jl`** — verify `compute_must_cache` L2-selects the
   new intrinsic (inherited via union; check, no change expected).

### Bennett.jl

**NONE.** The extractor already emits the correct byte-granular struct/element
GEPs and cell-granular header GEPs (table above). This is the design's key
claim: the front-end is already self-consistent per object; only the VM's
reservation was wrong. If review disputes this, the fallback is Rejected-alt-2
(front-end divide), but the `.ll` evidence supports zero front-end change.

**Diff estimate**: ~60 LOC added / ~4 changed in BennettVM (1 new struct + 1
forward + 1 helper + 2 one-line history rows + 1 ingest swap + doc); 0 in
Bennett.jl.

---

## RED-GREEN TEST PLAN

### New unit tests (`test/test_9n3y_genericmemory_alloc.jl`, new)

1. **header materialisation** — hand-build `IntrinsicGenericMemoryAlloc(:m, 16,
   0)`; `forward`; assert `locals[:m]==ARENA_BASE`, `memory[ARENA_BASE+1] ==
   ARENA_BASE+2` (data-ptr), `arena_top == 18`. Mutation-proof: perturb
   `base+_HEADER_CELLS` → `base` and confirm RED (element aliases header).
2. **round-trip to absent** — forward then `inverse`; assert `memory=={}`,
   `arena_top==0`, `:m` gone. Mutation-proof: drop the region-delete over
   `base+1` (shrink cells by 1) → RED via phantom `{base+1 => base+2}`.
3. **per-step inverse** — `per_step_inverse_check` over alloc + a store into
   `data-ptr+i` + a load; assert exact reverse.
4. **disjointness** — two `genericmemory(16)` allocs get windows
   `[B,B+18)`,`[B+18,B+36)`; store into each data region; round-trip both.
5. **gc_alloc_obj byte-granular** — `IntrinsicGCAlloc(:d, 64, 0)`;
   `arena_top==64` (was 8); store into field `d+40`; round-trip.
6. **fail-loud** — negative nbytes → `@test_throws`.

### Wall-pin flips (the deliverable's headline)

* **`test_jlglobal_singleton.jl` (e)** (`:146-179`): the two asserts
  `@test !occursin("jl_global", rmsg)` (stays) and
  `@test occursin("__unreachable__", rmsg)` (line 179) **FLIP** to a full
  round-trip: `run!` halts with `result[:...] == 7`, `isempty(rs.history)`,
  `rs.current == init` (exact reverse), and NO throw. Rewrite the `(e)` body to
  the fdict==7 + reverse shape of `(a)`.
* **`test_x3t0_multikey_return.jl` (f)** (`:309-349`): `@test
  occursin("__unreachable__", rmsg)` (line 349) **FLIPS** identically to
  `fdict(3,7)==7` + exact reverse.
* Subtests (a)-(d) of BOTH files: UNCHANGED (green) — singleton seeding,
  fail-loud matrices, sret guards are all orthogonal.

### Regression (must stay byte-identical)

`test_c_hashtable_e2e.jl`, `test_arena_roundtrip.jl`,
`test_multi_dynalloca.jl`, `test_memory_floor_cll.jl` — all C/malloc tier,
untouched reservation rule → byte-identical.

---

## PER-FIXTURE BLAST-RADIUS TABLE

| fixture | tier | effect | stays byte-identical? |
|---|---|---|---|
| `test_c_hashtable_e2e.jl` | C/malloc | none (÷8 unchanged, clang typed GEPs) | **YES** |
| `test_arena_roundtrip.jl` | malloc | none | **YES** |
| `test_multi_dynalloca.jl` | alloca/malloc | none | **YES** |
| `test_memory_floor_cll.jl` | C store/load | none | **YES** |
| `test_416r12_jl_alloc_genericmemory.jl` | Julia Memory | struct type `IntrinsicGCAlloc`→`IntrinsicGenericMemoryAlloc`, reserve `2+nbytes`, header write | **NO — update asserts (RED→GREEN); round-trip semantics preserved** |
| `test_gc_alloc_obj_ingest.jl` | Julia struct | reserve `nbytes÷8`→`nbytes`; `arena_top`/address asserts flip | **NO — update address/arena_top asserts; round-trip preserved** |
| `test_6bu3_struct_agg_ingest.jl` | Julia struct | same as above if it pins addresses | **check; likely address-assert update only** |
| `test_igr3_gc_loaded_ingest.jl` | gc_loaded | none (gc_loaded lowering unchanged) | **likely YES** (verify no arena_top pin) |
| `test_jlglobal_singleton.jl` (a-d) | singleton | none | **YES** |
| `test_jlglobal_singleton.jl` (e) | fdict e2e | wall flips to fdict==7 | **NO — intended flip** |
| `test_x3t0_multikey_return.jl` (f) | fdict e2e | wall flips to fdict==7 | **NO — intended flip** |

---

## TOP-3 SILENT-MISCOMPILE RISKS + KILLING GUARDS

* **R1 — byteoffset==element-index coincidence (Int8 only).** The whole data
  region is byte-granular and `Memory{Int8}` element i lands at `data-ptr+i`
  ONLY because `elsize==1`. A `Memory{Int64}` element i lands at `data-ptr+8i`
  (byteoffset `i×8`), one value per 8-cell stride — CORRECT under `nbytes`
  reservation, BUT if any downstream code assumed "one cell per element" it
  would read cell `data-ptr+i` and get garbage between stores. **Killing
  guard**: a test with a `Memory{Int16}`/`Memory{Int64}` round-trip (element i
  at `data-ptr + i×elsize`) asserting non-aliasing; and a Rule-1 assert in the
  genericmemory forward doc that reservation is byte-span, not element-count.
* **R2 — length read before Julia's store.** The alloc does NOT write length;
  if a control path reads `Memory.length` before rehash!'s explicit store, it
  reads absent=0 and silently under-iterates (no crash). **Killing guard**: an
  ingest-time assertion is impossible (dynamic), so add a genericmemory
  regression asserting the FIRST post-alloc access to `{i64,ptr}#0` in the
  fdict trace is a STORE not a LOAD (pin the rehash! order); and consider a
  debug-mode "length cell absent at read" trap paralleling the read-window trap.
* **R3 — reservation shorter than written span (off-by-header).** If
  `_HEADER_CELLS` and the data-ptr value disagree (e.g. header 2 cells but
  data-ptr set to `base+1`), element 0 overwrites the data-ptr field →
  self-corruption that may still round-trip (region-delete cleans both) and so
  pass a naive round-trip test while miscomputing. **Killing guard**: test 1's
  explicit `memory[base+1]==base+2` assertion + an oracle-VALUE check (fdict==7),
  not just round-trip — value correctness catches the alias that reversibility
  hides.

---

## NEXT WALL PREDICTION (Q7)

`fdict(3,7)` (single insert into a fresh Dict, grow-to-16, zero rehash
iterations) will return 7 and round-trip. The next wall is **Dict growth /
rehash COPY loop**: a fixture inserting enough keys to force a *second*
`jl_alloc_genericmemory` + the rehash! loop that copies old→new Memory
(`callee_rehash!.ll` has the loop body). That exercises (a) a runtime-trip-count
loop over element traffic, (b) a second-generation Memory whose old region is
leaked (arena no-free), and (c) possibly a `memcpy`/element-copy between two
gc_loaded data pointers. Secondary candidate: **wider-element Memory** (a
`Dict{Int8,Int64}` value Memory) exercising R1's `elsize>1` stride for real.
File both as successor beads.
