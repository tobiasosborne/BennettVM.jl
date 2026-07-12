# Design B — `jl_global#NNN` singleton materialization (bennettvm-416r.13 + rest of 416r.4)

> PROPOSER B. Independent design. Clears the FIRST RUNTIME wall of the fdict
> closed-world chain: `run!` KeyError on `Symbol("jl_global#NNN")` in
> `Define.forward` at Dict construction. Probe-grounded this session
> (Julia 1.12.x, WSL2); all line refs verified against the trees on disk.

---

## 0. One-paragraph thesis

The `jl_global#NNN` interned empty-`GenericMemory` singletons are **data
pointers with a zeroed 16-byte header**, not type-tags. Treat them exactly like
a C `const` array whose data we cannot read: the **front-end** (Bennett.jl)
recognizes them by name, materializes a **zeroed header** into
`ParsedIR.globals`, and **aliases every drifting load-result SSA name to the
stable global-variable name**; the **VM** (BennettVM) owns the deterministic
address by seeding that header into the read-only `GlobalROM` segment
(`>= GLOBAL_BASE = 2^48`) and prepending the same `Define(name, base)` binding
the C-globals path already uses. The VM NEVER reads the non-deterministic
`inttoptr` JIT address — the front-end provides only a zero header + a name;
the VM assigns the base. This reuses the entire 2026-07-06 C-globals landing
(`_global_segment` / `GlobalROM` / prepended `Define`) and forces the one piece
that landing deferred — **module-wide (multi-function) const-global segments**
— which simultaneously unblocks bead `bennettvm-h6c3`.

---

## 1. Decisions

### D1 — The singleton is materialized in **both** layers, split by role. Front-end owns *recognition + zero data*; VM owns *the deterministic address + write/read protection*.

