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
