# Scout report — determinism guard pair (Bennett-klgz / bennettvm-90l)

Ground-truth scout, 2026-07-12. Bennett.jl HEAD e7454fd, BennettVM.jl HEAD 838e2da,
Julia 1.12.5. No source changed. All probes below were run live.

---

## TL;DR verdicts

| Q | Verdict |
|---|---------|
| 1 | **dict_vm.jl is OFF the live path.** It is reached ONLY via `mem=:vm` (a legacy single-module recognizer). The live SC9-Case-B path is `extract_parsed_ir_set_from_julia(...; ptr_cells=true)` with `mem=:auto`, which never touches dict_vm.jl. A front-end guard must live on the ptr_cells extraction path — concretely at the 416r.13 runtime-global load site in `src/extract/instructions.jl:3631`. |
| 2 | **NO live silent-miscompile today.** The adversarial `Dict{MutableStruct,V}` case FAILS LOUD today — but so does the *deterministic* `Dict{String,V}` case, both via the SAME blunt incidental wall (416r.13 "unrecognized JIT global"), not via any determinism guard. So the guard is **defense-in-depth today**, and becomes **load-bearing correctness** the moment 416r.13 is taught to model runtime-callee PLT stubs (which the roadmap needs to make String-key Dicts work). |
| 3 | **The 3 benign ptrtoint are VERIFIED — all type-object tagging, none in the key-hash cone.** (Dict / AssertionError / KeyError type tags.) |
| 4 | **objectid does NOT arrive as `IRCall(:objectid)`.** On the closed-world path it is `load atomic ptr @jlplt_ijl_object_id_*_got` + an *indirect* call through the loaded SSA pointer. The VM's current `_NONDETERMINISTIC_CALLEES` denylist cannot see this shape; and it never reaches ingest today (front-end 416r.13 wall). `jl_object_id` is NOT in the CW-D2 whitelist. |
| 5 | **Minimal correct guard today = a determinism CLASSIFIER at the front-end 416r.13 load site**, distinguishing `ijl_object_id` (reject, name the construct) from `memhash_seed` (deterministic content hash, admit). ~15–40 LOC front-end + a test; VM-side 90l stays a belt-and-suspenders mirror, its "inlined no-callee" extension BLOCKED-BY the front-end runtime-callee-global modeling decision. |

---

## Q1 — Today's pipeline & where a front-end guard must live

**dict_vm.jl is gated behind `mem === :vm` only** (`src/extract/module_walk.jl:359,372`):
```julia
if mem === :vm
    if _dict_vm_is_recognised(func)
        return _dict_vm_extract(...)        # ← dict_vm.jl, the OLD IRMap* recognizer
```
The live Case-B tests do NOT use `mem=:vm`. Both `test_cwd4_genericmemory.jl:236` and
`test_jlglobal_singleton.jl:160` call:
```julia
set = extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8}; ptr_cells = true)
```
`extract_parsed_ir_set_from_julia` (julia_set.jl) defaults `mem=:auto` and forwards it to
each per-callee `extract_parsed_ir`. `:auto` never becomes `:vm`, so **dict_vm.jl /
vector_vm.jl are dead for the live fdict path**. The Dict is handled by walking
`transitive_callees` and extracting each surviving callee body (`setindex!`, `rehash!`,
`ht_keyindex2_shorthash!`, …) as ordinary ParsedIR under the ptr_cells cell model — NOT by
the IRMap* recognizer.

Confirmed live: fdict extracts 4 bodies —
`[fdict#…, setindex!#…, rehash!#…, ht_keyindex2_shorthash!#…]`.

**Guard home for the LIVE path:** NOT dict_vm.jl (off-path). The single choke point where the
key-hash provenance is visible on the live path is the ptr_cells load lowering in
`src/extract/instructions.jl` — specifically the 416r.13 unrecognized-runtime-global guard at
**line 3631** (see Q5). The closed-world completeness check in `julia_set.jl`
(`_closed_world_check!`) is a secondary net but sees only *surviving Symbol/Function callees*,
not the inlined load-of-GOT shape (Q4).

