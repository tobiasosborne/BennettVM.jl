# ADR 0015 — `Dict` reversibility: route (b) is the correctness floor; route (a) is a quantum-circuit optimization

> Status: **ACCEPTED** (2026-06-04). Decided by the project lead.
> **Amends ADR 0013 §D-3** (it does not supersede the rest of 0013).
> Subsumes the "research-grade / blocked" framing of SC9 Case B
> (`bennettvm-9i1`, `bennettvm-7xa`, Bennett.jl `Bennett-800b`).
> Grounded in a 3-agent codebase sweep + a live `code_llvm` probe
> (2026-06-04); see §Evidence.

---

> ⚠ **GROUND-TRUTH FINDING — 2026-06-08 (does NOT change the decision; for the lead).**
> The route-(b) premise here ("the Dict's `keys`/`vals` `Memory` backing = the
> store-level memory floor; reversibly execute the inlined opcodes") was verified
> against the REAL `code_llvm(fdict, Tuple{Int8,Int8}; optimize=false)` IR
> (committed at `test/reference/fdict_O0.ll`) and **does not hold for Julia 1.12.5**:
> there is NO in-body `jl_alloc_genericmemory` — the keys/vals/slots backings are
> interned GLOBALS (`@jl_global#146/#147`, the empty-`Dict` singleton), and the
> mutating WRITE lives inside the OPAQUE `@j_setindex!_NNN` callee (not inlined).
> So a pure store-floor route (b) cannot reverse a write it never executed, and
> there is no in-body alloc to model as a `DynAlloca` (no length witness). Two
> independent design proposers converged on this. SC9 Case B is therefore BLOCKED
> ON A LEAD DECISION between: **(A)** recognize the inlined `getindex` → the proven
> `RevMap`/`IRMapGet` (delivers bare `fdict` from source, but uses route-(a)
> primitives + revives the `9i1` recognizer this ADR called undecidable — i.e. the
> ground truth INVERTS which route is the tractable correctness floor); **(B)** defer
> bare-`fdict`, prove the route-(b) machinery on hand-built IR + fail loud; **(C)**
> Design G — extract/inline `setindex!` (the research-grade path this ADR demoted).
> The determinism guard (`90l`/`klgz`) is durable under any option. See `HANDOFF.md`
> (2026-06-08 session) for the full analysis and the two proposer reports.

---

## Context

ADR 0013 split the two heap-bearing SC9 cases by *how memory reaches the VM*:

- **§D-2 — Vector / raw heap = route (b):** lower `alloca`/`load`/`store`/
  `getelementptr` onto a universal *store-level reversible floor*. "This floor
  makes any emitter's raw heap reversible." Reversal is the three-layer history
  (L1/L2/L3); in the worst case L3 checkpoint-replay.
- **§D-3 — `Dict` = route (a):** Bennett.jl *recognizes* `setindex!`/`getindex`/
  `delete!` and emits language-neutral `IRMapInsert`/`IRMapGet`/`IRMapDelete`;
  BennettVM owns a `RevMap` ADT. Rationale: a `Dict` is GC-allocated with a
  data-dependent rehash, and `(k, old_v)`-capture alone is not reversible across
  a rehash — so "route (b) for `Dict`" looked both expensive and unsound.

In practice route (a) became *the* path for `Dict`, and that is what made SC9
Case B read as "blocked / research-grade":

- Julia **inlines** the isbits-key `getindex` (`d[k]`) at every optimize level
  to raw `Int8` hash arithmetic + an open-addressing probe loop over the Dict's
  `keys`/`vals` `Memory` backing + a `KeyError → unreachable` diamond — **no
  `@j_getindex` callee survives** (the `setindex!` *write* does survive as
  `@j_setindex!_NNN`).
- Route (a) therefore has to **re-recognize** "this inlined hash-probe soup is
  `M[k]`" and **prove the `KeyError` branch dead** — statically undecidable in
  general, version-fragile (bead `bennettvm-9i1`).

The error was conflating *"the recognizer is blocked"* with *"`Dict` is
reversibly-uncompilable."* They are different claims.

## Evidence (2026-06-04 grounding sweep)

Live `code_llvm(fdict, Tuple{Int8,Int8})` and a 3-agent read of both repos
established:

- The inlined `Dict` read is **deterministic raw opcodes**: pure integer hash
  arithmetic (`sext/xor/shl/mul/lshr` — *identical* to `hash(::Int8)`, **no**
  `objectid`/`pointer`/`ptrtoint`/`rdrand`), a probe loop (`load/cmp/branch`
  over the backing `Memory`), and a `KeyError`→`unreachable` dead-end.
- BennettVM's **L3 checkpoint-replay reverses ANY deterministic
  forward-executable instruction** — it snapshots `IState` (including `memory`)
  and replays; the instruction need not be locally invertible, only
  deterministic (`src/history/Replay.jl`). This is the rr lesson: "record
  nondeterminism, replay determinism" — and there is no nondeterminism to record
  for isbits keys.
- The store-level floor (§D-2) already reverses raw `alloca`/`load`/`store` **end
  to end on a C-emitted `.ll`** (`test_memory_floor_cll.jl`) and a dynamic-N C
  VLA (`test_dyn_roundtrip.jl`). The Dict's `keys`/`vals` `Memory` is the *same*
  kind of heap.

So reversibly **executing** the inlined `Dict` opcodes (route b) has **no
in-principle blocker for value-semantic keys**. The "research-grade" difficulty
is a property of route (a)'s *recognizer*, not of route (b)'s *execution*.

## Decision

**Correctness first; optimize on top.** This is the project's own established
pattern (ADR 0012 collatz: L3 trace-tape now, pebble-game later; ADR 0014:
memory floor "ships L3-correct first, then the L1 Exchange form lands as a perf
pass"; the three-layer history itself: L3 is the correct floor, L1/L2 are
optimizations on top). `Dict` was the one case that tried to ship the
*optimization* (route a) as the only path. This ADR restores consistency.

1. **Route (b) is the CORRECTNESS path for `Dict`,** identical to Case A
   (Vector). The `Dict`'s `keys`/`vals` `GenericMemory` backing is heap the §D-2
   floor already reverses; the hash is `IRBinOp`; the probe is ordinary control
   flow; the `KeyError` is a dead branch. **No new VM primitive is required** —
   route (b) for an isbits `Dict` is the Case A Memory recognizer
   (`bennettvm-m9i`) generalized to the Dict's backing, plus ordinary control
   flow, plus the memory floor (all of which exist or are in flight). SC9 Case B
   is **engineering, not research.**

2. **Route (a) (`Dict` recognition → `IRMap*`/`RevMap`) is RETAINED but
   DEMOTED** to a **quantum-circuit-lowering optimization**. It yields an O(1)
   reversible map primitive with an O(1) `(k, old)` delta that pebble-lowers
   cleanly (PRD §3.4 / SC5) — which the route-(b) probe loop over a growable
   store may *not* (it may carry no uniform bound). Route (a) is therefore **off
   the SC9 correctness critical path** and lands when the quantum/pebble tier
   needs it. The VM-side `RevMap` + `IRMap*` ops already built and proven
   (`test_dict_roundtrip.jl` Parts A/B, `test_revmap_roundtrip.jl`,
   `src/ir/revmap.jl`) are **preserved as-is** for that tier — do **not** delete
   them.

3. **Determinism is part of the correctness floor.** Route (b) is reversibly
   correct **only for deterministic-hash keys**. The extraction / VM boundary
   **MUST fail loud (Rule 1)** on identity/`objectid`-hashed keys (mutable
   structs with the default `hash` → allocation-address-dependent →
   *unreplayable*, a genuine in-principle blocker, the rr limit). isbits keys
   (Int8, Int, Float bit-patterns) and content-hashed keys (`String` via
   `memhash_seed`) are deterministic and in-scope; objectid-hashed keys are out.
   This guard is correctness, **not** a later optimization, and is not yet
   implemented (filed as a bead).

## Consequences

- **SC9 Case B is no longer "blocked / research-grade."** It is the Case A
  Memory recognizer generalized + the determinism guard. The load-bearing
  reason-to-exist gate becomes tractable engineering.
- **The Vector/Dict split of ADR 0013 §D-2/§D-3 collapses on the correctness
  axis:** both go through the store-level floor for correctness; recognition
  (`RevMap` for Dict; future Exchange/no-history forms for both) is an
  *optimization* layered on top, eventually feeding the pebble-game/quantum
  subset.
- **Beads:** `bennettvm-9i1` (route-a inlined-`getindex` recognizer) is closed as
  **superseded** — its residual value (the route-a recognizer as a future
  quantum optimization) is re-filed at P3. `bennettvm-7xa` (e2e `fdict` gate) is
  re-pointed off `9i1` and onto the new route-(b) Case B bead (→ `m9i`) plus the
  determinism-guard bead. `bennettvm-m9i` is annotated as the **shared
  prerequisite for both Case A and Case B route (b)**.
- **Bennett.jl `heap.jl` Dict reject** ("irreversible hash-table mutation by
  construction") remains correct **for the `:heap` path** but is **not** a
  statement about reversibility in principle; the `:vm` route-(b) path makes an
  isbits `Dict` reversible. Recorded in Bennett.jl `Bennett-800b` and its
  reversible-VM PRD so a future Bennett.jl agent does not re-litigate.
- **Pebble-game boundary (unchanged from 0013):** dynamic-N `alloca` and
  unbounded maps cannot enter the Bennett-1989 pebble-game pass without a
  uniform-bound pre-pass; the `lower_vm → pebble` interface must fail loud on
  them (relates to M9). This is exactly where route (a)'s `RevMap` re-enters as
  the optimization.

## Reuse (Law 2)

Same as ADR 0013 §D-2: the store-level memory floor
(`src/ir/memory_floor.jl`, `array_index.jl`, `alloca.jl`), the three-layer
history (`src/history/`), `Bennett.ParsedIR` + the `.ll`/`.bc` entry points.
The `RevMap` ADT and `IRMap*` ops (`src/ir/revmap.jl`) are retained for the
optimization tier rather than reimplemented or removed.

## Refs

- ADR 0013 §D-2 (route-b store floor), §D-3 (route-a, now amended), §Consequences
  (pebble boundary); ADR 0014 (memory floor "L3-correct first"); ADR 0012
  (collatz "trace-tape now, optimize later"); ADR 0002 (three-layer history /
  Enzyme min-cut).
- PRD v4 §3.6.2 Case B, §6 SC9, §3.3 (three-layer history / L3 replay), §3.4 +
  SC5 (pebble-game → quantum oracle).
- The 2026-06-04 grounding sweep (3 read-only agents + live `code_llvm` probe);
  rr (O'Callahan–Huey 2017) "record nondeterminism, replay determinism."
- Beads: `bennettvm-9i1`, `bennettvm-7xa`, `bennettvm-m9i`, `bennettvm-xkl`;
  Bennett.jl `Bennett-800b`.
- BennettVM: `src/history/Replay.jl`, `src/ir/memory_floor.jl`,
  `src/ir/revmap.jl`, `test_dict_roundtrip.jl`, `test_dyn_roundtrip.jl`,
  `test_memory_floor_cll.jl`, `test_revmap_roundtrip.jl`.
