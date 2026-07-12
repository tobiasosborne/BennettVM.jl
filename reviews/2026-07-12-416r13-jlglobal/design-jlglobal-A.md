# Design A — clear the `jl_global#NNN` runtime wall (fdict closed-world set)

> Proposer A, 3+1 protocol. Beads `bennettvm-416r.13` (CW-D3 remainder) +
> tail of `bennettvm-416r.4`. Grounded in `scratchpad/scout-jlglobal-census.md`
> (2026-07-12), ADR 0018/0021, and verified line refs below. No code written.

---

## 0. The wall in one paragraph (verified)

`run!` on the lowered 4-function fdict `VMProgram` throws `KeyError:
Symbol("jl_global#23405")` in `Define.forward` → `_resolve`
(`arithmetic_assignment.jl:153`). Root cause chain, all confirmed against the
census and source:

1. Front-end names the load `%"jl_global#23405" = load ptr, ptr
   @"jl_global#23405"` → `names[load.ref] = :jl_global#23405`
   (`module_walk.jl:310-311`).
2. The load matches neither the `+Type#N` type-tag arm
   (`instructions.jl:3537-3547`) nor `haskey(names, ptr.ref)` (the operand is a
   `GlobalVariable`, not an SSA), so it hits `return nothing` at
   `instructions.jl:3565` — **dropped**. `_extract_const_globals`
   (`module_walk.jl:918`) drops the `ptr`-initializer global too (no matching
   arm → final `else: continue`), so it never lands in `.globals`.
3. The name stays bound in `names`; every later use (`IRPtrOffset` base,
   `IRStore` val) resolves via `_operand` to `ssa(:jl_global#23405)` — a
   dangling operand.
4. BVM lowers `IRPtrOffset` to `Define(dest, base.name, :add, offset÷ew)`
   (`ingest_body.jl:534`); `base.name = :jl_global#23405` is never in
   `active_locals` → `KeyError` at forward.

The two live culprits are the empty-`GenericMemory` **singletons** (`#71` keys,
`#72` vals/slots) — real interned data pointers, not type-tags — stored into the
fresh `Dict`'s fields AND read at offset +8 (data-ptr, feeds a **compile-time
len-0 memset** → inert) and, downstream in `rehash!`, at offset 0 (length →
must read 0). See census Q3.

---

## 1. Design decisions

### D1 — Layer split: front-end RECOGNISES (by name, never address); VM MINTS the address + materialises the segment

**Decision.** Recognition of a `jl_global#NNN` singleton-data load happens in
**Bennett.jl** (`src/extract/instructions.jl`), mirroring the existing
`+Type#N` type-tag arm. The **deterministic pointer VALUE and the zeroed backing
segment are minted by BennettVM** (`GLOBAL_BASE + offset`), reusing the
`bennettvm-416r.4` `GlobalROM` machinery. The ParsedIR contract carries only a
*name + "this is a zeroed singleton header"* tag — never an address.

**Rationale.** The JIT address (`inttoptr (i64 <addr>)`) is visible ONLY at the
LLVM layer, so the "never depend on the non-deterministic JIT address" floor
(ADR 0021 D3) must be **enforced where that address is reachable** — the
front-end. The front-end already discharges exactly this obligation for
`+Type#N` (recognise by name, mint a dense id, never read the initializer;
`instructions.jl:3522-3547`, `constexpr.jl:123-153`). We extend that discipline;
we do not invent a second address-handling site. The VM inventing the address
(`GLOBAL_BASE+offset`, deterministic by construction — ADR 0018 §A) means no
name→address map ever crosses the repo boundary.

**Rejected alternative.** *VM binds dangling `jl_global#` names at ingest* (scan
for undefined SSA operands matching `r"jl_global#\d+"`, bind to fresh zeroed
segments). Rejected: (a) it makes the VM pattern-match Julia's naming
convention, coupling the reversible VM to a front-end idiom it should never
know; (b) it can only guess the header size and read-window from a name it
cannot interpret; (c) it conflates "front-end forgot to define a value" (a bug
we WANT to fail loud on) with "this is a modelled singleton" (legitimate).
Keeping recognition in the layer that sees the initializer preserves the
fail-loud boundary.

