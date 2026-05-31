# ADR 0008 — `Dict` as a reversible-map ADT (SC9 Case B)

> Status: **ACCEPTED** (2026-05-31). M_DICT.1 milestone (bd
> `bennettvm-t4c`). BennettVM pin `ef3c9d5`; Bennett.jl pin `7904560`
> (2026-05-28). Implements ADR 0013 §D-3 for the `Dict` row of the
> memory floor. **Corrects ADR 0013 §D-3** (its "Bennett.jl *recognizes*
> the high-level `Dict` operations … `IRMapInsert`/`IRMapGet`/
> `IRMapDelete`" is aspirational, not implemented — Finding 1) and
> **supersedes the framing of bead `bennettvm-jrc`** ("PersistentDictRef
> … threaded through RState but NOT stored in `IState.locals`") — the
> reversible-map ADT must live *inside* `IState` (its own field, not
> `locals`; Finding 3, Decision 1),
> exactly as ADR 0010 superseded `bennettvm-720` and ADR 0009 superseded
> `bennettvm-0zn`.

## Context

Case B is PRD v4 §3.6.2 ("**Case B. `Dict{K,V}` and other hash-table
mutations.**", l.621–634) and one of the four SC9 motivating programs
("if SC9 fails, BennettVM has no reason to exist", l.1059–1060). The PRD
asserts the *reversibility claim* that justifies the whole case: "**This
rejection is false in the VM model**: a `Dict` with a history of
`setindex!`/`delete!` operations IS reversible if the history is
preserved" (l.624–625), via "the Bennett-1973 history-tape mechanism
applied to heap mutation, not to control flow" (l.628–629). The
canonical motivating program (l.633) is

```julia
fdict(k::Int8, v::Int8) = let d = Dict{Int8,Int8}(); d[k] = v; d[k] end
```

with the SC9 Case B gate `fdict(Int8(3), Int8(7))` → `7` and `unrun!`
to empty history.

ADR 0013 §D-3 (l.87–109) already chose the *model* (lead's option D3):
not raw-store inlining, but a BennettVM-owned **reversible-map ADT** with
delta-history undo, fed by language-neutral high-level map ops
(`IRMapInsert`/`IRMapGet`/`IRMapDelete`). This ADR resolves the
engineering questions D-3 left open — *where the map lives in VM state,
what the deltas carry, what the type is called, and what is achievable
now vs. behind a Rule-14 Bennett.jl change* — and corrects two claims in
D-3 and `bennettvm-jrc` that the empirical probe this session
falsified.

The bead chain (written 2026-05-25, before the probe) reads the
Bennett.jl citations as *interception sites*: `bennettvm-t4c` and
`bennettvm-jrc` both cite `heap.jl:313-320` and `instructions.jl:
2106-2110` as "the rejection site this type is designed to intercept."
Two facts found this session show that framing is the same mistake ADR
0013 §Context already named for the heap cases: **there is no ParsedIR
to intercept** (Finding 2), and the map cannot live where `jrc` puts it
(Finding 3).

## Ground truth (verified)

**Finding 1 — Bennett.jl has NO `IRMap*` recognition; ADR 0013 §D-3's
"recognizes" is aspirational, not implemented.** `grep -rn "IRMap"
../Bennett.jl/src/` returns **nothing** (verified this session). ADR 0013
§D-3 states, in the present tense, "**Bennett.jl** *recognizes* the
high-level `Dict` operations (`setindex!`/`getindex`/`delete!`) and emits
**language-neutral** high-level map ops (working names `IRMapInsert` /
`IRMapGet` / `IRMapDelete`)" (l.94–97) — this is **false today**. What
*exists* in Bennett.jl is the persistent-DS tier, the eventual lowering
*target*: `pmap_set`/`pmap_get` and their CF / HAMT / Okasaki / linear-
scan implementations (`../Bennett.jl/src/persistent/persistent.jl:66–72`,
`interface.jl:7–8`). There is **no bridge** from a `Dict` IR op to that
tier. The `Dict`→`IRMap*` recognition is the entire unsolved research
problem, tracked as Bennett.jl bead **`Bennett-800b`** (P3, in progress;
"Julia Dict support — reversible hash-table compilation (research
program)"). Its own description names the core difficulty: under the
optimizer `setindex!(d,k,v)` "writes to slot `hash(k) mod capacity`, then
probes on collision — a RUNTIME-KEY-DEPENDENT location… that hash-and-
probe logic carries information INTO the return value: it is live
computation, not dead skeleton." With `optimize=true`, Julia inlines
`setindex!`/`getindex` into raw hash arithmetic with **no callee boundary
to pattern-match** — so the `IRMap*` emit has nothing to hook onto. This
ADR records that correction (documentation of reality, like ADR 0009
Finding 1).

**Finding 2 — Bennett.jl rejects `Dict` at EXTRACT time, before any
ParsedIR.** The bead's two cites are both real but mean different things:

  - `../Bennett.jl/src/extract/heap.jl:313–320` is the **Dict-specific**
    reject under the M4 heap scope guard. `_m4_scope_guard` matches a
    `setindex!` callee (`occursin(_M4_DICT_SETINDEX_RE, cname)`) and
    raises: "`Dict` detected … is `setindex!` on a Julia `Dict`. A Dict
    is an irreversible hash-table mutation (rehash, probe-sequence
    reorder, ndel bookkeeping) … see Bennett-800b" (l.313–320).
  - `../Bennett.jl/src/extract/instructions.jl:2106–2110` is a **generic**
    fallthrough, NOT Dict-specific: "call to '$(cname)' has no registered
    callee handler or intrinsic pattern" (l.2106–2110). A `Dict` op
    reaches *this* one under `mem=:auto` because the scope guard is gated
    on `mem===:heap`, so under `:auto` it falls through to the generic
    no-handler arm rather than the bespoke Dict message.

  Under **either** mode the reject fires inside `extract_parsed_ir`,
  **before any ParsedIR is produced** for a `Dict` op — identical in shape
  to ADR 0013 §Context's heap finding ("there is no ParsedIR to
  intercept"). The bead's "rejection site this type is designed to
  intercept" framing is therefore mis-scoped: unblocking Case B is an
  integration-architecture problem (a `mem=:vm` recognition arm,
  Decision 4 / Rule 14), not a BennettVM ingest interception.

**Finding 3 — the round-trip invariant requires the map INSIDE `IState`
(corrects `bennettvm-jrc`).** `src/ir/IState.jl` defines `IState` as a
`mutable struct` (l.134) with `memory::Dict{Int64,Int64}` (l.138, "the
addressable heap, as a sparse map", l.58) and `locals::Dict{Symbol,
Int64}` (l.136, the scalar register file). The overrides
`Base.==` (l.211–216) and `Base.hash` (l.218–224) content-compare **all**
fields, *including* `locals` and `memory`. The load-bearing round-trip
invariant is `unrun!(run!(s, prog)) == initial(s) && isempty(s.history)`
(`src/ir/RState.jl:23`); reversal of non-injective ops goes through L3
checkpoint-replay, whose `CheckpointEntry` is a `deepcopy(IState)`
snapshot (`src/history/CheckpointEntry.jl:272`, `new(deepcopy(snapshot),
…)`). `bennettvm-jrc` scopes the live `Dict` ref as "threaded through
RState but NOT stored in IState." **That placement breaks two
invariants:**

  - (a) If the map lives *outside* `IState`, then `IState.==` cannot see
    it → the round-trip test `rs.current == rs.initial` **spuriously
    passes** even when the map was never reversed (Rule 4: a test that
    passes without checking the invariant is broken — the spike's
    `Dict`-identity trap, `IState.jl:206-207`).
  - (b) `CheckpointEntry`'s `deepcopy(IState)` would **not capture the
    map** → an L3 replay restores an `IState` snapshot that omits map
    state, corrupting reconstruction (the very mechanism Case B's
    insert/delete deltas interleave with, exactly as Case A's mixed L2/L3
    history, ADR 0009 Finding/Decision).

  Therefore the reversible-map ADT must be its **own dedicated field on
  `IState`** — NOT in `locals` (which is `Dict{Symbol,Int64}` = scalars
  only, l.136), but a sibling field mirroring `memory::Dict{Int64,Int64}`
  — so it participates in `==`/`hash`/`deepcopy`/L3-checkpoint
  **automatically**, the same way `memory` does (`IState.jl:215,222`).
  This corrects `jrc`.

**Finding 4 — delta shapes (history-tape capture; PRD Case B l.621–634).**
The three map ops partition by injectivity exactly as the memory floor
does (ADR 0013 §D-2 table, l.69–76):

  - `setindex!(d,k,v)` (**IRMapInsert**) is non-injective in the map (it
    overwrites or creates a binding) → push the L2 payload `(key = k,
    prior = old_v_or_missing)`, where `prior === missing` (Julia's
    `Missing`) encodes "key was absent." Inverse: if `prior === missing`
    then `delete!(d, k)`, else `setindex!(d, k, prior)` (PRD l.626).
  - `delete!(d,k)` (**IRMapDelete**) is non-injective → push `(key = k,
    old_val = M[k])`; inverse `setindex!(d, k, old_val)` (PRD l.627).
  - `getindex(d,k)` (**IRMapGet**) is **injective w.r.t. the map state**
    (a pure read; the map is unchanged) → **no map history**. *But* its
    LOCALS side is non-injective when it assigns an SSA `dest` that is
    reused across loop iterations: overwriting that scalar without a
    record is irreversible. This is exactly the `MemoryLoad` situation
    (`src/ir/memory_floor.jl:65–73`, "is_injective = false — the L3
    baseline"), so IRMapGet's *dest write* follows the **MemoryLoad L3
    pattern** — reversed by checkpoint-replay, never a per-instruction
    `inverse()`. IRMapGet is map-injective and locals-non-injective; both
    sides must be handled.

  These map deltas are genuine **L2** deltas: small, well-defined
  payloads. Note the payload is **NOT** empty/zero-sized — the
  `prior::Union{V,Missing}` (insert) and `old_val::V` (delete) fields
  carry real data, so the ADR 0002 empty-`NamedTuple` optimization
  (`src/history/delta.jl:266–268`, "Empty NamedTuple is the dominant
  case") does **not** apply to map ops.

**Finding 5 — naming.** The bead names the type "PersistentDictRef"
(`bennettvm-jrc`), but reversibility here is via **explicit history-tape
undo**, not a persistent/immutable (functional) data structure. "Persistent"
actively misleads: it suggests structural sharing à la Okasaki / Conchon-
Filliâtre, which we do **not** rely on. We rename to **`RevMap`** (chosen
over `ReversibleMap`/`IRMapADT` for brevity and because it reads as the
runtime *value* type, while `IRMap*` already names the IR *ops* — keeping
op-level and value-level names visibly distinct). `RevMap` is backed by a
`Base.Dict` owned by `IState` (mirroring `memory`). **Rehash is irrelevant
here, for a precise reason:** the raw-store path ADR 0013 §D-3 l.89–91
rejected would capture slot-level `(slot, old_byte)` and break when a
rehash relocates entries — but our deltas reverse through the `Dict` API
(`delete!`/`setindex!`, Finding 4), and BOTH `IState.==` and the L3
`deepcopy` compare `Dict` **content**, not slot layout ("same key set …
regardless of internal slot layout", `IState.jl:174–178`). A rehash is
thus invisible to the content-level invariant; `(key, prior)` reversal is
correct even across a growth rehash — exactly why an owned `Base.Dict`
suffices where slot-capture would not. We also decline Bennett.jl's CF
persistent tree (circuit-only tier, ADR 0009 Finding 1; the `persistent/`
tier is the lowering *target*, not a VM runtime type). Because we use no
persistent-DS, the Okasaki / Conchon-
Filliâtre Law-1 citation gap is **moot** (same resolution as ADR 0009
§Reuse: cite no theory we don't rely on). ADR 0013 §D-3 listed the CF
semi-persistent map as a *candidate backing*; this ADR declines it for
the VM runtime — a balanced/owned `Dict` is simpler and the
history-tape, not the structure, supplies reversibility.

**Finding 6 — reuse / Law 1 (paths verified present via `ls`).** The
mechanism is Bennett-1973's history tape applied to heap mutation
(`references/foundational/bennett-1973-logical-reversibility.pdf`, "the
history tape" §3, p. 528; PRD Case B l.628–629 says verbatim "This is the
Bennett-1973 history-tape mechanism applied to heap mutation, not to
control flow"); the delta payload is the Enzyme min-cut "cache the minimum
needed to invert" principle (`references/ad-and-checkpointing/
enzyme-2020.pdf`; ported in ADR 0002); the reversible-heap precedent is
Axelsen-Glück 2013 "Reversible Representation and Manipulation of
Constructor Terms in the Heap" (`references/reversible-languages/
AxelsenGluck2013_reversible_heap.pdf`); the IR encoding follows RSSA's
`MemoryAssignment` (`references/reversible-ir/mogensen-2016-rssa.pdf` §3).
**Two Law-2 / Law-1 gaps recorded honestly:** (i) PRD Part IV's reuse map
has **no `Dict`/reversible-map row** — recommend adding one citing
Axelsen-Glück 2013 (Decision/Consequences); (ii) ADR 0013 §Refs cites
"Mogensen 2018 (reversible GC / RIL `MemoryAssignment`)", but the file
`references/reversible-ir/mogensen-ril.pdf` is **Mogensen 2015** ("Garbage
Collection for Reversible…", RC 2015, LNCS 9138, p. 79–94, 2015 — verified
this session). Year drift; flag the fix (the RSSA file `mogensen-2016-
rssa.pdf` is correctly 2016).

## Decision

**1. The BennettVM reversible-map ADT (`RevMap`) lives INSIDE `IState`.**
Per Finding 3, `RevMap` is a **dedicated `IState` field** (NOT in
`locals`), mirroring `memory::Dict{Int64,Int64}` so that `Base.==`,
`Base.hash`, `deepcopy`, and the L3 `CheckpointEntry` snapshot cover it
**automatically** (`IState.jl:215,222`; `CheckpointEntry.jl:272`). This
**corrects and supersedes** `bennettvm-jrc`'s "live `Dict` reference
threaded through RState but NOT stored in IState" framing, on the
round-trip-invariant rationale of Finding 3(a)/(b): a map outside
`IState` makes the round-trip test spuriously pass and corrupts L3
replay. Superseded exactly as ADR 0010 superseded `bennettvm-720` and ADR
0009 superseded `bennettvm-0zn`.

**2. History-tape capture (Finding 4).** `IRMapInsert`/`IRMapDelete` are
**non-injective L2 deltas** with the payloads and inverses of Finding 4
(`(key, prior=old_v_or_missing)` with `missing`-means-absent for insert;
`(key, old_val)` for delete). `IRMapGet` is **map-injective** (no map
history) but its SSA-`dest` write is non-injective and follows the
**`MemoryLoad` L3 pattern** (`memory_floor.jl:65–73`) — reversed by
checkpoint-replay, never a per-op `inverse()`. The backing is the
BennettVM-owned `RevMap` (a `Base.Dict` in `IState`, Decision 3); reversal
is **API-level** (`delete!`/`setindex!`) and the round-trip invariant is
**content-level** (`IState.jl:174–178`), so an internal rehash on growth
is invisible to it (Finding 5) — there is no slot layout to reverse.

**3. Rename `PersistentDictRef` → `RevMap`; re-scope `bennettvm-jrc`**
(Finding 5) to "Define `RevMap` + `IRMapInsert`/`IRMapGet`/`IRMapDelete`
ops; map lives inside `IState` (own field, mirroring `memory`); structural
`==`/`hash` via the existing `IState` overrides." The CF semi-persistent
map (ADR 0013 §D-3 candidate) is **declined** for the VM runtime in favour
of an owned `Dict`; reversibility comes from the history tape, not the
structure.

**4. Two-tier achievability (the scoping honesty — mirrors ADR 0009's
"testable now vs. behind Rule-14").**

  - **(a) Testable NOW (unblocked).** The BennettVM-side `RevMap` ADT +
    the three `IRMap*` ops + delta capture + a round-trip unit gate on a
    **hand-built `IRMap*` `VMProgram`** are implementable and testable
    today, with no Bennett.jl change — the same pattern ADR 0013 §D-5
    step 4 anticipated and ADR 0009 used for the C/`.ll` Case A route.
    The hand-built program exercises insert → get → (round-trip to empty
    history), asserting both the map content (forward, against the oracle
    `fdict`) and the round-trip invariant (`RevMap` participates in
    `IState.==` by Decision 1).
  - **(b) BLOCKED on a Rule-14 Bennett.jl change.** The end-to-end SC9
    Case B gate (`fdict` via `reversible_compile(..., target=:reversible_vm)`)
    is blocked on the `Dict`→`IRMap*` **front-end recognition arm**
    (ADR 0013 §D-4.2 `mem=:vm` arm; Bennett.jl bead **`Bennett-800b`**),
    a **Core** Bennett.jl change requiring per-diff user approval
    (Rule 14). The `optimize=true` inlining of `setindex!`/`getindex`
    into hash arithmetic with no callee boundary (Finding 1) is its core
    difficulty.

  **No Rule-14-free end-to-end path exists for a genuine Julia `Dict`.**
  Unlike Case A — where a C VLA reaches `lower_vm` via the emitter-
  agnostic `.ll` route (ADR 0009 Decision 3, ADR 0013 §D-1) — a C
  raw-hashmap is **NOT** a substitute for the `Dict` ADT: a hand-rolled C
  hashmap is raw stores, which fall under the **Case A store-level floor**
  (ADR 0013 §D-2), not the high-level map ADT. There is no emitter that
  produces `IRMap*` ops today; the only producer would be the
  `Bennett-800b` recognition arm. So the hand-built unit gate (4a) is the
  only executable proof of the *ADT* until Rule-14 work lands.

  **Width/typing scope.** v1 `RevMap` is `Dict{Int64,Int64}`, exactly like
  `memory` (`IState.jl:138`); keys/values are concrete `Int64`, so
  `missing` is an unambiguous "absent" sentinel (no stored value can be
  `Missing`). `fdict`'s `Dict{Int8,Int8}` typing therefore inherits ADR
  0009's width-masking milestone (its Decision 4 rung 5) — the end-to-end
  `fdict` Int8 gate is blocked on **width masking in addition to
  `Bennett-800b`**. The unblocked unit gate (4a) uses `Int64` keys/values
  and is unaffected.

**5. Correct ADR 0013 §D-3 (Finding 1).** Record that its "Bennett.jl
*recognizes* `Dict` ops → `IRMap*`" (present tense, l.94–97) is
**aspirational**: the recognition is **unimplemented** (no `IRMap` in
`../Bennett.jl/src/`), tracked as `Bennett-800b`. ADR 0013 §D-3's *model*
(BennettVM-owned reversible map, history-tape undo, `getindex` injective)
stands and is built on; only its tense about the Bennett.jl side is
corrected here.

**6. Canonical program and gates.** The canonical program is `fdict`
(PRD l.633). The **unit gate** (unblocked, this ADR's executable proof) is
a hand-built `IRMap*` `VMProgram` round-trip with an `fdict`-shaped oracle
(`fdict(Int8(3),Int8(7))` → `7`; round-trip to empty history). The
**end-to-end gate** (`fdict` via `target=:reversible_vm`) is **behind
`Bennett-800b`**.

## Consequences

- **`bennettvm-t4c`** (this ADR) closes on commit of this file.
- **`bennettvm-jrc`** ("M_DICT.2 Define PersistentDictRef … threaded
  through RState but NOT stored in IState") is **mis-framed and
  superseded** (Finding 3). It is **renamed and re-scoped** to: "Define
  `RevMap` + `IRMapInsert`/`IRMapGet`/`IRMapDelete`; the map is a
  dedicated `IState` field (NOT `locals`), mirroring `memory`, so it
  participates in `==`/`hash`/`deepcopy`/L3-checkpoint automatically." cf.
  ADR 0010 closing `bennettvm-720` and ADR 0009 closing `bennettvm-0zn`
  as superseded-by-design.
- **New child beads to file** (orchestrator creates):
  1. **BennettVM `RevMap` ADT + `IRMap*` ops** — `RevMap` field on
     `IState`; `IRMapInsert`/`IRMapGet`/`IRMapDelete` instructions with
     the Finding-4 deltas/inverses. **Unblocked. P0.** (This is the
     re-scoped `jrc` plus the lowering bead `bennettvm-8i5` it blocks.)
  2. **Hand-built `IRMap*` round-trip unit gate** — forward against the
     `fdict` oracle + round-trip-to-empty-history; must assert map content
     via `IState.==` (Decision 1) so it cannot spuriously pass (Rule 4).
     Must also exercise an `IRMapInsert` inside a loop body (L2 map delta
     interleaved with L3 control-flow checkpoints, per ADR 0009 rung 7).
     **Unblocked. P1.** (Depends on bead 1.)
  3. **Bennett.jl `Dict`→`IRMap*` recognition arm** — the `mem=:vm`
     extraction arm recognizing `setindex!`/`getindex`/`delete!` and
     emitting `IRMap*`. **Rule-14 / Core; BLOCKED; references
     `Bennett-800b`** (per-diff user approval; `optimize=true` inlining is
     the core difficulty). P2.
  4. **End-to-end `fdict` SC9 Case B gate** — `reversible_compile(fdict,
     Tuple{Int8,Int8}, target=:reversible_vm)` forward + round-trip.
     **BLOCKED on bead 3.** P1.
  5. **PRD + ADR 0013 patch (factual fixes)** — add a Part IV reuse-map
     **`Dict`/reversible-map row** citing Axelsen-Glück 2013 (Finding 6
     gap (i)); amend **ADR 0013 §D-3 l.94** ("recognizes"→"will recognize —
     unimplemented, `Bennett-800b`", Finding 1) and **§Refs l.175**
     ("Mogensen 2018"→"2015", Finding 6 gap (ii)). P2.
- **`getindex` has a dual nature** (Finding 4): map-injective (no map
  delta) yet locals-non-injective (L3 for its SSA `dest`). The unit gate
  MUST reuse a `get`-`dest` SSA name across a loop to exercise the L3 side,
  not just a single straight-line `get` (Rule 4) — otherwise the
  injective-read claim is untested in the case that actually needs L3.
- **Pebble-game boundary** (inherited, ADR 0013 §Consequences l.146–149):
  an unbounded `RevMap` cannot enter the Bennett-1989 pebble-game pass
  until a bound-analysis pre-pass exists; the `lower_vm`→pebble interface
  must fail loud (Rule 1) on map inputs (relates to M9).

## Reuse (Law 2)

Reuse: the **Bennett-1973 history tape** applied to heap mutation
(`references/foundational/bennett-1973-logical-reversibility.pdf`, "the
history tape" §3 (p. 528); PRD Case B l.628–629, verbatim "the Bennett-1973
history-tape mechanism applied to heap mutation, not to control flow");
the **Enzyme min-cut** "cache the minimum needed to invert" principle for
the `(key, prior)`/`(key, old_val)` payloads
(`references/ad-and-checkpointing/enzyme-2020.pdf`; ported in ADR 0002);
the **Axelsen-Glück 2013 reversible heap** as the reversible-data-in-heap
precedent (`references/reversible-languages/AxelsenGluck2013_reversible_heap.pdf`);
the **RSSA `MemoryAssignment`** IR encoding
(`references/reversible-ir/mogensen-2016-rssa.pdf` §3). In-tree:
`IState.memory`'s sparse-`Dict` + zero-init + `==`/`hash`/`deepcopy`
discipline (`src/ir/IState.jl:138,211–224`) is the template the `RevMap`
field follows; the `DeltaEntry` payload layer
(`src/history/delta.jl:272–285`) carries the map deltas; the `MemoryLoad`
L3 baseline (`src/ir/memory_floor.jl:65–73`) is the template for
`IRMapGet`'s SSA-`dest` side; the L3 checkpoint-replay layer
(`src/history/Replay.jl`, `CheckpointEntry.jl:272`) reverses all
non-injective ops uniformly.
Why not reuse further: (1) Bennett.jl's **CF / HAMT / Okasaki**
persistent maps (`../Bennett.jl/src/persistent/`) are the circuit
backend's **lowering target**, not a VM runtime type — declining ADR 0013
§D-3's "candidate backing" of the CF semi-persistent map (l.103–105) for
the VM, because reversibility comes from the history tape, not the
structure, and an owned `Dict` is simpler. (2) **Law-1 gap recorded
honestly:** no Okasaki / Conchon-Filliâtre persistent-data-structure PDF
is in `references/` (verified by `ls`); because this ADR decides *not* to
use a persistent tree (Decision 3), that gap is **moot for the chosen
design** — we cite no persistent-DS theory because we rely on none (same
resolution as ADR 0009 §Reuse). (3) **Law-2 gap recorded:** PRD Part IV
has no `Dict`/reversible-map row — Consequences bead 5 patches it with
Axelsen-Glück 2013.

## Refs

- `bennettvm_prd.md` (PRD v4) §3.6.2 Case B (l.621–634; reversibility
  claim l.624–625; insert/delete capture pattern l.626–627; Bennett-1973
  framing l.628–629; `fdict` body l.633), §6 SC9 (l.1055–1060), §3.7
  frontend integration (l.660–664).
- `docs/adr/0013-reversible-memory-architecture.md` — §D-3 `Dict`-as-ADT
  decision (l.87–109; the "recognizes" tense corrected, l.94–97; rehash-
  not-reversible, l.89–91; CF-backing candidate declined, l.103–105),
  §D-2 memory floor (l.69–76), §D-4.2 `mem=:vm` arm (l.121–124), §D-5
  build order step 4 (l.137–138), §Consequences pebble boundary
  (l.146–149); §Refs "Mogensen 2018" year-drift (l.175).
- `docs/adr/0009-dynamic-size-memory.md` — the "testable now vs. behind
  Rule-14" two-tier template; §Reuse moot-persistent-DS-gap resolution;
  the C/`.ll`-route precedent that Case B has NO analogue of (Decision 4).
- `docs/adr/0010-nested-loops.md`, `docs/adr/0014-memory-floor-lowering.md`,
  `docs/adr/0002-enzyme-min-cut-mapping.md` (bead-supersession precedent;
  L3 baseline; min-cut port).
- Bennett.jl (pin `7904560`): `../Bennett.jl/src/extract/heap.jl:313–320`
  (Dict reject under `mem=:heap`), `../Bennett.jl/src/extract/
  instructions.jl:2106–2110` (generic no-handler fallthrough, `mem=:auto`),
  `../Bennett.jl/src/persistent/persistent.jl:66–72` &
  `interface.jl:7–8` (`pmap_set`/`pmap_get` lowering target); `grep -rn
  "IRMap" ../Bennett.jl/src/` → NONE (Finding 1); bead `Bennett-800b`.
- BennettVM (pin `ef3c9d5`): `src/ir/IState.jl:134,136,138,211–224`
  (mutable struct; `locals`/`memory`; `==`/`hash`), `src/ir/RState.jl:23`
  (round-trip invariant), `src/history/CheckpointEntry.jl:272`
  (`deepcopy` snapshot), `src/history/delta.jl:266–268,272–285`
  (`DeltaEntry` payload), `src/ir/memory_floor.jl:65–73` (`MemoryLoad`
  L3 baseline).
- References (verified present): `bennett-1973-logical-reversibility.pdf`,
  `enzyme-2020.pdf`, `AxelsenGluck2013_reversible_heap.pdf`,
  `mogensen-2016-rssa.pdf` (2016, correct); `mogensen-ril.pdf` is
  Mogensen **2015** (not 2018).
- CLAUDE.md Laws 1 & 2, Rules 1, 4, 9, 14.
