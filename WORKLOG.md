# WORKLOG — BennettVM.jl

> Chronological session log. Prepend new sessions to the top. Capture
> what was done, what was decided, and what surprised us — anything a
> future agent or human would wish it knew, that's not derivable from
> `git log` or the retrospective.

---

## Session — 2026-07-06 — 416r.4 LANDED via 3+1: const globals as read-only VM memory (unblocks real ROMs; closes dzd)

**What.** `bennettvm-416r.4` (const globals as initialized read-only VM memory
segments) — the prerequisite for loading a real NES ROM. Done via the CORE 3+1
protocol (2 opus proposers → 1 opus implementer → orchestrator review), because
it touches Bennett.jl's extractor AND BennettVM's IState/memory-floor.

**The scoping finding that shaped it.** A `const uint8_t rom[]` read at a runtime
index (`rom[i&7]`) breaks at the FRONT-END, not the VM: `getelementptr [8 x i8],
ptr @rom, i64 0, i64 %idx` is the SAME 2-index array GEP wall as C stack arrays
(dzd / qal5 / U16), just with a global base. So 416r.4 = front-end 2-index-array-
GEP support + VM globals materialization, and the front-end half ALSO closes dzd.

**Design decision (the 3+1 divergence I ruled on).** Both proposers converged
(reuse `IRVarGEP`, one-element-per-cell — VERIFIED against `_extract_const_globals`
which stores one zero-extended element per cell — `GLOBAL_BASE=2^48` tier). They
split on ROM storage: Proposer B seeded it into `IState.memory` (→ deep-copied
into EVERY L3 checkpoint — a 16KB ROM × thousands of checkpoints = scale-killer);
Proposer A used a read-only segment excluded from checkpoints. **Ruled for A** —
semantically correct (ROM is immutable) and essential for 16KB scale.

**Implementation (verified green by orchestrator, not trusted).**
- Front-end (Bennett.jl `src/extract/instructions.jl`): new "Case C" arm before
  the qal5 reject — 2-index array GEP on a const-global OR local-alloca integer
  array → `IRVarGEP(base, idx, elem_width)`. Fails loud on non-integer element /
  first-index≠0 / >3 operands. Handles BOTH bases → **closes dzd** (the C-stack-
  array wall E1 dodged with calloc).
- VM: `GlobalROM` wrapper with `deepcopy_internal(g,_)=g` — the override lives on
  the SMALL type, so IState's default field-by-field deepcopy stays safe (no
  fragile custom IState deepcopy; a future field can't be silently dropped). ROM
  is shared across all checkpoints, excluded from `==`/`hash`, seeded once at
  `initial_state`. `MemoryStore` to `>=GLOBAL_BASE` FAILS LOUD (const write =
  miscompile). `_global_segment` materializes only REFERENCED globals; a
  `Define(name,base)` prepended to the entry block binds the ROM pointer
  (reversible like any create).
- Verified: `test_global_array_vm.jl` 2375/2375 (gtest all 0:255 fwd==native +
  round-trip; store-to-global fails loud; dzd stack-array round-trip; 256B + 16KB
  arrays + ROM-NOT-in-checkpoint assertion). BennettVM full suite 9328/9328.
  Bennett.jl front-end (qal5/haiy updated legitimately, not weakened) green.

**Two touched Bennett.jl fail-loud tests (reviewed, legit).** qal5's original
fixture (`[4 x i32], ptr @tbl, 0, %i`) IS the 416r.4 goal and now extracts — the
test now positively checks that + rejects a genuine multi-dim `[2x[2xi32]]` and a
non-integer `[4xdouble]`. haiy swapped its now-supported `[4xi64]` local case for
`[4xdouble]` (still rejected). Fail-loud coverage preserved.

**CRITICAL follow-up for the roadmap.** Multi-function const globals are DEFERRED
behind a fail-loud guard (`ingest_multi.jl`): per-function `_lower_parsed_ir`
assigns bases from `GLOBAL_BASE+0`, so two functions referencing globals collide;
the merged VMProgram also drops per-function globals. **This is on the nestest
critical path** — `cpu6502.c` is multi-function and `cpu6502_core` (a callee)
reads the ROM. Filed as a follow-up bead + wired as a dep for A1/E2.

---

## Session — 2026-07-06 — E1 LANDED: full hardware-faithful 6502 core, all 151 opcodes green on the VM

**What.** E1 (`zbeg`, CLOSED) — `emulator/cpu6502.c`, a complete MOS 6502
fetch-decode-execute core, extracts + lowers + runs on BennettVM. Built by an
opus subagent; orchestrator-reviewed (code read + independent harness runs).

**THE DISPATCH VERDICT (E1's central de-risk).** A C `switch(op)` over the 151
sparse official opcodes, compiled at -O0, **survived extraction as 1 plain LLVM
`switch`, 0 `@switch.table` lookups** — no qal5/dzd lookup-table wall. So the
full opcode decode is a mechanical `switch`; the wall I feared (dense
if/elseif → jump table) does NOT materialize for sparse real 6502 encodings at
-O0. This is the key reusable finding for anyone extending the core.

**Verification (orchestrator ran these, did NOT trust the agent's report — which
was in fact a non-report; see gotcha).**
- Subset (5 representative groups: loads, ALU+flags, ALL addr modes, JSR/RTS +
  hardware stack, known-answer loop): **57/57, full fwd+rev round-trip** (VM==
  native, history empty, frames==1, cursors 0, current==initial).
- Full sweep (all 23 groups, forward-only via new `BENNETT_CPU_FWDONLY=1`):
  **273/273** — every opcode VM==native bit-for-bit + 6 known-answer semantic
  groups match closed-form 6502. Round-trip is a generic VM property (proven on
  the sample + hashtable/collatz), so forward-only all-opcode + round-trip-sample
  is the efficient-but-rigorous split.

**Code review — hardware-faithful, not a toy.** Correct ADC/SBC overflow; the
**JMP-indirect (0x6C) page-boundary bug** modeled; TXS sets no flags (TSX does);
PHP/PLP B/U handling; JSR pushes return-1, RTS +1, RTI no +1. **NES-correct: no
BCD** (the 2A03 disables decimal mode). mode-0 observable = xorshift64 checksum
over regs + \$0000-\$01FF so any reg/cell error avalanches (Rule 4).

**Gotchas worth knowing.**
- **The opus agent never reported.** Its final messages were "I'll wait for the
  monitor's completion event on the full run" — it had launched its OWN full
  fwd+rev sweep (~28min, pid 73232) in the background and idled on it, so the
  task-notification carried no summary. Lesson: a subagent that kicks off a long
  background job can complete with an empty report; the orchestrator MUST verify
  from artifacts, not the agent's final message. I killed the stale pid (and,
  clumsily, `pkill -f test_cpu6502` also killed my OWN verification run once —
  match patterns carefully when self-running the same harness).
- **Reverse cost makes full fwd+rev impractical to iterate:** ~5s/seed L3 replay
  → ~28min for all 23 groups. Added `BENNETT_CPU_FWDONLY` (uses B1 `record=false`)
  → same forward result, ~3min. This is why B1 landing first paid off immediately.
- Build artifacts (`cpu6502.O0.ll` 393KB, `cpu6502_golden`) are regenerated by
  `build!()` every run → gitignored (unlike the committed `test/reference/c/*.ll`
  fixtures, whose harness does NOT rebuild). Follow-up `bennettvm-6vp9`: clang-
  gate + suite-register a small FWDONLY smoke subset.

**Semantic-validation scope (honest).** E1 validates via known-answer programs +
hardware-faithful review + native-consistency — NOT against an independent 6502
reference. Full conformance is E2/nestest's job (that IS what nestest is for);
noted on `bc08`. The core is nestest-ready by structure (`cpu6502_core(mem,pc,
budget,mode)` runs from any PC over preloaded memory).

---

## Session — 2026-07-06 — Orchestrated build begins: B1 fast mode LANDED (E1 6502 core in flight)

**What.** Started orchestrating the emulator build: claimed E1 (`zbeg`, 6502
core) + B1 (`zr7x`, fast mode), delegated both to subagents in parallel (E1→opus,
B1→sonnet), orchestrator reviews each. **B1 landed + reviewed green + committed.**
E1 still running at time of this entry (`emulator/cpu6502.c` grew to ~58KB — a
full core).

**B1 — forward-only fast mode (`run!(...; record=false)`), CLOSED.**
- Mechanism: `record=false` ORs into the existing M7.6 `replay_mode` push-
  suppression (no new suppression logic) → no L1/L2/L3 tape recorded.