**Rationale.** The "never read the JIT address" guarantee must live where the
address is *assigned* — the VM's `_global_segment`, which mints
`GLOBAL_BASE + offset` and never touches the initializer. The front-end cannot
own the address without baking a VM-layout constant into the IR (which the
current C-globals contract deliberately avoids: the front-end ships *data +
name*, the VM assigns *base*). So recognition (name → "this is an opaque
singleton") and the zero payload belong to the front-end; the base, the
read-only ROM, and the fail-loud store/read guards belong to the VM. This is
the exact division the C `static const uint8_t rom[8]` path already uses;
we are adding one more *producer* of `ParsedIR.globals` entries and one more
*consumer-side reference shape* (`IRPtrOffset`/`IRStore` base, not just
`IRVarGEP`).

**Rejected alternative — VM binds dangling names to fresh zeroed segments on
its own.** The VM would have to invent a name→segment mapping for names it
never saw declared, guess the header size, and re-derive canonicalization it
has no LLVM context for. It also can't distinguish a genuinely-missing SSA
(a real extractor bug — must stay fail-loud, CLAUDE.md Rule 1) from an
intentionally-dropped singleton load. Keeping recognition in the front-end
preserves the VM's "every unbound name is a bug" invariant.

**Rejected alternative — front-end lowers the load to a constant-identity
`IRBinOp` (the type-tag trick) carrying a magic `SINGLETON_BASE` address.**
This bakes a shared VM-layout constant into front-end IR (breaks the clean
"front-end never emits VM addresses" separation the C path maintains), and a
raw small id can't back a header the VM read-only-protects. Rejected.

### D2 — Front-end recognizes `^jl_global#\d+$` **opaque-pointer** globals; readable-data globals can never be mis-seeded because they take the existing real-data arms first.

The recognizer is a sibling of `_is_type_tag_global_name`
(`src/extract/constexpr.jl:135`):

```julia
_is_singleton_data_global_name(s) = occursin(r"^jl_global#\d+$", s)
```

- `^…$` anchors exclude the `@"jl_global#NNN.jit"` alias (never in
  `LLVM.globals`, but belt-and-suspenders) and the drifting *load-result*
  names like `jl_global#233831` (those are SSA names, never module globals).
- Dispatch is **by name prefix**, the pattern already in force
  (`+` → type-tag; `jl_global#` → singleton-data). This is acceptable because
  the two subsets are *byte-identical in LLVM shape* and only the name differs
  (census Q2b) — name is the only available discriminator, and Julia's naming
  convention is stable in *structure* (drift is only in the `#N` counter, which
  the regex tolerates).
- **The empty-vs-non-empty guard is structural, not name-based.** The new arm
  lives at the **`else` fall-through** of `_extract_const_globals`
  (`module_walk.jl:1030`), *after* the `ConstantDataArray` / `ConstantStruct` /
  `ConstantAggregateZero` / `ConstantInt` arms. A global with actually-readable
  data (a non-empty `const` array captured by a closure) matches one of those
  arms and is materialized with its **real** bytes — it can never reach the
  singleton arm. Only a global whose initializer is the **opaque
  `constant ptr @X.jit`** (readable arms all miss → `else`) is seeded as a zero
  header. Per the Julia-runtime invariant, the ONLY opaque-inttoptr
  `jl_global#NNN` constant-ptr singletons on the closed-world Dict path are the
  shared **empty** `GenericMemory` instances (census Q3). See D6 for the
  residual-risk guard.

**Fail-loud story for a future third kind (design Q2).** Under `ptr_cells`, a
`load ptr, ptr @GlobalVariable` whose name matches **neither** recognizer and
whose result type is a pointer currently hits the silent `return nothing` drop
(`instructions.jl:3565`) → dangling SSA → a late KeyError. We replace that
silent drop, **scoped to `ptr_cells && ptr isa GlobalVariable && rt isa
PointerType`**, with an explicit `_ir_error` listing the two recognized kinds
(`+Type#N`, `jl_global#N`). A genuinely new JIT-global kind then fails at the
*load site* with a precise breadcrumb, not as a downstream dangling operand.

### D3 — Front-end **aliases** every singleton load-result SSA name to the stable **global-variable** name; it does NOT emit an instruction that defines the load result.

This is the load-bearing wrinkle B found by probe: the vals singleton is loaded
**twice**, and the two load results get *distinct* drifting names
(`jl_global#23383`, `jl_global#233831`), while the global variable is the single
`@"jl_global#23383"`. Both load results are used downstream (verified). If we
only rely on the "first load result name coincidentally equals the global name"
coincidence, the *second* load's uses stay unbound and the wall survives.

**Decision.** In the singleton arm of the load handler (`instructions.jl`,
immediately after the `+Type` arm at :3547), set
`names[inst.ref] = Symbol(LLVM.name(ptr))` (the stable global-variable name)
and `return nothing` (drop the load — no IRLoad/IRBinOp emitted). Because SSA
guarantees defs precede uses, every downstream `_operand(load_result, names)`
(`helpers.jl:204`) now resolves to `ssa(:jl_global#23383)` — the single
canonical name that (a) keys the `ParsedIR.globals` header entry and (b) is
bound once by the VM's prepended `Define`. All N loads of one singleton collapse
to one address ⇒ pointer identity is preserved (a hypothetical singleton==other
comparison is stable).

**Rejected alternative — register each load-result name as its own header
entry.** N loads → N zero headers → N distinct bases → the same singleton gets
different addresses, breaking pointer identity and wasting cells. Rejected.

**Rejected alternative — emit `IRVarGEP(dest, base=gname, 0)` to define the
load result explicitly.** For the first load `dest == gname` (name coincidence)
→ self-referential GEP requiring `gname` bound before itself. Aliasing via
`names` is strictly simpler and drift-immune.

### D4 — Header shape: a **zeroed 16-cell window** per singleton, keyed by the global-variable name, in `ParsedIR.globals`.

Probe: the construction GEP is `IRPtrOffset(base, off=8, elem_width=8-bits)`
⇒ `Define(dest, base, :add, 8)` — the data-ptr field lands at **cell base+8**
(byte GEP, `ew_bytes=1`). `rehash!` reads the length via a `{i64,ptr}` struct
GEP field 0 ⇒ **cell base+0**. Only `length@cell0 == 0` is load-bearing for
control flow; the data-ptr@cell8 read is consumed solely by a compile-time
`memset(len=0)` (inert, census Q3). We seed **cells [0..15] = 0** (one entry
`globals[gname] = (zeros(UInt64, 16), 8)`) so that (a) length@0 and data-ptr@8
are both *seeded* zeros (not absent), and (b) the VM read-window trap (D5) has a
concrete bound. 16 is a deliberate small over-provision covering both the i8
byte-GEP offsets and the wider `{i64,ptr}` field offsets.

### D5 — VM read/write protection: **store to any `>= GLOBAL_BASE` fails loud (already true); load of a `>= GLOBAL_BASE` cell NOT in the ROM fails loud (NEW).**

- **Write-protect (already implemented):** `MemoryStore.forward`
  (`memory_floor.jl:220`) already errors on `a >= GLOBAL_BASE`. The IRStore
  that stores the singleton *pointer value* into a Dict field writes the *field*
  cell (arena/gc-alloc, `< GLOBAL_BASE`) — never the singleton — so it does not
  trip this; a bogus store *onto* the singleton address would, killing the
  "write-to-singleton is a miscompile" risk for free.
- **Read-window trap (NEW):** `MemoryLoad.forward` (`memory_floor.jl:251`)
  currently reads `get(s.globals.cells, a, 0)` for `a >= GLOBAL_BASE` — a read
  of an **unseeded** global cell silently returns 0. Change to fail loud when
  `a >= GLOBAL_BASE && !haskey(s.globals.cells, a)`. This bounds the readable
  window: a data read *past* a singleton's 16-cell header (i.e. a non-empty
  singleton whose contents we mis-seeded as empty) traps instead of reading a
  phantom 0. **Safe against the existing `test_global_array_vm.jl`:** `gtest(i)
  = rom[i&7]` reads are always in `[0,7]` ⊂ the seeded `rom[8]`; the 16 KB NES
  case reads `[0,16383]` ⊂ the seeded array — no in-bounds read becomes a trap.
  An out-of-bounds global read is UB and *should* trap (Rule 1).