### D2 — Front-end emission: recognise by `jl_global#`-prefix, drop the load, record a zeroed-header tag; TIGHTEN the fall-through to fail loud

**Decision.** Add, in `constexpr.jl` beside `_is_type_tag_global_name`:

```julia
_is_singleton_data_global_name(s) = startswith(s, "jl_global#") && occursin(r"#\d+$", s)
```

Add a new arm in `instructions.jl`, **immediately after** the type-tag arm
(after line 3547), **before** the `haskey(names, ptr.ref)` block:

```julia
if ptr_cells && ptr isa LLVM.GlobalVariable && _is_singleton_data_global_name(pname)
    # Empty-GenericMemory singleton (or any interned jl_global#N data pointer).
    # NEVER read the initializer address (ADR 0021 D3 floor). Model as a 2-cell
    # (16-byte) zeroed Memory header: length@0 = 0, data-ptr@8 = POISON.
    # The load-result SSA name (already bound in `names`) is materialised by the
    # VM's GLOBAL_BASE Define-prepend; the load itself produces no IRInst.
    push!(singleton_globals, inst.ref)          # threaded accumulator (D2b)
    return nothing
end
```

The load-result name binding is supplied downstream by BVM (D3), exactly as the
`416r.4` const-array Define-prepend binds a ROM-pointer SSA name.

**Then TIGHTEN the fall-through** (`instructions.jl:3565`): a
`ptr_cells`-gated `load` whose pointer is a `GlobalVariable` matching **none** of
{`+Type#N`, `jl_global#N`, a captured `.globals` literal} currently returns
`nothing` **silently**. Change it to `_ir_error(...)` — an unrecognised
runtime-global load is an unmodelled construct and must fail loud (CLAUDE.md §1).
This is the fail-loud story for "a future third kind of global": it can no
longer be silently dropped into a dangling operand.

**D2b — threading + persistence.** `singleton_globals::Set{_LLVMRef}` is an
extraction-local accumulator owned in `_module_to_parsed_ir_on_func`
(`module_walk.jl:166-167`, beside `tag_ids`/`tag_ssa`), threaded into
`_convert_instruction` as a kwarg (signature at `instructions.jl:2543-2544`;
call site `module_walk.jl:573-579`). Unlike `tag_ids` (baked into emitted IR, so
NOT persisted), singletons DO cross the contract: at ParsedIR construction
(`module_walk.jl:374/390/414/658`) convert the ref-set to
`Dict{Symbol,Int}` keyed by the load's SSA name (via `names[ref]`), value =
header cell-count (constant `2`), and store into a **new ParsedIR field**
`singleton_globals::Dict{Symbol,Int}`.

**Distinguishing singleton-data from type-tags given identical LLVM shapes.**
Name-prefix dispatch (`+` vs `jl_global#`) is the ONLY signal available (census:
byte-identical shapes) and is *already the established pattern* — the type-tag
arm dispatches on `+`-prefix today. It is acceptable **because the wrongness is
made loud, not silent**: (a) the tightened fall-through fails loud on any
unrecognised prefix; (b) the VM read-window trap (D5) fails loud if a
`jl_global#`-named thing is NOT actually a 16-byte-header object. We never depend
on the name being *right*, only on the model being *bounded*.

**Rejected alternative.** *Reuse `.globals` for singletons* (register
`parsed.globals[name] = (zeros(2), 64)`). Rejected: `.globals` is the "readable
compile-time const literal" channel (`_j_const#N` memcpy sources; IRVarGEP
QROM bases). Overloading it forces the VM to name-sniff `jl_global#` vs
`_j_const#` to decide "materialise as ROM-array" vs "materialise as
poison-header + windowed", re-introducing the coupling D1 removed. A dedicated
field keeps the two channels typed and lets the VM dispatch on *role*, not name.

### D3 — VM materialisation: extend `_global_segment` for singletons; seed length=0, data-ptr=POISON; module-wide bases

**Decision.** In `ingest.jl`, extend `_global_segment` (`226-250`) so that, in
addition to the IRVarGEP-referenced const arrays, it materialises **one 2-cell
segment per entry in `parsed.singleton_globals`**, unconditionally (a recognised
singleton whose load was dropped is referenced by construction — its
`IRPtrOffset` base / `IRStore` val need the binding). For each singleton name:

- assign `base = GLOBAL_BASE + offset` (same running cursor as const arrays),
- seed `cells[base] = 0` (length), `cells[base+1] = GLOBAL_POISON` (data-ptr),
- record window `(base, 2)` (D5),
- register in `name_to_base` + `ordered` so the existing entry-block
  Define-prepend (`ingest.jl:584-587`) binds the SSA name.

The `IRStore` that writes the singleton pointer into a `Dict` field then
resolves its val operand to `base` (a plain Int64 cell address, ADR 0018 §A);
`rehash!` later reads that address back out of the Dict field and derefs it —
hitting the same seeded length=0.

**Rationale.** This is the minimal extension of the landed 416r.4 path: same
cursor, same `GlobalROM`, same Define-prepend, same read path
(`memory_floor.jl:251`, `get(s.globals.cells, a, 0)`). Reusing the ROM tier buys
**write-protection and checkpoint-exclusion for free** (D4). The census (Q3)
proves a zeroed 16-byte header is exactly sufficient for fdict(3,7): length@0=0
satisfies the `rehash!` loop bound; data-ptr@8 feeds only a len-0 memset.

**Rejected alternative.** *Model each singleton as an `IRAlloca` (stack, 2 cells,
absent=0)*. Attractive because alloca auto-binds its dest and absent cells read
0. Rejected: (a) a stack alloca is **writable** — a stray store to the singleton
would silently succeed (Julia-semantics miscompile: singletons are shared &
immutable), losing the D4/Q5 write-protection; (b) it is per-invocation, not
module-scope/read-only/deterministic-shared; (c) it cannot carry the read-window
bound. The ROM tier gives all three.

### D4 — Module-wide segment unification; DELETE the multi-function fail-loud guard

**Decision.** Replace the deferred-guard at `ingest_multi.jl:204-211` with real
module-wide support:

- Thread a running `global_base_offset::Int64` (start 0) through the per-function
  lowering loop (`ingest_multi.jl:191-212`). Pass it into `_lower_parsed_ir` →
  `_global_segment` so each function's bases start at `GLOBAL_BASE + cumulative`.
- Collect each function's `GlobalROM.cells` + windows into a **merged**
  `GlobalROM`; after each function advance `cumulative` by that function's cell
  count.
- Construct the merged `VMProgram` (`ingest_multi.jl:220-223`) **with** the
  merged `GlobalROM` (currently defaults to empty — the exact reason the guard
  exists).

**Cross-function drift is a non-issue here (verified).** The `#NNN` numbers drift
per-function-module, but census Q2 shows the `jl_global#` singletons appear
**only in the root fdict PIR**; `rehash!`/`setindex!`/`ht_keyindex2` reference
only `+Type#N` GenericMemory tags. The singleton addresses flow to `rehash!`
**through memory** (stored into a Dict field, read back as a value), so `rehash!`
derefs the root's segment by VALUE — it never re-materialises its own singleton.
Therefore per-function segments at disjoint module-wide bases are correct with no
name-unification needed. (If a future set had the same singleton referenced
directly in two functions, they would get two distinct zeroed segments; because
the segment is read-only and its length is 0, the two are behaviourally
identical — a divergence only a pointer-identity `==` on the raw singleton could
observe, which the empty-Memory path never does.)

**Relation to bead `bennettvm-h6c3` (multi-function const globals, NES ROM
track).** This subsumes h6c3's core mechanism: module-wide base assignment +
merged `GlobalROM` carried into the merged `VMProgram` is exactly what readable
const arrays across functions need too. h6c3 becomes "add a multi-function
IRVarGEP-const-array test on top of the machinery this bead lands" — partially
unblocked, its infrastructure done. Note it explicitly in the h6c3 bead on close.

**Rationale.** The guard's own comment (`ingest_multi.jl:195-202`) names the two
blockers — colliding `GLOBAL_BASE+0` bases and the merged program dropping
per-function globals — and this decision fixes both directly. Fail-loud was the
right floor while single-function only; clearing this wall requires lifting it.

### D5 — Bounded read window + poison data-ptr: make silent-zero-read impossible

**Decision.** Two additive VM guards, both drift-immune (keyed on address, never
on name/number):

