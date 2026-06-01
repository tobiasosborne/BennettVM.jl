# HANDOFF — BennettVM.jl

> What the next session needs to know. Read top to bottom; do not skim.

## Current state (2026-06-01 — Case B VM-side + opcode coverage + FP ADR)

> Orchestrated session: Opus coders + Sonnet hostile reviewers, serial Julia
> (Rule 7); the FP ADR (no Julia) ran concurrently with a Julia test agent.
> Bennett.jl pin `f73a5ed` (unchanged). **Suite 3694 → 3942.** 6 commits
> pushed this session (`00a5bff..` → HEAD).

### What landed (all pushed, reviewed)
- **SC9 Case B VM-side is COMPLETE.**
  - **`jrc`** — `RevMap` reversible-map ADT (`const RevMap = Dict{Int64,Int64}`,
    a dedicated `IState` field so it rides `==`/`hash`/`deepcopy`/L3-checkpoint,
    ADR 0008 Finding 3) + `IRMapInsert`/`IRMapGet`/`IRMapDelete` (`src/ir/revmap.jl`).
    Insert/Delete = L2-predelta non-injective (MemoryStore template, missing-sentinel
    hardened so absent-key ops round-trip); Get = L3-only (MemoryLoad template),
    absent-key forward fails loud. 68 unit tests, mutation-proved, hostile APPROVE.
  - **`l49`** — hand-built round-trip gate (`test/test_revmap_roundtrip.jl`):
    straight-line `fdict` (oracle `fdict_ref(3,7)==7`, round-trips on BOTH the L2
    must_cache path and the L3 path) + a **genuine back-edge loop CFG** (insert L2
    deltas ×n interleaved with L3 control-flow/get checkpoints; n=3 hits the
    `{0=>0}` missing-sentinel absent-key insert inverse end-to-end). Hostile APPROVE
    (caught a docstring RED-signal misattribution — the aggregate round-trip is
    blind to a broken per-op inverse; `per_step_inverse_check` is the real catch,
    the M8.2 lesson; corrected).
- **`81y`** — **ADR 0011** (`docs/adr/0011-fp-inheritance.md`): Float64 via inherited
  Bennett.jl SoftFloat dispatch (UInt64 bit patterns + `IRCall` to `soft_f*`);
  **resolves PRD §8.1's deferred FP question** (3 v3 schemes rejected, Law 2).
  Honest scope: decision only — `IRCall` is still a GAP (`ingest.jl` raises); the
  VM-side `IRCall→soft_f*` wiring is **`8ox` (now unblocked)**.
- **`d7t`** — executable opcode-coverage matrix (`test/test_opcode_coverage.jl`):
  16 IRInst rows asserted vs live `lower_vm` (11 DONE + 2 e2e witnesses, 4 GAP
  fail-loud, IRSwitch N/A; `testset 0` pins the taxonomy via live `subtypes(IRInst)`).
  No discrepancy vs `docs/coverage-matrix.md`.

