# ADR 0021 — CW-D extraction contract: Julia transitive-callee IR via the typed callgraph

> **Status: ACCEPTED 2026-06-10.** Beads `bennettvm-416r.11/.12/.13`
> (CW-D1/2/3). Probe-grounded (scout transcript archived in session
> 2026-06-10; Julia 1.12.5). Implements ADR 0017 §Decision 1 for the Julia
> front end, completing what ADR 0020 did for C.

## Probe results (the ground truth)

For `fdict(a,b) = (d=Dict{Int8,Int8}(); d[a]=b; d[a])` at `optimize=false`:

- The opaque write callee **has recoverable IR in-process**:
  `code_llvm(setindex!, Tuple{Dict{Int8,Int8},Int8,Int8}; optimize=false,
  dump_module=true)` succeeds. The transitive closure is **finite**:
  `setindex!` → `ht_keyindex2_shorthash!` (self-recursive) → `rehash!` →
  `AssertionError`, bottoming out at runtime C walls.
- **The original Case B blocker dissolves**: `rehash!`'s body calls
  `jl_alloc_genericmemory_unchecked` with the backing length as an
  argument — the "missing length witness" of HANDOFF 2026-06-08 exists
  one level down the callgraph; closed-world extraction reaches it.
- `dump_module=true` does NOT stitch callee bodies (2 defines only) —
  per-callee extraction + set assembly is required.

## Decisions

1. **Name linkage = the typed callgraph, never mangled names.** Callee
   identity comes from `code_typed` `:invoke` statements'
   `MethodInstance.specTypes` (recursion key `(f, Tuple{argtypes...})`,
   feeding `code_llvm(f, argtypes; optimize=false)` per callee). The
   mangled `j_<name>_NNN` suffix drifts per compilation — REJECTED
   (Rule 5/8). Version shim required: 1.12's `:invoke` arg-1 is a
   `CodeInstance` (`.def → MethodInstance`); ≤1.10 a bare
   `MethodInstance` — `mi_of(x)` helper, pinned by test. ~~Callgraph edges
   are resolved from the SAME O0 inference run that produced the body.~~
   **CORRECTED — see Amendment A (2026-06-14): edges come from
   `optimize=true`, bodies from `optimize=false`. At O0 there are ZERO
   `:invoke`s.**
2. **Output shape = the CW-C shape.** New
   `extract_parsed_ir_set_from_julia(f, argtypes; ...)` →
   `Vector{Pair{Symbol,ParsedIR}}`, consumed unchanged by BVM
   `lower_vm(::Vector{<:Pair})` + guard-5. Symbol-callee `IRCall`
   (ADR 0020 D1) carries the linkage; the `ptr_cells` cell model
   generalizes to Julia ptr args/returns (Dict, Memory as Int64 cells).
   Closed-world check at set-assembly: every emitted call Symbol resolves
   in-set or in the CW-D2 whitelist — fail loud otherwise.
3. **CW-D3 re-scope (supersedes the bead's "initialized data segment"
   framing): the interned globals are runtime TYPE-TAG pointers**
   (`private alias ptr, inttoptr (i64 <JIT-addr> to ptr)`) — Dict/KeyError
   Type objects for `gc_alloc_obj`, NOT data backings, and their addresses
   are **non-deterministic (JIT/ASLR)**. The floor must never read the
   `inttoptr` address as data: `gc_alloc_obj(type_tag, …)` becomes an
   arena intrinsic that IGNORES the tag value; literal `_j_const#N`
   globals (readable initializers) materialize as ordinary segments.
4. **CW-D2 whitelist** (draft table in the scout report, archived):
   arena class = `gc_alloc_obj`/`ijl_gc_*_alloc`/
   `jl_alloc_genericmemory_unchecked` (length from arg); ptr-compute =
   `julia.gc_loaded`; bulk = `llvm.mem*`; dead-branch = `ijl_throw`/
   `jl_argument_error`/`llvm.trap`; pure = `llvm.ctlz`/
   `llvm.smul.with.overflow`. **MANDATORY pre-work (Rule 2): a mutation
   audit of `julia.write_barrier`/`ijl_gc_queue_root` and
   `julia.get_pgcstack`/gc-frame ops** — verify they touch only GC
   bookkeeping (droppable at the floor) and read no world-age/task
   counters (determinism), BEFORE classifying them as no-ops. Anything
   unverified fails loud.

## Sequencing (gates per chunk, CW-C2-sized)

- **CW-D1a** — callgraph walker (`transitive_callees`, visited-set for
  self-recursion, `mi_of` shim). Gate: `fdict` closure == the probed set;
  visited-set mutation-proof.