1. **Windowed ROM reads.** Add `windows::Vector{Tuple{Int64,Int64}}` (`(base,
   len)`) to `GlobalROM` (`IState.jl:297`). In `MemoryLoad.forward`
   (`memory_floor.jl:242-256`), for `a >= GLOBAL_BASE`: if `a` falls in **no**
   registered window → **fail loud** ("read past modelled global segment"). The
   empty singleton reads only length@base and data-ptr@base+1 — both inside
   `(base,2)`. A *non-empty* singleton (a const array captured by a closure that
   we also matched by `jl_global#` name) reads at offset ≥16 → traps on first
   out-of-window read instead of silently returning 0. This converts "wrong
   model" into "loud failure" — we never have to *prove* a `jl_global#` is empty.
2. **Poison data-ptr.** Seed data-ptr@base+1 = `GLOBAL_POISON` (a reserved
   sentinel in a trap band, e.g. `GLOBAL_BASE - 1` or a dedicated
   `POISON_BASE`). Any `MemoryLoad`/`MemoryStore`/GEP-deref whose resolved
   address is in the poison band → fail loud. For the empty singleton the
   data-ptr feeds only `memset(len=0)` (`IntrinsicMemset.forward` loops
   `base:base+cells-1` with `cells=0` → empty loop, never touches poison) → no
   trap. For a non-empty misuse, `memset(len>0)` derefs poison → trap.

**Write-protection (Q4/Q5) is inherited free**: `MemoryStore` to `>= GLOBAL_BASE`
already fails loud (`memory_floor.jl:220-225`).

**Checkpoint exclusion (Q4) is inherited free**: `GlobalROM` is shared read-only
and `deepcopy_internal(::GlobalROM)` returns the same object
(`IState.jl:310`), so ROM segments are never per-checkpoint copied. The added
`windows` field rides the same share.

**Rationale.** Q5 demands silent zero-read be *impossible*. Guard (1) kills reads
past the modelled header; guard (2) kills the one escape guard (1) misses — a
data-ptr *within* the header being dereferenced with non-zero length. Together
with write-protect, all three miscompile classes are loud.

---

## 2. ParsedIR-level contract (concrete)

**New ParsedIR field** (`Bennett.jl/src/ir_types.jl`, after
`synth_ptr_provenance` at line 590):

```julia
# jl_global#NNN empty-GenericMemory singleton-data pointers (census Q3). Maps
# the load-result SSA name → modelled header cell-count (always 2: length@0,
# data-ptr@8). The VM mints a deterministic GLOBAL_BASE address + a zeroed,
# read-only, windowed segment and binds the name via a Define-prepend. The
# ADDRESS is NEVER carried here (ADR 0021 D3). Empty for any non-ptr_cells / no-
# Dict module. Analogous in threading to `synth_ptr_provenance`.
singleton_globals::Dict{Symbol,Int}
```

Update all 3 convenience constructors (`ir_types.jl:593-616`) to default it to
`Dict{Symbol,Int}()`, and the 4 real construction sites
(`module_walk.jl:374, 390, 414, 658`) to pass the built dict.

**No new instruction shape.** The singleton load emits *no* IRInst (dropped); the
binding is a VM-side `Define(name, base, :add, 0)` prepend, identical to the
existing const-array path. Downstream `IRPtrOffset` / `IRStore` are unchanged —
their operands simply now resolve.

---

## 3. Exact touch list (verified line refs)

### Bennett.jl (front-end)

| file:line | change |
|---|---|
| `src/extract/constexpr.jl:136` | add `_is_singleton_data_global_name` beside `_is_type_tag_global_name` (~2 LOC) |
| `src/extract/instructions.jl:2543-2544` | add `singleton_globals::Set{_LLVMRef}=Set{_LLVMRef}()` kwarg to `_convert_instruction` |
| `src/extract/instructions.jl:3548` | new singleton arm (after the type-tag arm, before `haskey(names,...)`) — `push!(singleton_globals, inst.ref); return nothing` (~12 LOC) |
| `src/extract/instructions.jl:3565` | tighten the fall-through: unrecognised `ptr_cells` GlobalVariable load → `_ir_error(...)` fail loud (~8 LOC) |
| `src/extract/module_walk.jl:166-167` | own `singleton_globals = Set{_LLVMRef}()` beside `tag_ids`/`tag_ssa` |
| `src/extract/module_walk.jl:573-579` | pass `singleton_globals=singleton_globals` into `_convert_instruction` |
| `src/extract/module_walk.jl:374/390/414/658` | build `Dict{Symbol,Int}(names[r]=>2 for r in singleton_globals)` and pass to `ParsedIR(...)` |
| `src/ir_types.jl:566-616` | new field + 3 constructor updates |

