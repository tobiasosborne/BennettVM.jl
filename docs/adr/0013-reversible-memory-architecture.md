# ADR 0013 — Reversible-memory architecture (language-agnostic LLVM-opcode contract)

> Status: **ACCEPTED** (2026-05-28). Umbrella architecture for SC9 Cases A
> (dynamic memory) & B (`Dict`) — the load-bearing reason BennettVM
> exists (it unlocks while-loops / dynamic memory / `Dict` for the next
> version of Bennett.jl). Synthesized from a 3-agent research pass (Rule 6
> Core tier: prior-art / reusable-substrate / language-agnostic-contract,
> reports 2026-05-28) + the orchestrator's own empirical probes. Direction
> and the `Dict` model (**D3**) chosen by the project lead (2026-05-28).
> **Subsumes the bead-chain framing of the M_DYN / M_DICT ADRs (0008,
> 0009) and `bennettvm-jrc`** (see §Consequences).

## Context

The four SC9 motivating cases split by *how they reach BennettVM*:

- **Arithmetic + control flow** (collatz / Case D done; nested loops /
  Case C done, ADR 0010): reachable via Bennett.jl's LLVM extractor →
  `ParsedIR` → `lower_vm`.
- **Heap** (dynamic `Vector` / Case A; `Dict` / Case B): **NOT reachable**
  through Bennett.jl's Julia-function extractor. Verified empirically
  (2026-05-28): Julia GC allocation emits a thread-local GC-frame read
  (`call ptr asm "movq %fs:0,$0"` / `julia.get_pgcstack`) rejected at
  `Bennett.jl/src/extract/instructions.jl:2103` (`Bennett-5oyt / U15`)
  *before any `ParsedIR` exists*; `Dict` is additionally rejected by
  design (`Bennett-800b`). This holds for `mem=:auto`, `mem=:persistent`,
  and `optimize=false` alike. The bead-chain assumption ("intercept the
  reject in BennettVM ingest") is therefore false: there is no ParsedIR
  to intercept. Unlocking A/B is an *integration-architecture* question
  (PRD v4 §VIII.2, the deferred boundary question), not an ingest gap.

**Binding directive (project lead, 2026-05-28):** BennettVM must be a
reversible VM **over LLVM opcodes — useful to ANY emitter (C, Rust,
Julia) — and sensible without Bennett.jl.** Bennett.jl source changes to
make the Julia path seamless are welcome and anticipated. This rules out
a Julia-specific frontend (no `code_typed`-only path) as the core.

## Decision

### D-1. The contract is LLVM-opcode-level IR; BennettVM is emitter-agnostic.

BennettVM consumes `Bennett.ParsedIR`, which already *is* an
LLVM-opcode-level IR (its `IR*` types mirror `alloca`/`load`/`store`/
`getelementptr` faithfully — `Bennett.jl/src/ir_types.jl:144–196`). The
language-agnostic entry point already exists:
`extract_parsed_ir_from_ll` / `_from_bc`
(`Bennett.jl/src/extract/entry.jl:125,177`) accept `.ll`/`.bc` from any
emitter and share the same converter as the Julia-function path. The
Julia-specific GC-frame reject is x86-Julia-TLS and **never fires on a
C/Rust `.ll`**. A pure-integer C/Rust kernel flows through to `lower_vm`
today. **No new IR reader is built** (Law 2). A concrete C-`.ll`
round-trip demo is part of the build (D-5) as the executable proof of
emitter-agnosticism.

The one language coupling in the contract is `IRCall.callee::Function`
(`ir_types.jl:206`, a Julia object). Fix: add `callee_name::Symbol`
alongside it (a small Bennett.jl change, D-4).

### D-2. Reversible memory = a universal "store-level" floor (PRD-mandated).

PRD v4 §3.2 (l.429) and §3.7 (l.705–711) already **mandate** an
`IRLoad`/`IRStore` → `Exchange` lowering ("Memory access MUST always be
an exchange (Vieri 1995 §4.2.1)… pairs every effective load with an
explicit zero-write"). The literature (RC3 `MemoryInterchangeInstruction`
/ `MemoryAssignment`, Axelsen-Glück 2013, Mogensen 2018) confirms the
exchange model + the Bennett-1973 history tape applied to memory. Per
universal LLVM opcode:

| LLVM op | BennettVM lowering | Injective? | History |
|---|---|---|---|
| `load` | `MemoryInterchange x := M[a] := 0` (displaced value → fresh zero RSSA var; zero by construction in well-formed RSSA) | **Yes** | **L1** none |
| `store` (zero-precond holds) | `MemoryInterchange old := M[a] := v`, `old` routed to a zero ancilla | **Yes** | **L1** none |
| `store` (lossy overwrite) | record `(addr, old)` | No | **L2** delta |
| `alloca` (static N) | zeroed region; (alloc,free) is identity under the zero-invariant | Yes | **L1** none |
| `alloca` (dynamic N) | as above + record `(base, n)` | No | **L2** delta |
| `getelementptr` | `ArithmeticAssignment addr := base + idx*stride` (dual modop) | **Yes** | **L1** none |

This **floor makes any emitter's raw heap reversible** — it covers Case A
(dynamic `Vector`) directly, and a C/Rust array program for free. It
**reuses** the existing `MemoryInterchange` (= reversible load, L1),
`MemoryAssignment` (= in-place modop store, L2 empty payload), and
`MemorySwap` (`src/ir/memory_instructions.jl`) plus the shared zero-init
("absent key = 0") convention. A **store-RHS-vs-LHS aliasing guard**
(port of RC3 `AliasingAnalysisPass`, PRD §3.5) is added so multi-store
operations reverse in correct order.

### D-3. `Dict` = a BennettVM reversible-map ADT (lead's choice: option D3).

> **⚠ AMENDED by ADR 0015 (2026-06-04, lead).** This D-3 design (recognize
> `Dict` ops → `IRMap*` → `RevMap`, i.e. "route (a)") is **DEMOTED to a
> quantum-circuit-lowering optimization**. The **correctness path for `Dict`**
> is **route (b)** — reversibly executing the raw lowered opcodes over the §D-2
> store-level floor, identical to Case A (Vector); the Dict's `keys`/`vals`
> `Memory` is just heap the floor already reverses. The `RevMap`/`IRMap*` work
> below is **retained as-is** for the optimization tier (it is already built and
> proven VM-side) — do not delete it, and do not re-promote it to *the* path.
> SC9 Case B is engineering (generalize the `m9i` Memory recognizer + a
> deterministic-hash-key fail-loud guard), **not** research-grade. Do not
> relitigate; see `docs/adr/0015-dict-route-b-correctness-floor.md`.

Julia's `Dict` cannot be cheaply inlined to raw stores (GC-allocated
backing + data-dependent rehash), and `(k, old_v)`-capture alone is
**not** reversible under a rehash (the probe-sequence/layout changes).
Therefore:

