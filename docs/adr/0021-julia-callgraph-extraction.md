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
   `MethodInstance` — `mi_of(x)` helper, pinned by test. Callgraph edges
   are resolved from the SAME O0 inference run that produced the body.
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