- **The non-obvious part (why it's more than a one-line kwarg):** a fast-mode
  RState ends with `isempty(history) && step_count>0`, which is *structurally
  identical* to the legitimate "normal run, no checkpoint pushed yet" case that
  `unstep!` reverses via its `s.initial`-replay fallback. Without a marker,
  `unrun!` after fast mode would **silently succeed** by full-replaying from
  `s.initial` on every backward step — O(n²), correct-but-catastrophic, exactly
  the Rule-4 "runs, just slowly" trap. Fix: a monotonic `fast_mode` taint bit on
  `RState`, checked FIRST in `unstep!` → fail loud. The agent (sonnet) caught
  this itself; good judgment.
- **Review (orchestrator = the +1):** read all 3 core-file diffs line-by-line;
  ran `test_fast_mode.jl` (56/56, suite mode), `test_delta_push.jl` (the
  legitimate empty-history replay the guard must NOT break — green), and
  `test_rstate.jl` (the `==`/`hash`/constructor change — 10/10). **Judgment call
  logged:** the `fast_mode` field is on `RState` (core-adjacent, `src/ir/`), NOT
  in the CLAUDE.md Rule-2 enumerated core list (ir_types/gates/lower/etc.). I
  accepted it WITHOUT full 3+1 — it's a defaulted bookkeeping field with direct
  precedent (`step_count`/`initial` were added post-hoc the same way), fully
  back-compat, thoroughly reviewed. Future agents: if the RState surface keeps
  growing ad hoc, revisit whether it warrants the 3+1 gate.

**The framerate baseline (this is the number that matters).** ~**67.7 VM-steps
per guest 6502-instruction** (stable across input sizes). → ~8.6–10k
guest-instr/s recording, ~18–24k fast. SMB needs ~500k/s. So the **toy** CPU core
is already ~50× short before any PPU — quantitative confirmation that Track B (C
port `eqz5` / native codegen `3h9u`) is mandatory for framerate, and that fast
mode buys only ~2.3×. Recorded on `zr7x` + design doc §9.1.

**No new beads needed for B1** — clean landing, no issues arising. The benchmark
data feeds existing B2 (`9xla`) / B3 (`eqz5`).

---

## Session — 2026-07-06 — North star raised: SMB @ NES framerate — two-track strategy + full bead DAG

**What.** The emulator north star was raised from "nestest headless" to **play
Super Mario Bros at actual NES framerate (60.0988 Hz), loading speedrun
scripts.** Assessed bead coverage (answer: existing beads cover *only* the
CPU-correctness trophy — zero PPU/APU/timing/loader/TAS/perf), specced a
two-track strategy into `docs/design/emulator-on-bennettvm.md` §9, and filed the
full DAG (16 beads + 1 new epic).

**The load-bearing finding (§9.1).** Framerate is UNREACHABLE on the current
Julia tree-walking VM interpreter — ~2–4 orders of magnitude short — because of
**double interpretation** (Julia interprets the VMProgram which interprets 6502;
1 guest instr ≈ 20–80 VM `step!`). Budget: SMB needs ~500k 6502-instr/s +
~5.4M PPU-dot/s; E0 measured ~28,500 guest-opcodes/s forward on a *toy* core.
**Reversibility is NOT the blocker** — `rr` does native reversible execution at
~1.2–2× overhead. The interpreter is. So framerate ⇒ get off the Julia
interpreter.

**Strategy (correctness first, user-directed).**
- **Track A** (epic `v5eb`, P2): full reversible NES, correct-but-slow, on the
  VM. Beads `hahl`(ROM/NROM loader) → `6sma`(PPU bg) → `tsjq`(sprites+sprite-0)
  / `pldf`(scroll+NMI) ; `jm77`(controller→InputRef) ; `87sk`(APU) ;
  `nxpa`(.fm2 parser) ; `ikow`(framebuffer golden vs FCEUX) ; capstone
  `ztz7`(SMB boots→1-1 under TAS). E1 `zbeg` bumped P3→P2 (gates all of Track A).
- **Track B** (NEW epic `1is3`, P2–P4): faster reversible execution. **Lead
  approach = PORT THE VM INTERPRETER TO C** (`eqz5`) — the user's directive; a
  fast C `run!`/`unrun!` reimplementing L1/L2/L3, ~10–50× over the Julia
  tree-walker, reversibility semantics port directly. `zr7x` forward-only fast
  mode lands first (baseline + decouples speed from reversibility). `9xla` Julia
  hot-loop opt ; `vspu` bounded rewind horizon (can't keep ~51M deltas/level) ;
  `3b70` real-time frame scheduler ; `3h9u` (stretch) native codegen + rr-style
  delta instrumentation.

**Gotchas / decisions worth knowing.**
- **SMB is genuinely the easy NES target for mappers**: Mapper 0 / NROM, no bank
  switching, and it uses only official opcodes. The hard parts are PPU
  sprite-0 hit (HUD/playfield split — load-bearing) + NMI timing, not the CPU.
- **A `.fm2` TAS movie is BOTH the speedrun-loader AND the PPU oracle** —
  per-frame framebuffer hashes vs FCEUX are the golden master (Rule 4).
- **`bd ready` after wiring** correctly surfaces exactly two entry points:
  `zbeg` (E1 core) and `zr7x` (B1 fast mode) — the intended parallel starts.
- **Beads-sync (again):** every `bd create` re-triggered the lossy auto-export
  that drops the 4 memory records; restored with `bd export --include-memories`
  before commit (per `reference_beads_sync_models` gotcha 1).

---

## Session — 2026-07-03 — Side quest: run an emulator (NES/6502) on the VM, reversibly — feasibility PROVEN + MVP

**What.** Investigated "decompile Super Mario Bros → LLVM → run on BennettVM,
log side effects to a tape." Split into two ideas: (1) *lift the ROM's 6502 to
LLVM* — dead end (undecidable statically: indirect jumps, self-modifying code,
mappers; jamulator abandoned); (2) *compile an emulator to LLVM, ROM as data,
side effects to a tape* — the right architecture, and it fits the VM. Built a
working MVP of (2), wrote `docs/design/emulator-on-bennettvm.md` + reproducible
`docs/design/emulator-mvp/`, filed epic `bennettvm-v5eb` (+ E0/E1/E2/InputRef).

**MVP (E0, `bennettvm-33bf`, CLOSED).** A genuine 8-opcode 6502 fetch-decode-
execute core in C (`docs/design/emulator-mvp/mos6502.c`) running hand-assembled
guest machine code (a BNE-driven loop computing 5·n), through the **C path**
(clang -O0 .ll → `extract_parsed_ir_set_from_ll(ptr_cells=true)` →
`lower_vm(entry=:mos6502)` → 406 VM instrs). Forward == native-C golden AND
`unrun!` to exact initial state, every input. GREEN + reproducible from the repo.

**Surprises / gotchas worth knowing (not in any diff):**
- **RAM was the easy part.** Dynamic array read/write at a *runtime index*
  round-trips today — better than the capability audit implied. Requirements
  1–3 (unbounded loop, runtime-index RAM, opcode dispatch) are all green NOW.
- **The Julia path can't back a real emulator yet.** `zeros(Int64,64)` +
  runtime-indexed loop → Julia heap-allocs via the GC, emitting `call ptr asm
  "movq %fs:0"` (thread-ptr for GC state) → rejected (Bennett-5oyt/U15). A
  *small* array (`zeros(Int64,8)`) is SROA'd away so it slips through — which
  is why a naive Julia smoke test misleads. **Use the C path** (this is exactly
  why the frontier e2e is a C hashtable, not Julia). Julia array path =
  `bennettvm-m9i` + the fdict/gc-alloc CW-D workstream.
- **C stack arrays are rejected; heap arrays pass.** `uint8_t mem[64]` emits a
  two-index GEP `[64 x i8], ptr, 0, %idx` → rejected (Bennett-qal5/U16, already
  bead `bennettvm-dzd`). Fix: `calloc`'d pointer RAM → single-index `i8, ptr,
  %idx` GEP, the shape the hashtable path handles. The MVP does this.
- **Dense if/elseif over small opcodes {0,1,2} → LLVM switch.table lookup GEP →
  rejected.** But *sparse real 6502 opcodes* (0xA9/0xE8/…), binary-tree, and
  control-divergent dispatch all pass. Real 6502 decode is sparse, so this is a
  non-issue in practice (verified: `smoke_dispatch.jl` D1/D2/D3).
- **Perf is the wall, as expected.** Reverse ≈ 570 guest-opcodes/s at K=32
  (L3-replay-bound); forward ~50×. Projected: forward ~0.5 s/NES-frame (~1–2 fps
  slideshow), reverse ~20–25 s/frame. Not a correctness blocker; `bennettvm-uom`
  (L1/L2 memory-delta lowering) is the lever. Cross-ref `bennettvm-w0a0`.

**Validation.** The spike independently rediscovered the exact known frontier —
every obstacle already had a bead (dzd, m6c/6ox/rlx/agm, 416r.4, m9i, uom, w0a0).
The one genuine gap with no bead: *recording* nondeterministic input (controller
reads) — filed `bennettvm-6dko` (InputRef, a TAS-movie input tape dual to
OutputRef). Trophy target: `nestest.nes` headless CPU conformance, reversible.

---

## Session — 2026-06-30 — Documentation round: production README rewrite + new docs/src site

**What.** Replaced the README (which was frozen at the Phase-1→2 transition — it called
the project "Phase 2 gated / M0", `bennettvm_prd.md` "PRD v3", and `src/`/`test/` "empty",
and spent ~90% of its body on the archived spike) with a public-facing front door for the
**production** VM: the `run!`/`unrun!` round-trip, the three-layer history model, the
instruction set, the registration-hook integration, and the four motivating cases (A–D).
Added a Diátaxis `docs/src` site from scratch — `index.md`, `getting_started/quickstart`,
`explanation/{what_is_bennettvm, instruction_set, reversibility_model, integration}`,
`reference/api` — plus `docs/make.jl` and `docs/Project.toml`.

**Method.** A mapping workflow (6 subagents) produced subsystem maps + a doc-staleness
audit; a write-then-adversarially-verify workflow authored the pages grounded in a
verified-facts block + source. The verify pass **empirically confirmed** facts by reading
source and compiling: e.g. the collatz entry-parameter key is `Symbol("n::Int64")` (not
`:n`) — the quickstart and README now use the correct key.

**Facts pinned in the new docs (from source).** Public API = exactly the 10 exports
(`VMProgram, lower_vm, n_instructions, initial_state, is_halted, result, step!, run!,
unstep!, unrun!`). `initial_state(prog, input::AbstractDict)` takes **two** args. IState
has **no flat `locals` field** — the active register file is `active_locals(s) =
frames[end].locals`. History is L1 injective / L2 `DeltaEntry` min-cut / L3 `CheckpointEntry`
(K=64) + replay; injective L1-skipped steps reverse via the **L3 replay fall-through**, not
a per-instruction inverse. Heap is **cell-addressed** `Int64`. There is no `:circuit`
symbol in Bennett.jl (the circuit target is `:gate_count`/`:depth`).

**Gotchas / follow-ups (unfiled — ran no `bd` to keep the jsonl export clean).**
- `BENNETT_JL_PIN.md`, `src/lower_vm.jl`, and `bennettvm_prd.md` §3.7 cite four divergent
  Bennett.jl SHAs — reconcile to one canonical pin.
- `src/BennettVM.jl` "Status" docstring is frozen at "M0.1 package skeleton only"; several
  PRD §3.x signatures (`initial_state(prog)`, the immutable-IState `step!` ordering, the
  `locals` field) describe abandoned designs. All catalogued in the session's subsystem maps.
- `docs/make.jl` uses `doctest=false` (the VM examples are plain ```julia blocks).

## Session — 2026-06-26 — Bennett-igr3: ingest julia.gc_loaded data-ptr launder (Small-tier)

**Bennett-igr3 landed** (the BVM ingest half; downstream of Bennett.jl `qmv7`). Bennett.jl's
qmv7 extraction emits the heap-Memory base of a `setindex!` value-store as
`IRCall(:d, Symbol("julia.gc_loaded"), [mem, data], [64,64], 64)` — Julia's GC-rooting
launder, which RETURNS the data pointer (args[2]); `mem` (args[1]) only keeps the Memory
GC-rooted and is STRUCTURALLY UNREAD. Before this arm, the IRCall fell through to the
SoftCall allowlist and failed loud ("unknown callee_name :julia.gc_loaded").

Added one arm in `src/ir/ingest_body.jl` (`_lower_body_inst`), right after the
`_HEAP_DISPATCH` check and before the Float32 guard / SoftCall constructor: it aliases
`dest := data` via the established pointer-identity create `Define(dest, data, :add, 0)`
(the cell-addressed VM treats the laundered data ptr AS the Memory virtual base — the base
qmv7's IRVarGEP/IRLoad/IRStore re-root onto). Reversed by L3 checkpoint-replay (`Define` is
non-injective, ADR 0012 §D1). Arg-count≠2 fails loud (Rule 1). `data` lowered via
`_lower_ptr_operand` (SSA-ptr discipline, matching IRStore/IRLoad/IRVarGEP).

Test `test/test_igr3_gc_loaded_ingest.jl` (8 @tests, registered beside its `gc_alloc_obj`
sibling): ingest shape `Define(:d,:data,:add,0)`, forward binding `:d==data`, the
mem-invariance soundness witness (vary `:mem` → bit-identical `:d`, mirroring gc_alloc
tag-invariance), and the fail-loud arity guard. Full suite **6897/6897**.

**Process** (BVM Rule 6 Small-tier: one file, ≤30 LOC, existing `Define`): TDD red→green
(Rule 5) + a hostile reviewer subagent → APPROVE_WITH_NITS (operand order + reversibility +
dispatch ordering all confirmed correct against ground truth; nit applied: use
`_lower_ptr_operand` not `_lower_operand` for the ptr arg). No full `run!`/`unrun!`
round-trip needed — gc_loaded emits a bog-standard `Define`, whose reversal is already
covered by the generic Define round-trip tests; it adds no new reversal mechanism.

**Symbol gotcha:** Bennett.jl emits the UN-canonicalised LLVM name `Symbol("julia.gc_loaded")`
(via the generic call path `Symbol(cname)`), NOT a canonical `:gc_loaded` — contrast
`:gc_alloc_obj`, which Bennett.jl DOES canonicalise (`instructions.jl:2636`). Verified
empirically against the qmv7 `GCL_I8` fixture (operand order `[mem, data]` per
`test/reference/fdict_O0.ll`).

**Next:** pairs with `Bennett-jfw6` (closed today, Bennett.jl side) toward the full fdict
e2e (`bennettvm-7xa`). The downstream BVM cell-index bug `Bennett-eln6` (i8 GEP byte-offset
mapped directly as cell-index) is the next CW-D item.

---

## Session — 2026-06-25 — M13 COMPLETE: vw8 e2e collatz capstone (target=:reversible_vm one-liner)

**bennettvm-vw8 landed; M13.1–M13.4 closed.** Added `test/test_e2e_collatz.jl`
(59/59 green; full suite 6889/6889) proving the user-approved capstone — the
public Bennett.jl one-liner

    Bennett.reversible_compile(collatz_steps, Int64; target = :reversible_vm)

— compiles, runs forward to the irreversible Int64 collatz oracle (capped-at-20
golden master), and `unrun!`s to the P0.6 exit invariant across 9 inputs (incl.
x=27→20). Routed via the **a5j load-time registration hook** (`__init__` sets
`Bennett._REVERSIBLE_VM_BACKEND[] = lower_vm`); arg/ret keys derived from the
Begin/End markers (robust to extraction renames, à la `test_fp_roundtrip.jl`).

**Bead-bookkeeping correction (recon-driven):** zg5/fu5/kl3 (M13.1–3) described a
STALE design — a `driver.jl` validator edit + a Project.toml extension dep — that
was **superseded by a5j's registration hook** (no `lower()` edit, no extension,
no circular dep; the dispatch arm in `reversible_compile` intercepts
`:reversible_vm` BEFORE `lower()` is reached). All three closed as superseded;
vw8 `--force`-closed (it was blocked by kl3 + the 7xa Dict / xkl Vector cases,
but scalar collatz is Case D — independent of those). The user had ALREADY
approved emitting `target=:reversible_vm`; the "REQUIRES USER APPROVAL" flags
were stale. **M13 is functionally complete** — the VM backend is reachable from
Bennett.jl's public API end-to-end.