---

## Q2 — Threat model: is it a LIVE silent-miscompile today? **No.**

Three functions probed (`code_llvm ... optimize=false`, then live extraction with
`ptr_cells=true`):

```
fdict(a::Int8,b::Int8)          — isbits key           (deterministic, in-scope)
fmk(m::MK,b::Int8)  MK mutable  — Dict{MK,Int8}         (ADVERSARY: objectid/address hash)
fstr(a::String,b::Int8)         — Dict{String,Int8}     (deterministic content hash; MUST be allowed by a correct guard)
```

**Hash-provenance at the top level** (`code_llvm`, counts): fdict has 27 `hash` mentions
(getindex inlined to raw arithmetic); **fmk and fstr have 0** — their setindex!/getindex are
opaque callees, so the hash lives *inside* those callees, which the closed-world extractor
walks into.

**Live extraction results** (`extract_parsed_ir_set_from_julia(...; ptr_cells=true)`):
- `fdict` (control) → **EXTRACTED OK** (4 bodies). Int8 `hash` inlines to pure integer
  arithmetic → no runtime-global load → clean. ✅ correct (deterministic, in-scope).
- `fmk` (adversary) → **FAILS LOUD** while extracting `ht_keyindex`:
  ```
  load of an UNRECOGNIZED Julia JIT global `@"jlplt_ijl_object_id_111_got"`
  (a `constant ptr` whose load returns a pointer) under ptr_cells. ... Fail loud
  at the load site (bennettvm-416r.13 / CLAUDE.md §1).
  ```
- `fstr` (String) → **ALSO FAILS LOUD** while extracting `getindex`:
  ```
  load of an UNRECOGNIZED Julia JIT global `@"jlplt_memhash_seed_3927_got"`
  ... Fail loud at the load site (bennettvm-416r.13 / CLAUDE.md §1).
  ```