### Tracker reconciliation + beads filed
- Closed **`8i5`/`usf`/`l19`** (M_DICT.3/.4/.5) as **superseded by ADR 0008** —
  their VM-side op semantics landed in `jrc`; the "intercept the reject in ingest"
  framing was debunked by ADR 0008 Finding 2; residual ingest recognition is owned
  by `0do`. (`usf`'s `is_injective(getindex)=true` was WRONG — corrected to false.)
- Filed **`gqd`** (P3): ConditionalEntry predecessor labels aren't validated vs the
  LabelTable — sound today (forward-only/L3 never dereference them), latent landmine
  for a future backward-dispatch/pebble pass. From `l49` review.

### Findings to fold into the existing PRD-patch beads (`278`/`bk9`)
ADR 0011 surfaced two PRD inaccuracies (verified vs Bennett.jl src): PRD §3.6 l.544
cites **`soft_uitofp` which does NOT exist** (only `soft_sitofp`); and SoftFloatLib
exports **60** `soft_*` symbols, not the "~30"/"32 primitives" the stale comment says.

### The cross-repo "both repos together" gate (Rule 14 — needs USER approval)
The Case A/B *end-to-end* unblocks are Bennett.jl `src/` changes I did NOT touch:
- **`0do`** — Bennett.jl `Dict→IRMap*` recognition arm (`mem=:vm`). Unblocks
  `7xa` (e2e `fdict`, SC9 Case B). **Research-grade** (Bennett-800b: `optimize=true`
  inlines Dict ops to raw hash arithmetic, no callee boundary — no known solution).
- **Case A `mem=:vm` Vector arm** (Julia `push!`/`Vector`, bead `xkl`/task#11): drop
  the GC-TLS inline-asm, emit dynamic-N `IRAlloca`/load/store past the GC wall.
The C/`.ll` `frtN` form of Case A already round-trips (`xld`, done). Surface the
specific diff for per-diff approval before any Bennett.jl `src/` edit.

### Next ready BennettVM work (no approval needed)
- **`8ox`** (M_FP.2, **now unblocked** by ADR 0011) — wire `IRCall→soft_f*` dispatch
  in ingest; the gate to FP-in-VM (SC10).
- **`m6c`** (OutputRef nominal type, PRD §3.5) — but verify it has a consumer
  (no `run_oracle!` yet; may be premature).
- **`6r6`** (M1 bench harness), **`5ii`** (Lean toolchain bootstrap — independent,
  SC7), **`uom`** (L1 Exchange opt), plus P2/P3 cleanups (`ack`, `c0e`, `kuq`, `b5g`, `3ah`).
- **`bgc`** (width-masking) — NOT a clean pickup: 3 undecided options + de-prioritized
  ("frtN round-trips without it"); needs a design decision first, not a straight code bead.

### Gotchas this session
- `bd create` wants **`--type`**, NOT `--issue-type` (the CLAUDE.md Rules-section
  example is stale; the Quick-Reference block is right).
- Three pre-existing **untracked WIP files** from prior sessions were found this
  session (the broken `test_opcode_coverage.jl`; the references/ dirs). Treat
  untracked files as untrusted WIP and verify before adopting (Rule 3).

---

## Current state (2026-05-28 — Session 9 close)

- **Phase 2.** Bennett.jl pin `877341e` (current; unchanged). **Suite 3330/3330.**
  6 commits pushed (`e9dfd7f..a4815a1`).
- **🧭 ARCHITECTURE PIVOT (ADR 0013, lead-approved incl. Dict model D3).**
  The recon that drove it: **Cases A (dynamic `Vector`) and B (`Dict`) cannot
  reach BennettVM through Bennett.jl's Julia-function extractor** — GC
  allocation emits a TLS GC-frame inline-asm rejected at
  `Bennett.jl/src/extract/instructions.jl:2103` (`Bennett-5oyt/U15`) BEFORE
  any `ParsedIR` exists; `Dict` is additionally rejected by design
  (`Bennett-800b`). Verified across `mem=:auto/:persistent`, `optimize=false`.
  The bead-chain "intercept the reject in ingest" framing is therefore
  **empirically impossible**. Lead directive: **BennettVM must be a
  reversible VM over LLVM opcodes — useful to ANY emitter (C/Rust/Julia),
  sensible without Bennett.jl; Bennett.jl changes are welcome/anticipated.**
  (Saved to auto-memory: `bennettvm-language-agnostic`, `bennettvm-raison-detre`.)
- **ADR 0013** = the architecture: contract = LLVM-opcode IR (`ParsedIR` /
  `.ll`/`.bc`); reversible heap = a **store-level floor** (PRD §3.2/§3.7
  exchange mandate); **Dict = D3** (Bennett.jl recognizes Dict ops → neutral
  `IRMap*` ops → a BennettVM reversible-map ADT it controls; no rehash gap).
- **ADR 0014** = memory-floor lowering (L3 baseline; bump-allocator
  addressing; **defers the PRD §3.7 L1 Exchange optimization** to bead `uom`,
  same trace-tape-now pattern as collatz/pebble-game).

### What landed this session (all pushed, hostile-reviewed where Core)
- **SC9 Case C (nested loops)** — `matrix_sum_while(Int8(3))==9` round-trips.
  The PRD's `for i,j` form folds to `n*n`; the `while`-form is a genuine
  nested CFG the EXISTING ingest lowers with zero src changes (ADR 0010).
  `bennettvm-720/of5` satisfied by existing ingest + L3.
- **`IRCast`** (sext/zext/trunc) — `CastInstruction`, Define-templated
  (`bennettvm-hek`). + **`matrix_tri`** (triangular nested `while`) round-trips.
- **e4l ingest fix** — within-edge synthetic φ-const name collision
  (two φ-params taking the same constant on one edge → duplicate exit arg).
  Fix preserves cross-edge sharing (collatz/matrix_sum counts byte-identical).
- **Memory floor v1** (`bennettvm-x9j`, ADR 0014) — `MemoryStore`/`MemoryLoad`
  (scalar, L3) + bump-allocator `IRAlloca`. **EMITTER-AGNOSTIC PROOF:** a **C**
  function (`clang-18 -O0`) round-trips end-to-end via
  `extract_parsed_ir_from_ll` (committed `test/reference/through_mem.{c,ll}`).
- **M_OPCODE.1** audit → `docs/coverage-matrix.md` (16 IRInst subtypes).

### SC9 scorecard
- ✅ **D** (collatz) · ✅ **C** (nested loops) · 🔨 **A** (dynamic memory —
  memory floor v1 scalar done) · ⏳ **B** (Dict — D3 ADT, not started).

### What's next (Session 10) — and the Bennett.jl dependency
Cases A & B BOTH ultimately need **Bennett.jl-side work** (lead pre-approved
in principle; per Rule 14 show the specific diff before editing
`../Bennett.jl/src`):
- **A (Julia `Vector`)** needs the **`mem=:vm` arm** (ADR 0013 D-4 / task#11):
  (1) trivial — drop the `movq %fs:0` TLS inline-asm; (2) core — emit
  dynamic-N `IRAlloca` + `IRLoad`/`IRStore` for Julia heap past the GC wall;
  (3) small — `IRCall.callee_name::Symbol`. Plus the **U16** 2-index aggregate
  GEP reject (`bennettvm-dzd`) blocks even C arrays — needs a Bennett.jl GEP
  extension.
- **BennettVM-side autonomous runway** before that fork: **v2 GEP**
  (`IRPtrOffset`/`IRVarGEP` → Define address arithmetic), testable via a
  pointer-arg C function (the SUPPORTED 1-index GEP form; aggregate arrays are
  U16-blocked). Then v3 dynamic-N alloca.
- **B (Dict)** = D3 reversible-map ADT (reframes `bennettvm-jrc`) + Bennett.jl
  Dict→`IRMap*` recognition.

### Key open beads
`uom` (L1 Exchange, P2), `dzd` (v2 GEP reach / U16, P2), `b5g` (resolve_ptr
polish, P3), the SSA-dup latent gap (P2), `3ah` (_phi_const collision, P3),
task#11/`zg5`/`kl3`/`fu5` (Bennett.jl mem=:vm + M13 dispatch — all need
user approval). ADRs 0008/0009 (per-case) subsumed by ADR 0013.

## Current state (2026-05-28 — Session 8 close)

- **Phase:** **Phase 2 (production).** **Bennett.jl pin:** `877341e` (matches this device's Bennett.jl HEAD; `bennettvm-18b` pin-mismatch resolved).
- **Test suite:** **2872 / 2872 passing** (`julia --project=. -e 'using Pkg; Pkg.test()'`), up from 2108 at Session 7.
- **M8 milestone — CLOSED.** M8.5 (`012f6cd`, the 100-random-program property capstone, +510 assertions) + the two deferred follow-ups: `s9c` (M8.4 generator hostile review — generator verified SOUND; reviewer's "blocker" was already covered by existing tests) and `7cg` (`1ce192a`, CallInstruction.inverse :direct pc-symmetry audit). Generator-hardening follow-up `bennettvm-jpb` (P3) filed.
- **🎯 M_UNBOUNDED milestone — CLOSED. `collatz_steps` (SC9 Case D, the load-bearing motivating case) ROUND-TRIPS END-TO-END.** This is the first of the four P0 motivating cases to land.
  - **ADR 0012** (`docs/adr/0012-collatz-lowering.md`, `7ea1e7c`) — the keystone lowering design, synthesized from a 2+1 independent design pass. Decisions: dedicated `Define` instruction for SSA-creates (D1), `COMPARISON_OPERATORS` (D2), `SelectInstruction` MUX (D3), IRPhi→ConditionalEntry / IRBranch→ConditionalExit+critical-edge-split / IRRet→End (D4), synthetic zero-creates for constant φ-incomings (D5).
  - **The crux** (both design proposals missed it; orchestrator-caught): collatz's loop reuses SSA temporary names every iteration → each iteration OVERWRITES the last → NOT zero-history. **User chose trace-tape = the existing L3 checkpoint-replay** (`unstep!` restores a full-IState snapshot + replays forward, never calling per-instruction `inverse()`, so overwrites are captured automatically). `Define`/`Select` are therefore `is_injective=false`. **Pebble-game (zero-history loops) deferred to M9.**
  - **Landed (each Opus coder + review, pushed):** `3vj` comparison ops (`2d3b587`), `d3p` Define (`d04e8cc`), `8wj` Select (`ee2fad3`), `c39` the real `lower_vm` ingest (`127fe57`, `src/ir/ingest.jl` — generic over the 6 IRInst types via critical-edge splitting; hostile-reviewed), `hvx` the SC9 Case D round-trip gate (`523d0c1`, `test/test_collatz_roundtrip.jl`). `h7f` (M_UNBOUNDED.2) closed as superseded-by-L3.
  - **Key scope finding (in test docstring):** the L3 round-trip invariant alone catches *reversal* bugs but NOT *forward-semantic* bugs (L3 replays a deterministic-but-wrong forward and still closes); the **oracle anchor** (forward result == irreversible Julia `collatz_steps`) is the complementary half. Both mutation-proved.

### What's next (Session 9)

- **The other three P0 motivating cases** (`M_DICT`, `M_DYN`, `M_NESTED`) — but note ALL of them, like collatz, need a real `ParsedIR→VMProgram` ingest. `c39` built the *collatz-shaped* generic ingest (`src/ir/ingest.jl`); generalizing it is **`M_OPCODE`** (audit `lower_vm` vs all 17 IRInst subtypes + fill gaps). M_OPCODE is the natural next foundation before the remaining cases. The motivating-case beads' "intercept the reject" framing is inaccurate — `extract_parsed_ir` already yields the symbolic loop (see `bennettvm-c39` notes); the work is lowering, not interception.
- **Collatz follow-ups (filed):** `bennettvm-bgc` (P1, ADR R1 — width-masking: the ingest doesn't mask to i8, so oracle agreement holds only for non-overflowing inputs; round-trip is width-independent), `bennettvm-3ah` (P3, ingest hardening: `_phi_const_name` collision for numeric-suffix labels + entry-as-loop-header now fail-loud), `bennettvm-jpb` (P3, generator hardening).
- **Orchestration note:** another agent was touching beads early in this session; cross-device sync is via `.beads/issues.jsonl` import (no conflicts arose — remote stayed in sync throughout).

## Current state (2026-05-27 — Session 7 close, partial)

- **Phase:** **Phase 2 (production).**
- **PRD:** `bennettvm_prd.md` is v4.
- **Bennett.jl pin:** `877341e` (unchanged this session).
- **Test suite:** **2108 / 2108 passing.** `julia --project=. -e 'using Pkg; Pkg.test()'`.
- **M8 (per-step inverse + property-test family) — 4 of 5 sub-beads CLOSED.**
  Session was cut short before M8.5 (100-program property capstone).
  All four landings orchestrated as Opus coder + Sonnet hostile reviewer
  pairs (M8.4 hostile review deferred — see below):
  - **M8.1** `adf12a9` — `test/reference/countdown.jl` gains
    `countdown_program(n)` factory + include-time `@assert` self-check
    (two clauses: `result[:steps_N] == countdown_ref(N)` AND
    `result[:n_N] == 0`; clause 2 pins `:sub`/`:add` direction —
    reviewer-caught defect: clause 1 alone is theatre against the
    n-decrement mutation because the unrolled layout always runs
    exactly N blocks regardless of body arithmetic). Refactor hoists
    `build_countdown_vm` (→ `countdown_program`) and `_decrement_block`
    from `test/test_forward_interpreter.jl` to the reference file;
    updates 7 consumer tests to include directly instead of leaning
    on transitive include order. Updates ADR 0002 citation.
  - **M8.2** `107aad9` — `test/test_per_step_inverse.jl` —
    `per_step_inverse_check(vm, inputs; checkpoint_interval,
    must_cache_set, label, _forward_snapshots_override)`. Reusable
    parameterized check that snapshots post-step IState, walks back
    via `unstep!`, asserts equality at every position; mismatch raises
    `ErrorException` pinning step index + offending IState field.
    Also asserts `rs.current == rs.initial` post-sweep (catches
    `rs.initial`-mutation bugs in the M4.3 L3 restore site).
    **Architectural finding (reviewer-caught, fixed):** when
    `must_cache_set` is empty, the L3 fallback path is
    `forward()`-driven (`Replay.jl`'s `_restore_to_checkpoint` reads
    nearest CheckpointEntry snapshot and replays forward) and
    BYPASSES `inverse()` entirely. So countdown(N)/empty-must_cache
    testsets are blind to per-instruction `inverse()` regressions.
    The M4.5 anchor inherits the same blind spot. Fix: extended the
    M7-delta testset to cover countdown(5)/K=4 with `must_cache_set =
    compute_must_cache(vm)` so the L2 path (M7.4 fast-path, the
    actual `inverse()` call site) is driven on the anchor. Docstring
    rewritten to honestly bound what each shape catches.
  - **M8.3** `f0435a9` — `test/test_mutation_proof.jl` — 5 instruction
    kinds × 2 mutations × 2 paths (L2 scaffold for non-injective;
    M6.3 direct `forward+inverse` round-trip for L1-short-circuited
    injective kinds — the M6.2 push gate prevents `unstep!` from
    reaching `inverse()` for SwapInstruction, MemoryInterchange,
    MemorySwap). Strategy (a) chosen: `BennettVM.eval(body)` shadows
    canonical method; `Base.delete_method` inside `try/finally`
    restores; `n>=1` signature-drift check + post-restore GREEN
    scaffold assertion form the double safety net.
    **World-age trap finding:** Julia world-age semantics make a
    freshly-`eval`'d method invisible to calls from any function
    whose compilation predates the eval. First implementation gave
    20/20 false GREEN. Fix: every call into mutated production code
    is wrapped in `Base.invokelatest(...)`. Documented in file
    docstring §"World-age caveat".
    `CallInstruction.inverse()` excluded — its `make_delta` raises
    unconditionally (v5-deferred per ADR 0002 §Open Questions item
    4) so the L2 path cannot be driven. Audit-trail cross-reference
    added at `src/ir/call_instruction.jl` (17-line docstring,
    pure documentation, no behavior change) pointing at follow-up
    `bennettvm-7cg` (P2).
  - **M8.4** `989c6a9` — **UNREVIEWED** —
    `test/generators/random_program.jl` — seeded random RSSA program
    generator. `random_program(rng; shape=:any, size_hint=4)` with
    three shape constructors (linear chain, conditional reconvergent
    diamond, unrolled loop) + `default_rng() =
    MersenneTwister(0xBE171973)` (BE1 = Bennett + 1973). Excludes
    CallInstruction (same exclusion M8.3 took). Hostile reviewer NOT
    RUN — session was cut short. Self-mutation-proof on the
    determinism test passed (global-RNG injection → 20/20 RED →
    restored). Follow-up `bennettvm-s9c` (P2) tracks the deferred
    review. Do NOT re-open `bennettvm-bii` unless a regression is
    found.

## What you (next session) are picking up

**M8.5 — 100-random-programs property test capstone — is the next bead.**

`bennettvm-tnp` (P1). Consumes M8.2's scaffold + M8.4's generator:
loop `default_rng()` 100 times, call `random_program(rng)`, push the
program through `per_step_inverse_check` at multiple K and
must_cache_set settings. The capstone for the M8 milestone. Note
that M8.4 isn't externally reviewed — M8.5's full-suite green is
itself a strong validation signal for the generator (100 random
programs exercising scaffold+history+IR end-to-end), but flag any
suspicious failure as a candidate generator bug first.

Also outstanding before M8 milestone close:
- `bennettvm-s9c` (P2) — deferred hostile review of M8.4 generator.
- `bennettvm-7cg` (P2) — direct round-trip audit of
  `CallInstruction.inverse()` (M8.3 follow-up).

After M8: the four P0 SC9 motivating cases (M_DICT, M_DYN, M_NESTED,
M_UNBOUNDED) which are the load-bearing acceptance gate before M13
(Bennett.jl `target=:reversible_vm` dispatch arm).

## Session 7 orchestration notes (partial)

Same Opus + Sonnet pattern as Sessions 5 and 6. Orchestrator
(opus[1m]) ran in foreground; each sub-bead spawned one Opus coder
(general-purpose subagent) then one Sonnet hostile reviewer
(general-purpose subagent). Reviewer per-claim signoff + mutation
probes uncovered the load-bearing findings (M8.1 weak self-check,
M8.2 L3 blind spot, M8.3 MemorySwap-duplicate + generic fragment).
M8.4 review skipped due to time pressure — see `bennettvm-s9c`.

**Stale untracked dirs**: the 8 `references/<topic>/` dirs (foundational,
ad-and-checkpointing, implementations, quantum-uncomputation,
reverse-debugging, reversible-ir, reversible-isa, reversible-languages)
are local PDF stashes carried across sessions; they are NOT in
`.gitignore` but also NOT committed yet. No effect on suite.

### Earlier session marker (Session 6 close: 1997/1997)
- **M7 (history layer L2: delta with min-cut) — CLOSED this session.**
  All seven sub-beads, orchestrated as Opus coder + Sonnet hostile
  reviewer pairs:
  - **M7.1** `cd911b6` — ADR 0002 `docs/adr/0002-enzyme-min-cut-mapping.md`.
    Six binding design decisions for M7.2-M7.7. Key finding from
    source cross-check: all three ArithmeticAssignment modops AND
    MemoryAssignment are structurally injective via `dual_modop`;
    strengthens `bennettvm-ack` and `bennettvm-c0e` follow-ups.
  - **M7.2** `400593b` — `DeltaEntry{T<:Instruction} <: AbstractHistoryEntry`
    at `src/history/delta.jl`. Parametric on T, NamedTuple payload,
    step::Int field. Structural ==/hash. Julia 1.12 dispatch quirk
    documented: do NOT add cross-T `==` method (shadows same-T).
  - **M7.3** `9d1b374` — `make_delta(instr, s_pre, step)` per-instruction
    in `src/ir/<instr>.jl` files. Per ADR finding: empty NamedTuple
    payload for ArithmeticAssignment + MemoryAssignment;
    CallInstruction errors v5-deferred. Generic fallback errors loudly.
  - **M7.4** `c7edd6b` — `unstep!` DeltaEntry fast-path:
    pop-and-inverse when top of history is a DeltaEntry whose step
    matches step_count. Existing M4.3 path byte-preserved as
    fallback. `inverse(::T, s, payload::NamedTuple)` specialisations
    coexist with existing `prev::Any` methods (no ambiguity).
  - **M7.5** `ecabb78` — `compute_must_cache(prog)::Set{Tuple{Symbol,Int}}`
    + `must_cache(set, label, idx)::Bool` at `src/analysis/liveness.jl`
    (new dir). Stub: returns all non-injective body positions.
  - **M7.6** `281414a` — INTEGRATION. New kwargs on step!/run!:
    `must_cache_set` (default empty) and `replay_mode` (default false).
    Push gate is the ADR composition rule: replay_mode → L1 → L2 → L3.
    `_block_index_at(prog, pc)` private helper. unstep!'s replay loop
    sets replay_mode=true. **ADR deviation accepted**: kwarg, not
    VMProgram field — avoids 18-file test cascade; default-empty
    reproduces M6.2 behaviour bit-for-bit. Zero pre-existing regressions.
  - **M7.7** `d29c9b2` — M7 milestone capstone. Seven testsets, 150
    new assertions. **Sub-linear ratio achieved: 0.0909** on
    18-Swap + 2-Arith program (well below 0.5 ADR floor, < 0.1
    design target). Scaling sweep confirms ratio approaches the 10%
    asymptote monotonically from below. L2 path matches L3 path on
    countdown(5). Composition with M6 (all-injective → zero history)
    preserved.

## Session 6 orchestration notes

Same Opus + Sonnet pattern as Session 5. The seven sub-beads ran
sequentially per Rule 7 (no parallel Julia). Highlights:

- **M7.1's ADR was binding**: subsequent coders deferred to ADR §
  references rather than the (sometimes outdated) bead text. M7.3 in
  particular ignored the bead's "capture pre-target value" wording
  and followed the ADR's empty-payload finding.
- **M7.6's ADR deviation**: `must_cache_set` ships as a kwarg, not a
  VMProgram field. Hostile reviewer accepted this as an
  optional-capability parameter (Rule 13 is about toggling competing
  behaviours; the default here is a strict subset).
- **M7.7 mutation-provability gap (informational)**: testset 3's
  sub-linear ratio assertion is architecturally double-enforced by
  L1 + L2, so no single-line mutation can drive ratio above 0.5.
  Reviewer flagged this as a strength of the architecture, not a
  defect.

No follow-up beads filed this session (the existing `bennettvm-ack`,
`bennettvm-c0e`, `bennettvm-xtb` from Sessions 4–5 were strengthened
with ADR-derived rationale; nothing new emerged).
- **Setup gotcha:** Manifest.toml is gitignored (per-machine). Fresh
  clones MUST run `julia --project=. -e 'using Pkg; Pkg.develop(path="../Bennett.jl"); Pkg.instantiate()'`
  before tests pass.
- **M6 (history layer L1: injective no-log) — CLOSED this session.**
  All four sub-beads orchestrated through Opus coder + Sonnet hostile
  reviewer pairs:
  - **M6.1** `6b59824` — `is_injective` trait at `src/history/Injective.jl`.
    Type-level true for `SwapInstruction`, all `ControlInstruction`
    subtypes (Begin/End, Uncond Entry/Exit, Cond Entry/Exit),
    `MemoryInterchange`, `MemorySwap`. Value-level true for
    `ArithmeticAssignment` iff `modop === :xor`. Conservative on
    `:xor` only — broaden-to-`:add`/`:sub` filed as follow-up
    `bennettvm-ack`. 30 new assertions.
  - **M6.2** `e9eb994` — `step!` push site AND-gated by
    `!is_injective(instr)`. `step_count` increments unconditionally;
    only the L3 push is gated. Cascading test updates to
    `test_unstep.jl`, `test_checkpoint_push.jl`, `test_unrun.jl`,
    `test_roundtrip.jl` for the new push patterns (net -7 assertions
    from removed out-of-bounds `history[i]` checks; +7 new in
    `test_injective.jl`). Round-trip invariant preserved via
    Replay.jl's `s.initial` fallback.
  - **M6.3** `44dfdca` — contract tests pinning `inverse(i, _, nothing)
    == s_pre` for every M6.1-injective type. New file
    `test/test_injective_inverse.jl`. **Audit result: no bugs in any
    existing inverse() method.** 81 new assertions. Identified gap
    `bennettvm-xtb` (P3) — `_handle_backward_cross_block_dispatch!`
    missing; non-blocking because Replay.jl's `s.initial` fallback
    handles empty-history cross-block backward traversal.
  - **M6.4** `fa90ee1` — M6 milestone capstone integration test. Five
    all-injective programs (xor-chain, swap-chain, two-block-uncond,
    memory-ops, mixed) under K ∈ {1, 4, 64, typemax(Int)}. 14
    testsets, 490 new assertions. `isempty(rs.history)` asserted
    after EVERY step, not just at end. Confirms M6 architecture
    composes correctly.

## Session 5 orchestration notes

Orchestrated as four Opus coding subagents (one per sub-bead) + four
Sonnet hostile reviewers, serial (Rule 7 — no parallel Julia). Each
reviewer produced per-claim signoff with hostile mutation probes
(Rule 6 — "Core" change tier for M6.1/M6.2; "Small" + reviewer for
M6.3/M6.4). M6.2 coder hit a 529 Overloaded mid-edit on
`test_roundtrip.jl` and `test_injective.jl`; orchestrator finished
those manually using the coder's partial state, then sent the
combined diff through the reviewer.

Follow-up beads filed this session (do not block M7):

- `bennettvm-ack` (P2) — broaden `is_injective(::ArithmeticAssignment)`
  to `:add`/`:sub` modops (PRD v4 §3.2 reconciliation).
- `bennettvm-c0e` (P2) — `MemoryAssignment` value-level
  discrimination (modop===:xor case).
- `bennettvm-xtb` (P3) — `_handle_backward_cross_block_dispatch!`
  for future direct-inverse `unstep!` optimization.

## What you (next session) are picking up

**M8 — per-step inverse property test — is the next milestone.**

Per PRD v4 §3.13 (per-step inverse pattern) + §3.15 (property test
discipline). M8 is mostly testing infrastructure that exercises the
M2/M4/M6/M7 layers under randomised programs. M8.x sub-beads are in
`bd ready`.

After M8: the four P0 SC9 motivating cases (M_DICT, M_DYN, M_NESTED,
M_UNBOUNDED) which are the load-bearing acceptance gate before M13
(Bennett.jl `target=:reversible_vm` dispatch arm).

**Parallel-startable alternatives** (independent of M8):
- `bennettvm-ack` (P2): broaden `is_injective(ArithmeticAssignment)`
  to `:add`/`:sub`. ADR 0002 source cross-check confirmed all three
  modops are structurally injective via `dual_modop`. Small,
  low-risk simplification that reduces M7.6's must_cache set.
- `bennettvm-c0e` (P2): MemoryAssignment value-level injectivity.
  Same shape as bennettvm-ack.
- `bennettvm-6r6` (P1): M1.1 benchmark harness for history strategies.
- `bennettvm-34c` (P1): M_OPCODE audit of lower_vm vs Bennett.jl's
  17 IRInst subtypes.
- `bennettvm-81y` (P1): M_FP.1 ADR for SoftFloat-dispatch FP
  inheritance.

### Open observation carried over from Session 4

- `bennettvm-kuq` (P2): `unstep!` search loop uses
  `entry isa CheckpointEntry` while the truncation loop uses the
  polymorphic `_entry_step()` helper. **Still asymmetric.** M6 did
  not introduce a new entry type (M6's no-push semantics meant the
  L3 entry type set didn't grow). When M7 introduces a delta entry
  type, resolve this asymmetry — the search loop should use the
  polymorphic helper too.

### Open observation flagged this session

- `bennettvm-kuq` (P2): `unstep!` search loop uses
  `entry isa CheckpointEntry` while the truncation loop uses the
  polymorphic `_entry_step()` helper. Asymmetric. Only matters when
  M6/M7 entry types arrive; the M6 implementer should resolve when
  they touch Replay.jl.

### Session 4 notes

- 31 stale beads (M5/M0/M2/M3 sub-beads) were closed at session start
  to reconcile the tracker with `git log` reality.
- M4.5's hostile review was in progress in the background when the
  session was paused. The reviewer's mutation probe to
  `src/history/Replay.jl` (removing the restore-side deepcopy) was
  caught and reverted on `git status` BEFORE the M4.5 commit. The
  probe DID empirically confirm one matrix entry (restore-side
  deepcopy → M4.5 test 4 RED). Full M4.5 hostile review can be
  resumed next session if any latent doubt remains.

### Earlier state (preserved for history)

## Old state (pre-Session-4, retained for diff context)

- **Phase:** **Phase 2 (production).**
- **PRD:** `bennettvm_prd.md` is v4. v3 archived at `docs/prd/bennettvm_prd_v3.md`.
- **Bennett.jl pin:** `877341e` (repinned 2026-05-26 from `5731cec`,
  docs-only diff).
- **Test suite:** **565 / 565 passing.** Single `julia --project=. -e
  'using Pkg; Pkg.test()'`.
- **Milestones complete (2026-05-26 orchestration session):**
  - **M5** — RC3 `rvm` pre-read (build + sample run + instruction
    taxonomy). ADR at `docs/adr/0001-rc3-rvm-smoke.md`.
  - **M0** — Bennett.jl handoff smoke (Project.toml, src/BennettVM.jl
    skeleton, lower_vm digest, regression-anchor test). ADR at
    `docs/adr/0000-handoff-smoke.md`.
  - **M2** — IR foundation (18 sub-beads): all 12 RSSA instruction
    types (ArithmeticAssignment, SwapInstruction, MemoryAssignment,
    MemoryInterchange, MemorySwap, CallInstruction, BeginInstruction,
    EndInstruction, UnconditionalEntry/Exit, ConditionalEntry/Exit)
    with forward/inverse + constructor validation + round-trip tests;
    BasicBlock with structural_inverse + reversed(); LabelTable
    with dual-address layout; VMProgram with cross-block container.
  - **M3** — forward-only interpreter (8 sub-beads): initial_state,
    is_halted, result, step!, run! with max-steps guard, cross-block
    dispatch via LabelTable, args→params two-phase rename,
    countdown(N) golden-master integration test against an
    irreversible Julia reference (countdown_ref).
- **Most recent commit:** see `git log -1`.
- **Git tag:** `spike-0-archived` still marks the end of Phase 0. No new
  tag created for v4 ratification.
- **Test suite:** spike `spike/` is frozen (789/789 passing, chmod -w);
  Phase-2 `test/` is empty.

## What you (next session) are picking up

**M3 (forward interpreter) closed. M4 is the next milestone** — history
layer 3 (checkpoint-replay), which is the first step toward `unrun!`
and the reverse direction. After M4 comes M6 (history L1 — injective
no-log), M7 (history L2 — delta min-cut), M8 (per-step inverse +
property test).

After the history layer is in, the four motivating cases (M_DICT,
M_DYN, M_NESTED, M_UNBOUNDED — all P0) become the SC9 acceptance
gate.

Parallel-startable independent tracks:

- **M1.1** (P1) — benchmark harness for history strategies. Independent
  of M4-M8.
- **M_OPCODE** (P1) — audit lower_vm against Bennett.jl's 17 IRInst
  subtypes (only 6 are exercised so far via collatz_steps).
- **M_FP.1** (P1) — ADR documenting SoftFloat-dispatch FP inheritance.

### Earlier handoff (Phase-2 first session: M5 + M0) — DONE

This section is preserved for historical reference; M5 and M0 closed
2026-05-26.

### A. Phase-2 first session: M5 + M0 (recommended)

This is `bennettvm-phase2-epic` first child issues (M5 then M0).

1. **M5 — RC3 `rvm` pre-read** (gates everything).
   - Build `rc3` and `rvm` from `references/implementations/RC3/`. The
     repo uses Maven/CUP; build instructions in its README. **Java
     toolchain required.**
   - Run at least one RSSA program through `rvm`. Sample programs in
     `references/implementations/RC3/compiler/programs/rssa/vm/`.
   - File `docs/adr/0001-rc3-rvm-smoke.md` capturing: (a) build steps;
     (b) the sample RSSA program; (c) `rvm` output; (d) verbatim
     observations about RSSA semantics that should inform Phase-2 IR.
   - The literature pre-read (Mogensen 2016 §3, Deworetzki-Meyer 2021
     §2.2 pp. 66–67) should happen before or during this milestone.

2. **M0 — Bennett.jl handoff smoke** (PRD §6 SC1, §9 M0).
   - Initialize Phase-2 Julia package: `Project.toml` at root,
     `src/BennettVM.jl`, `test/runtests.jl`.
   - Implement a stub `lower_vm(parsed::ParsedIR) :: VMProgram` that
     returns an empty `VMProgram` and prints a digest of the input
     `ParsedIR` (number of blocks, instructions, args).
   - Call it on `collatz_steps(::Int8)` from
     `Bennett.jl/test/test_y986_loop_header_dispatch.jl:129`. Goal:
     verify the import works at pin `5731cec` and the type signature is
     correct.
   - File `docs/adr/0000-handoff-smoke.md` with the digest output.

### B. Alternative first session: M1 (cost measurement)

Independent of M5/M0. Could be done in parallel by a separate session.

- Benchmark, on the spike's countdown(10_000) program (the spike is
  read-only — `chmod -R u+w spike/` first, restore after):
  - Full-snapshot history (the spike baseline).
  - A delta-history sketch (just record `(register, old_value)` tuples).
  - A periodic-checkpoint sketch (snapshot every K steps; replay forward
    from nearest checkpoint to reach an arbitrary step).
- Write up in `docs/measurements/m1-history-cost.md`. Use the data to
  set the default checkpoint interval in v4 §3.3.

### What to NOT do

- **Do NOT promote spike code into Phase 2.** PRD v4 §1.1, §5.3, §7.7.
  Phase 2 starts from an empty `src/`+`test/` tree. The spike is tagged
  `spike-0-archived` and `chmod -R -w`. Use as a *pattern source*, not
  source to fork. The reviewer specifically called this out as
  load-bearing.
- **Do NOT modify Bennett.jl source.** CLAUDE.md Rule 14. v4 §3.7
  Handoff A is specifically designed so that Phase-2 M0 does not require
  any Bennett.jl mutation. If you find yourself wanting to add an export
  to Bennett.jl (e.g., for `IRBasicBlock`), STOP and ask the user. The
  qualified-access pattern (`Bennett.IRBasicBlock`) suffices.
- **Do NOT skip the RC3 pre-read.** PRD v4 §3.1 and SC6 are explicit.
  Writing Phase-2 IR before reading RC3's `instances/` directory is a
  Law-2 violation.
- **Do NOT add a `target=:reversible_vm` dispatch arm to Bennett.jl
  unilaterally.** That is Handoff B (v4 §3.7), ADR 0003, requires user
  approval and 3+1 protocol.
- **Do NOT introduce floating-point support.** v4 §3.6: out of scope for
  Phase-2 initial release. Emit a clear "FP not supported" error if a
  `ParsedIR` carries an FP `IRBinOp`.

## Key v4 normative requirements (cheat sheet)

Sections to re-read often:

- **§3.1** RSSA IR; isomorphic to RC3 taxonomy (12 concrete subclasses).
  φ-equivalents on BOTH joins AND splits. Variable-destroying uses.
- **§3.2** Injective / non-injective / control-flow partition. Memory =
  exchange. Jumps = source-label-encoded.
- **§3.3** Three-layer history: no-log / delta-min-cut / checkpoint-replay.
  Full snapshots forbidden.
- **§3.7** Consume `Bennett.ParsedIR` (`Bennett.jl/src/ir_types.jl:347`).
  `IRBasicBlock`/`IRInst` not exported; access qualified. `IRLoad`/`IRStore`
  → `Exchange` translation pass required pre-RSSA.
- **§3.9–§3.17** Spike-derived API + invariants (mutable RState, structural
  `==`, forward-before-push, discard-pop predicate, per-step inverse test,
  golden master co-location, seeded random programs WITH control flow).

## Tools you should know about

- **`bd ready`** — find available work. After Phase-2 epic opens, M0/M5
  will appear.
- **References are not in git.** `references/` is ~127 MB and intentionally
  untracked. SHA256 manifest at `references/manifest/SOURCES.md`.
- **Bennett 1973 PDF on disk** at `references/foundational/bennett-1973-logical-reversibility.pdf`
  (user-supplied 2026-05-25; SHA256 `e61ad668…0687`). v3's blocker is
  resolved.
- **`playwright-cli` with `--browser chromium --headed`** still works for
  paywall acquisition. ACM DL still blocked.
- **`spike/`** is `chmod -w`. If you need to re-run a probe (e.g., for M1
  cost measurement), `chmod -R u+w spike/`, run, then `chmod -R -w spike/`.

## Bennett.jl pin

- Pinned SHA: `5731cec22a1fd29efe02d4dc21c2a57e655ecb47`.
- Pin date: 2026-05-23. Confirmed still current 2026-05-25.
- See [`BENNETT_JL_PIN.md`](./BENNETT_JL_PIN.md) for repinning policy.
- Phase 2's Handoff A (v4 §3.7) is designed to be insensitive to most
  Bennett.jl changes; only `ParsedIR` struct breakage requires repinning.

## Open questions for the user (deferred from v3 §VIII)

(Reduced from six to two genuine items; see v4 §8.1.)

1. **Floating-point reversibility scheme.** Residual tape vs posit-with-
   sticky vs opaque snapshots. v4 defers to v5 after a Phase-2 prototype.
2. **Divergence handling.** Whether Phase 2 inherits Bennett.jl's
   `max_loop_iterations` style or implements a separate termination
   analysis.

## Quick session-start checklist

When the next agent arrives:

- [ ] `cat PHASE.md` — confirm Phase 2.
- [ ] `bd ready` — what's claimable. Expect Phase-2 milestones.
- [ ] Read `bennettvm_prd.md` (v4) §0, §1, §3, §6, §9 at minimum.
- [ ] Read this `HANDOFF.md` top to bottom.
- [ ] Read `CLAUDE.md` top to bottom (Rule 16: re-read after every context
      compression).
- [ ] Skim `WORKLOG.md` Session 2 for what landed.
- [ ] Read `spike/RETROSPECTIVE.md` if not done in prior session.
- [ ] Only then start work — and start with M5, not M0.
