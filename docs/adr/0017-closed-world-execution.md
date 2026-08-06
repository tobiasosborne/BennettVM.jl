# ADR 0017 — Closed-world reversible execution (Option C): calls, heap, intrinsic boundary; C-first validation

**Status:** ACCEPTED 2026-06-10 (lead decision, bead `bennettvm-e67u`).
**Supersedes:** the *executability premise* of ADR 0015 (that the store-level
memory floor alone can reversibly execute bare `fdict` IR). ADR 0015's role
assignment for route (a) — RevMap/`IRMap*` recognition as a
quantum-circuit-lowering optimization (`bennettvm-o1y`) — is **retained**.
**Amends:** ADR 0013 (the language-agnostic memory contract gains a heap tier
and an intrinsic boundary); ADR 0016 D8.

---

## Context

The 2026-06-08 probe (`test/reference/fdict_O0.ll`, Julia 1.12.5,
`code_llvm(fdict, Tuple{Int8,Int8}; optimize=false)`; HANDOFF.md 2026-06-08)
refuted ADR 0015's premise:

- The Dict `keys`/`vals`/`slots` backings are **interned globals**
  (`@"jl_global#146/#147"`, the empty-Dict singleton, ll. 9/28/29) — there is
  no in-body `jl_alloc_genericmemory` to model as `DynAlloca`.
- The write is the **opaque callee** `@"j_setindex!_149"` (l. 59) — the VM
  never sees the write's opcodes, so it cannot execute the write *forward*,
  let alone reverse it.
- Only the `getindex` read is inlined (hash arithmetic + open-addressing
  probe + KeyError diamond, ll. 102–157).

Three options were tabled at `bennettvm-e67u`: **A** — recognize the inlined
`getindex` → proven `RevMap` (fast, Julia-1.12.5-specific, fragile); **B** —
defer bare `fdict`, prove machinery on hand-built IR; **C** — extract/inline
the opaque callees and model the global backings.

The lead's product north star (recorded 2026-06-10, this session): *a
programmer writes completely normal Julia/Rust/C — unbounded loops, floats,
Dicts — with no side effects and no opaque syscalls; Bennett.jl yields a
fixed circuit when unrollable, else fails loud; switching the backend to
BennettVM yields an executable reversible program; correctness before
performance; the quantum lowering comes only after the VM story is rock
solid.* The "no side effects / no opaque syscalls" constraint **is** a
closed-world assumption: everything the function does is in principle
visible as LLVM IR.

Under that story, option A cannot be the correctness floor (no recognizer
generalizes to Rust's SipHash/SwissTable `HashMap` or a hand-rolled C table;
recognition is the right technology only for the quantum tier, where
data-dependent probe sequences cannot lower to fixed circuits anyway). And
option C is not Dict-specific research — it is the product: Dict is merely
the first construct big enough that Julia stopped inlining it.

## Decision