**Interpretation (the crux):**
- There is **NO live silent-miscompile**. The adversary is rejected TODAY.
- But it is rejected by the **wrong, indiscriminate wall** (416r.13 "unrecognized JIT
  global"), *for the wrong reason* (an opaque runtime-callee pointer load it cannot model),
  NOT by a determinism guard naming the construct.
- The **same wall over-rejects the deterministic String case** (`memhash_seed`) — which
  ADR 0015/0017 explicitly place IN scope. So today the wall cannot tell "deterministic
  content hash (String)" from "nondeterministic identity hash (MK)".

Note: I initially suspected the older U14 atomic-load wall
(`instructions.jl:3462`), but under `ptr_cells=true` the U14 ordering check was RELAXED for the
`{NotAtomic,Unordered,Monotonic,Acquire,Release}` band (Bennett-ares / CW-D2 lever 1), and
`jlplt_*_got` loads are `unordered` — so they pass U14 and are caught one guard later, at the
416r.13 pointer-global guard. That is the true live wall.

**Consequence for bead priority:** the guard is **defense-in-depth today** (not urgent —
nothing miscompiles). It converts to **urgent correctness** the instant someone teaches the
extractor to model these `jlplt_<name>_got` runtime-callee stubs — which the closed-world
roadmap REQUIRES, because that is exactly how String-key (and any callee-invoking) Dicts stop
failing loud. At that moment `ijl_object_id`'s stub would extract just like `memhash_seed`'s,
and without a determinism guard the MK case would silently lower to a program that hashes on a
virtual-heap address. **The guard should land WITH (or before) the runtime-callee-global
modeling, not after.**

---

## Q3 — The benign ptrtoint census (fdict, live IR) — VERIFIED

`code_llvm(fdict, Tuple{Int8,Int8}; optimize=false)`: exactly **3 ptrtoint + 3 inttoptr**, all
type-object address-tagging pairs, none touching the key:

```
L45: %Dict          = ptrtoint ptr %"+Main.Base.Dict#128"      to i64      ; Dict type tag (ctor)
L46: %6             = inttoptr i64 %Dict to ptr
L376: %AssertionError = ptrtoint ptr %"+Core.AssertionError#133" to i64     ; AssertionError type tag (throw path)
L377: %106          = inttoptr i64 %AssertionError to ptr
L405: %KeyError      = ptrtoint ptr %"+Main.Base.KeyError#130"  to i64      ; KeyError type tag (throw path)
L406: %115          = inttoptr i64 %KeyError to ptr
```
Each is `ptrtoint` of a `+<Type>#<N>` type-object GLOBAL immediately re-`inttoptr`'d — the
Julia calling-convention way of passing a type object as a constant. The keys are the i8 SSA
values `a`/`b`; none appears here. **The old census (3, all type-tagging, provably outside the
key-hash cone) holds on today's IR.** These are handled by the `+Type#N` type-tag arm of the
416r.13 recognizer (`instructions.jl` type-tag global path), which returns a constant identity
— so they never reach the fail-loud arm.

---

## Q4 — VM side (90l): what shape actually reaches ingest?

**objectid's structural shape on the closed-world path** (`code_llvm(Base.ht_keyindex,
Tuple{Dict{MK,Int8},MK})`):
```
; @ runtime_internals.jl:856 within `objectid`
%ijl_object_id = load atomic ptr, ptr @jlplt_ijl_object_id_201_got unordered, align 8
%9             = call i64 %ijl_object_id(ptr addrspace(10) %"key::MK")
```
It is a **PLT/GOT lazy-binding stub**: an atomic load of a *function pointer* from
`@jlplt_ijl_object_id_*_got`, then an **indirect call through the loaded SSA value**. The name
`ijl_object_id` appears only as the GOT global's symbol, never as a callee `nameof`.

Mapping to the bead's three candidate shapes:
- **(a) IRCall to a named callee `:objectid`** — does NOT occur. The call target is an SSA
  pointer, and `_callee_sym` (BVM `ingest_body.jl:77-78`) only handles `Function`/`Symbol`.
  So the VM's `_NONDETERMINISTIC_CALLEES` denylist (`ingest_call.jl:140`, currently
  `{rand,rand!,randn,randexp, objectid,pointer_from_objref, time,time_ns,getpid}`) would NOT
  match this even if it reached ingest.
- **(b) inlined ptrtoint / load-of-GOT + indirect call** — this IS the real shape, and TODAY
  it never reaches the VM: the front-end 416r.13 guard rejects the `load @jlplt_*_got` before
  any ParsedIR is produced (Q2). Under ptr_cells, a heap-pointer `ptrtoint`/`load ptr` is
  modeled as a 64-bit cell (`instructions.jl:3615`), but a load of a *runtime-callee GOT
  global* is specifically the unrecognized-global case that fails loud.
- **(c) bare Symbol IRCall to `jl_object_id`** — would only arise if the extractor were taught
  to model the GOT stub as a named runtime call. `jl_object_id` is NOT in the CW-D2 whitelist
  `_D1B_MODELED_HEAP_INTRINSICS` (julia_set.jl:81, = malloc/calloc/realloc/free/memset/memcpy/
  memmove/gc_alloc_obj/jl_alloc_genericmemory_unchecked) nor BVM `_HEAP_DISPATCH`
  (ingest_call.jl:160), so such a Symbol callee would trip the `julia_set.jl`
  `_closed_world_check!` fail-loud — another incidental catch, again indiscriminate w.r.t.
  determinism.

**Bottom line for 90l:** the VM `_NONDETERMINISTIC_CALLEES` denylist is a correct
belt-and-suspenders mirror, but it guards a shape (`IRCall(:objectid)`) that the live
closed-world extractor **cannot currently produce**. The bead's "extend to the inlined
no-callee case" is exactly the load-of-GOT + indirect-call shape — and the right VM extension
**cannot be specified until the front-end decides how it will model `jlplt_<name>_got`
runtime-callee stubs** (presumably as named IRCalls to the resolved symbol `ijl_object_id` /
`memhash_seed`). The VM mirror should then denylist the *resolved identity-hasher names*
(`ijl_object_id`, `jl_object_id`) while leaving `memhash_seed` off the list.

---

## Q5 — Placement recommendation (facts + short recommendation)

**Facts constraining placement:**
1. ADR 0017 corollary: with a deterministic virtual heap, address hashing is deterministic
   *inside the VM*; the nondeterminism boundary is (i) values crossing INTO the VM and
   (ii) the future circuit lowering. So the *principled long-term* home is the circuit-lowering
   boundary.
2. TODAY the adversary is already loud (416r.13), so nothing is broken — but the message names
   no construct, and the same wall over-rejects String.
3. The risk window opens when 416r.13 is relaxed to model runtime-callee GOT stubs (needed for
   String-key Dicts). The one place where `ijl_object_id` and `memhash_seed` are
   *distinguishable by name* AND where "values crossing into the VM" physically enter is the
   front-end runtime-global load site.

**Recommendation — minimal correct guard TODAY:** put a determinism CLASSIFIER at the
front-end 416r.13 load site, `src/extract/instructions.jl:3631` (the `ptr_cells &&
GlobalVariable && PointerType` arm). Demangle the `jlplt_<name>_got` symbol; classify:
- identity/address hashers (`ijl_object_id`, `jl_object_id`, `object_id`,
  `pointer_from_objref`, `jl_egal`-of-pointer) → **fail loud naming the construct** ("Dict key
  hashed by object identity / allocation address — nondeterministic across replays,
  unreplayable; only isbits and content-hashed String keys are supported (ADR 0015 §Decision
  3 / ADR 0017 corollary)").
- deterministic content/value hashers (`memhash_seed`, `memhash`, `hash`) → do NOT reject here;
  route to the (future) runtime-callee model.

This gives the adversary a **specific, construct-naming diagnostic** today (Rule-1 legibility,
strictly better than the generic "unrecognized JIT global"), and it is the durable guard that
survives when 416r.13 is relaxed — it is what lets memhash_seed through while still catching
ijl_object_id.

Do NOT try to place the whole guard at dict_vm.jl (off the live path, Q1) and do NOT rely on
the VM denylist alone (it can't see the inlined shape, Q4).

**Scale estimate:**
- **Front-end (Bennett-klgz):** ~15–40 LOC in `src/extract/instructions.jl` at line 3631
  (a small `const _NONDETERMINISTIC_RUNTIME_GLOBALS` + demangle + classify before the generic
  fail-loud), plus one regression test: `Dict{MutableStruct,V}` → construct-naming error;
  `Dict{Int8,V}` still extracts; `Dict{String,V}` NOT rejected by *this* guard (it will still
  hit 416r.13's generic wall until callee-modeling lands — assert on the guard's absence, not a
  green extraction). Best sequenced together with the runtime-callee-global modeling bead.
- **VM-side (bennettvm-90l):** the current `_NONDETERMINISTIC_CALLEES` denylist is already
  correct as a mirror. Minimal change today: add resolved identity-hasher names
  (`ijl_object_id`, `jl_object_id`) to the set (~5 LOC) + extend the existing machine-checked
  mirror test so front-end classifier ⟺ VM denylist stay in sync (pattern:
  `_D1B_MODELED_HEAP_INTRINSICS ⟺ _HEAP_DISPATCH`, e.g. test_416r12_jl_alloc_genericmemory.jl).
  The "inlined no-callee" extension is **BLOCKED-BY** the front-end runtime-callee-global
  modeling decision — file it as depends-on, not do-now.

---

## Probe artifacts (scratchpad, throwaway)
- `probe1.jl` — code_llvm hash-provenance counts (fdict/fmk/fstr)
- `probe2.jl` — transitive_callees + live extraction of all three
- `probe3.jl` — fdict ptrtoint census + ht_keyindex objectid IR shape
- `probe4.jl` — full 416r.13 error text for ht_keyindex (MK) and getindex (String)