NB cross-repo: this session also landed two Bennett.jl CW-D extraction walls
(Bennett-59zi sret call→memcpy; Bennett-qmv7 setindex! gc_loaded heap-store) that
feed the fdict path; see Bennett.jl worklog/090. Downstream BVM beads filed:
`Bennett-igr3` (ingest `julia.gc_loaded` IRCall — the next BVM-side fdict step).

---

## Session — 2026-06-23 — Bennett-6bu3 (consumer side): StructType {ptr,ptr} aggregate ingest + IRInsertBits pin reconciliation

**Cross-repo 3+1 driven from Bennett.jl** (bead `Bennett-6bu3`); this is the
BennettVM CONSUMER half. Bennett.jl's extractor now supports StructType
`insertvalue`/`extractvalue` (Julia's `{ptr,ptr}` GenericMemoryRef body) via an
additive `field_widths::Vector{Int}` on `IRInsertValue`/`IRExtractValue`
(Option 1 — chosen over a new IR node precisely BECAUSE BVM's slot model already
handles it).

**BVM change is essentially nil — by design.** The insertvalue/extractvalue
ingest (`src/ir/ingest.jl`) decomposes an aggregate into a FAMILY of per-slot
`Define`s keyed by field INDEX (`_agg_<dest>_slotK`), each an Int64 cell —
**index-keyed and width-agnostic**. Because the extractor sets
`n_elems == length(field_widths)`, the existing slot loop + bounds guards handle
`{ptr,ptr}` (two 64-bit cells) UNCHANGED. So `ingest.jl`/`ingest_phi.jl` got
COMMENT-ONLY updates (the stale "StructType fails loud upstream" claim is now
false). This is the payoff of Option 1 over Option 2 (a new `IRExtractBits` would
have needed a brand-new bit-offset→slot ingest arm here).

**Pre-existing drift reconciled.** `test/test_opcode_coverage.jl:171` pinned
`length(filter(isconcretetype, subtypes(Bennett.IRInst))) == 19`, but Bennett.jl
has had **20** concrete subtypes since `Bennett-dv1z` added `IRInsertBits` — so
this testset (0) was **silently RED** (84 pass / 1 FAIL) against the live tree,
unnoticed since dv1z. Bumped the pin 19→20 and added `Bennett.IRInsertBits` to
the canonical list + a `coverage-matrix.md` row marking it **N/A** (it is
synthesised only by Bennett.jl's sret bits-chain and never reaches BVM — sret
aggregate returns are rejected upstream). The pin now moves in lockstep with
Bennett.jl's `test_q04a` (==20).

**New test:** `test/test_6bu3_struct_agg_ingest.jl` (28/28) — hand-built
`{ptr,ptr}`-shaped ParsedIR (`IRInsertValue`/`IRExtractValue` with
`field_widths=[64,64]`) → `lower_vm` → `run!` matches oracle → `unrun!` to EMPTY
history (P0.6) → per-step inverse check; slot-family Defines present.

**Verified.** BVM full `Pkg.test()`: green (test_opcode_coverage now 86/86 at
count 20; test_aggregate_extract_insert 50/50 unchanged). Bennett.jl full suite
also green (689198 pass / 0 fail / 3 broken). The fdict root (Bennett.jl side)
advances past the insertvalue wall to the `ptrtoint ptr %memory_data… (iwo9 /
CW-D3 Lever 1)` GenericMemory data-pointer wall → next is the GenericMemory
recognizer (`Bennett-jfw6` / `bennettvm-m9i`), NOT a standalone iwo9 extension.

## Session — 2026-06-23 — CW-D3 Lever 3: gc_alloc_obj → IntrinsicGCAlloc arena ingest

**Agent:** Opus 4.8 (1M) implementer (Lever-3 half of the gc_alloc_obj capability,
bead `bennettvm-416r.12` gc_alloc_obj PART only). Cross-repo design pre-decided in
`../Bennett.jl/docs/design/Bennett-iwo9-CW-D3-typetag-consensus.md` decision 5. Serial Julia
(Rule 7). Red-green TDD (Rule 5 spec-from-scratch shape).

**What landed.** BennettVM now ingests Bennett.jl's (Lever-2) `IRCall(:obj, :gc_alloc_obj,
[size_op, tag_op], [64,64], 64)` as a deterministic arena bump-allocation, mirroring
`IntrinsicMalloc` verbatim, with the Julia type tag IGNORED (ADR 0021 D3 floor).

- `src/ir/intrinsics.jl`: new `struct IntrinsicGCAlloc <: Instruction` with fields
  `dest`, `nbytes_operand`, `type_tag`. Added to the `_ArenaAlloc` union so it inherits
  `predelta_payload` / `forward` / `inverse` / L3-raise verbatim — ZERO new state-transition
  code. New `_alloc_cells(::IntrinsicGCAlloc, s)` resolves cell count from `nbytes_operand`
  alone.
- `src/history/Injective.jl`: `is_injective(::Type{IntrinsicGCAlloc}) = false` (same shape
  as IntrinsicMalloc — materialises a pointer + opens a region).
- `src/history/delta.jl`: `is_l2_capable(::Type{IntrinsicGCAlloc}) = true` (inherits the
  `(base, cells)` L2 path via the union). VERIFIED (per consensus R6) that BOTH traits
  dispatch per-CONCRETE-type, not on the union — that's why the two one-liners are needed
  even though forward/inverse come free from the union membership.
- `src/ir/ingest_call.jl`: `:gc_alloc_obj` added to `_HEAP_DISPATCH`; new
  `_lower_intrinsic_call` arm (`_need(2)` → size, tag; both via `_lower_operand`).

**The tag-ignored-by-construction guarantee.** The `type_tag` field is STRUCTURALLY UNREAD:
the ONLY methods that touch the field at all are the constructor and the ingest arm that
stores it. `_alloc_cells` / `predelta_payload` / `forward` / `inverse` read only `dest` and
`nbytes_operand`. The tag-invariance test is the soundness witness: the same alloc with tags
0/1/99 (and an SSA-bound tag whose locals value is junk `123456789`) yields a bit-identical
post-forward IState (asserted via BennettVM's `IState` ==/hash override over
pc/locals/memory/arena_top). No JIT type-tag address can reach the VM.

**Red→green.** RED: `UndefVarError: IntrinsicGCAlloc not defined` + the ingest arm absent
(gc_alloc_obj fell through to the `else` memmove `_need(3)` → "expects 3 args, got 2").
GREEN after the four edits: `test/test_gc_alloc_obj_ingest.jl` 23/23.

**Regression.** `test_arena_roundtrip.jl` 54/54, `test_symbol_callee_ingest.jl` 8/8 — no
regression. (Full suite NOT run per instruction — long; targeted files only, one julia at a
time.)

**LOC.** `intrinsics.jl` code-only LOC (excl blank/comment/docstring) ~135 after the add —
comfortably under the ~200 Rule-10 cap; no split needed.

**Scope discipline.** Did ONLY the gc_alloc_obj ingest. The other `416r.12` whitelist parts
(jl_alloc_genericmemory, throw→halt, write_barrier audit) stay OPEN. No Bennett.jl mutation.

---

## Session — 2026-06-15 — CW-D1b landed (closed-world producer) + Case-B path re-confirmed SETTLED

**Agents:** Opus 4.8 (1M) orchestrator, autonomous. 3+1 design pass → Opus implementer
→ +1 + hostile review. Serial Julia (Rule 7).

**Course-correction first (the lead caught it):** mid-D1b I surfaced a closed-world-vs-RevMap
"fork" as if open. It is NOT — the worklog/ADR record settles it: **ADR-0017 (lead, 2026-06-10)
chose CLOSED-WORLD execution OVER RevMap**, knowing RevMap was the easier "tractable floor";
RevMap is demoted to quantum-tier (`o1y`). DO NOT RELITIGATE. Recorded as bd memory
`case-b-closed-world-settled`. The U14/dv1z extractor walls are the **accepted closed-world
runway**, not a pivot trigger.

**Landed: CW-D1b** (`bennettvm-416r.11` chunk b) — `extract_parsed_ir_set_from_julia` in
**Bennett.jl** (`src/extract/julia_set.jl`, commit `06c1ed91`; additive). Drives D1a's
`transitive_callees`, extracts root + helper bodies, keys by drift-free canonical
`<barename>#<digest>` Symbols, and `_closed_world_check!` fails loud on any IRCall escaping
the closed world (the completeness `transitive_callees` defers). `test_d1b` 30 Pass / 1 Broken.

