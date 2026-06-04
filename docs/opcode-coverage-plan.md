# Opcode-coverage plan — Bennett.jl → BennettVM pipeline

> **Goal (lead, 2026-06-04):** every LLVM opcode that is *reversibly possible*
> for a side-effect-free function must flow Julia → Bennett.jl extract →
> `ParsedIR` → BennettVM ingest → `run!`/`unrun!`; the genuinely-impossible set
> must **fail loud cleanly** (never silently miscompile). Tracking epic:
> **`bennettvm-x49`**. Grounded in the 2026-06-04 opcode stocktake (3-agent
> sweep + live `code_llvm` probe) and ADR 0015.
>
> **Out of this goal's scope** (separate tracks — do not fold in): L2 min-cut
> quality (M1 / `6r6…`), pebble-game (M9), Lean (M11/M12), route-(a) Dict
> `RevMap` (`o1y`), general perf/hygiene.

## Current coverage (HEAD)

15 of 19 `IRInst` ingested; 3 GAP (`IRPtrOffset`, `IRInsertValue`,
`IRExtractValue`); 1 N/A (`IRSwitch`, pre-expanded). `L3` checkpoint-replay
reverses *any* deterministic forward-executable instruction, so coverage is
purely (a) what the front-end emits and (b) what ingest accepts. The
impossible-set rejects are already in place and tested on the Bennett.jl side.

## Phases (each row: gap → owning repo → beads → deps)

| Phase | Gap | Repo | Beads | Deps |
|---|---|---|---|---|
| **P1 — ingest scalars** (start now, no upstream dep) | IRPtrOffset → `Define` addr arithmetic | BVM | `b5x` | — |
| | IRExtractValue/IRInsertValue → multi-slot model | BVM | `acq` | (couples Bennett `6bu3`) |
| **P2 — FP completeness** | `soft_frem` (musl fmod) + wire `frem` | Bennett.jl→BVM | `Bennett-tfx`(BG5) → `01w` | — |
| | `fdim` + `uitofp` edge | BVM | `4dn` | — |
| | width-masking; F32 clean reject | BVM | `bgc`, `h0t` | ready |
| **P3 — Case A dynamic Vector (LINCHPIN)** | mem=:vm Memory recognizer | **Bennett.jl** (Rule 14) | `Bennett-jfw6`(BG1) ↔ `m9i` | — |
| | push!/pop! lowering | BVM | `6db` → `ehp` | — |
| | push!-Vector e2e gate | BVM | `xkl` | `m9i`, `6db` |
| | multi-array / in-loop alloca | BVM | `uil` | — |
| **P4 — Case B Dict route (b)** (ADR 0015) | generalize recognizer to Dict backing | both | `tu9` ↔ `Bennett-800b`/`jfw6` | `m9i` |
| | determinism guard (objectid keys) | both | `90l` ↔ `Bennett-klgz`(BG2) | — |
| | e2e `fdict` gate | BVM | `7xa` | `tu9`, `90l`, `bgc` |
| | loop-bound for probe loop | Bennett.jl | `Bennett-lqlc`, `Bennett-jgyx` | — |
| **P5 — aggregate/GEP reach** | multi-index GEP (U16) FILL | both | `Bennett-8e1f`(BG3) → `dzd` | — |
| | struct aggregates (U10) FILL | both | `Bennett-6bu3`(BG4) → `acq` | — |
| **P6 — clean-fail-loud** | nondeterminism + indirectbr/atomic/volatile/opaque | BVM (Bennett ✓done) | `0kl` | — |
| **P7 — integration + alignment** | dispatch arm, full opcode set | both | `zg5`→`fu5`→`kl3`→`vw8` | **decoupled from Lean** (`zg5`↛`7zl`) |
| | coverage-matrix doc (19-row) | BVM | `ftz` | — |
| | doc reconciliation | both | `278`; `Bennett-800b` retitled | — |

**Critical path:** `m9i`/`Bennett-jfw6` (Case A recognizer) is the single
linchpin — it unlocks Case A (`xkl`) *and* Case B (`tu9`→`7xa`). Build first.
P1, P2, P5, P6 are independent and parallel-startable.

## Cross-repo alignment map

| BennettVM (ingest side) | Bennett.jl (front-end side) |
|---|---|
| `m9i` (Memory ingest — proven on `frtN.ll`) | `Bennett-jfw6` (BG1 recognizer) |
| `tu9` (Dict-backing ingest) | `Bennett-800b` (route-b home) + `jfw6` + `klgz` |
| `90l` (determinism guard, VM boundary) | `Bennett-klgz` (BG2 guard, extraction) |
| `dzd` (2-index GEP ingest) | `Bennett-8e1f` (BG3, U16 FILL) |
| `acq` (aggregate multi-slot ingest) | `Bennett-6bu3` (BG4, U10 struct FILL) |
| `01w` (frem dispatch) | `Bennett-tfx` (BG5, `soft_frem`) |
| `zg5/fu5/kl3/vw8` (dispatch ADR + e2e) | dispatch arm landed (`Bennett-33zr`) |

## Genuinely impossible — must stay fail-loud (NOT gaps to fill)

Inherited from Bennett.jl; reversibility cannot fix these. Already rejected +
tested on the Bennett.jl side (U14 atomic/volatile, U15 inline-asm/opaque-call,
U4eu indirectbr, cmpxchg/atomicrmw/callbr). `0kl` adds the BennettVM-ingest
defensive mirror + verification.

- **Nondeterminism:** `objectid`/identity hashing (→ `90l`/`klgz`), `rand`/RDRAND,
  pointer-identity. *(Doubly fatal for reversibility — no replay.)*
- **True I/O**, **opaque external calls** (body not visible),
  **atomics/volatile/concurrency**, **indirectbr** (computed goto).
- **FP ops with no `soft_*` primitive** until implemented (`frem` until BG5;
  F32/F16 refused by design — double-rounding isn't bit-exact).