### D6 — Residual empty-vs-non-empty risk is bounded by the **closed-world contract + the opaque-initializer gate (D2)**; documented, not hand-waved.

We seed `length=0`. If a *non-empty* interned singleton were referenced and its
`length@0` read as our fake 0, a copy loop would run 0 trips and silently drop
elements — a miscompile the read-window trap (D5) cannot catch (the length read
is *in* the window). Two structural facts bound this to zero on the target
class:

1. **The opaque-initializer gate (D2):** any global with *readable* data takes a
   real-data arm and is materialized with true bytes; only opaque-`inttoptr`
   constant-ptr singletons reach the zero-header arm.
2. **The Julia-runtime invariant:** `Dict{K,V}()` shares the *empty*
   `GenericMemory` singletons via these interned constant-ptr globals; a
   non-empty backing is never an interned `jl_global#NNN` constant-ptr (it is
   heap-allocated fresh via `jl_alloc_genericmemory_unchecked`, census Q3).

Front-end tripwire (fail-loud, Rule 1): the singleton arm asserts the
initializer is opaque (`LLVM.initializer` errors, or is a `ptr`-typed constant),
i.e. is genuinely one of the shapes the readable arms rejected. A future opaque
singleton that is *read as scalar data* (not as an opaque pointer stored into a
field / GEP+memset) is caught by the D5 window trap the moment it dereferences
past cell 15. The length-only-read residual is documented against the contract.

### D7 — Multi-function/module-wide segments: **unify into ONE module ROM with a running base cursor; delete the `ingest_multi.jl:204` fail-loud guard.** This subsumes bead `bennettvm-h6c3`.