**Ground truth (the blocker, honestly handled):** 0/4 `fdict` callee bodies extract today —
`setindex!`/`rehash!` hit the **U81** ptr-width wall, `ht_keyindex2_shorthash!` the **dv1z**
heterogeneous-sret wall. ADR-0021 confirmed the IR is *recoverable* (`code_llvm`); D1b found
that *lowering it through `extract_parsed_ir`* walls. So D1b ships the producer machinery
proven on a synthetic extractable root, with `fdict` as an HONEST `@test_throws` (`:fail_loud`)
+ `@test_broken` (`:skip ≥4`) tripwire that auto-flips when CW-D2 clears the walls.

**Hardening + hostile-review fixes (pre-commit):** the producer `register_callee!`s live
callees to clear the U15 guard, but was permanently polluting the process-global
`_known_callees` — a real interlock with `test_bd5f_heap_m4` (pins Dict-rejection, runs later
in `runtests`, needs `setindex!` UNregistered). Fixed: SNAPSHOT + SCOPED restore in a `finally`
(race-tolerant — only touches keys this call added; Gate G guards it). Plus S1 (closure-`#`
barename `rsplit`), S3 (Gate E asserts a real wall), N2 (within-process digest determinism).
Hostile review: no BLOCKER; the bd5f interlock independently verified.

