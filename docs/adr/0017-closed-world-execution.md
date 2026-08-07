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

**What this relaxes, stated exactly.** Decision item 4's "faithful reversible throw" is retained **unchanged for guards admitted under a proof** (Bennett-583s base-cancellation, Bennett-jbko pointer identity, Bennett-8g7m, Bennett-57hd value identity — §4b). For a guard whose condition depends on a confined value it is downgraded from *proved faithful* to **unproved**: the throw may be missed, or the halt may be spurious, on inputs where the unprovable premise fails. Neither direction is *authorised* — both are *unbounded by the theorem*.

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

### 4b. Value identity: oracle match for a base-cancelling difference through memory (Bennett-57hd, 2026-08-07)

**Context.** §4a's confined-value contract deliberately says nothing about values that ESCAPE. Julia's `push!` closed-world ROOT computes `array.ref.ptr_or_offset − array.ref.mem.data` — the `MemoryRef`'s byte displacement inside its `GenericMemory` — converts it to an element index with `udiv exact 8`, and lets that index escape: into a live grow-or-not branch, and into two closure-environment slots that `_growend!` reads as `jl_alloc_genericmemory_unchecked`'s **allocation size** and `llvm.memmove`'s **length**. Bennett-583s declines because `_memdata_root` establishes base cancellation by **syntactic SSA equality** of the two `.data` loads, and here the two operands are the two halves of **one `MemoryRef`**, both read out of one freshly `julia.gc_alloc_obj`-ed `Array` header, related through one aggregate store and one same-slot reload rather than through one SSA name. §4a declines, and correctly: clause (iii) requires every use of the `sub` to be an `icmp`, and there is no dead-throw sink to confine an escaping index into. Under the arena model (`bennettvm-pdqx`: no region table, three monotone cursors; ADR 0018 §E: an unstored load reads `0`) a wrong allocation size is an undetectable adjacent-allocation clobber. **No confinement-class contract is available for this shape, and none may be invented; §4a must not be widened to reach it.**

**Decision.** Introduce a *third* admission contract, at the **existing (oracle-match) strength** and never a weaker one, applicable to a `ptrtoint` whose every use is a difference of two provably identical pointers:

> **VALUE-IDENTITY CONTRACT.** A `ptrtoint ptr %S to i64` (`pt`) may be admitted as a width-64 cell identity iff a syntactic, single-basic-block predicate establishes all of:
> (i) `%S` is a **certified cell producer** in the §4a clause-(i) sense (`_foz5_cert_src_kind`), named by the emission walk and not suppressed;
> (ii) `pt` has at least one use, and **every** use is a two-operand **i64** `sub` whose sibling operand is itself a `ptrtoint` of a source `%T` also satisfying (i);
> (iii) for every such sibling, `%S` and `%T` lie in **one basic block** and reduce to the **same canonical value** under a straight-line copy analysis confined to that block, whose only inference steps are (a) forwarding a pointer-result `load` to the value written by the uniquely-reaching store to the same canonical slot, through the `insertvalue` chain of an aggregate store, and (b) equating two loads of one canonical slot across a window containing no writer to that slot; and
> (iv) every store the analysis forwards through targets a **p06b-certified cell pointer**, so that the copy step it reasons about is one the extraction materialises as cells.
>
> **Loop safety, stated because its absence otherwise reads as an oversight.** No back-edge condition appears above and none is needed. A basic block executes **as a straight line on every entry** — control enters only at the top and leaves only at the terminator — so every fact clause (iii) establishes ("this store wrote that slot", "nothing between them wrote it") is a statement about ONE ITERATION, and the load reads what the store wrote *in that same iteration*; a previous iteration's write is irrelevant precisely because the current iteration overwrote it before reaching the load. Clause (iii) further requires `%S` and `%T` to lie in that block, and LLVM SSA admits a use of an earlier iteration's definition only through a `phi`, which clause (i) refuses outright. The two sources are therefore always same-iteration, and the identity proved between them holds on every entry.
>
> Writers are determined **fail-closed**, from LLVM's own attributes rather than from a table of callee names: an intervening `call` writes unknown memory **unless** its `memory` (MemoryEffects) attribute — read at the call site, falling back to the callee declaration — proves it writes neither argument memory nor other memory, or it is `llvm.memcpy`/`memmove`/`memset` with a compile-time-constant length, in which case it writes exactly `[dst, dst+n)`. Two roots are disjoint only when one is a `noalias`-returning call whose result the other provably **predates**, or a non-escaping `alloca` proved by a `nocapture`-attribute use scan (call site **or** callee declaration). A same-root byte-range non-overlap judgement is taken only when `_root_scale(root)` is the **byte tier** (1 byte per cell), so that native byte disjointness transports to VM cell disjointness. Every unmodelled effect, every non-constant length, every negative length, every unretrievable attribute and every cross-block window terminates the analysis unsuccessfully. A call carrying **any operand bundle** is unmodelled by definition and terminates it too, whatever its `memory` attribute says: LLVM's own `CallBase::getMemoryEffects()` ORs in `writeOnly()` for a clobbering bundle, so the raw attribute alone would believe a truthful `memory(none)` declaration about a call LLVM itself treats as a writer.
>
> For such `pt` the guarantee is: **each admitted `sub` evaluates to `0` in the native program and to `0` in BennettVM, on every input, under any map from native addresses to pointer-cell values.**

