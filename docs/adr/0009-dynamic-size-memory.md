# ADR 0009 — Dynamic-size memory (SC9 Case A)

> Status: **ACCEPTED** (2026-05-31). M_DYN.1 milestone (bd
> `bennettvm-s4r`). BennettVM pin `c09544d`; Bennett.jl pin `7904560`
> (2026-05-28). Implements ADR 0013 §D-2 for the dynamic-N row of the
> memory floor and extends the scalar floor of ADR 0014 (§D4) to arrays
> of runtime size. **Supersedes the strategy framing of the bead chain
> `bennettvm-s4r` ("inherit `:persistent_tree`, extend via delta") and
> `bennettvm-0zn` ("route dynamic-N `IRAlloca` to
> `_lower_alloca_dynamic_n!`")** — see §Ground truth and §Consequences,
> exactly as ADR 0010 superseded the `bennettvm-720` interception
> framing.

## Context

Case A is PRD v4 §3.6.2 ("**Case A. Dynamic-size memory.**
`Vector{T}(undef, n)`, … `IRAlloca` whose `n_elems` operand is
`SSAOperand` rather than `ConstOperand`", l.610–612) and one of the four
SC9 motivating programs ("if SC9 fails, BennettVM has no reason to
exist", l.1059–1060). The PRD's design guidance is that
`target=:reversible_vm` "MUST handle dynamic-size memory in full
generality, **reusing the `:persistent_tree` mechanism where applicable
and extending it otherwise**" (l.617–619), and Part IV's reuse map lists
the persistent-tree strategy as "Reused for §3.6.2 case A; extended in
BennettVM for full generality" (PRD l.940).

The bead chain (written 2026-05-25, before any empirical probe) read
that guidance literally: `bennettvm-s4r` scopes "inherit Bennett.jl's
`:persistent_tree` … extend … via delta history" and `bennettvm-0zn`
scopes "route dynamic-N `IRAlloca` to `_lower_alloca_dynamic_n!` and
ingest the resulting persistent-tree shape". This ADR records that the
*"where applicable"* qualifier is load-bearing: the persistent-tree
machinery is **not applicable to the VM execution model** (Finding 1),
and Case A's reversibility is already decided by ADR 0013 §D-2 — a bump
allocation plus L2 element deltas, needing no persistent tree at all.

## Ground truth (verified)

**Finding 1 — Bennett.jl's `:persistent_tree` is circuit-backend-only;
it does not transfer to the VM memory model.**
`_lower_alloca_dynamic_n!`
(`../Bennett.jl/src/lowering/memory.jl:75–98`) is only wired for the
`:persistent_tree` strategy —

```julia
# memory.jl:79-81
strategy === :persistent_tree ||
    error("_lower_alloca_dynamic_n!: unsupported strategy :$strategy " *
          "(only :persistent_tree wired today)")
```

— and that strategy allocates **gate wires** via a `WireAllocator`:

```julia
# memory.jl:86-88
n_bits = _state_len_bits(impl)
wires = allocate!(ctx.wa, n_bits)
ctx.vw[inst.dest] = wires
```

It registers a persistent-map impl in `ctx.persistent_info` and a
`PtrOrigin` provenance for the circuit's GEP walkers (`memory.jl:91–96`);
it emits **no VM memory op**. Its output is consumed by Bennett.jl's
`lower()` → `ReversibleCircuit` pipeline. BennettVM's path is separate:
`lower_vm` (`src/ir/ingest.jl`) assembles a `VMProgram`
(`src/ir/ingest.jl:453,630`) whose heap is `IState.memory::Dict{Int64,
Int64}` (`src/ir/IState.jl:138`, "the addressable heap, as a sparse
map", l.58). There is no `WireAllocator`, no gate wire, and no circuit in
the VM. The literal persistent-tree machinery therefore does not
transfer; reusing it would require running Bennett.jl's circuit lowering
and then *re-extracting* a heap from gate wires — strictly more work than
the floor ADR 0013 already mandates. (This is the same shape of finding
as ADR 0013 §Reuse: "Bennett.jl's `:persistent_tree`/gate-level
reversibility is circuit-backend-specific … BennettVM models memory at
the load/store level instead.")

**Finding 2 — the VM mechanism is already decided by ADR 0013 §D-2.** The
memory-floor table classifies the two relevant rows
(`docs/adr/0013-reversible-memory-architecture.md:74–75`):

| LLVM op | BennettVM lowering | Injective? | History |
|---|---|---|---|
| `alloca` (static N) | zeroed region; (alloc,free) is identity under the zero-invariant | Yes | **L1** none |
| `alloca` (dynamic N) | as above + record `(base, n)` | No | **L2** delta |

and the narrative classifies a lossy overwrite as `store (lossy
overwrite) → record (addr, old) → No → L2 delta` (ADR 0013 l.73). Both
allocation metadata `(base, n)` and per-write `(addr, old)` are captured
by the existing delta layer — no persistent tree appears anywhere in the
decided design.

**Finding 3 — the delta layer supports both with no struct change, but
this is a *new addition* layered on the scalar floor, not a change to
it.** `DeltaEntry{T}` already carries an arbitrary
`payload::NamedTuple` (`src/history/delta.jl:272–285`), "the minimal
extra information the inverse needs beyond current state" (l.266–268),
empty in the dominant case but accepting `(old_value = …,)` /
`(base = …, n = …)`. The M7.4 fast-path pops a top-of-history
`DeltaEntry` and calls `inverse(entry.instruction, s.current,
entry.payload)` (`src/history/Replay.jl:333–339`). Crucially, the
**scalar** memory floor records *nothing* in deltas: `MemoryStore` /
`MemoryLoad` are `is_injective == false` with **no `make_delta`**, and
their `inverse()` *raises* — reversal is L3 checkpoint-replay only
(`src/ir/memory_floor.jl:212–235` forward; `:250–280` the raising
inverses; the module docstring "is_injective = false (the L3
baseline)", l.65–73). Dynamic-array writes that use an L2 `(addr,
old_value)` delta are therefore a **new layer** added on top of the
ADR 0014 floor for the array case; they do not retroactively change how
the scalar `n_elems = 1` store reverses.

**Finding 4 — `frtN` (the SC9 Case A canonical program) is undefined in
the PRD.** `frtN` is *named* in the SC9 four-program list
(`bennettvm_prd.md:656` and `:1056`) but §3.6.2 Case A (l.610–619)
gives only a description of the case, never a concrete program body — in
contrast to Cases B/C/D, which each ship a runnable snippet
(`fdict`/`matrix_sum`/`collatz_steps`, l.633/643/652). This ADR defines
`frtN` (Decision 3) and files a bead to patch the PRD.

## Decision

**1. The VM does NOT reuse Bennett.jl's `:persistent_tree`.** Per
Finding 1 it is circuit-backend-only. The PRD's "reuse `:persistent_tree`
*where applicable* and extending otherwise" (l.617–619) is satisfied by
judging it **not applicable** to the VM execution model and extending via
the ADR 0013 §D-2 floor. This supersedes the strategy framing of
`bennettvm-s4r` and the routing framing of `bennettvm-0zn`
(`_lower_alloca_dynamic_n!` is not called from `lower_vm`), exactly as
ADR 0010 found the `bennettvm-720` interception unnecessary. No overclaim:
the *semantic intent* of the PRD guidance (reuse a reversible-heap
substrate where it fits, extend where it doesn't) is honored — we reuse
the ADR 0013 floor's substrate (`IState.memory` + the delta layer) and
extend it to arrays. This decision also declines the *more directive*
reuse-map row at **PRD Part IV l.940** ("Reused for §3.6.2 case A;
extended in BennettVM for full generality"), which on its face mandates
the persistent tree; that row is overridden on the strength of Finding 1
(empirical: the strategy is circuit-only) and ADR 0013 §Reuse, which
already made the identical call for the memory umbrella.

**2. Two-mechanism design, both grounded in ADR 0013 §D-2.** Allocation
reversibility and mutation reversibility are *distinct* and neither
substitutes for the other:

  - **(a) Allocation = bump advance + an L2 `(base, n)` delta.** A
    dynamic-N `IRAlloca(dest, width, n_elems::SSAOperand)` resolves `n`
    at runtime, advances the ADR-0014 §D1 bump allocator by `n` cells
    reserving `base … base+n-1`, materialises the pointer `dest = base`
    in `locals` (the ADR 0014 §D1 `Define(dest, base, :add, 0)` pattern),
    and pushes an L2 delta recording `(base, n)`. `unstep!` of the alloca
    zero-clears the `n` reserved cells and retracts the bump pointer to
    `base` — recovering the pre-alloca heap exactly (the dynamic-N row,
    ADR 0013 l.75; the size-recoverability hazard, ADR 0013 l.151–152).
  - **(b) Mutation = each lossy indexed store pushes an L2 `(addr,
    old_value)` delta.** An element write `arr[i] = v` lowers to an
    address computation `addr = base + i*stride` (the GEP row, ADR 0013
    l.76) followed by a lossy store; the store pushes
    `(old_value = M[addr],)` to the delta history before overwriting.
    `addr` is *recomputable at inverse time* from the live SSA operands
    (`base`, `i`, `stride`), so the delta need only carry the lost cell
    value — the Enzyme min-cut principle of caching the minimum needed to
    invert (ADR 0002).

  Allocation captures **region metadata** (where the array lives, how
  big); mutation captures **element values** (what was overwritten). An
  `(base, n)` delta cannot un-overwrite an element, and an `(addr,
  old_value)` delta cannot retract a bump pointer — both are required.

  **Per-write `(addr, old_value)` delta is mandated over L3 whole-state
  snapshots.** PRD §3.3 forbids the Phase-0 full-snapshot pattern:
  "**Anti-pattern (from spike, do NOT carry over):** the spike's `Const`,
  `Move`, … incur a full-snapshot history entry each. Phase 2 MUST
  partition by injectivity … and pay the history cost only for the
  non-injective subset" (l.441–444), and "The history payload is the
  ancilla value(s), not a full snapshot" (l.427). A loop of `M` array
  writes under L3 snapshots is `O(M·heapsize)`; under per-write deltas it
  is `O(M)` — the min-cut-optimal cost (ADR 0002). (The ADR-0014 *scalar*
  floor ships L3-first deliberately because a single-cell program has no
  amplification; an unbounded dynamic array does, so the L2 delta is
  required here, not deferred.)

**3. Canonical program (`frtN`).** Defined via the ADR 0013 §D-1
emitter-agnostic `.ll` route (ADR 0013 l.78–79: "covers Case A (dynamic
`Vector`) directly, and a C/Rust array program for free"), which needs
**no** Rule-14 Bennett.jl change. The Case A golden master is a C
function that allocates a runtime-sized `int` array, writes a
data-dependent pattern, reduces it, and returns a scalar:

```c
// frtN — SC9 Case A canonical (C/.ll route; oracle: frtN_oracle below)
int frtN(int n) {
    int a[n];                 // VLA: dynamic-N alloca, n_elems = SSAOperand
    for (int i = 0; i < n; i++) a[i] = i * i;   // data-dependent stores
    int s = 0;
    for (int i = 0; i < n; i++) s += a[i];      // reduce
    return s;                 // = sum_{i<n} i^2
}
```

with the co-located irreversible oracle (golden-master convention,
PRD §3.14; cf. ADR 0014 §D5's committed-`.ll` discipline so no clang is
needed at test time):

```julia
frtN_oracle(n) = sum(i^2 for i in 0:n-1)   # 0 for n ≤ 0
```

Forward execution must agree bit-for-bit with `frtN_oracle`; the program
must round-trip to empty history. (Width: choose `n` small enough that
`sum i^2 ≤ typemax` of the source width — width masking is a prerequisite,
Decision 4.) The Julia `Vector{Int}(undef, n)` form of the same program
is the eventual user-facing case, reachable only via the Bennett.jl
`mem=:vm` arm (Decision 4); the C/`.ll` form is testable now.

**4. Scope & prerequisites (the implementation chain; re-scopes
`bennettvm-0zn`).** Case A requires the capabilities ADR 0014 §D4
explicitly deferred ("dynamic-N alloca (`SSAOperand` n_elems — **Case
A's actual need**), width masking", l.75–78):

  1. `IRPtrOffset` / `IRVarGEP` address arithmetic — `addr := base +
     idx*stride` for `arr[i]` (ADR 0013 §D-2 GEP row, l.76; ADR 0014 §D4
     "deferred to v2", l.47–48).
  2. Arrays `N > 1` — the bump allocator reserving `N` consecutive cells
     (ADR 0014 §D1 already reserves `base … base+N-1`; lift the
     `n_elems = 1` v1 scope, ADR 0014 §D4).
  3. Dynamic-N `alloca` — `n_elems::SSAOperand` resolved at runtime +
     the `(base, n)` L2 delta (Decision 2a).
  4. Indexed lossy store with `(addr, old_value)` L2 delta (Decision 2b).
  5. Width masking — Case A's running sum can exceed the element width
     (ADR 0014 §D4, ADR 0012 R1).
  6. Multi-store aliasing guard (RC3 `AliasingAnalysisPass` port,
     ADR 0013 §D-2 l.83–85, ADR 0014 §D4) — needed once GEP enables
     multiple stores to the same region.
  7. **L2/L3 history interleaving inside loops.** `frtN`'s two `for` loops
     are reversed by L3 checkpoint-replay (ADR 0010), while their array
     element writes push L2 `(addr, old_value)` deltas (Decision 2b) — so
     `frtN`'s history is a *mixed* L2-`DeltaEntry` / L3-`CheckpointEntry`
     stack. Replay re-drives `step!` forward with `replay_mode=true`, which
     suppresses all pushes (`src/history/Replay.jl:403–409`), so the L3
     replay does NOT double-push the interleaved L2 deltas; but that this
     composes correctly is a deep interaction (Rule 2) — the per-step-
     inverse + round-trip gate MUST exercise a mixed-history loop, not just
     isolated L2 or L3 cases (Rule 4).

  **Hard boundary — pebble-game exclusion.** Dynamic-N inputs are
  EXCLUDED from the Bennett-1989 pebble-game pass until a bound-analysis
  pre-pass exists. ADR 0013 §Consequences: "Dynamic-N `alloca` and
  unbounded maps cannot enter the Bennett-1989 pebble-game pass (PRD §3.4,
  needs uniform bounds). The `lower_vm` → pebble interface MUST fail loud
  (Rule 1) on dynamic-N inputs until a bound-analysis pre-pass exists"
  (ADR 0013 l.147–149).

  **Rule-14 dependency.** The Julia `Vector` source path needs Bennett.jl's
  `mem=:vm` extraction arm (ADR 0013 §D-4.2: "translate dynamic-N
  `Core.memorynew` → `IRAlloca(n_elems=SSAOperand)` + element traffic →
  `IRLoad`/`IRStore`", l.121–124), which is a **Core** Bennett.jl change
  requiring per-diff user approval (Rule 14). **Case A is testable NOW via
  the C/`.ll` route without it**, so this ADR's gate does not block on the
  Bennett.jl change.

## Decision 2a refinement (2026-05-31, bead 0zn impl)

Implementing the dynamic-N alloca (`bennettvm-0zn`) surfaced two points
that sharpen Decision 2a's original wording without changing its intent.

**(i) No runtime bump pointer exists → single-dynamic-array fixed
compile-time base + fail-loud on alloca-after-dynamic.** Decision 2a §2(a)
spoke of advancing "the ADR-0014 §D1 bump allocator by `n` cells" at
runtime and "retract[ing] the bump pointer to `base`" on reverse. But
`IState` (`src/ir/IState.jl:134-151`: `pc`, `locals`, `status`, `memory`)
carries **no runtime allocator state** — there is no live bump pointer to
advance by a runtime `n`. The implemented strategy is therefore a
**single dynamic array per routine at a frozen compile-time base**: the
ingest bump cursor at the point of the dynamic alloca becomes
`DynAlloca.base`, frozen, owning the open-ended address tail `[base, ∞)`
exclusively. The cursor is NOT advanced (the runtime size is unknown at
lowering). Consequently **any alloca after a dynamic one fails loud**
(Rule 1) — a second region would alias the frozen base
(`src/ir/ingest.jl:345-357`, the `saw_dynamic` guard + the dynamic-N
dispatch). The same single-region precondition is also enforced at
RUNTIME: `DynAlloca.forward` (`src/ir/alloca.jl`) fails loud (Rule 1) if
its `dest` pointer is already live, i.e. the alloca is RE-executing under
the frozen base (a loop / back-edge reaches it) — the unconditional-delete
L2 inverse would corrupt the prior allocation, so re-execution is rejected
rather than miscompiled. Multi-dynamic-array support AND in-loop dynamic
allocas (threading a runtime bump pointer through `IState`) are deferred to
a new bead with the exact forcing condition: *a routine emitting ≥2
dynamic-N allocas, a dynamic-N alloca followed by any further alloca, or a
dynamic-N alloca reached by a back-edge (re-executed).*

**(ii) The `DynAlloca` runtime instruction** (`src/ir/alloca.jl:135`).
`forward` (`:164`) materialises the pointer `s.locals[dest] = base` and
bumps `pc`; it does **NOT** zero the region — cells stay ABSENT and read
as `0` by the floor's absent=0 convention (`MemoryLoad.forward` /
`IState.memory`), matching the ADR 0014 §D1 zero-init convention ("cells
default to 0 by the zero-init convention", §D1:46 — the "does not
pre-populate `s.memory`" phrasing is `src/ir/ingest.jl:317`'s, not §D1's;
Law 1) and LLVM `alloca`'s uninitialised semantics. This
refines §2(a)'s "zero-clears the reserved cells" wording: under absent=0 a
deleted cell and a zeroed cell read identically *forward*, but only
**deletion** preserves the `IState.==`-by-Dict-content round-trip
invariant (the missing-sentinel trap `MemoryStore` documents — writing `0`
into a previously-absent cell leaves a phantom `{addr=>0}` key that breaks
equality). The L2 `(base, n)` delta is captured PRE-`forward()` via
`predelta_payload` (`:182`, resolving `n = s.locals[n_operand]`,
fail-loud if absent), the `MemoryStore` L2 template (Law 2); there is NO
`make_delta` (the sole L2 path is the pre-state hook).

**(iii) The unconditional-delete soundness lemma**
(`inverse(::DynAlloca, s, ::NamedTuple)`, `src/ir/alloca.jl:213`). On
reverse the L2 inverse UNCONDITIONALLY deletes the whole region
`base … base+n-1` (removing KEYS, never writing `0`) and removes the
pointer. This restores the exact pre-alloca heap **regardless of whether
the region's element stores reversed via L2 (per-write `(addr,old_value)`
delta) or L3 (whole-state checkpoint)**: the frozen-base bump allocator
guarantees every address in `[base, base+n-1]` was absent pre-alloca and
belongs exclusively to this allocation's lifetime, so deleting the whole
region is the exact inverse of "open this region" once any element writes
have themselves been reversed (history is LIFO — the alloca pushed first,
pops last). The `n <= 0` case makes the loop empty (only the pointer is
undone). This is proven under L2/L3 interleave by `test/test_alloca_delta.jl`
testset 5 (an L3 checkpoint forced between the alloca and a region store,
the store reversing via L3 replay while the alloca reverses via its L2
delta), satisfying the Decision-4 rung-7 "mixed-history loop" gate
(l.232-241). Both mutation-proofs (delete range off-by-one; pointer-undo
elided) confirmed RED then restored (Rule 5).

## Decision 2a multi-array refinement (2026-06-04, bead `bennettvm-uil` impl)

The "single dynamic array per routine at a frozen compile-time base" strategy
of the 2026-05-31 refinement (point (i)) is **lifted to ≥2 dynamic-N allocas**
by threading a runtime bump pointer through `IState`. This is the GATE for SC9
Case B (a `Dict` has TWO `GenericMemory` backings — keys + vals — exceeding the
single-dynamic-array floor; ADR 0016 D8).

**The design: `base = instr.base + s.heap_top` (a runtime OFFSET, default 0).**
`IState` gains a field `heap_top::Int64` (`src/ir/IState.jl`), the running total
of dynamic cells allocated so far, expressed as an OFFSET from each
`DynAlloca`'s frozen compile-time base, STARTING AT 0:

  * `DynAlloca.forward` (`src/ir/alloca.jl`) reads `n = s.locals[n_operand]`,
    materialises `s.locals[dest] = instr.base + s.heap_top`, advances
    `s.heap_top += n`, and bumps `pc`.
  * `predelta_payload` captures `base = instr.base + s.heap_top` (the RUNTIME
    offset base, BEFORE forward advances the cursor) and `n`.
  * the L2 `(base, n)` `inverse` deletes the runtime region `p.base ..
    p.base+p.n-1`, removes the pointer, retracts `s.heap_top -= p.n`, and
    decrements `pc`. So `heap_top` round-trips `0 → … → 0`.

The k-th dynamic alloca owns the disjoint window `[instr.base + offset_k,
instr.base + offset_k + n_k)` where `offset_k = heap_top` at its alloc time; the
disjointness lemma generalises (each `heap_top` advance steps past the previous
region; each address absent pre-alloca). The unconditional-delete soundness
lemma (point (iii)) carries over unchanged — it now deletes the runtime offset
window rather than the frozen window.

**Why the offset model (not an absolute cursor): zero churn.** A SINGLE dynamic
alloca has `heap_top == 0`, so `base = instr.base + 0 == instr.base` —
BYTE-IDENTICAL to the pre-`uil` frozen-base behaviour. So NO `VMProgram` /
`initial_state` change is needed and NO existing test churns: the 3-/4-/5-arg
`IState` constructors default `heap_top` to 0; every single-DynAlloca program
(`frtN`, `test_dyn_roundtrip`, `test_alloca_delta`, `test_vec_vm_roundtrip`,
`test_array_floor`) is unchanged. `heap_top` participates in `IState`'s
`==`/`hash` (the `revmap` precedent; ADR 0008 Finding 3 — a round-trip test
that failed to restore it would FAIL, Rule 4) and rides L3 `deepcopy(IState)`
checkpoints automatically (an `Int64` needs no custom method). The L2 NamedTuple
inverse path (`src/history/Replay.jl`) and the L3 checkpoint path BOTH carry
`heap_top` with NO change — verified before impl (`unstep!` passes `s.current`
to `inverse`; the L3 restore deepcopies the snapshot IState).

**Ingest (`src/ir/ingest.jl` `_lower_alloca!`):** a dynamic alloca AFTER a
dynamic one is now ADMITTED (all dynamic allocas share the SAME frozen
compile-time base; the runtime offset distinguishes them, so the cursor is NOT
advanced and the `saw_dynamic` guard no longer gates the dynamic arm). But a
STATIC alloca after a dynamic one STILL fails loud — the compile-time cursor is
frozen at the first dynamic region's base and cannot step past a runtime-sized
region (it would alias). The guard is split: static-after-dynamic → error;
dynamic-after-dynamic → allowed.

**Still deferred (follow-up beads):** (a) **in-loop / back-edge dynamic alloca**
(same dest re-executed) — `DynAlloca.forward`'s `haskey` guard still rejects it;
the offset model makes it tractable (remove the guard + test LIFO heap_top
retract under a back-edge), but that is not done here. (b) **static alloca after
a dynamic alloca** (mixed layout) — kept fail-loud (would need the compile-time
cursor to advance past a runtime region).

Gated by `test/test_multi_dynalloca.jl`: two DISTINCT dynamic allocas own
DISJOINT offset windows (no cross-array clobber), round-trip to empty history
with `heap_top == 0`, the `heap_top` accounting (`n1+n2` forward; `n1` after
reversing one), per-step inverse under the L2 deltas, the single-array no-churn
guarantee (`base == instr.base`), and a mutation-proof (removing the `heap_top
+= n` advance ALIASES the regions — confirmed RED, including the per-step
inverse catching `heap_top` diverging to a NEGATIVE value mid-stream, then
restored GREEN; Rule 5). Full suite 6308/6308.

## Consequences

- **`bennettvm-s4r`** (this ADR) closes on commit of this file.
- **`bennettvm-0zn`** ("route dynamic-N `IRAlloca` to
  `_lower_alloca_dynamic_n!`") is **mis-framed and superseded** — there is
  no `_lower_alloca_dynamic_n!` call in `lower_vm` (Finding 1). It is
  **re-scoped** to the Decision-4 implementation chain (dynamic-N alloca
  ingest with a `(base,n)` L2 delta, *not* a persistent-tree route), cf.
  ADR 0010 closing `bennettvm-720` as superseded-by-existing-design.
- **New child beads to file** (one per Decision-4 rung; orchestrator
  creates): `IRPtrOffset`/`IRVarGEP` address arithmetic; arrays `N>1`;
  indexed lossy store + `(addr,old_value)` L2 delta + the `make_delta`
  the scalar floor lacks; width masking; multi-store aliasing guard (RC3
  port); the `frtN` golden master + forward/round-trip gate (the SC9 Case
  A executable proof); **patch the PRD §3.6.2 to give `frtN` a body**
  (Finding 4).
- **The L2 delta is a new layer, not a scalar-floor change** (Finding 3):
  `MemoryStore`/`MemoryLoad` remain L3-baseline for `n_elems = 1`; the
  indexed-array store adds a `make_delta` + a payload-accepting
  `inverse`. Both halves of the test discipline still apply (Rule 4): the
  per-step inverse catches reversal bugs, the oracle-anchored forward
  catches forward-semantic bugs.
- **Pebble-game and Rule-14 boundaries** (Decision 4) stand as hard gates;
  the dynamic-N → pebble interface must fail loud until the bound-analysis
  pre-pass (relates to M9).

## Reuse (Law 2)

Reuse: the ADR 0013 §D-2 reversible-memory floor and its constituent
published mechanisms — **Enzyme min-cut** delta selection (capture the
minimum needed to invert = the overwritten value;
`references/ad-and-checkpointing/enzyme-2020.pdf` §2 "Cache" (p. 4); PRD
Part IV l.930; ported in ADR 0002), the **Bennett-1973 history tape**
applied to heap mutation
(`references/foundational/bennett-1973-logical-reversibility.pdf` Table 1
(p. 528); PRD Part IV l.935; PRD §3.6.2 l.628–629), the **Vieri 1995
memory-as-exchange** rule (a load MUST store back;
`references/reversible-isa/vieri-1995-pendulum-ms.pdf` §4.2.1 (p. 32);
PRD §3.2 l.429–433, §3.7 l.705–711, Part IV l.928), and **rr periodic
checkpoint+replay** as the L3 baseline
(`references/reverse-debugging/ocallahan-2017-rr-deployability.pdf` §2.1
(p. 2); PRD Part IV l.931). The IR encoding of indexed memory ops follows
the RSSA `MemoryAssignment`/`MemoryInterchange` forms
(`references/reversible-ir/mogensen-2016-rssa.pdf` §3). Concretely in the
tree: `IState.memory` + zero-init + the `DeltaEntry` payload layer
(`src/ir/IState.jl`, `src/history/delta.jl`, `src/history/Replay.jl`) and
the bump allocator + non-injective L3 template
(`src/ir/memory_floor.jl`, ADR 0014).
Why not reuse further: Bennett.jl's `:persistent_tree`
(`../Bennett.jl/src/lowering/memory.jl:75–98`) is **not applicable** to
the VM model — it allocates gate wires for the circuit backend
(`memory.jl:86–88`) and produces a `ReversibleCircuit`, not VM heap
traffic (Finding 1). **Law-1 gap recorded honestly:** there is no
Okasaki / Conchon-Filliâtre persistent-data-structure PDF in
`references/` (verified by `ls references/`); because this ADR decides
*not* to use a persistent tree (Decision 1), that gap is **moot for the
chosen design** — we cite no persistent-data-structure theory because we
rely on none.

## Refs

- `bennettvm_prd.md` (PRD v4) §3.6.2 Case A (l.610–619), §3.2 (l.429–433),
  §3.3 anti-full-snapshot (l.441–444; l.427), §3.7 (l.705–711), §6 SC9
  (l.1055–1060), Part IV reuse map (l.928, l.930, l.931, l.935, l.940);
  the `frtN` gap (named l.656, l.1056; no body in §3.6.2).
- `docs/adr/0013-reversible-memory-architecture.md` — §D-2 memory-floor
  table (l.69–76, dynamic-N row l.75, lossy-store l.73), §D-4.2 `mem=:vm`
  arm (l.121–124), §D-1 emitter-agnostic `.ll` (l.40–53, "for free" l.79),
  §Consequences pebble-game (l.147–149) / size-recoverability hazard (l.151–152),
  §Reuse (persistent-tree-is-circuit-only, l.165–167).
- `docs/adr/0014-memory-floor-lowering.md` — §D1 bump allocator (l.40–48),
  §D2 L3 baseline (l.50–65), §D4 v1 scope & deferrals (l.75–78),
  §Consequences (l.86–95).
- `docs/adr/0012-collatz-lowering.md` §Decision (trace-tape = L3, l.60–64);
  `docs/adr/0010-nested-loops.md` (bead-supersession precedent);
  `docs/adr/0002-enzyme-min-cut-mapping.md` (the min-cut port).
- `../Bennett.jl/src/lowering/memory.jl:75–98` (`_lower_alloca_dynamic_n!`
  — circuit-only; `allocate!(ctx.wa, …)` at l.86–88; `:persistent_tree`
  guard at l.79–81).
- BennettVM: `src/ir/memory_floor.jl` (`MemoryStore`/`MemoryLoad`, L3
  baseline), `src/ir/IState.jl:138` (`memory::Dict{Int64,Int64}`),
  `src/history/delta.jl:272–285` (`DeltaEntry` payload),
  `src/history/Replay.jl:307–339` (M7.4 delta fast-path),
  `src/ir/ingest.jl` (`lower_vm`/`VMProgram` assembly).
- References (verified present): `enzyme-2020.pdf`,
  `bennett-1973-logical-reversibility.pdf`, `vieri-1995-pendulum-ms.pdf`,
  `ocallahan-2017-rr-deployability.pdf`, `mogensen-2016-rssa.pdf`.
- CLAUDE.md Laws 1 & 2, Rules 1, 4, 9, 14.