- **CW-D1b** — per-callee O0 extraction + set assembly
  (`extract_parsed_ir_set_from_julia`). Gate: ≥4 ParsedIRs for `fdict`;
  closed-world symbol check fail-loud.
- **CW-D1c** — linkage into BVM guard-5; hand-stitched `fdict` set
  (globals deferred) round-trips on the VM; throw branches dead.
- **CW-D2** — whitelist + the write_barrier/pgcstack audit.
- **CW-D3** — type-tag globals per Decision 3 → bare-`fdict` e2e (`7xa`).

## Reuse (Law 2)

`extract_parsed_ir_set_from_ll` set-producer pattern + Symbol-callee
`IRCall` (ADR 0020); `_HEAP_DISPATCH`/`_NONDETERMINISTIC_CALLEES` hook
points (ADR 0018 §C); the registry pattern of `register_callee!` fed by
`(f, argtypes)` instead of mangled names. New for this project: the typed
callgraph walker (no published reversible-computing prior art applies —
this is Julia-compiler plumbing in service of ADR 0017's closed-world
acquisition).

## Amendment A — edges@optimize=true, bodies@optimize=false (2026-06-14, CW-D1a)

> **Status: ACCEPTED.** Probe-grounded (Julia 1.12.5) during CW-D1a
> implementation. Corrects the last sentence of Decision 1.

The original Decision 1 claim — *"Callgraph edges are resolved from the SAME
O0 inference run that produced the body"* — is **materially wrong on Julia
1.12.5** (Law 1; the same class of error CLAUDE.md Rule 5/9 warns about). Fresh
probe of `fdict(a,b)=(d=Dict{Int8,Int8}();d[a]=b;d[a])`:

- `code_typed(fdict, Tuple{Int8,Int8}; optimize=false)` has **ZERO `:invoke`
  statements** — calls are dynamic `:call` Exprs, no `CodeInstance`/
  `MethodInstance` present. `mi_of` has nothing to run against at O0.
- The `:invoke` edges (with a `Core.CodeInstance` arg-1) materialize **only at
  `optimize=true`**.

**Corrected mechanism (as implemented in CW-D1a):** the walker
(`transitive_callees`) sources callgraph **edges at `optimize=true`** via
`Base.code_typed_by_type(specTypes; optimize=true)`; callee **bodies** are still
extracted at **`optimize=false`** — but that is D1b's concern, not the edge
walk. The Bennett.jl test carries a permanent **O0-regression tripwire** (Gate
5: `!isempty(transitive_callees(fdict, …))`) so a future "fix-to-ADR-letter"
regression to O0 fails loud. Decisions 2–4 and the chunk sequencing are
unaffected.

Implemented: Bennett.jl `src/extract/callgraph.jl` (commit `0c2a7f87`), test
`test_d1a_transitive_callees.jl` 15/15. Bennett.jl worklog 081 carries the full
ground-truth record (closure = {setindex!, ht_keyindex2_shorthash! [self-rec],
rehash!, AssertionError}; length witness confirmed in `rehash!`).

## Amendment B — semantic certification of interned heap literals (2026-09-24, Bennett-hsm3 / gcf7 D1–D3)

> **Status: ACCEPTED.** Probe-grounded (Julia 1.12.7). Refines Decision 3.
> Design: Bennett.jl `docs/design/hsm3/{proposal_A,proposal_B,orchestrator_review}.md`;
> defect record: Bennett.jl `docs/design/5viz_gcf7_hostile_review.md`.
> Implemented: Bennett.jl `src/extract/jlglobal_cert.jl`.

**The defect this amendment removes.** Julia's codegen interns EVERY heap-object
literal a method references as `@"jl_global#N" = private constant ptr
@"jl_global#N.jit"`, the `.jit` alias being `inttoptr (i64 K to ptr)`. That covers
a `const Ref(…)`, a struct / tuple box, a `String`, an `Array`, a non-empty
`Memory`, and the empty `GenericMemory` singleton alike.

The 416r.13 front end recognised the singleton BY NAME (`^jl_global#\d+$`) and
recorded its empty-vs-non-empty guard as "structural". Both were false: the name
and the LLVM shape are identical for every literal. Two executed miscompiles (gcf7
D1/D2), both of which reversed cleanly on BennettVM:

- `const RI = Ref(42); h3(x) = RI[] + x` extracted as a load off a zero blob.
  BennettVM returned 0/10/−5 against the oracle 42/52/37.
- `const M3 = Memory{Int}([7,8,9]); length(M3) + x` returned 10 against the
  oracle 13.

**The 416r.13 "structural" argument is withdrawn. `jl_global#N` naming is NOT
evidence of anything.**

**Amended rule.** Decision 3's rule "the floor must never read the `inttoptr`
address as data" stands. Nothing derived from the address's numeric value (the
value, a hash, an ordering, an offset) ever enters `ParsedIR` or influences emitted
IR.