**Gates (orchestrator-run, fresh subprocess):** test_d1b 30 Pass/1 Broken; `using Bennett`
clean; Bennett.jl gate-count 39/39. Full `Pkg.test` deferred to the CW-D1 pre-push. **Pin:**
repin still deferred to D1c (BVM doesn't consume the producer yet).

**Follow-ups:** `bennettvm-2k1k` (P3, unify benign-intrinsic const). **Next (the runway to a
real `fdict`):** the extractor extensions — ptr_cells-for-Julia (ADR-0021 D2) + U14 atomic-load
collapse + dv1z heterogeneous-sret — each a core 3+1; then D1c (hand-stitched set ok first) →
CW-D2 whitelist → CW-D3 globals → `7xa`. Full ground-truth in Bennett.jl worklog 082.

---

## Session — 2026-06-14 — CW-D1a landed (transitive_callees walker) + ADR-0021 Decision-1 corrected

**Agents:** Opus 4.8 (1M) orchestrator, foreground, autonomous directive ("keep
working; Opus coders, Sonnet summarization; what would a senior expert demand?").
3+1 design pass (fresh ground-truth → 2 blind Opus proposers → synthesis) → Opus
implementer → +1 + hostile review. Serial Julia (Rule 7).

**Landed:** **CW-D1a** (`bennettvm-416r.11` chunk a) — the `transitive_callees`
typed call-graph walker, in **Bennett.jl** front-end (`src/extract/callgraph.jl`,
commit `0c2a7f87`; additive, Rule-14 crossing under standing approval). Returns the
transitive `:invoke` callee closure (root excluded) toward per-callee body
extraction (D1b) + BVM linkage (D1c). `test_d1a_transitive_callees.jl` 15/15.

**MATERIAL finding (Law 1, the design pass earned its keep):** ADR-0021 Decision 1
said edges come from the "same O0 inference run." **FALSE on Julia 1.12.5** — at
`optimize=false` there are ZERO `:invoke`s; edges materialize only at
`optimize=true`. Walker harvests **edges@optimize=true**, bodies@optimize=false
(D1b). ADR-0021 **Amendment A** records the correction; Gate 5 is a permanent
O0-regression tripwire. Closure for `fdict` = {setindex!, ht_keyindex2_shorthash!
(self-rec), rehash!, AssertionError}; the Case-B length witness IS in `rehash!`
(`jl_alloc_genericmemory_unchecked`, i64 length arg) — the 2026-06-08 blocker
dissolves one level down the callgraph, as ADR predicted.

**Closed-world boundary (hostile-review S1):** walker is `:invoke`-only;
`:foreigncall`/dynamic-`:call`/Builtin intentionally dropped — a typed-callgraph
closure, NOT a complete leaf inventory. Runtime-intrinsic COMPLETENESS is CW-D2's
job, fail-loud at D1b/D2 set-assembly (ADR-0021 Decision 2). Documented as a
contract in `_invoke_callees` so D1b can't silently miss alloc/`_growat!` helpers.

**Gates (orchestrator-run, fresh subprocess):** test_d1a 15/15; `using Bennett`
clean precompile; Bennett.jl gate-count regression 39/39. Full `Pkg.test` deferred
to pre-push (additive + caller-less). **Pin:** repin deferred to D1c (BVM doesn't
consume the walker yet — don't bump the tested-against SHA before testing against
it). Full ground-truth record in Bennett.jl worklog 081.

**Next:** CW-D1b — per-callee O0 extraction + `extract_parsed_ir_set_from_julia` →
`Vector{Pair{Symbol,ParsedIR}}` (mirror the ADR-0020 `extract_parsed_ir_set_from_ll`
producer). D1b risk: `_extract_parsed_ir_cached`'s key is `f::Function`-typed; the
`Type{AssertionError}` constructor callee needs the untyped `extract_parsed_ir` path
or a cache-key widening.

---

## Session — 2026-06-08 — opcode-coverage: acq + b5x/xv0u landed; Case B ground-truth blocker surfaced (lead decision pending)

**Agents:** Opus 4.8 (1M) orchestrator, foreground. Directive: Opus coders, Sonnet
hostile reviewers/scouts, serial Julia (Rule 7), commit/push BOTH repos per unit,
raise beads, "what would a senior expert say", verify-don't-rubber-stamp, cross-repo
explicitly allowed. Suite 6308 → 6450.

### Landed (both pushed)
- **`acq`** (BVM `f77aade`): ingest `IRExtractValue`/`IRInsertValue` (ArrayType
  aggregates) via a per-slot synthetic-name model reusing `Define`-copy (no IState
  change). Hostile review caught a SILENT MISCOMPILE (`insertvalue index≥n_elems`
  silently dropped the value) — closed with lower-time fail-loud guards + tests.
  Aggregate `IRRet` (sret) fails loud (deferred → bead filed). 6308→6376.
- **`b5x`/`xv0u`** (Bennett `31b63a6` + BVM `c7d1016`; repin 231bde6→31b63a6): additive
  `IRPtrOffset.elem_width` so the cell-addressed VM recovers element index =
  `offset_bytes÷(elem_width÷8)` (a hardcoded ÷8 silently miscompiled non-i64 — Rule 2).
  The bead said "1 construction site"; there were **8** (positional ctor → all-or-build-
  breaks). Circuit backend IGNORES `elem_width`, so a wrong UNIT at any site is invisible
  to Bennett.jl's 688k suite — verified bits-not-bytes at all 8 by hand + hostile review.
  6376→6450.

### THE finding (Case B / `tu9`/`7xa`) — lead decision pending
Captured the REAL `code_llvm(fdict, Tuple{Int8,Int8}; optimize=false)` IR
(`test/reference/fdict_O0.ll`, Julia 1.12.5). It REFUTES ADR 0015 / ADR 0016 D8's
route-(b) premise: NO in-body `jl_alloc_genericmemory` (the keys/vals/slots backings are
interned globals `@jl_global#146/#147`, the empty-Dict singleton); the key/value WRITE is
the opaque `@j_setindex!_149` callee (not inlined). So "two GenericMemory backings → two
DynAlloca regions over the store floor" has nothing to anchor on (no alloc, no length
witness), and a pure floor can't reverse the opaque write. Two independent Opus proposers
converged. ADR 0015 now carries a finding banner; HANDOFF + this entry have the 3 options
(A recognize-inlined-getindex→RevMap / B defer+prove-machinery / C Design-G) and my
recommendation (A — the ground truth inverts which route is the tractable correctness
floor). Escalated; lead chose to STOP and hand off.

### Lessons (not derivable from git)
- **Bennett.jl `.git/hooks/pre-push` runs the FULL `Pkg.test` (~65min, --check-bounds=yes)**
  before allowing a push. After manually gating, push with `SKIP_PUSH_TESTS=1 git push`.
  I tripped it 3× (3 concurrent suites — Rule 7 violation); orphaned julia children survive
  a kill of the git-push parent → kill by PID. BennettVM has no such hook. (`bd remember
  bennett-prepush-hook-runs-full-suite`.)
- **A substring `grep` for "genericmemory" gave a FALSE "2 allocs"** — they were
  `; @ genericmemory.jl:NNN` source-location comments. Grep `call.*alloc_genericmemory`
  for real alloc calls. This near-miss is exactly why the proposers re-checked and found
  the blocker; Rule-3 skepticism (verify the scout, verify your own grep) paid off twice
  this session (also: the scout wrongly claimed Case A's Julia-source e2e is unproven —
  `test_vec_vm_roundtrip.jl` proves it, in the green suite).
- The orchestration loop (design-scout → Opus coder → my-own fresh `Pkg.test` gate →
  Sonnet hostile review → fix → commit/push) caught a real silent miscompile in BOTH acq
  and b5x. Worth the cost. Never trust a subagent's test count (false-143 trap).

### Follow-up beads filed
Multi-key aggregate `IRRet` return; split `src/ir/ingest.jl` (~1262 LOC, Rule 10);
Bennett.jl reconcile `IRPtrOffset.offset_bytes` (mem=:heap stores element index, P3);
Case B lead-decision bead (blocks `tu9`/`7xa`).

---

## Session — 2026-06-04 (PM) — opcode-coverage epic: BVM-only front cleared + dynamic-memory keystone (5 beads; 4722→6308)

**Agents:** Opus 4.8 (1M) orchestrator, foreground. Directive: Opus coders, Sonnet
hostile reviewers/scouts, serial Julia (Rule 7), commit/push per bead, raise beads,
"what would a senior expert say", verify-don't-rubber-stamp. Pin unchanged (`231bde6`).
Epic `bennettvm-x49`. Every change: ground-truth read → (design pass where Core) →
Opus coder → Sonnet hostile review w/ per-item signoff → orchestrator verifies the
diff + the soundness-critical parts → full `Pkg.test()` gate → commit + push.

### What landed (5 beads, all committed + pushed; suite 4722 → 6308)
1. **`ftz` — coverage matrix** (`docs/coverage-matrix.md`): 19 IRInst, 15 COVERED /
   3 GAP (IRPtrOffset, IRExtractValue, IRInsertValue — all the shared `else` at
   ingest.jl:370) / 1 N/A (IRSwitch). Corrected stale bead line-numbers (244/346).
2. **`0kl` — clean-fail-loud completeness** (`9a8d2b8`→`16ec63d`): the north-star's
   "fail loud cleanly" half. `_NONDETERMINISTIC_CALLEES` guard in the IRCall arm
   (rand/objectid/time/getpid… → a SPECIFIC "nondeterministic — no replay, doubly
   fatal" error before the generic SoftCall allowlist) + `test_fail_loud_completeness.jl`
   pinning every representable impossible construct to a cause-naming error, and
   honestly documenting atomic/volatile/indirectbr/opaque as upstream-rejected
   (unrepresentable in ParsedIR). Reviewer caught a phantom `:rdrand` (not a Julia
   Function name) → removed.
3. **`h0t` — Float32 ingest-boundary rejection** (`8e2fd67`; ADR 0011 D2). A research
   pass settled reachability: f32 soft ops are UNREACHABLE from accepted Float64
   programs (SoftFloat wrapper → integer-only IR; Bennett bars f32 upstream). Sound
   LOCAL guard: reject a soft op that touches f32 (`ret_width==32 || any(==(32),
   arg_widths)`) — catches soft_fptrunc/fpext, over-rejects nothing (f64→int yields
   ret_width=64 + a separate IRCast :trunc). Witness: SC10 gate lowers to 4 SoftCalls,
   zero f32. Placed at INGEST (test_softcall.jl's direct-construction unit tests
   untouched).
4. **`bgc` — width-aware integer ops** (`526173d`; ADR 0012 R1). The ingest dropped
   IRBinOp/IRICmp `width`, so narrow programs diverged from a native-width oracle on
   overflow. `_apply_binop` gains `width::Int=64`: each op extracts low-`w` bits and
   RE-EXTENDS per the op's OWN signedness (sext for sdiv/srem/ashr/signed-cmp; mask
   for udiv/urem/lshr/unsigned-cmp; low-bits for add/sub/mul/…), masks arithmetic
   results, returns 0/1 for compares. **Key insight: because every op re-extracts,
   the stored representation's high bits never matter** → NO IState/Cast/Select/input-
   binding change. `Define` gains a `width` field (default 64 ⇒ byte-identical no-op;
   ArithmeticAssignment stays width-64 ⇒ injective ops unchanged). Golden-master vs
   native Int8: `f(50)=(3·50)÷2` → 203 (was 75). 3 existing i32 tests' oracles moved
   to the low-32-bit carrier (`& 0xFFFFFFFF`) — branch outcomes verified unchanged
   (the `:sgt` diamond still takes the same arm).
5. **`uil` — runtime bump pointer (Case B KEYSTONE)** (`55bb84e`; ADR 0009). Lifts the
   dynamic-array floor from ONE dynamic alloca to ≥2 (Dict = keys+vals = 2 backings).
   **Offset design** (chosen for zero churn): `IState.heap_top::Int64` (default 0) is a
   running OFFSET; `DynAlloca` base = `instr.base + s.heap_top`; forward `heap_top+=n`,
   inverse `heap_top-=n` (round-trips 0→…→0). Single alloca: `base = instr.base + 0`
   = byte-identical to pre-uil ⇒ NO VMProgram/initial_state change, no churn to ~111
   IState call sites. Ingest now admits dynamic-after-dynamic, still fails loud on
   static-after-dynamic. Two allocas get disjoint offset windows. Reviewer's latent
   n<0 cursor-corruption defect fixed pre-commit (predelta fail-loud).

### Beads filed this session (follow-ups)
- **Bennett.jl** (P3, bug): `extract` f32 `fptosi/fptoui/sitofp` fall through to a
  SILENT `IRCast` (instructions.jl:2344/2367) instead of fail-loud — latent .ll-path
  miscompile. Found in h0t research.
- `bennettvm-kmpg` (P3): document/expose the narrow-width `result()` carrier contract
  (i32 -2 surfaces as 4294967294 post-bgc) + a Select wide-literal note.
- `bennettvm-9v84` (P3): in-loop / back-edge dynamic alloca (offset model makes it
  tractable — remove the forward haskey guard + LIFO retract). Blocked-by uil.
- `bennettvm-s3xr` (P3): static alloca after a dynamic one (mixed layout). Blocked-by uil.

### Load-bearing lessons (not in git)
- **Resolve design forks at the orchestrator, not in a coder prompt.** bgc looked like
  "mask Define results" but a native-Int8 golden-master needs sign-AWARE narrow ops
  (sdiv on a wrapped-negative value) — derived the full LLVM-faithful width/sign model
  + the "re-extract ⇒ stored form doesn't matter" simplification BEFORE delegating, so
  the coder got an unambiguous spec. Same for uil: derived the OFFSET design (`base =
  instr.base + heap_top`) which the scoping agent had left as the absolute-cursor
  design — the offset form eliminated ALL the test churn the scope feared.
- **Ground the spec + establish RED empirically first.** A Sonnet probe compiled
  `f(x::Int8)=(3x)÷2`, dumped the real lowered ops (`:mul`/`:sdiv` width=8), and showed
  the concrete divergence (VM 75 vs native -53) — the failing test bgc had to turn green.
- **The collatz-Int8 overflow test is a trap** — a wrapped Int8 collatz trajectory may
  CYCLE (never reach 1) and hang the oracle; bgc used a straight-line `(3x)÷2` instead.
- **uil offset insight:** an absolute runtime cursor breaks the heap_top round-trip
  (advance ≠ n under a `max`); an OFFSET from the frozen base makes advance == n exactly
  and keeps single-array byte-identical. The disjointness + LIFO-retract was the
  soundness crux the hostile reviewer proved with worked windows.

### What's next — the cross-repo phase (epic x49 continues)
The BVM-only correctness/completeness front is DONE. Remaining epic work is cross-repo
(Bennett.jl recognizers, Rule 14) + each warrants its own design pass:
- **Case A part-2 (`xkl`):** `6db` push!/pop! lowering (build on uil's heap_top; needs a
  push! model design pass — length/capacity/topmost-region) + a Bennett.jl push!/growend!
  recognizer + the e2e gate.
- **Case B (`tu9`/`90l`/`7xa`):** NOW UNBLOCKED by uil. Generalize the mem=:vm Memory
  recognizer to the Dict keys/vals backing (Bennett.jl) + the objectid/identity
  determinism guard (`90l`) + the e2e `fdict` round-trip.
- **`acq`** (aggregate IRExtractValue/IRInsertValue → multi-slot IState) — BVM-only but a
  new state model. **`b5x`** blocked on Bennett `xv0u` (IRPtrOffset elem_width).
  **`4dn`/`01w`** blocked on Bennett soft_fdim/soft_frem/soft_uitofp.

---

## Session — 2026-06-04 — SC9 CASE A LANDED (dynamic Julia Vector e2e) + route-(b) Dict decision + opcode-coverage plan

**Agents:** Opus 4.8 (1M) orchestrator, foreground. User directive: Opus coders,
Sonnet hostile reviewers/scouts, serial Julia, commit/push regularly, raise beads,
"what would a senior expert say". Bennett.jl `src/` write access standing (Rule 14).
Pin bumped `b234496` → `231bde6` (Case A recognizer; see BENNETT_JL_PIN.md).

### What landed (all committed + pushed, both repos)
1. **Route-(b) Dict decision — ADR 0015** (+ ADR 0013 §D-3 amendment banner).
   Lead call: correctness floor first, optimize on top. A `Dict` compiles by
   reversibly EXECUTING its inlined isbits opcodes over the store-level memory
   floor + L3 (route b) — NO in-principle blocker for value-semantic keys (live
   `code_llvm` probe: deterministic hash; no objectid/pointer/rdrand). Route (a)
   recognize→`IRMap*`/`RevMap` DEMOTED to a quantum-circuit-lowering optimization
   (`o1y`, supersedes `9i1`). Recorded in both repos (Bennett-800b + reversible-VM PRD).
2. **Opcode-coverage stocktake + granular plan** — epic `bennettvm-x49`,
   `docs/opcode-coverage-plan.md` (P1–P7 + cross-repo bead map + the
   genuinely-impossible fail-loud set). Full bead reconciliation across both repos:
   created the missing gap beads; fixed a contradictory dep (`zg5` was gated on the
   whole Lean chain `7zl` — decoupled); un-deferred `Bennett-tfx` (soft_frem);
   retitled the stale `Bennett-800b`.
3. **SC9 CASE A LANDED** — a dynamic Julia `Vector{T}(undef,n)`+indexed loop
   round-trips e2e from source under `target=:reversible_vm`. ADR 0016 (2+1 design
   pass vs the real `/tmp/fvec_O0.ll`) → recognizer `Bennett.jl/src/extract/vector_vm*.jl`
   (reuses heap.jl M2/M3 partition) → hostile review → regression caught+fixed →
   `Pkg.test` **4722/4722**. Two BennettVM ingest root-cause fixes (i1 boolean mask
   for the `xor i1 %c,true` NOT-idiom; within-edge SSA-dup φ). Commits `9933d27`,
   `233d193` (+ Bennett.jl `1d574f2`, `231bde6`).

### Load-bearing lessons (not in git)
- **Caught a silent-miscompile blueprint (b5x).** The IRPtrOffset scout proposed
  `offset_bytes ÷ 8` → cell offset. WRONG: the VM is cell-addressed (1 cell/element),
  so for an i32 array `p[2]` (offset_bytes=8) ÷8 gives cell 1 but the element is at
  cell 2, and `8%8==0` so no guard fires. b5x is therefore cross-repo: Bennett.jl
  IRPtrOffset must carry `elem_width` (additive; `Bennett-xv0u`). Same stride trap
  is handled in the Case A recognizer (ADR 0016 D6: recover the index by the
  RECOGNIZED stride, never a constant).
- **A false-green from a stale precompile cache.** A coder's standalone
  `julia test/file.jl` reported 143/143 while the hardening was actually broken; the
  fresh-subprocess `Pkg.test()` exposed it (the new P-callee guard over-rejected the
  dead `ijl_bounds_error_int` throw — the allowlist missed the unmangled runtime
  throw entries). **GATE ON `Pkg.test()`, NEVER a standalone file run.** Also: a
  background `julia … | tail` masks the real exit code — capture to a file with
  `; echo $?`.
- **Case A ships on a SINGLE dynamic array; Case B needs `uil` first** (a `Dict` has
  TWO GenericMemory backings keys+vals; ADR 0016 D8). `tu9` re-wired onto `uil`.

### Open / next (epic x49)
push!-grown Vector (`xkl` + `6db`/`ehp`); FP `soft_frem`→`frem` (`Bennett-tfx`→`01w`);
`b5x` (needs `Bennett-xv0u`); aggregates (`acq`, `dzd`/`Bennett-8e1f`, `Bennett-6bu3`);
Case B (`tu9`/`7xa`) behind `uil`. Low: `bennettvm-2lgo`, `bennettvm-5js9`.

---

## Session — 2026-06-02 — FP/SC10 landed; Case B write-side e2e; Case A plumbing; Bennett.jl repinned

**Agents:** Opus 4.8 (1M) orchestrator, foreground. User directive: Opus coders,
Sonnet hostile reviewers, serial Julia, commit/push regularly, **escalate at
forks / "what would a senior expert say"**. User granted **Bennett.jl `src/`
write access** (Rule 14 satisfied at orchestration level). Bennett.jl repinned
`f73a5ed` → `b234496`. Commits: `b0ee45a` (FP, BennettVM), `b234496` (Bennett.jl
mem=:vm Dict arm), `985f104` (Case B ingest, BennettVM). Suites at close:
Bennett.jl 688504/1-Broken; BennettVM 4497→4558.

### The load-bearing lessons (not derivable from git)

1. **Ground-truth probes beat blueprints — twice.** I sent two read-only
   investigators + Opus coders armed with a file/line "blueprint." Both coders
   came back with the blueprint's *premise falsified by a live `code_llvm`/IR
   probe*. Always probe the actual IR on the live Julia (1.12.5) before trusting
   a recognition plan. The two surprises:
   - **Case A:** `Vector{undef,n}` does NOT lower to a clean `frtN`-shaped
     ParsedIR. Julia 1.12 drags the full `Memory` ABI: `jl_alloc_genericmemory_unchecked`,
     `julia.gc_loaded` data-pointer launder, MemoryRef `{ptr,ptr,size}` chains,
     inexact/bounds throw diamonds, **SIMD-vectorised at -O2**. The `mem=:heap`
     recogniser is hardwired for the opposite (constant-N, loop-free,
     single-block-collapse). The `:vm` Memory recogniser is a *distinct Core
     build* (`M_DYN.7`), not a small interception.
   - **Case B:** the prior "research-grade because `optimize=true` inlines
     `setindex!`" framing (ADR 0008 Finding 1 / Bennett-800b) is **half-wrong on
     1.12.5**. The WRITE `setindex!` survives as a clean callee `@j_setindex!_NNN`
     at *both* opt levels (recognisable). It's the READ `getindex` (`d[k]`) that
     is fully inlined to raw Int8 hash arithmetic + a `Memory` probe loop + a
     KeyError diamond — *no* `@j_getindex` callee for an isbits key (verified the
     IR dump directly; `-O0` doesn't help — inlined at both levels). String keys
     keep `getindex` as a callee, but aren't RevMap-compatible. → answered
     Bennett-800b's own "first research step." The bare-`fdict` is blocked on the
     read, not the write (`9i1`).

2. **A purely-subtractive recogniser is how you avoid silent miscompiles.**
   `dict_vm.jl` drops *only* proven-dead skeleton (forward-taint closure from
   GC/alloc/asm/memset/global-load seeds, reusing `heap.jl` helpers), rewrites
   recognised callees, and **fails loud on everything else** (surviving call,
   non-skeleton branch, computed instr, a `ret` whose operand isn't a recognised
   callee result = the inlined-getindex blocker). Hostile review found no
   silent-miscompile path. This posture is the template for `M_DYN.7`.

3. **Orchestration recovery: a coder hit an API rate-limit on its FINAL report**
   (after ~30 min / 62 tool-uses of real work). The edits were in the working
   tree (coders don't commit). I recovered by verifying the tree directly —
   running the gate (`test_dict_roundtrip.jl` 34/34), reading the recogniser,
   hostile review, full suites — rather than re-running the coder. Lesson: a
   killed subagent ≠ lost work; verify the tree.

4. **Pre-push hooks flake under N-way Julia contention.** Bennett.jl's pre-push
   `Pkg.test()` hook FAILED-FAST during a push while the user's NJOY + PadeTaylor
   suites were also running Julia — yet the same tree had just passed the full
   suite (688504/1) and a clean diagnostic re-run showed no error. Rule 7
   (no-parallel-Julia) is **per-project**; cross-project Julia doesn't violate it
   but DOES cause precompile-cache contention that can flake a hook. Re-push once
   contention clears rather than `SKIP_PUSH_TESTS=1`.

5. **Two milestones now bottleneck on hard frontend recognisers** — escalated to
   the lead (see HANDOFF "The fork"). Case A = hard engineering; Case B read =
   research-grade + an architecture-directive call (LLVM-opcode core vs a
   Julia-frontend typed-IR adapter for Dict ops).

---

## Session — 2026-06-01 — Case B VM-side (RevMap) + opcode coverage + FP ADR

**Agents:** Opus 4.8 (1M) orchestrator, foreground. Per-bead delegation: Opus
coding subagents + Sonnet hostile reviewers. Serial Julia (Rule 7); the one
non-Julia task (the FP ADR) ran concurrently with a Julia test agent — the only
permitted parallelism. (Note: this WORKLOG had drifted — its previous top was
Session 4; Sessions 5–11, incl. the M5–M8 milestones, the collatz keystone, and
the `target=:reversible_vm` dispatch arm + Case A `frtN`, are recorded in git +
HANDOFF.md, not here.)

**Result:** **Suite 3694 → 3942** (clean baseline confirmed at session start).
6 commits pushed. **SC9 Case B VM-side is complete.**

### Bead-by-bead
- **`jrc` — RevMap ADT + IRMap* ops** (commit `3025464`). ADR 0008's child-bead 1.
  `const RevMap = Dict{Int64,Int64}` as a dedicated `IState` field (Finding 3 — it
  MUST live in IState so the round-trip `==`/L3-checkpoint can see it; an external
  map would spuriously pass and corrupt replay). `IRMapInsert`/`IRMapDelete` mirror
  `MemoryStore` (L2 predelta, NamedTuple inverse, the `was_present`/`missing`
  sentinel — hardened so a delete of an absent key round-trips, a senior-grade
  improvement over ADR Finding 4's bare `(key,old_val)`). `IRMapGet` mirrors
  `MemoryLoad` (L3-only, `is_injective=false`); absent-key forward fails loud (a
  Dict get is not zero-init heap). 68 tests, 2 mutation probes RED→GREEN, hostile
  APPROVE-WITH-NITS (loop-body coverage correctly owned by `l49`).
- **M_DICT reconciliation** (commit `d48bd90`). Closed `8i5`/`usf`/`l19`
  (M_DICT.3/.4/.5, written pre-ADR-0008) as superseded: their VM-side ops landed in
  `jrc`; their "intercept the reject in ingest" framing was debunked by ADR 0008
  Finding 2; the ingest recognition is owned solely by `0do`. `usf`'s
  `is_injective(getindex)=true` was factually wrong (ADR 0008 Finding 4 → false).
- **`l49` — hand-built round-trip gate** (commit `b1789a4`). Part A straight-line
  `fdict` (both L2 must_cache + L3 paths); Part B a **genuine back-edge loop CFG**
  (not the documented fallback) proving insert L2 deltas interleave with L3
  control-flow/get checkpoints across iterations, incl. the `{0=>0}` missing-sentinel
  case end-to-end. Hostile review caught that the coder's mutation-proof docstring
  misattributed the RED signal to the aggregate `current==initial` — which STAYS
  GREEN because `unstep!`'s `s.initial` fallback masks a broken per-op inverse (the
  M8.2 blind-spot); `per_step_inverse_check` is the real catch. Docstring corrected.
- **`81y` — ADR 0011, FP inheritance** (commit `6fe925b`). FP = inherited Bennett.jl
  SoftFloat dispatch (UInt64 + `IRCall` to `soft_f*`); resolves PRD §8.1. Honest:
  decision only, `IRCall` is a GAP, wiring is `8ox` (unblocked). Surfaced two PRD
  inaccuracies (`soft_uitofp` absent; 60 exports not ~30) — fold into `278`/`bk9`.
- **`d7t` — executable opcode-coverage matrix** (commit `32b4b7d`). 16 IRInst rows
  asserted vs live `lower_vm`; `testset 0` pins the taxonomy via `subtypes(IRInst)`
  (needs `InteractiveUtils` in the test target — Pkg.test sandbox only sees declared
  deps). No discrepancy vs `docs/coverage-matrix.md`.

### Beads filed / lessons
- Filed **`gqd`** (P3): unvalidated ConditionalEntry predecessor labels — latent
  landmine for future backward-dispatch/pebble.
- Rule 3 paid off repeatedly: a subagent confabulated that ADR 0011 "already
  existed" (it was new/untracked); another found a broken untracked WIP
  `test_opcode_coverage.jl`. Verify subagent claims and untracked files.
- `bd create` flag is `--type`, not `--issue-type` (stale CLAUDE.md example).

### Stopped (user request)
Stopped cleanly after letting two in-flight independent agents (`d7t`, `81y`)
finish rather than stranding their work. The cross-repo "both repos together"
unblocks (`0do` Dict recognition; Case A `mem=:vm` Vector arm) are Rule-14
Bennett.jl `src/` changes awaiting per-diff user approval — NOT started.

---

## Session 4 — 2026-05-26 — M4 closed (history layer L3 complete)

**Agents:** Opus 4.7 orchestrator; per-bead delegation pattern — Opus for
coding passes, Sonnet for hostile review passes. Sequential Julia per
Rule 7.

**Result:** All five M4 sub-beads closed in one session. M4 (history layer
L3: checkpoint-replay) is complete. **Tests: 565 → 990 passing (+425).**
Five atomic commits, each fully provenanced.

### Bead-by-bead

- **M4.1 (`bennettvm-v1t`) — `CheckpointEntry` history entry type.**
  Commit `cbd6644`. New file `src/history/CheckpointEntry.jl`. Immutable
  struct, deep-copy constructor (encapsulates spike Q2.2 lesson at the
  type boundary), explicit `Base.==` and `Base.hash` overrides. 31 new
  tests. Hostile review caught a Q2.1↔Q2.2 citation defect (the
  orchestrator's brief had propagated the same error); fixed pre-commit.
  Memory-isolation test added as a non-blocking observation fix.

- **M4.2 (`bennettvm-n26`) — `step!` pushes CheckpointEntry every K steps.**
  Commit `a325be5`. RState gains `step_count::Int` field (3-arg
  constructor for M4.3's replay arithmetic). `step!` and `run!` gain
  `checkpoint_interval::Int = 64` kwarg. Push fires post-forward,
  post-cross-block, post-halt-detection (the spike Q3 ordering preserved).
  84 new tests. Hostile review caught TWO blocking defects: D1 missing
  `&& step_count > 0` guard (which would have broken M4.3's replay),
  D2 missing sentinel test for the documented mutation-proof claim.
  Both fixed pre-commit; 3 non-blocking observations also addressed.

- **M4.3 (`bennettvm-3do`) — `unstep!` via checkpoint restore + replay.**
  Commit `9f6cda7`. New file `src/history/Replay.jl`. RState gains
  `initial::IState` field (chosen over phantom step-0 anchor to preserve
  PRD invariant `isempty(history)` post-full-reversal). Five-step
  algorithm: precondition → find-nearest ≤ target → restore-with-
  deepcopy → truncate-future-history → replay forward with
  `checkpoint_interval=typemax(Int)`. 103 new tests. Hostile review
  ACCEPT no blocking defects. Filed `bennettvm-kuq` as P2 follow-up
  for an asymmetric dispatch between search and truncation loops
  (`isa CheckpointEntry` vs `_entry_step` polymorphism) — only
  matters when M6/M7 entry types land.

- **M4.4 (`bennettvm-5jb`) — `unrun!` full reversal.**
  Commit `36e2cd3`. Added to `src/history/Replay.jl`. Loop predicate is
  `s.step_count > 0` (Phase-2 design property: the "fully reversed"
  signal moved from history-emptiness to step_count, because L3's
  s.initial fallback means empty-history-but-step_count>0 is reachable).
  Max-iterations guard mirrors `run!`'s pattern. Post-loop structural
  assertion `isempty(s.history) || error(...)` per bead spec. Explicitly
  rejects manual status-reset to `:running` (pinned by a "corrupted
  initial.status" test). 66 new tests. Hostile review CONDITIONALLY
  ACCEPT — 3 cosmetic observations (typo, stale file docstring title,
  missing spike Q3 citation) — all fixed pre-commit.

- **M4.5 (`bennettvm-n2g`) — M4 milestone capstone round-trip test.**
  Commit `61c47cd`. New file `test/test_roundtrip.jl`. Tests-only; no
  production code touched. 10 testsets, 141 new assertions, including
  the load-bearing per-step inverse pattern (spike Q3 lesson:
  after-each-unstep! state must match the forward-captured snapshot at
  that step_count, catching mid-stream corruption the aggregate test
  would mask). K values exercised: {1, 2, 4, 7, 16, 64, typemax(Int)}.
  Test 1 vs golden-master countdown_ref. Test 8 diversifies with a
  single-block program (no cross-block dispatch). M4.1-M4.4 holds up
  on FIRST RUN — no integration bug surfaced.

### Decisions / load-bearing design points

- **`initial::IState` field on RState, NOT phantom step-0 anchor in
  history.** Considered both. The phantom-anchor approach would have
  contaminated `isempty(history)` post-reversal — a PRD invariant the
  spike's `unrun!` already pins. The separate field keeps the structural
  signal clean: unstep! at step_count=1 → fall through to s.initial,
  no special-case handling in unrun!'s loop predicate.

- **Replay during unstep! uses `checkpoint_interval = typemax(Int)`** to
  suppress spurious checkpoint pushes mid-replay. Safe because M4.2's
  `% K == 0 && step_count > 0` guard never fires when K = typemax.

- **K=1 is documented as forensic-test mode, not production.** A K=1
  configuration reproduces the §3.3-prohibited per-step snapshot
  pattern. Documented in `step!`'s docstring and exercised in the M4.5
  K-sweep so the system PROVES it works at K=1 without invoking K=1
  in any production code path.

- **Double-defended deepcopy.** Both ends of the snapshot lifecycle
  deep-copy: M4.1's constructor (push side) and M4.3's restore step
  (pop/read side). A future maintainer who drops one defense still
  has the other. The hostile reviewer verified this via a probe that
  removed the restore-side deepcopy — the per-step inverse test (M4.5
  test 4) turned RED as the mutation-proof matrix predicted.

### Tracker reconciliation at session start

At the top of the session, `bd ready` was lying: M5.1 was surfacing
ready, but the HANDOFF and git log showed M5/M0/M2/M3 all closed in the
prior session (2026-05-26 day-1). 31 stale beads — closed them in a
batch with reasoned reasons before claiming M4.1. The takeaway: closing
beads is not optional at session end; orchestrators must enforce.

### What's next

M4 closes the L3 history strategy. **M6 is up next** — history layer L1
(injective no-log). M6.1 introduces an `is_injective(::Type{<:Instruction})`
trait; injective instructions (SwapInstruction, control-flow markers,
MemoryInterchange/MemorySwap, ArithmeticAssignment when modop=`:xor`)
skip the history push entirely. Then M7 (L2 delta min-cut) gates on
M6. M8 (per-step inverse property test) gates on M7.

After the history layers are complete, the four SC9 motivating cases
(M_DICT, M_DYN, M_NESTED, M_UNBOUNDED — all P0) become the acceptance
gate.

---

## Session 2 — 2026-05-25 — Phase 1 close: PRD v4 authored

**Agents:** Opus 4.7 orchestrator; 4 parallel Sonnet research subagents
(literature survey, Bennett.jl integration boundary, spike retrospective
deep-read, RC3+Janus prior-art) plus 1 Sonnet hostile reviewer. All
research subagents were read-only (no `julia` invocation; CLAUDE.md Rule 7
permits parallel here).

**Result:** PRD v4 ratified. Phase 1 closed. `PHASE.md` flipped to `Phase 2
(production)`. v3 archived at `docs/prd/bennettvm_prd_v3.md` (582 LOC,
frozen). v4 at root `bennettvm_prd.md` (1223 LOC). bd issue
`bennettvm-pb2` closed.

### Timeline

#### 1. Bennett 1973 PDF acquired (the v3 blocker)

User supplied `bennett1973.pdf` from their Windows downloads folder mid-
session. Copied to `references/foundational/bennett-1973-logical-reversibility.pdf`,
SHA256 `e61ad668…0687`. Verified against IBM JRD 17(6) Nov 1973: confirmed
three-stage Compute/Output/Cleanup construction (Table 1, p. 528), 7-stage
input-from-output construction (Table 2, p. 530), `2√(νs)` segmentation
bound and `ν²` log-ν nested-segmentation bound at p. 530 lower right. v4
§2.1 cites these directly. Manifest and PHASE.md updated to mark blocker
resolved. **TIB ILL not required.**

#### 2. Parallel Sonnet research subagents (4 agents, all read-only)

Per CLAUDE.md Rule 7, only Julia-touching agents must be serial; literature
review and codebase reading can parallelize. Dispatched four:

- **A. Literature survey** (`references/`, all 8 §2 subdirectories).
  Verified citation pages by opening PDFs; produced ~2800-word per-pillar
  table; flagged hallucination risks (Bennett 1973 vs 1989, RSSA φ on
  splits AND joins, BobISA jump source-label encoding, Unqomp/Reqomp/Qurts
  design-point differences).
- **B. Bennett.jl boundary** (`../Bennett.jl/` at pin `5731cec`). Mapped
  pipeline: `Julia → code_llvm → ParsedIR → lower() → LoweringResult →
  bennett()`. Identified `ParsedIR` (`Bennett.jl/src/ir_types.jl:347`,
  exported at `Bennett.jl/src/Bennett.jl:88`) as the natural Phase-2
  handoff. Documented three handoff alternatives; recommended Handoff A
  (consume `ParsedIR` externally; no Bennett.jl source mutation needed at
  Phase-2 start).
- **C. Spike retrospective deep-read.** Cross-referenced all Q1–Q9 findings
  + 6 "elevated" findings beyond the retrospective into proposed v4
  normative wording with file:line citations.
- **D. RC3 + Janus implementations.** Mapped RC3's RSSA taxonomy (12
  concrete instruction subclasses in `references/implementations/RC3/.../instances/`),
  TOPPS-janus `Invert.hs` `invertStmt` pattern for injective inversion,
  janus-vesta's `MOV` violation of the memory-as-exchange rule (an explicit
  non-reuse). Produced the §Part IV reuse matrix.

#### 3. PRD v4 written (1191 LOC pre-review)

Structure: §0 executive summary; §1 phase context (what survived from v3,
what v4 changes); §2 prior-art with corrected citations (BobISA →
Thomsen-Axelsen-Glück 2012, RIL → Mogensen 2015 §3); §3 Phase-2 design
spec (17 normative subsections; §3.9–§3.17 are spike-derived); §4 reuse
map with file:line; §5 Phase-1 retrospective summary; §6 8 success
criteria; §7 risks; §8 reduced open questions + ADR queue; §9 milestone
work breakdown M0–M12; appendices.

#### 4. Hostile reviewer pass (Sonnet, per CLAUDE.md Rule 6)

Verdict: REQUEST CHANGES (most severe finding was BLOCKER).

- **2 BLOCKERS:** (1) `IRBasicBlock` and `IRInst` not exported from
  Bennett.jl — `using` example was broken; fixed to qualified access and
  noted Rule-14 constraint. (2) §3.7 missing `IRLoad`/`IRStore` →
  `Exchange` lowering pass; v4 §3.2 mandates memory-as-exchange but §3.7
  silently admitted classical loads/stores via `ParsedIR`. Added
  pre-RSSA normalization-pass requirement.
- **5 MAJORS:** `step!`/`unstep!` signature claim wrong (spike uses
  `(s, prog)`, not `(s, instr)`); two citations to nonexistent
  retrospective §6.x sections (correct path is Q-numbered); wrong
  file:line for uniform-bound analysis (`cfg.jl:81–83` →
  `driver.jl:79–82`); Part VI vs Part IX milestone-numbering mismatch
  + broken `§6.1–§6.8` cross-ref; "15 instruction classes" → "12
  concrete subclasses (22 files)".
- **6 MINORS + 1 NIT:** small citation corrections (Bennett 1973
  resource-bound page, Bennett 1989 Theorem 1 page, Meuli 2019 section
  numbering, `collatz_step` → `collatz_steps`, `LabelTable.java:12` →
  `LabelEntry.java:7` for dual-address, Appendix A.4 missing file paths,
  Bennett.jl boundary §8.2 oversells resolution).

All 14 defects fixed before commit. Final v4 LOC: 1223.

#### 5. Phase transition + close

- `git mv bennettvm_prd.md → docs/prd/bennettvm_prd_v3.md`.
- v4 installed at `bennettvm_prd.md`.
- `PHASE.md` flipped to `Phase 2 (production)` with ratification date.
- `README.md` status table updated.
- This worklog entry.
- bd: `bennettvm-pb2` closed.

### Findings worth recording (will outlive PRD v4)

**Parallel research subagents are massively load-bearing for PRD work.**
Four agents covered ~10,000 words of structured output in ~10 min wall-
time across literature, Bennett.jl, spike, and prior-art implementations.
Serial would have taken ~40 min and the cross-references between domains
would have been weaker (each agent's report assumed cold context, which
sharpened the per-domain summaries). Pattern to repeat for v5.

**Hostile-reviewer subagent caught 14 defects in 1191 LOC.** Two were
BLOCKERS that would have shipped if not caught (`IRBasicBlock` non-export;
missing `IRLoad`/`IRStore` translation pass). The reviewer's per-axis
signoff structure (12 named axes, verdict + evidence per finding, positive
notes section) is the right format — vague "looks ok" reviews are useless;
this format is actionable. Keep the format for Phase-2 reviewer subagents.

**Citation page numbers drift between sub-agents and reality.** Agent A
claimed several page numbers that were close but wrong (Bennett 1989
Theorem 1 location; Meuli 2019 §III-B vs §III). The hostile reviewer
caught all of these. Lesson: page-precise citations need a separate
verification pass; agents won't self-correct.

**Bennett 1973 user-supply path beats TIB ILL.** The user had the PDF on
their personal machine; we burned half a session of Subagent D in pre-
Phase-0 trying to get it through TIB VPN and exhausted 30+ mirrors. For
future hard-to-acquire PDFs, **ask the user first** before launching an
acquisition subagent.

**RC3 is the right pre-read, not just a reference.** The implementations-
survey agent found that RC3's instruction taxonomy is the canonical RSSA
embedding and that Phase 2's IR MUST be structurally isomorphic to it.
This is the strongest Law-2 reuse in v4: not "consult RC3" but "match its
taxonomy, with deviations requiring an ADR." The pre-read criterion is
elevated to M5 (gating M0).

### Decisions for future-me

- **Don't ship Bennett.jl mutations as part of Phase 2 M0.** v4 §3.7
  Handoff A ensures Phase 2 starts with zero Bennett.jl source mutation.
  Handoff B (`target=:reversible_vm` dispatch arm) is deferred to ADR 0003
  with the 3+1 protocol and explicit user approval (CLAUDE.md Rule 14).
- **The Phase-2 first action is the RC3 `rvm` smoke test**, NOT writing
  Phase-2 IR code. v4 §6 SC6 and §9 M5 codify this.
- **The straight-line property test gap (Q9 of the retrospective + §6.5
  of the deep-read report) is now binding for Phase 2** as v4 §3.15:
  random control-flow programs are required, not just straight-line. M7
  exercises this.

---

## Session 1 — 2026-05-23 — Pre-Phase-0 prep + Phase-0 spike + close

**Agents:** Opus 4.7 orchestrator; 11 serial sub-agent passes (Opus for
code, Sonnet for review/summarization, per user directive).

**Result:** Phase 0 complete. Spike at `spike/` with 789/789 tests
passing, `spike-0-archived` git tag, chmod -w. PRD v4 bead filed as
`bennettvm-pb2`. Phase 1 (PRD v4 authoring) is the next session.

### Timeline

#### 1. Greenfield arrival → CLAUDE.md synthesis

- Read `bennettvm_prd.md` (PRD v3, 582 LOC).
- Cross-read CLAUDE.md from `../Bennett.jl`, `../Feynfeld.jl`,
  `../PadeTaylor.jl`, `../cft-anyons`.
- Synthesized BennettVM-specific CLAUDE.md: Three Laws (Ground truth,
  Reuse before reinvention, Phase discipline), 16 numbered Rules,
  Phase-0 gating P0.1–P0.8, hallucination callouts specialized for
  reversible-computing literature, reuse-map enforcement template.

#### 2. Ground-truth acquisition (parallel research subagents)

User directive: "It is nonnegotiable to obtain all ground truth
locally before anything else." Discovered:

- `Bennett.jl/docs/literature/memory/` already had ~13 PDFs (Unqomp,
  Reqomp, Qurts, Meuli, Spooky pebble, Enzyme, …).
- `research-notebook/raw/literature/` had Bennett 1989, Knill 1995,
  RFUN/Thomsen 2012, PRS15, more.
- `playwright-cli` v1.59 installed system-wide; cached Chromium 1217
  at `~/.cache/ms-playwright/`.

Dispatched 3 parallel Sonnet subagents (A: foundational/rr/AD; B:
languages/IR; C: ISAs/quantum-reg-machine + source clones). Then
dispatched Subagent D (paywall pass via headed Chromium + TIB VPN)
after the first three returned. Total: 43 paper PDFs + 5 source
clones (RC3 ✓, TOPPS-janus, jana, janus-vesta, evincarofautumn-janus)
+ Enzyme symlinks. ~126 MB in `references/`.

**Acquisition findings worth recording:**

- Bennett 1973 PDF cannot be obtained via TIB VPN. The IBM JRD
  historical archive (IEEE Xplore volume 5288520) is on a separate
  IBM subscription not included in TIB's IEEE bundle. Recommended:
  TIB ILL via `fernleihe@tib.eu`, DOI 10.1147/rd.176.0525.
- ACM DL papers (Griewank revolve, James-Sabry Π, etc.) are
  inaccessible via playwright-cli even with headed Chromium because
  `page.request` doesn't share Cloudflare clearance cookies with the
  browser context. Known limitation; future subagents should
  skip-fast on `dl.acm.org`.
- `frank-reversible-cmos.pdf` pre-existing in `Bennett.jl/docs/literature/`
  was *misidentified* — it's a 2020 IEEE CMOS paper, NOT Frank 1999
  PhD. Acquired the real 406-page Frank 1999 thesis separately from
  MIT DSpace. Bennett.jl may want a heads-up.

**PRD v3 errata surfaced during acquisition** (logged in
`references/manifest/SOURCES.md §Citation-errata`):

- **BobISA citation correction.** PRD §2.5 cites "Axelsen-Yokoyama
  2011 LATA". Actual paper is **Thomsen-Axelsen-Glück 2012** (RC
  2012, DOI 10.1007/978-3-642-29517-1_3). The 2011 LATA paper by
  Axelsen-Glück is a different artifact (universal reversible TM).
  Confirmed by Mogensen 2022's own reference list.
- **Mogensen RIL ghost.** No standalone RIL paper exists. RIL is
  introduced inside Mogensen 2015 LNCS 9138 §3 ("Garbage Collection
  for Reversible Functional Languages"). The "Mogensen RIL" line in
  PRD v3 §2.3 misled subagent B for ~10 min before they discovered
  this.

#### 3. Bennett 1973 user override

Subagent D's escalation: Bennett 1973 PDF was a strict P0 blocker per
PRD §5.5 ("Ground truth from local PDFs only (Bennett 1973,
Yokoyama-Glück 2007)"). User elected to proceed without it:

> "we have to move on without bennett. flip to phase 0"

This is a Law 1 / PRD §5.5 override. Documented in PHASE.md
"Substitute ground truth" table:

- `references/foundational/vitanyi-time-space-energy.pdf` §2
- `references/foundational/Bennett1989_time_space_tradeoffs.pdf` §1–2
- `references/foundational/buhrman-tromp-vitanyi-2001.pdf` §1

The spike sub-agent prompts (`scripts/spike-templates/0[1-4]-*.md`)
were updated to cite the substitute sources, not the off-disk PDF.
The retrospective Q7 was pre-populated to ask whether the
substitution actually hurt.

The substitute sources turned out to be entirely sufficient for
Phase 0 Stage 1 (forward + reverse). Bennett 1989 §1 Lemma 1
restates the 1973 three-tape construction with explicit per-step
quintuple-index history entries — *cleaner* than the 1973 original
is reputed to be. Bennett 1989 also splits the construction into
three stages (Compute / Output / Cleanup), of which Phase 0
implements only Stage 1.

**Per the Phase-0 close retrospective:** Phase 2 Stage 2 and Stage 3
(Output channel, Cleanup) WILL need the Bennett 1973 original. TIB
ILL should be pursued before Phase-2 design begins.

#### 4. Phase-0 spike — 11 serial sub-agent passes

User directive: "orchestrate this serially: delegate each coding
step to an opus subagent, research and summarisation to sonnet. no
more than one subagent at a time. you monitor progress and raise
beads as issues arise."

Beads epic: `bennettvm-ua7`. Sub-issues `ua7.1` through `ua7.11`.

| # | Pass | Agent | Outcome |
|---|---|---|---|
| 1 | interpreter | Opus | written |
| 1R | review | Sonnet | REQUEST CHANGES (4 findings: exception-safety, missing `@assert`, Q2.3 docstring inaccuracy, missing `private=true`) |
| 1F | revise | Opus | 4 fixes (~14 LOC) |
| 1R2 | re-review | Sonnet | ACCEPT, raised Q2.4 docstring as new finding |
| 1F2 | mechanical | Opus | Q2.4 docstring rewritten |
| 2 | 8 instructions | Opus | written, smoke test passes |
| 2R | review | Sonnet | ACCEPT, flagged Q4 history-length convention complexity for Pass 3 |
| 3 | tests | Opus | 789 tests, mutation-proof exposed real weakness, added per-step inverse test |
| 3R | review | Sonnet | ACCEPT, mutation-proof reproduced (19 RED on perturbation, 0 after revert) |
| 3F | mechanical | Opus | 2 doc errors fixed |
| close | retrospective | Sonnet | `spike/RETROSPECTIVE.md` written, Q6 cross-check done |

#### 5. Findings worth recording (will outlive the spike)

**The Julia `==` footgun (Q2.1).** Default `Base.==` on a struct with
a `Dict` field does identity-compare on the `Dict`. Two `IState`
values with equal content but distinct `Dict` objects fail `==`.
Without overriding `Base.==` on `IState`, the entire round-trip
invariant silently never holds. This is the #1 finding from the
spike and should be a CLAUDE.md rule or a Julia-pattern memory.

**Exception-safety in `step!`.** Pass-1 originally pushed the
history snapshot BEFORE calling `forward()`. If `forward` threw,
the snapshot was orphaned and the VM was inconsistent. Reorder
(call `forward` first, push only on success) fixes it cleanly.
The Pass-1F reorder is the right pattern for any trace VM.

**The per-step inverse test (Pass 3).** Pass-3's brief-prescribed
mutation (swap `prev` for `s` in `inverse(::BinaryOp, ...)`) did NOT
initially break the aggregate round-trip test, because the LEADING
`Const` inverse restores `s.current` regardless of corruption left
by mid-stream inverses. Mutation-proof failed quietly. Solution:
snapshot every pre-step `IState` during forward execution; then
during `unrun!`, assert `s.current == pre_states[i]` at each step.
This catches per-instruction-kind inverse bugs because the mutated
inverse leaves `s.current` at the post-step state, which is detected
before any later inverse can mask it. **Phase 2 must keep this
pattern.**

**Return/Halt collapse (RETRO Q1).** PRD §5.1 lists `Return` and
`Halt` as distinct opcodes, but the spike has no subroutines, so
they degenerate to identical implementations. Both are kept per P0.4
(no ninth instruction, but also no opcode removal). PRD v4 must
decide: keep both (for forward compat with subroutines), unify, or
reuse the slot.

**`UnaryOp :not` ambiguity (RETRO Q3).** PRD §5.1 wording "Bool-typed
regs" is moot when locals are `Dict{Symbol,Int64}` (no Bool type).
The spike's `:not` is bitwise `~` on Int64 (so `:not 1 = -2`). Not
boolean negation. PRD v4 must either widen the local-value type to
include Bool or rename the op (e.g., `:bnot`).

**History-length convention (Q4).** With discard-pop on idempotent
terminal transitions, `length(history) == steps_with_observable_effect`,
which for countdown(3) is 19 (not 20 — the Halt step is popped).
Test 3 (history invariant) uses convention (c): step-by-step counting,
`length(history) == n_calls` for non-terminal steps, `n_calls - 1`
after terminal. The top-of-file comment in `test_history.jl` is the
most detailed documentation of this design choice in the spike.

**Q6 cross-check (Law 2 evidence):** none of RC3, TOPPS-janus, jana,
janus-vesta, or evincarofautumn-janus has a history-tape +
round-trip property test in the BennettVM sense. RC3 has an `rvm`
(RSSA VM) but compiler-level reversal, not runtime trace.
TOPPS-janus does syntactic `invertStmt` (the Yokoyama-Glück 2007
"no history for reversible source" structural lesson). Therefore
BennettVM IS distinct work, not a rebuild. Phase 2 must continue to
justify each design decision against published prior art per Law 2
but is not displaced by any existing artifact.

#### 6. Phase-0 close

- `spike/RETROSPECTIVE.md` written (264 LOC, 9 questions answered).
- `chmod -R -w spike/` (filesystem read-only marker).
- `git tag spike-0-archived`.
- `PHASE.md` flipped to "Phase 1 (archive; PRD v4 pending)" with 8
  numbered sharpest items for v4.
- `bennettvm-pb2` filed (PRD v4 epic).
- Three commits:
  - `0c7425d` bd init.
  - `5c611c4` Phase-0 spike complete: 789/789 tests, retrospective.
  - `bcc49c5` Phase 0 → Phase 1 transition.

### Decisions for future-me

- **Don't promote spike code into Phase 2.** PRD §1.4 / §7.8 / CLAUDE.md
  P0.7 — Phase 2 starts from an empty `src/`+`test/`. The spike's
  type names and API shapes are *patterns* to consult, not source to
  fork.
- **The 3+1 reviewer pattern from Bennett.jl was overkill for Phase
  0** but produced load-bearing findings (Pass 1R's 4 findings, Pass
  3R's mutation-proof reproduction). Keep it for Phase 2. The
  overhead is worth the structural integrity.
- **PRD v3 was wrong in ~5 places** that we caught (BobISA citation,
  RIL ghost, RState mutability, :not Bool wording, Return/Halt
  semantics). Expect more in Phase 2; budget time to log them.