- **Bennett.jl** *recognizes* the high-level `Dict` operations
  (`setindex!`/`getindex`/`delete!`) and emits **language-neutral**
  high-level map ops (working names `IRMapInsert` / `IRMapGet` /
  `IRMapDelete`) — it does **not** inline Julia's hashtable.
- **BennettVM** implements a **reversible map it fully controls**: its own
  representation (so there is no foreign rehash to reverse), with delta
  history capturing `(k, old_v_or_missing)` on insert and `(k, old_v)` on
  delete; `getindex` is injective (no history). Candidate representation:
  reuse Bennett.jl's **Conchon-Filliâtre semi-persistent map**
  (`Bennett.jl/src/persistent/research/cf_semi_persistent.jl`, whose Diff
  chain *is* the Bennett-1973 tape) as the backing structure, or a simple
  reversible balanced tree.
- This is **language-agnostic at the semantic level**: any frontend that
  recognizes its language's map type emits the same `IRMap*` ops; a
  raw-hashmap C program that does not is still covered by the D-2
  store-level floor.

### D-4. Bennett.jl is one frontend; three scoped changes unblock the Julia path.

Each cites this ADR, gets its own review, and (for the core change) the
3+1 protocol (Bennett.jl Rule 2):

1. **Trivial** — silent-drop the `movq %fs:0` TLS inline-asm at
   `extract/instructions.jl:~2101` (mirror the existing
   `_heap_is_allowlisted_tls_asm` allowlist). ~5 lines.
2. **Core** — a `mem=:vm` extraction arm: lift the back-edge guard
   (`heap.jl`) and the M4 `Dict` scope guard; translate dynamic-N
   `Core.memorynew` → `IRAlloca(n_elems=SSAOperand)` + element traffic →
   `IRLoad`/`IRStore` (for `Vector`); recognize `Dict` ops → the
   `IRMap*` high-level ops (D-3). Additive: `:auto`/`:heap`/`:persistent`
   stay byte-identical.