### BennettVM.jl (VM)

| file:line | change |
|---|---|
| `src/ir/IState.jl:297-313` | `GlobalROM` gains `windows::Vector{Tuple{Int64,Int64}}`; update ctors, keep `deepcopy_internal` share; add `POISON_BASE` const |
| `src/ir/intrinsics.jl:104-116` | add `GLOBAL_POISON` sentinel const near `GLOBAL_BASE` |
| `src/ir/ingest.jl:226-250` | `_global_segment` gains a `base_offset` kwarg + a loop over `parsed.singleton_globals` seeding `(0, POISON)` cells + windows; returns windows too |
| `src/ir/ingest.jl:420, 584-587, 963` | thread windows into the returned `GlobalROM`; Define-prepend already handles `ordered` |
| `src/ir/memory_floor.jl:242-256` | `MemoryLoad.forward`: window-membership + poison-band traps for `a >= GLOBAL_BASE` / poison |
| `src/ir/memory_floor.jl:212-228` | `MemoryStore.forward`: add poison-band trap (write-to-`>=GLOBAL_BASE` already loud) |
| `src/ir/ingest_multi.jl:191-223` | thread `global_base_offset`; merge per-function `GlobalROM` cells+windows; construct merged `VMProgram` WITH merged ROM; **delete** the `204-211` fail-loud guard |
| `src/ir/intrinsics.jl` (memset forward) | confirm len-0 memset never derefs poison (loop is empty) — add a test, no code change expected |

---

## 4. RED-GREEN test plan

### New test files

**BennettVM `test/test_jlglobal_singleton.jl`** (hand-built ParsedIR set +
per-step/round-trip via existing `per_step_inverse_check` scaffold):

1. *materialise + bind* — a 1-block PIR with `singleton_globals =
   Dict(:s=>2)`, an `IRPtrOffset(:.p, base=ssa(:s), +8, ew)`, an `IRStore` of
   `ssa(:s)`; `initial_state` seeds `(0, POISON)` at the assigned base;
   `run!` completes; `:s` resolves to `GLOBAL_BASE`; length read = 0.
2. *round-trip* — `unrun!` restores `arena_top`/memory/locals byte-identical,
   history empty (ROM excluded from checkpoints).
3. **adversarial — write fails loud**: an `IRStore` to `ssa(:s)` (address ≥
   `GLOBAL_BASE`) → `@test_throws ErrorException` ("READ-ONLY").
4. **adversarial — read past header fails loud**: `IRPtrOffset(:.q, ssa(:s),
   +16, ew)` then `IRLoad` → out-of-window → `@test_throws`.
5. **adversarial — poison deref fails loud**: load data-ptr@8 then `IRLoad`
   through it (non-memset consumer) → poison-band trap → `@test_throws`.
6. **number-drift immunity**: build the same PIR with key `:s` renamed to a
   different `jl_global#` number; assert identical run result (no name pinned).

**BennettVM `test/test_jlglobal_multifunc.jl`**: a 2-function set, one function
with a singleton, one with an IRVarGEP const array; assert disjoint
module-wide bases, merged ROM carried into the `VMProgram`, both round-trip.
(Also the h6c3 down-payment.)

**Bennett.jl `test/test_jlglobal_extract.jl`**: `extract_parsed_ir_set_from_julia(
fdict_d1b, Tuple{Int8,Int8}; ptr_cells=true)` — assert the root PIR's
`singleton_globals` has **count 2** (NOT specific numbers — Rule 5); every
`IRPtrOffset` base / `IRStore` val name is in `singleton_globals` or otherwise
defined (no dangling operand); a `+Type#N` still routes to the type-tag
`IRBinOp` arm (unchanged); an unrecognised GlobalVariable ptr-load `@test_throws`.

### Existing wall-pin that FLIPS