**Why this is an ORACLE-MATCH contract and §4a is not.** §4a admits a value it *cannot* prove equals native's, and buys safety by proving the value's only influence is a halting branch. §4b proves the *equality itself*, and needs no claim about the value's influence: 583s's proof needs the representation map `φ` to be translation-cancelling within a region, jbko's needs `φ` injective, and §4b needs **nothing of `φ`**, since `φ(p) − φ(p) = 0 = p − p` for every function `φ`. The admitted value is therefore layout-independent and may escape without restriction — into `udiv exact`, into a live branch, into an allocation size and a memmove length — because it is *correct*, not merely *confined*.

**Failure-direction matrix (both columns bounded).**

| | native RETURNS a value | native THROWS |
|---|---|---|
| **§4b admits** | the extracted program returns the **same** value; the admitted difference is the constant `0` in both worlds, so no downstream value differs from what the pre-existing model would have produced | the extracted program takes the **same** branch at every downstream guard *whose operands this contract supplies*, and it supplies them oracle-exact. This is not a claim that the whole program's throw behaviour is proved: it is the conjunction of (a) the §4a conditioning clause — everything outside `τ` is computed by the pre-existing, already-sound model — with (b) §4a clause (iv), under which a §4a-admitted value can only ever operate a branch with a pruned `:__unreachable__` successor and therefore **never operates a live guard**. So a §4a admission elsewhere in the same program cannot silently degrade a guard fed by a §4b value. Given (a) and (b), a pruned throw block is reached exactly when native throws ⇒ Decision item 4's **proved-faithful** reversible throw, not §4a's downgraded one |
| **§4b declines** | the pre-existing loud `_ir_error` wall; nothing is emitted | same |

Contrast §4a's banner, which had to say "the throw may be MISSED, and the halt may be SPURIOUS; neither direction is authorised; both are UNBOUNDED by the theorem." **This section has no such paragraph, and that difference is its whole point.**

**What this relaxes: NOTHING.** Decision item 4's "faithful reversible throw" is retained unchanged. §4a's downgrade is **not extended**: a value admitted under §4b is proved, so it *satisfies* §4a's conditioning clause "everything outside `τ` is computed by the pre-existing, already-sound model" rather than violating it, and no clause of §4a is invoked. Bennett-jbko's trajectory-correspondence argument is likewise preserved **by construction**: the grow-or-not branch is decided by an oracle-exact index, so the allocation sizes derived from it, and hence `arena_top`, are provably the native ones. Had this value been admitted under a *declared* premise instead, §4a's and jbko's guarantees would both have become conditional on that declaration, and this ADR would have had to say so.

**Explicitly NOT weakened.**
(a) **583s and §4a retain first and second refusal.** The predicate is the **third** disjunct of both the arm's entry and its admission (`||` short-circuit); order of refusal is 583s → §4a → §4b, so no cluster an existing contract owns can change hands. `_memdata_root` is left byte-for-byte untouched: probe `p07_steal.jl` measured that widening it makes the 583s arm claim jbko's `%L84` witness and then error. Non-steal is **structural** and measured over both corpus bodies: §4b is `false` on both 583s clusters, on all three §4a clusters, and cannot fire on jbko's witness, because (ii) demands every use be a `sub` while jbko demands every use be an `icmp eq`/`ne`.
(b) **Nothing is fabricated** (Bennett-lbot, reaffirmed). The `sub`, the `udiv exact`, the `add`s, the `icmp`, the `xor` and the `br` are emitted verbatim by the ordinary paths, and the coercion emits the same `IRBinOp(:or, src, 0, 64)` cell-identity node the other two contracts emit. No branch is folded, no cluster elided, no constant substituted — the difference is *proved* to be zero, never *assumed* or *written* to be.
(c) **Determinism (ADR 0018 §A) is untouched.** No new nondeterministic producer; the Bennett-klgz unrecognised-JIT-global reject is unreachable from this admission. The singleton empty `Memory` the corpus derivation passes through is a **recognised** JIT global, handled by the CW-D3 Lever-2 singleton-data alias arm.
(d) **The circuit tier is untouched.** The admission lives inside the `ptr_cells` gate, `false` on the circuit path; `verify_reversibility` and every gate count are byte-identical.