3. **Small** — `IRCall.callee_name::Symbol` for language-neutral callee
   identity (`ir_types.jl:206`).

### D-5. Build order: language-agnostic core first, then the Julia feed.

1. **BennettVM reversible-memory floor** (D-2): `IRAlloca`/`IRLoad`/
   `IRStore`/`IRPtrOffset`/`IRVarGEP` ingest + the Exchange lowering +
   aliasing guard. Test on hand-built `ParsedIR` **and a real C-emitted
   `.ll`** (proof of D-1 / emitter-agnosticism). `IRCast` (the immediate
   non-memory gap) lands here too.
2. **Bennett.jl `mem=:vm` arm** (D-4.2) to feed Julia `Vector`.
3. **Case A** (dynamic `Vector`) end-to-end round-trip gate (SC9).
4. **BennettVM reversible-map ADT** (D-3) + **Bennett.jl `Dict`
   recognition** → **Case B** (`Dict`) end-to-end round-trip gate (SC9).

## Consequences

- **Supersedes** the "intercept the reject" framing of the M_DYN/M_DICT
  bead chains and the ADR 0008/0009 placeholders; reframes
  `bennettvm-jrc` ("PersistentDictRef") as the language-agnostic `IRMap*`
  + reversible-map ADT of D-3. These beads are updated, not closed-blind.
- **Pebble-game boundary (risk).** Dynamic-N `alloca` and unbounded maps
  cannot enter the Bennett-1989 pebble-game pass (PRD §3.4, needs uniform
  bounds). The `lower_vm` → pebble interface MUST fail loud (Rule 1) on
  dynamic-N inputs until a bound-analysis pre-pass exists (relates to M9).
- **Engineering hazards to address in the build** (from the prior-art
  report): (1) aliasing → the D-2 guard; (2) allocation-size
  recoverability → the dynamic-N `(base,n)` delta; (3) exchange-before-
  delta ordering (prefer L1); (4) reference-counted shared heaps —
  **deferred** (Julia GC is tracing; rare at LLVM level); (5) the
  zero-invariant is global — enforce statically or fall back to delta.

## Reuse (Law 2)

Reuse: `MemoryInterchange`/`MemoryAssignment`/`MemorySwap`
(`src/ir/memory_instructions.jl`); the three-layer history
(`src/history/`); Bennett.jl's `ParsedIR` contract + `.ll`/`.bc` entry
(`extract/entry.jl`); the Conchon-Filliâtre semi-persistent map
(`Bennett.jl/src/persistent/research/cf_semi_persistent.jl`) as the
candidate `IRMap*` backing; RC3 `AliasingAnalysisPass` (ported).
Why not reuse further: Bennett.jl's `:persistent_tree`/gate-level
reversibility is circuit-backend-specific (it produces a circuit, not a
VM program) — BennettVM models memory at the load/store level instead.

## Refs

- PRD v4 §3.2 (memory-as-exchange, l.429), §3.7 (`IRLoad`/`IRStore` →
  `Exchange` mandate, l.705–711), §3.3 (three-layer history), §3.6.2
  Cases A/B, §VIII.2 (integration-boundary open question), §3.4 (pebble).
- Vieri 1995 §4.2.1 (PISA exchange); Axelsen-Glück 2013 (reversible
  heap); Mogensen 2018 (reversible GC / RIL `MemoryAssignment`);
  Bennett 1973 (history tape). RC3 `MemoryInterchangeInstruction.java` /
  `MemoryAssignment.java` / `AliasingAnalysisPass.java`.
- Bennett.jl: `ir_types.jl:144–196,206`; `extract/entry.jl:125,177`;
  `extract/instructions.jl:2103`; `heap.jl`;
  `persistent/research/cf_semi_persistent.jl`.
- BennettVM: `src/ir/memory_instructions.jl`, `src/ir/ingest.jl`,
  `src/history/`, `docs/coverage-matrix.md`; ADR 0002 (delta/min-cut),
  ADR 0012 (lowering), ADR 0010 (nested loops).
- The three research reports (2026-05-28 session); CLAUDE.md Rules 1, 2,
  6, 14; the language-agnostic directive (memory `bennettvm-language-agnostic`).