**`test/test_x3t0_multikey_return.jl` (f)** (`:308-338`). Today it asserts the
runtime wall: `@test rthrew; @test occursin("jl_global", rmsg)` (`:336-337`).
After this bead the construction wall is cleared. Flip to: run to the **next**
wall (or completion) and assert the OLD wall is gone —
`@test !occursin("jl_global#", rmsg)` when it still throws — plus a new pin for
the next wall's signature (see §5). Update the comment block `:322-325` to name
the successor bead. This is the mandated wall-pin advance.

---

## 5. Silent-miscompile risk analysis (top 3, each with its killing guard)

| # | Risk | Guard that kills it |
|---|---|---|
| 1 | A `jl_global#` name we matched is **not** an empty-16B-header object (e.g. a non-empty const singleton captured by a closure); reads at offset ≥16 silently return 0 → miscompile | **D5 guard (1): windowed ROM reads** — every `a ≥ GLOBAL_BASE` outside a registered `(base,len)` window fails loud. First out-of-header read traps; we never depend on proving emptiness from the name. |
| 2 | A store lands on a singleton pointer (Julia singletons are shared & immutable; a write is a semantics violation) and silently corrupts shared state | **Inherited: `MemoryStore` to `≥ GLOBAL_BASE` already fails loud** (`memory_floor.jl:220`). Plus D5 poison-band trap for the data-ptr escape. |
| 3 | The data-ptr@8 (a value read *within* the header, so window guard (1) passes) is dereferenced with non-zero length → deref of a bogus/zero address silently reads/writes cell 0 (a legit stack address) | **D5 guard (2): poison data-ptr** — seed data-ptr = `GLOBAL_POISON`; any load/store/deref in the poison band fails loud. The empty-singleton path's `memset(len=0)` never derefs it (empty loop), so no false trap. |

Residual (accepted, next-agent): a `jl_global#` object whose *true* content is a
16-byte header but semantically different from an empty Memory (same shape,
different meaning) and whose length field is genuinely 0 — indistinguishable and
harmless for fdict(3,7). If a future site needs the data-ptr as a real backing,
the poison trap converts it to a loud "unsupported non-empty singleton" the next
agent extends deliberately.

---

## 6. Scope boundary — the NEXT wall (predicted from census evidence)

This clears **construction**. The fdict run then executes `d[a]=b` →
`setindex!` → `ht_keyindex2_shorthash!` → `rehash!`. Census Q3 shows `rehash!`
reads the singleton **length (0)** — satisfied by our seeded header — and then
**allocates fresh backing via `jl_alloc_genericmemory_unchecked`** (length from
arg; census: emitted as `Memory{UInt8}[]` / `Memory{Int8}[]` `IRCall`s).

**Predicted next wall (most-likely first):**
1. The `jl_alloc_genericmemory_unchecked` / `julia.gc_loaded` / GenericMemory
   allocation-and-copy path in `rehash!` — either an intrinsic not yet fully
   lowered in the VM (ADR 0021 D4 whitelists it at *extraction*; VM-side
   `_HEAP_DISPATCH` coverage is the open question), or a `MemoryStore` through
   the freshly-allocated backing.
2. The multi-function `CallEnter`/return actually *executing* into `setindex!`
   (BobISA call/return under the merged program) — prior beads lowered it
   statically; this is its first run.
3. A `+Type#N` GenericMemory tag flowing into `gc_alloc_obj` at *runtime* (the
   census says structurally unread — `intrinsics.jl:194-210` — but that's a
   lower-time claim; confirm at run time).

**Recommendation for the next agent:** after landing this, re-run the census
repro (`scratchpad/probe.jl`) and pin the new wall's message in the flipped
test_x3t0 (f). Design here is forward-compatible: module-wide ROM (D4) + the
poison/window guards (D5) are exactly the substrate the rehash!-allocation wall
will build on.

---

## 7. Estimated diff size

| repo | LOC (impl) | LOC (test) |
|---|---|---|
| Bennett.jl | ~55 (recogniser + arm + fail-loud tighten + field + 3 ctors + threading) | ~60 |
| BennettVM.jl | ~110 (GlobalROM windows + poison + `_global_segment` + 2 memory_floor traps + ingest_multi module-wide merge − deleted guard) | ~120 |

Both are additive and reuse the landed 416r.4 GlobalROM tier; no core
phi-resolution / gate-lowering touched.