Adopt **Option C, reframed as four general capabilities** ("the closed-world
execution stack"). The Dict blocker dissolves into capabilities the story
requires anyway:

1. **Closed-world IR acquisition** (front-end, Bennett.jl). The transitive
   call graph reaches the VM as IR. For C/Rust: compile to a single LLVM
   module (LTO) and ingest via the existing
   `extract_parsed_ir_from_ll`/`_from_bc`. For Julia: recursive callee
   extraction (the opaque `j_setindex!` *has* IR; the extractor must ask for
   it), plus extraction of interned-global initializers.
2. **Reversible call/return** (VM). Multi-function `VMProgram`; calls and
   returns are reversible transitions in the BobISA/PISA discipline (the
   return must recover the call site from local state — jumps encode their
   source). General `IRCall` ingest replaces the whitelist-only path.
3. **Reversible heap floor** (VM). A deterministic arena allocator: the VM
   owns its virtual address space, so allocation addresses are deterministic
   by construction. At the correctness floor, `free`/GC is a **no-op**
   (arena semantics — the run terminates; leaked space is history cost, and
   the lead's correctness-first rule explicitly accepts an expensive floor);
   `realloc` = alloc + copy; globals = initialized memory segments.
4. **A bounded intrinsic boundary.** Recursion bottoms out at runtime/libc
   walls. A small whitelist — `malloc`/`calloc`/`realloc`/`free`,
   `memcpy`/`memmove`/`memset`, `jl_alloc_genericmemory`, `gc_alloc_obj`,
   throw/`unreachable` — gets hand-written reversible semantics, once,
   language-agnostically (each language's runtime maps onto the same set).
   Everything outside the whitelist fails loud (Rule 1).

### 4a. Confined values: admission without an oracle-match proof (Bennett-foz5, 2026-08-06)

**Context.** The keep-branch dead-block pruner (Decision item 4 / Bennett-utzc) leaves the predecessor's conditional branch into a pruned `unreachable` block intact, so a guard that fires at runtime reaches BennettVM's `:__unreachable__` halt sink — described in `module_walk.jl` as "a faithful reversible throw". That description presumes the guard's condition is computed from values admitted under **oracle match**: every admitted value provably equals what native computes.

Julia's `@boundscheck` cluster under `--check-bounds=yes` computes a pointer difference across the two halves of a **split captured `MemoryRef`** — the `.ptr_or_offset` half read from the closure environment struct, the `.mem` half read from the GC-roots array. The two halves arrive through different function arguments with no SSA edge between them, and the only in-body pairing witness is a dead `insertvalue` that survives solely because extraction runs at `optimize=false`. Oracle match is therefore **not provable extraction-locally**, and never will be. (It is nevertheless expected to *hold* at runtime, because BennettVM's Julia tier is byte-granular (`_byte_cells`) and the closure slot is written by extracted code — but that is a property of the closed world, not a theorem the extractor can check.)

**Decision.** Introduce a *second*, strictly weaker admission contract, applicable **only** to values whose entire influence on the program is a dead-throw branch condition:

> **CONFINED-VALUE CONTRACT.** A value `v` may be admitted without an oracle-match proof iff a syntactic predicate establishes all of:
> (i) `v`'s source pointer is a **certified cell producer**, and is neither unnamed nor suppressed by the emission walk. "Certified cell producer" is exactly the positive whitelist below. Its depth discipline differs per arm, and is written out here because the guarantee is only as strong as it:
>   * an `extractvalue` of a StructType pointer field;
>   * a `load` of a pointer **whose pointer operand is not a `GlobalVariable`** — that shape is intercepted by the singleton-data alias arm, which emits no node at all and aliases the result name to a global symbol, so it is *registered without being materialised*. This arm is **depth-0 with respect to the loaded value's address**: the value a load produces is a fresh cell whatever its address was. A load *through* a WIDTH-0-SENTINEL address is therefore certified here, deliberately — the address question belongs to the load arm, whose node is emitted with or without a following coercion. **Clause (i) consequently does not provide sentinel-freedom for load-sourced values.**
>   * a `getelementptr` **whose base chain terminates in one of the above**. This arm is recursive precisely so that an interposed GEP cannot launder a PointerType `phi`/`select` — the Bennett-cc0 M2b WIDTH-0 SENTINEL, whose routing lives in `ptr_provenance` at lowering time rather than as a value — into a certified source. Index constness is not required (the corpus GEP has a variable index).
>
>   A PointerType `phi`/`select` is thus never certified **as a source, nor as a GEP base**. It may still appear as the *address* of a certified `load`, per the arm above;
> (ii) `v` has at least one use, and **every** use is a two-operand **i64** `sub` whose sibling operand is itself a `ptrtoint`;
> (iii) every use of each such `sub` is an `icmp`;
> (iv) the transitive use-closure of each such `icmp` contains only i1-typed `and`/`or`/`xor` instructions, each with at least one use, and conditional `br` terminators consuming the value as their **condition operand**; and every such `br` has at least one successor in the Decision-item-4 pruned dead-block set.
>
> For such `v` the guarantee is: **for every input on which the native program returns a value, the extracted program returns the same value or halts at the `:__unreachable__` sink.**

**What this relaxes, stated exactly.** Decision item 4's "faithful reversible throw" is retained **unchanged for guards admitted under a proof** (Bennett-583s base-cancellation, Bennett-jbko pointer identity, Bennett-8g7m). For a guard whose condition depends on a confined value it is downgraded from *proved faithful* to **unproved**: the throw may be missed, or the halt may be spurious, on inputs where the unprovable premise fails. Neither direction is *authorised* — both are *unbounded by the theorem*.

**Explicitly NOT weakened.**
(a) **Oracle-match proofs retain first refusal.** Where Bennett-583s's base-cancellation proof applies, it is used; the confined contract is consulted only after it fails (`||` short-circuit). A value with a single non-conforming use stays under oracle match and stays rejected.
(b) **No guard bit is ever fabricated.** Extraction never substitutes a constant, a zero cell, or any other placeholder for an operand of an unmodellable guard, and never rewrites or elides the compare or the branch: the `sub`, the `icmp`, the i1 algebra and the `br` are all emitted verbatim by the ordinary paths, and the coercion emits the same cell-identity node the base-cancellation proof emits. The bit is therefore *computed*, from operands the extraction has emitted defining nodes for — which is a claim about **provenance, not about correctness**. It is not a claim that those operands equal the native values (that is exactly what the contract declines to prove), nor, per clause (i)'s load arm, that every cell they transitively read was itself materialised. Emitting a placeholder that provably weakens a guard remains **UNSOUND** — the Bennett-lbot ruling is reaffirmed, not narrowed: under BennettVM's arena model there is no region table and three monotone cursors (`bennettvm-pdqx`), so a missed throw is an *undetectable* adjacent-allocation clobber, and ADR 0018 §E defines an unstored load as `0`.
(c) **Determinism (ADR 0018 §A) is untouched.** The contract neither relies on nondeterminism nor admits any new nondeterministic producer; the Bennett-klgz guard sits at the unrecognised-JIT-global reject and is unreachable from this admission.
(d) **The circuit tier is untouched.** The admission lives inside the `ptr_cells` gate, which is `false` on the circuit path; `verify_reversibility` and gate counts are byte-identical.

**Disclosed residual.** A confined value that were nondeterministic could make the *halt itself* nondeterministic. This is a reproducibility, not a correctness, degradation, and does not arise under ADR 0018 §A's deterministic arena.

**Corollary (determinism guard re-scope).** With a deterministic virtual
heap, address-based hashing (`objectid`, `ptrtoint` of heap pointers) is
deterministic *inside the VM*; the "one genuine in-principle blocker" of
ADR 0015 is dissolved at the VM tier. It re-emerges at the circuit tier
(address-dependent control flow ⇒ data-dependent circuit structure), so the
`bennettvm-90l` guard's long-term home is the circuit-lowering boundary, not
VM ingest. The guard remains worth building; its placement changes.

## Sequencing (epic: closed-world execution)

- **CW-A — Heap floor.** Design (ground truth: Axelsen–Glück 2013 reversible
  heap; Mogensen 2015 RIL/GC; Vieri PISA exchange discipline), then
  implement arena + intrinsics; prove on hand-built IR (absorbs option B as
  sequencing, including the multi-backing machinery).
- **CW-B — Calls.** Design (ground truth: BobISA — see PHASE.md citation
  erratum, Thomsen–Axelsen–Glück 2012 vs Axelsen–Yokoyama 2011; Vieri
  1995/1999), then multi-function `VMProgram`, general `IRCall` ingest,
  interpreter forward/`unstep!`, round-trip + mutation-proof tests.
- **CW-C — C-language validation.** A small open-addressing hash table in C,
  compiled by clang (18.1.3 local) to one `.ll` module — *no opaque callees,
  no GC, no interned singletons*. Bennett.jl `from_ll` grows multi-function
  + globals + intrinsic-call support; e2e round-trip on the VM, golden
  master against native execution. This is the first full demonstration of
  the story's language-agnostic claim.
- **CW-D — Julia closed-world extraction.** Recursive callee extraction,
  Julia-runtime intrinsic mapping, interned-global extraction; then bare
  `fdict` from source round-trips (`bennettvm-7xa` re-pointed here).

Work proceeds **serially** (Rule 7 plus integration of learnings); both
repos are in scope (lead approval 2026-06-10 satisfies Rule 14 / the
CLAUDE.md Bennett.jl-mutation gate for this workstream).

## Consequences

- Longest road to a green Julia `fdict` (multiple sessions). Option A
  remains available as a *demo-only* stopgap, never the floor.
- `bennettvm-tu9` (generalize Memory recognizer to Dict backing) is
  superseded. `bennettvm-o1y` (route (a) as quantum optimization) unchanged.
  `bennettvm-90l` re-scoped per the corollary. `bennettvm-u110` (ingest.jl
  Rule-10 split) will likely be forced by CW-B's ingest work.
- The VM's `RevMap` stays built and tested — it is the quantum-tier target
  shape that route (a) recognition will map onto.
- **Acquisition friction (Law 1):** the reference PDFs listed ✅ HAVE in
  `references/manifest/SOURCES.md` are absent on this machine (never
  committed; licensed sources). Each CW design step is gated on its ground
  truth being locally present; openly-licensed items (MIT theses, arXiv)
  are re-acquired, the rest must be synced from the acquisition machine.

## Reuse (Law 2)

- **Calls:** BobISA jump/call discipline (source-encoding jumps);
  Pendulum/PISA subroutine + memory-exchange rules (Vieri 1995 §, 1999 §).
  Why not reuse further: BobISA/PISA target hardware ISAs; we adapt the
  discipline to a block-structured VM over LLVM-derived IR.
- **Heap:** Axelsen–Glück 2013 (reversible heap manipulation), Mogensen
  2015 RIL §3 (reversible GC context). Why not reuse further: the
  no-free arena floor is deliberately *simpler* than published reversible
  GC — correctness-first; reversible reclamation is a later optimization.
- **C track:** stock clang/LLVM toolchain; Bennett.jl's existing
  `extract_parsed_ir_from_ll`. Why not reuse further: n/a — pure reuse.