ONE additional use is permitted. At extraction time, the closed-world Julia
producer running in the live producing session may use the address K **solely to
CLASSIFY the literal**. K is never dereferenced, never emitted into `ParsedIR`, and
never read by the floor at run time. The emitted program is address-free, so
determinism (ADR 0015 D3) is unaffected: the classification outcome is a property
of object identity, not of the address.

**Classification is a membership test.** K is admitted iff it equals
`pointer_from_objref(T.instance)` for some concrete `T <: Core.GenericMemory`
enumerated from the live GenericMemory TypeName caches. That is exactly the case
where the literal IS an empty-GenericMemory singleton:

- `length == 0`, and `length` and `ptr` are `const` fields;
- it is permanent, rooted by its DataType;
- `Memory{T}(undef, 0) === Int64[].ref.mem === Memory{T}.instance`.

Why membership is exact and safe:

- **The window.** The test runs inside a GC-disabled window. The window opens
  BEFORE emission, closes after classification, and contains no yield point
  (asserted).
- **Exactness.** Inside the window, the object codegen named at K cannot have been
  freed and its address reused. Two live objects cannot share an address, so
  membership is exact.
- **Safety.** Unlike a dereference, a membership test cannot crash on a garbage,
  foreign or freed address.
- **Dereference rejected.** Dereferencing K was considered and rejected: on the
  reflection path, codegen's temporary roots are dropped after emission.

What happens to literals that are not certified:

- Every other literal is NOT seeded, and fails loud at its first SURVIVING use.
- A literal whose loads only feed provably-dead throw paths never walls. The
  corpus's error-message Strings are the example.
- Near-misses are refused: `unsafe_wrap(Memory{Int}, p, 0)` (length 0, but not
  the singleton), `Memory{Nothing}(undef, 5)`, and any `Ref`, String or box.

**No live session ⇒ nothing certified.**

- `.ll`/`.bc`/IR-text ingest certifies nothing by default: an address from another
  process is meaningless here and is never classified.
- The opt-in `jl_globals = :live_session` runs the same membership test for IR the
  caller asserts `code_llvm` produced in THIS process. This is safe even if that
  assertion is false, because membership never dereferences.
- Imaging-mode IR (`--image-codegen` / pkgimage generation) has no address and is
  refused: there the slot is an `external` declaration, relocated at load.

**Contract shape.** A certified literal is shipped under an opaque OBJECT key
`jl_global#N.obj`, never the slot name. Slots sharing one K share one key. The
payload is a 16-cell ew-8 byte-tier header blob:

- `length@0 = 0`;
- **`data-ptr@8 = EMPTY_MEMORY_DATA_SENTINEL = GLOBAL_BASE + 2^47`** (D3).

The pre-amendment data pointer was 0. That was unfaithful: Julia's real data
pointer is never null, and 5viz copies that field. The sentinel is:

- non-null, like the real pointer;
- identical in every function's copy, so base-cancelling `ref.ptr − mem.ptr`
  arithmetic is exactly as before;
- never allocatable;
- inside the globals-tier read-window trap band
  `[GLOBAL_BASE, TLS_BASE − _TLS_TIER_GUARD)`. A dereference of a length-0
  Memory's data pointer is always UB, and here it TRAPS loud at the `MemoryLoad`
  instead of silently reading `memory[0]`.

Residual: two DISTINCT empty singletons share the sentinel data pointer (in real
Julia they differ). Only aliasing heuristics can observe this, and the corpus has
no such comparison.

Other consequences:

- **Caching.** ParsedIR carries no address and no certificate, so a certified
  ParsedIR may be cached or reused across sessions. The classification is a
  property of the program's code and const bindings, which is the same staleness
  caveat every extraction cache already has.
- **Type-tag globals** (Lever 1, `+Type#N`) are unchanged: still recognised by
  name, never by address.
- **`optimize=true` IR** that folds the slot load into a direct use of
  `@"jl_global#N.jit"` is refused loud (Bennett-fnxh / O1). Extract at
  `optimize=false`.

**BennettVM impact.** No `src/` change:

- `_global_segment` already copies the blob verbatim
  (`reinterpret(Int64, data[k+1])`).
- The trap band already exists (`memory_floor.jl`).

Pinned by `test/test_hsm3_literal_certification_vm.jl`:

- non-singleton literals throw `Bennett-hsm3` at extraction, so `lower_vm` never
  runs;
- the user-held empty singleton runs `== oracle` and reverses exactly;
- the sentinel lies in the trap band, and a `MemoryLoad` at it traps.

The existing Julia-extraction E2E files are unaffected: they bind only certified
singletons.