**Declared premises.** The theorem is unconditional; the *analysis* is the soundness surface, and it rests on exactly three declarations, none of them a Julia-ABI or codegen-layout claim (the class CLAUDE.md Rule 5 forbids): (P1) **LLVM attributes in the input module are truthful** — an *IR well-formedness* premise of the same class as "the `Sub` opcode means subtraction"; a false `noalias` or `memory(…)` would miscompile under LLVM's own optimiser, and a *missing* attribute always rejects. (P2) **`llvm.memcpy`/`memmove`/`memset` mean what LLVM says they mean**, identified by intrinsic name — the same premise the shipped Bennett-37mt / Bennett-vau9 / Bennett-sy29 arms already make. (P3) **ADR 0018 §A cell-copy fidelity** — a load/store/insertvalue copies a cell value verbatim; pre-existing, the substrate Bennett-jbko's shipped contract already stands on, and **executable**: `BennettVM/test/test_bvmd_byte_tier_vm.jl` gate (2) runs the store/load round-trip half today and `test_57hd_value_identity_vm.jl` runs this contract's exact shape. (P4) **LLVM.jl's instruction iteration over a basic block yields program order** — the substrate for the positional sequence and the definition-order test, and an LLVM.jl API premise rather than a Julia one. (P5) The VM transport of the second inference step ("two loads of one slot with no writer between return the same value") follows **inductively**, not by assumption: the base case is SSA ref equality, i.e. the same node and hence the same cell, and each store-forward hop is clause-(iv)-certified, so the copy the native world performs is a copy the extraction materialises. Each of (P1) and (P2) was measured load-bearing: reclassify the allocator's effects as unknown and the corpus lemma collapses.

**Disclosed residual and scope boundary.** The residual risk is not in the theorem but in the analysis: if the walker ever returns "same value" for two different values, the hypothesis is false and the consequence is a silently wrong allocation size. That is not hypothetical — a hostile review found and **executed** one such fail-open before landing (a `store ptr %a, ptr %a` self-store made a non-escaping `alloca` alias its own reloaded copy, a clobber was skipped, and the admitted difference ran to 64 on the VM against a guarantee of 0). It is closed, and the class is pinned by fixtures rather than by argument; a reader adding to this analysis should assume the next such hole exists and write the gate first. That is an implementation risk, not a weakening of this contract, and it is bounded by the fail-closed defaults, the single-block confinement, the depth and scan caps, and the pinned reject fixtures. A second-order form of it is that the `memory` attribute's value is a raw packed integer whose encoding is LLVM-internal and not a stable API; the decode therefore fails closed on any bit outside the locations this LLVM version defines, and two test canaries (`memory(argmem: readwrite)` must reject, `memory(none)` must admit) must move in opposite directions. The analysis is intraprocedural and single-block, so a copy chain crossing a call with unmodelled effects, or crossing a basic-block boundary, is refused — it degrades to the pre-existing loud wall, never to an admission. **Non-goal:** the contract does not propagate through `getelementptr i8` to admit a *nonzero* constant displacement; that generalisation was prototyped and measured to claim two clusters Bennett-583s owns while covering nothing new, and it re-acquires a byte-tier dependence this section is free of. A same-`MemoryRef` provenance-pair predicate resting on a declared Julia language invariant was considered and **rejected**: its failure mode is a silently wrong heap rather than a halt, it amplifies `bennettvm-jb6w`, and it was measured to cover nothing that §4a does not already own — the `%L21` / `%L43` clusters it was scoped around are admitted by the shipped §4a predicate today. The interprocedural extension is tracked separately (Bennett-v7gv) and is **not** authorised by this section.

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