The wall's set is 4 functions; only the **root** references singletons (probe:
`fdict_d1b` refs `jl_global#23382/#23383/#233831`; the other 3 PIRs reference
none). But the moment the root gets ROM cells, the multi-function guard
(`ingest_multi.jl:204`, "references a const global … not yet implemented …
fail loud") fires and blocks `lower_vm(set)`. So module-wide segments are
mandatory, not optional.

**Design.** Segments stay **per-function-disjoint** (a function's globals are
local to it — no cross-function global sharing is needed or attempted), unified
into ONE `GlobalROM` by a monotone module cursor:

- `_lower_parsed_ir` gains `global_base_offset::Int64 = 0`, threaded into
  `_global_segment` so its bases are `GLOBAL_BASE + global_base_offset +
  local_offset`.
- `ingest_multi.jl` maintains `global_cursor::Int64 = 0`; per function it calls
  `_lower_parsed_ir(...; global_base_offset = global_cursor)`, then advances
  `global_cursor += length(prog.globals.cells)` and merges `prog.globals.cells`
  into a module dict. Disjoint by construction (each function's cells occupy a
  fresh contiguous window).
- The merged ROM is passed to the final merged `VMProgram` constructor
  (currently `ingest_multi.jl:220` omits `globals`, defaulting empty — this is
  the "merged VMProgram drops per-function globals" gap the old guard warned
  about; we close it).

**h6c3 relationship: SUBSUMED.** h6c3 ("multi-function const-global segments for
the NES ROM track") is exactly this module-wide-ROM capability. This design
implements it (per-function disjoint windows + merged ROM). Close h6c3 as
fixed-by-this-bead, or re-point it at the NES-ROM *e2e fixture* if that is a
separate acceptance gate.

**Rejected alternative — keep the guard, single-function-only, and special-case
the entry function.** The set is inherently multi-function (call-forwarded
`setindex!`/`rehash!`); there is no single-function form of bare `fdict`.
Rejected.

### D8 — `_global_segment` reference-detection extends from **`IRVarGEP` base only** to **any `SSAOperand` naming a `parsed.globals` key.**

Probe: the singleton is referenced as `IRPtrOffset.base` and `IRStore.val`,
never `IRVarGEP.base`. The current `_global_segment` (`ingest.jl:234`) only
seeds+Defines globals used as an `IRVarGEP` base, so it would miss the singleton
entirely (no Define → name unbound → wall survives). Extend the scan to walk
*all* instruction operands (via existing operand-iteration reflection) and mark
any global whose name appears as an `SSAOperand`. This keeps the existing
behavior for `test_global_array_vm.jl` (`:rom` is an `IRVarGEP` base → still an
`SSAOperand` → still seeded) and *excludes* the `_j_const#N` memcpy-source
literals (they are consumed by the memcpy-global-src arm, never as an
`SSAOperand` — verified: they do not appear in the SSA operand stream).

---

## 2. ParsedIR-level contract (concrete)

**No new fields, no new instruction shapes.** The change is entirely in the
*population* of the existing `ParsedIR.globals::Dict{Symbol,Tuple{Vector{UInt64},
Int}}` field and in `names` aliasing during extraction:

- New `globals` entries: `globals[Symbol("jl_global#NNN")] =
  (zeros(UInt64, 16), 8)` — one per distinct singleton global variable, keyed by
  the stable global-variable name. Same `(data, elem_width)` shape every other
  `_extract_const_globals` arm emits; the VM already knows how to seed it.
- `names` aliasing: every singleton *load* instruction sets
  `names[load.ref] = Symbol(LLVM.name(ptr))`; the load emits no IRInst. Downstream
  `IRPtrOffset`/`IRStore` operands therefore carry `SSAOperand(:jl_global#NNN)`
  (the canonical name), which the VM binds via the prepended `Define`.
- The `IRPtrOffset` / `IRStore` shapes are **unchanged** — they already carry
  `SSAOperand(:jl_global#NNN)` today (that is exactly what dangles). We are
  making that name *resolvable*, not changing the instructions.

VM side, `VMProgram.globals::GlobalROM` (existing field, `VMProgram.jl:168`)
now carries the **merged module-wide** ROM for the multi-function path (today
it is left empty there). No struct change.

---

## 3. Exact touch list (verified line refs)

### Bennett.jl (front-end)

| file | anchor | change |
|---|---|---|
| `src/extract/constexpr.jl` | :135 `_is_type_tag_global_name` | add sibling `_is_singleton_data_global_name(s) = occursin(r"^jl_global#\d+$", s)` |
| `src/extract/module_walk.jl` | :150 `globals, … = _extract_const_globals(mod)` | pass `ptr_cells`: `_extract_const_globals(mod, ptr_cells)` |
| `src/extract/module_walk.jl` | :918 `function _extract_const_globals(mod)` + :1030 `else` | add `ptr_cells` param; add an arm in the `else` fall-through: `if ptr_cells && _is_singleton_data_global_name(LLVM.name(g)) && <initializer opaque>`: `out[Symbol(LLVM.name(g))] = (zeros(UInt64,16), 8)` |
| `src/extract/instructions.jl` | after :3547 (post `+Type` arm), before :3549 `haskey(names, ptr.ref)` | singleton arm: `if ptr_cells && ptr isa LLVM.GlobalVariable && _is_singleton_data_global_name(LLVM.name(ptr))`: `names[inst.ref] = Symbol(LLVM.name(ptr)); return nothing` |
| `src/extract/instructions.jl` | :3561-3565 (the `ptr_cells && rt isa PointerType` block + `return nothing`) | replace the silent `return nothing` for an unrecognized `GlobalVariable` ptr-load with `_ir_error(inst, "…unrecognized JIT global kind…")` (scoped: `ptr isa GlobalVariable && rt isa PointerType`) |

### BennettVM.jl (VM)

| file | anchor | change |
|---|---|---|
| `src/ir/ingest.jl` | :226 `function _global_segment(parsed)` | add `base_offset::Int64 = 0`; base = `GLOBAL_BASE + base_offset + offset`; **extend reference scan** from `IRVarGEP` base (:234) to any `SSAOperand` naming a `parsed.globals` key |
| `src/ir/ingest.jl` | :274 `function _lower_parsed_ir(…)` + :420 `_global_segment(parsed)` | add kwarg `global_base_offset::Int64 = 0`; pass to `_global_segment(parsed; base_offset = global_base_offset)` |
| `src/ir/ingest_multi.jl` | :191-213 the per-function loop + the :204 guard | delete the `isempty(prog.globals.cells) \|\| error(...)` guard; add `global_cursor` accumulator + `global_base_offset` pass + merge `prog.globals.cells` into `merged_globals` |
| `src/ir/ingest_multi.jl` | :220 final `VMProgram(...)` | pass `globals = GlobalROM(merged_globals)` |
| `src/ir/memory_floor.jl` | :251 `MemoryLoad.forward` global read | add read-window trap: `a >= GLOBAL_BASE && !haskey(s.globals.cells, a)` → `error(…read of unmodeled const-global address…)` |

No change needed to `IState.jl` `GlobalROM` (the `cells::Dict` already models
seeded-vs-absent via `haskey`); `MemoryStore` write-protect already present.

---

## 4. RED-GREEN test plan

### 4.1 The wall-pin flip (existing test — MUST change)

`test/test_x3t0_multikey_return.jl` testset **(f)** (:308-338) currently asserts
`rthrew && occursin("jl_global", rmsg)`. After the fix the jl_global KeyError is
gone. **Flip (f)** to assert progress to the NEXT wall (D6/§5 prediction): the
`run!` either completes or throws a *different* message; assert
`!occursin("jl_global", rmsg)` and pin the new wall's substring (the
`jl_alloc_genericmemory_unchecked` / rehash allocation wall — see §6). If `run!`
COMPLETES, assert the round-trip (`unrun!` → initial state) and the returned
value `== b` (the oracle: `fdict(3,7) = 7`). Keep testsets (a)-(e) green
(hand-built modules — untouched by these changes).

### 4.2 New RED-GREEN unit tests (BennettVM)

`test/test_416r13_jlglobal_singleton.jl` (new):

1. **Hand-built singleton round-trip** — a 1-function `ParsedIR` whose
   `.globals[:jl_global#7] = (zeros(UInt64,16),8)`, an `IRPtrOffset(base=
   :jl_global#7, off=8, ew=8)` + an `IRStore` of the singleton into a stack cell
   + a `MemoryLoad` of length@0. Assert: `lower_vm` prepends
   `Define(:jl_global#7, GLOBAL_BASE)`; `run!` reads length 0; `unrun!` → initial
   state, history empty. **Mutation-proof:** drop the prepend → RED (KeyError).
2. **Multi-function disjoint segments** — 2 functions each with one singleton;
   assert distinct bases (`GLOBAL_BASE`, `GLOBAL_BASE+16`), one merged ROM,
   both round-trip. **Mutation-proof:** force both `base_offset=0` → RED
   (aliased cells / wrong value).
3. **Write-to-singleton fails loud** — `IRStore(dest=:jl_global#7-derived-ptr,
   …)` resolving `>= GLOBAL_BASE` → `@test_throws ErrorException` (D5 store
   guard). Assert message mentions `GLOBAL_BASE`.
4. **Non-zero read past header fails loud** — `MemoryLoad` at `GLOBAL_BASE+99`
   (outside the 16-cell window) → `@test_throws ErrorException` (D5 read-window
   trap). Guards against silent phantom-0.
5. **Number-drift immunity** — extract `fdict` twice in one process; assert the
   VMProgram lowers both times regardless of the `#NNN` values (no test pins a
   number; assert `haskey(prog.functions, :rehash!)` etc. survive).

### 4.3 New RED-GREEN front-end test (Bennett.jl)

`test/test_jlglobal_singleton_extract.jl` (new):

6. **Load-result alias** — extract `fdict` set; assert the root PIR's
   `.globals` contains a `jl_global#…` zero-header key, and NO instruction
   carries a dangling `jl_global#…N` load-result name (every `SSAOperand`
   `jl_global*` resolves to a `.globals` key). Directly pins D3's alias.
7. **Second-kind fail-loud** — a synthetic `.ll` with a
   `load ptr, ptr @"weird_global#5"` (neither `+` nor `jl_global#`) under
   `ptr_cells` → `@test_throws` with the "unrecognized JIT global kind"
   breadcrumb (D2 fail-loud).

### 4.4 Regression guard (existing must stay green)

`test/test_global_array_vm.jl` (the C `rom[8]` / 16 KB NES ROM) MUST stay green:
verifies (a) the `base_offset=0` default keeps single-function bases identical,
(b) the read-window trap never fires on in-bounds `rom[i&7]` reads. Run it
explicitly in the RED-GREEN loop.

---

## 5. Silent-miscompile risk analysis (top 3)

1. **Non-empty singleton mis-seeded as `length=0`** (the deepest). *Guard:* the
   opaque-initializer gate (D2) — only opaque-`inttoptr` constant-ptr globals
   get the zero header; readable data takes a real-data arm with true bytes. The
   D5 read-window trap kills any *data* read past the header. Residual
   (length-only-read of a non-empty interned singleton) is bounded by the
   Julia-runtime empty-`GenericMemory`-sharing invariant (D6), documented, with
   a front-end opaque-initializer assertion.
2. **Cross-function global base collision** (module-wide merge). If two
   functions' segments overlapped, one would read the other's cells. *Guard:*
   the monotone `global_cursor` (D7) advances by exactly
   `length(prog.globals.cells)` per function → disjoint windows by construction;
   test 4.2#2 mutation-proofs it (force-collide → RED). The merged ROM is a
   plain disjoint dict union.
3. **Silent phantom-0 on an unseeded global read** (pre-existing latent bug in
   `MemoryLoad`). A read of any `>= GLOBAL_BASE` address not in the ROM returned
   0. *Guard:* the D5 read-window trap converts it to fail-loud; test 4.2#4
   pins it; `test_global_array_vm.jl` confirms no in-bounds read regresses.

---

## 6. Scope boundary + next-wall prediction

This clears the **construction** wall (`IRPtrOffset` off the keys singleton
during `Dict{Int8,Int8}()`). `run!` then proceeds into `d[a]=b` → `setindex!`
→ `rehash!`. Census Q3 shows `rehash!` (a) reads the singleton `length@0` (now
0 — handled) and (b) **allocates fresh backing via
`jl_alloc_genericmemory_unchecked`** (IRCall dests `Memory{UInt8}[]` /
`Memory{Int8}[]`). **Predicted next wall:** the VM ingest/execution of that
allocation intrinsic (does `_HEAP_DISPATCH` / the CW-D2 whitelist actually wire
`jl_alloc_genericmemory_unchecked` to an `IntrinsicMalloc`-class op with the
length taken from its arg? ADR 0021 D4 *designs* it; verify it is *implemented*),
or the element store/`ptrtoint` traffic around the freshly-allocated Memory. The
design leaves the next agent a clean extension point: singletons are now first-
class `.globals` entries and module-wide segments exist, so a `rehash!`
allocation is orthogonal (arena tier, not global tier).

---

## 7. Estimated diff size

- **Bennett.jl:** ~35-45 LOC + ~2 short docstring blocks. (recognizer ~2 LOC;
  `_extract_const_globals` arm + param ~12 LOC; load-handler alias arm ~6 LOC;
  unrecognized-kind fail-loud ~6 LOC; call-site thread ~1 LOC.)
- **BennettVM.jl:** ~40-55 LOC. (`_global_segment` offset + extended scan
  ~15 LOC; `_lower_parsed_ir` kwarg thread ~4 LOC; `ingest_multi` cursor +
  merge, minus the deleted guard ~20 LOC net; `memory_floor` read-window trap
  ~6 LOC.)
- **Tests:** ~2 new files (~140 LOC) + the (f) wall-pin flip (~15 LOC edited).

Net: two focused diffs, no new struct fields, no new instruction shapes; the
heaviest single piece is the module-wide-ROM merge (which also lands h6c3).
