# Cross-Repo Handoff — Bennett.jl + BennettVM.jl

> Author: orchestration session 2026-05-31 (Opus). For the next agent who will
> work on **both** repos simultaneously. Read this top-to-bottom before
> touching either repo. Companion to each repo's `CLAUDE.md`/`AGENTS.md`,
> `bennettvm_prd.md` (PRD v4), and `Bennett.jl/Bennett-VISION-PRD.md`.
>
> Recon basis: Bennett.jl pin `7904560` (2026-05-28); BennettVM pin `d28396f`
> (after this session's Case A Units 1–2). All `path:` refs are relative to
> the respective repo root.

---

## 0. TL;DR — the corrected mental model

**The big reframe (this is why you work in both repos):** *most* of the
functionality BennettVM's PRD lists as "remaining" is **already built in
Bennett.jl** — it is just **circuit-backend-only and not wired to the VM**.
The real remaining work is therefore **integration + VM-side consumption**,
plus a few genuinely-new pieces, not "build pebbling/FP from scratch."

- **Built in Bennett.jl, ready to reuse:** the Bennett-1989 **pebble-game**
  (`src/pebble/`, Knill DP + 4 strategies), **SoftFloat/Float64** (bit-exact,
  `src/softfloat/`, 32 ops), the **persistent-tree** heap (`src/persistent/`),
  the **circuit backend** (Toffoli/CNOT, `verify_reversibility`), **integer
  width** (sext/zext/trunc + masking), and the shared **frontend**
  (`extract_parsed_ir[_from_ll/_bc]` → `ParsedIR`).
- **Genuinely missing (the work ahead):** the **`target=:vm` dispatch arm**
  (absent — the keystone), **Dict** recognition (`Bennett-800b`,
  research-blocked), **pebbling for branching/dynamic** programs (circuit
  pebbling falls back to full Bennett on any branch — exactly the VM's case),
  the **`mem=:vm` extraction arm**, and the **BennettVM-side Lean**
  formalization (no Bennett.jl analogue).
- **Nearest finish line:** complete **SC9 Case A** (dynamic memory) in
  BennettVM — unblocked, a few units from a real round-trip gate.

**Operational trap (read §5):** the two repos have *different* beads-sync,
worklog, LOC, and commit conventions. Using the wrong one corrupts state.

---

## 1. The two repos and the boundary

```
Julia/C/Rust source ─► Bennett.jl frontend (LLVM IR ─► ParsedIR)   [SHARED]
                                   │
                  ┌────────────────┴───────────────────┐
        lower()/bennett()                     (NEW, absent today)
        target = circuit  ─►  ReversibleCircuit       target = :vm  ─►  VMProgram
        (Bennett.jl)                                  (BennettVM.jl)
```

- **Shared, unchanged across targets:** `extract_parsed_ir` → `ParsedIR`
  (`Bennett.jl/src/ir_types.jl`, `src/extract/entry.jl`). BennettVM already
  ingests `ParsedIR` (via `extract_parsed_ir_from_ll`) and emits a `VMProgram`
  — see `BennettVM/src/ir/ingest.jl`. **This half works today.**
- **Divergence point:** the `lower`/`bennett` stage. Bennett.jl produces a
  gate circuit; BennettVM produces a reversible VM program. (Ref:
  `Bennett.jl/Bennett-ReversibleVM-PRD.md §3`.)
- **The missing keystone:** there is **no `target=:vm` dispatch** in
  Bennett.jl. `target=` today selects an *optimization objective*
  (`:gate_count`/`:depth`), not a backend (`Bennett.jl/src/Bennett.jl:145`,
  `src/lowering/driver.jl:34`). There is not even a `:circuit` symbol. So
  `reversible_compile(f, target=:vm)` — the user-facing entry the whole VM is
  *for* — does not exist. Tracked as **`Bennett-spqu`** (open P2), explicitly
  in a "research + 3+1 design phase before implementation" state.

---

## 2. Capability map — what's built where, and the VM-wiring gap

| Capability | Built in Bennett.jl? | VM-wired? | What remains for the VM |
|---|---|---|---|
| Frontend `ParsedIR` / extractor | ✅ `src/extract/`, `ir_types.jl` | ✅ consumed by `ingest.jl` | nothing (works via `_from_ll`) |
| Pebble-game (Knill DP, 4 strategies) | ✅ `src/pebble/` | ❌ circuit-only; **falls back to full Bennett on any branch** | port the *substrate-agnostic* Knill DP (`pebble/pebbling.jl:39,88`) to schedule the VM's L2/L3 history; the gate-level machinery (WireAllocator) does NOT transfer |
| SoftFloat / Float64 (bit-exact, 32 ops) | ✅ `src/softfloat/` | ❌ applied via `softfloat_dispatch.jl` at circuit `reversible_compile` | register `soft_*` as known callees in the VM interpreter; route Float64 args through the dispatch wrapper (needs the `target=:vm` path for a *Julia* fn; a hand-built `ParsedIR` of `soft_*` IRCalls is interpretable now) — answers PRD SC10 / `M_FP` |
| Persistent-tree heap (4 impls) | ✅ `src/persistent/` | ❌ circuit-only (`NTuple` = static wires) | reuse as **bounded-region** primitives, OR use BennettVM's own `RevMap`/L3 model (ADR 0008/0009 chose the latter) |
| Circuit backend (Toffoli, verify) | ✅ `src/gates.jl`, `simulator.jl` | n/a (this is the *other* target) | this is the quantum-oracle output; the VM's pebble-extraction (north star) eventually feeds it |
| Integer width (sext/zext/trunc, mask) | ✅ `src/lowering/arith.jl:536`, `narrow.jl` | 🔶 partial in VM | BennettVM `bgc` (width masking) inherits the model; finish the VM-side masking |
| Dict / hash-table | ❌ rejected (`heap.jl:307`) | ❌ | `Bennett-800b` (research: recognize optimizer-inlined Dict ops) → then BennettVM `RevMap` (ADR 0008) |
| `target=:vm` dispatch | ❌ absent | ❌ | **the keystone** — `Bennett-spqu` design phase (§3) |
| Lean formalization | n/a (not in Bennett.jl scope) | ❌ not started in VM | BennettVM-only; PRD SC7; 5 abstract-VM theorems, 0 sorry/axiom |

**Bottom line:** of BennettVM PRD's unmet success criteria, **SC5 (pebble),
SC10 (FP), and most of the memory story resolve to *reusing/wiring* existing
Bennett.jl machinery**, not building it. SC7 (Lean) and the SC9 case-finishing
are genuinely BennettVM-side. The `target=:vm` arm + Dict are genuinely-new
Bennett.jl-side work.

---

## 3. The keystone: `target=:vm` + the Bennett-spqu design phase

This is the single highest-leverage missing piece and it is **joint**.

- **Bennett.jl side (`Bennett-spqu`, P2):** the bead mandates a *research +
  3+1 design phase* before implementation, with deliverables: (1) design brief
  + validation spike; (2) consensus design fixing the **machine model, the
  reversible ISA, the history/checkpoint scheme, and the `target=:reversible_vm`
  dispatch surface**; (3) a milestone roadmap. (Ref:
  `Bennett.jl/Bennett-ReversibleVM-PRD.md §8`.)
- **BennettVM side:** PRD v4 §VIII.2 leaves the integration boundary OPEN —
  "which IR Bennett.jl emits; whether it emits RSSA directly or BennettVM
  lowers a less-reversible IR." BennettVM has *already* answered much of this
  empirically (ADR 0012/0013/0014: it ingests the LLVM-opcode-level `ParsedIR`
  and lowers to a `VMProgram` itself). **The design phase should ratify the
  contract BennettVM already implements**, not redesign it.
- **Concrete dispatch hook (from recon):** the natural insertion is
  `Bennett.jl/src/Bennett.jl:380` (the `reversible_compile(parsed; …)` return
  site) or a new arm in `lower()`; a `:vm` arm would call a BennettVM-provided
  entry (e.g. `BennettVM.lower_vm(parsed)`) instead of `bennett(lr)`. Add a
  `:circuit` alias at the same time for dispatch symmetry. **Minor caveat to
  verify:** `BENNETT_JL_PIN.md` claims a "`target=:circuit` dispatch" exists,
  but the capability recon found no `:circuit` symbol (only `:gate_count`/
  `:depth`). Confirm the exact surface before designing — sources disagree.
- **Rule 14 / approval:** this is a Core Bennett.jl change. The user has
  authorized cross-repo work; still surface each Bennett.jl `src/` diff for
  per-diff approval (the spirit of BennettVM Rule 14 + Bennett.jl's 3+1).

---

## 4. Recommended sequencing — "how to proceed"

Five tracks. Tracks 1 and the Lean part of 1 are **unblocked now**; the rest
layer on the keystone.

**Track 1 — Finish SC9 in BennettVM (unblocked, nearest win).**
1. **Case A dynamic memory** (in progress): `0zn` dynamic-N alloca (decide the
   **region strategy** first — the bump cursor is compile-time, so a runtime-`n`
   region needs a fixed-base single-array strategy or runtime-base threading;
   likely a short ADR 0009 refinement) → `bgc` width masking (inherit
   Bennett.jl sext/zext model) → `xld` `frtN` end-to-end gate (clang-18 is
   installed; build the `.ll` fixture per ADR 0014 §D5). This closes SC9 Case A.
2. **`compute_must_cache` refinement** (`bennettvm-5pp`): restrict it to
   L2-capable instructions so global L2 (and the `frtN` gate's min-cut history)
   works without raising on `Define`/`VarGEP`/`MemoryLoad`.

**Track 2 — The keystone (`target=:vm`), joint, gated on a design phase.**
3. Run the `Bennett-spqu` research + 3+1 design phase (Bennett.jl process):
   ratify the `ParsedIR` handoff contract BennettVM already implements, fix the
   `target=:vm` dispatch surface, and add the user-facing
   `reversible_compile(f, target=:vm)` entry + a `:circuit` alias. This unlocks
   end-to-end `Julia fn → VMProgram` and is the prerequisite for FP/Dict-in-VM
   on *Julia* functions (the `.ll` route already works without it).

**Track 3 — Consume built Bennett.jl capabilities into the VM.**
4. **FP (SC10):** make `BennettVM` depend on / register Bennett.jl's
   `SoftFloatLib` `soft_*` ops as known callees in the interpreter; a Float64
   program (via the `.ll` route now, or `target=:vm` after Track 2) round-trips.
   The PRD's deferred "FP reversibility scheme" is effectively *resolved* — FP
   is `UInt64` arithmetic via SoftFloat; document this (closes the `M_FP` ADR
   `81y`).
5. **Pebbling / history optimization (SC5-analogue for the VM):** port the
   substrate-agnostic Knill DP (`Bennett.jl/src/pebble/pebbling.jl:39,88`) to
   place the VM's L2/L3 checkpoints optimally. Note: the circuit pebbler bails
   on branches; the VM needs its own scheduler over the history tape. (This is
   distinct from the *quantum* pebble-extraction in Track 5.)

**Track 4 — Dict (research-grade, blocked).**
6. `Bennett-800b` (Bennett.jl): research front-end recognition of inlined Dict
   ops (the `optimize=true` no-callee-boundary problem). Then BennettVM `RevMap`
   ADT + ops + `fdict` gate (ADR 0008; `jrc`→`l49`→`7xa`). SC9 Case B.

**Track 5 — The north-star quantum layer (much later).**
7. The VM-program → **uniform-circuit-family** pebble-extraction pass (PRD v3
   §3.7) that feeds the Bennett.jl circuit/quantum backend — the actual link to
   the "north-north-star" taint-driven quantum toolchain
   (`Bennett-VISION-PRD.md §1.1`). Large; depends on Tracks 2–3.

**Independent, interleavable:** BennettVM **Lean** baseline (SC7) — abstract VM
semantics only, 0 sorry/axiom; no Bennett.jl dependency, can start any time.
And **M_OPCODE** coverage (finish the remaining `IRInst` subtypes).

---

## 5. Operating in BOTH repos — the rule differences (CRITICAL)

An agent that applies one repo's conventions to the other will corrupt state.
The load-bearing differences:

| Topic | **Bennett.jl** | **BennettVM.jl** |
|---|---|---|
| **Beads sync** | **JSONL git sync** — `bd export -o .beads/issues.jsonl` + commit. `bd dolt push` is UNUSED / never worked; ignore its errors (user, 2026-05-31). `.beads/embeddeddolt/` is git-tracked too but is NOT the sync channel — the JSONL is. | **JSONL only:** `bd export -o .beads/issues.jsonl`; **NO `bd dolt push`**. After `git pull`, **`bd import`** to load the JSONL into the local Dolt DB (git pull ≠ bd sync — see `memory/bd-import-after-pull`) |
| **Worklog** | **Mandatory Rule 0:** prepend a session block to the highest `worklog/NNN_*.md`; new chunk at ~280 lines. **Never run `scripts/shard_worklog.py` (destructive).** | No worklog rule |
| **LOC limit** | None (god-files `lower.jl` ~2.9k, `extract/heap.jl` ~2.85k; splits tracked as beads) | **Rule 10: ~200 LOC/file** (excl. docstrings) |
| **Commit msg** | `Bennett-<id>: scope: summary`; worklog is provenance | Full `Source:/Reuse:/Validation:/Review:/Rollback:` template |
| **Dolt cache** | `.beads/embeddeddolt/` is git-tracked and changes with bead ops, but committing it does NOT sync a bead — you MUST also `bd export -o .beads/issues.jsonl` (the JSONL is the sync channel). Don't rely on the embeddeddolt commit alone. | JSONL committed with the change; `.beads/embeddeddolt/` is gitignored (per-machine) |
| **Multi-agent** | 3+1 (2 proposers + implementer + reviewer) for `ir_extract.jl`/`lower.jl`/`bennett_transform.jl`/`gates.jl`/`ir_types.jl` + phi resolution | tiered (Trivial/Small/Core); hostile reviewer always on Core |
| **Tests** | `Pkg.test()` (~28 min, 274 files); single-file **must** use `--check-bounds=yes` (`Bennett-2mj3`); `BENNETT_T5_TESTS=0` to skip the corpus | `Pkg.test()` (~35s, currently 3482); single-file `--check-bounds=yes` (same lesson) |
| **Phase system** | none | Phase 0/1/2 with `PHASE.md` gate (currently Phase 2) |
| **CI** | none (Rule 14-equiv) | none (Rule 12) |

Both repos: never `bd init --force`; never `--no-verify`; never amend a pushed
commit; work isn't done until `git push` succeeds.

---

## 6. Pin coordination

- `BennettVM/BENNETT_JL_PIN.md` pins Bennett.jl at **`877341e`** (2026-05-26).
- Bennett.jl HEAD is **`7904560`** (2026-05-28). The drift is **one commit**,
  the `Bennett-spqu` Vision-PRD doc — **docs-only, zero `src/` change** →
  re-pinning is safe.
- **Action:** once cross-repo work starts, re-pin to `7904560` (or to whatever
  the joint work lands on) and record it in `BENNETT_JL_PIN.md` per its own
  methodology. There is no shared pin file inside Bennett.jl; the pin is
  maintained unilaterally in BennettVM. For active co-development consider
  relaxing the pin (it exists to insulate against frontend churn during VM
  bring-up; once you are *changing* the frontend deliberately, the pin should
  track HEAD with each ratified contract change).

---

## 7. Approval gates & risk register

- **Rule 14 (per-diff approval for Bennett.jl `src/`):** the user has opened
  the cross-repo door, but keep surfacing each Bennett.jl source diff for
  approval. The big ones: the `target=:vm` dispatch arm, the `mem=:vm`
  extraction arm, and anything touching `Bennett-800b`/Dict.
- **Research-grade / not-yet-de-risked:** `Bennett-800b` (Dict recognition —
  the optimizer-inlining problem has no known solution in `references/`); the
  VM pebble-extraction for the quantum target (Track 5).
- **Effectively resolved (good news):** the PRD's deferred **FP reversibility
  scheme** — Bennett.jl's bit-exact SoftFloat answers it (FP = `UInt64`
  arithmetic). Float32 is intentionally rejected (double-rounding); leave it
  (`Bennett-e283`, P4).
- **Watch items:** the pebblers silently fall back to full Bennett on branches
  (so "pebbling is built" does NOT mean "loops are pebbled"); the persistent
  maps are `NTuple`/static-`max_n` (circuit shape), not a drop-in dynamic VM
  heap; `hashcons=:feistel` is wired-but-NYI (`memory.jl:224+`).

---

## 8. Immediate next actions (concrete)

1. **BennettVM, unblocked:** resume Case A — decide the dynamic-N **region
   strategy** (short ADR 0009 refinement) → implement `0zn` → `bgc` → `xld`
   (`frtN` `.ll` via clang-18). Then `5pp` (must_cache refinement).
2. **Joint, start the design phase:** open/clone the `Bennett-spqu` design work
   — write the `target=:vm` dispatch-surface brief, ratifying the `ParsedIR`
   contract BennettVM already implements. (Create a BennettVM tracking bead
   cross-linked to `Bennett-spqu`.)
3. **Re-pin** Bennett.jl `877341e → 7904560` in `BENNETT_JL_PIN.md` (safe).
4. **Hygiene:** BOTH repos sync beads via `bd export -o .beads/issues.jsonl` +
   git (NOT `bd dolt push` — unused/never-worked, ignore its errors). Bennett.jl
   also needs the worklog + `Bennett-<id>:` commits; BennettVM uses `bd import`
   after pull + the full commit template. Don't cross the streams.

---

*This handoff supersedes the "pebble/FP not started" framing in the prior
session summary: those are built in Bennett.jl and the work is wiring, not
greenfield. Verify every `path:line` against the live repos before relying on
it (Rule 3 / skepticism) — the recon was thorough but the codebases move.*
