# WORKLOG — BennettVM.jl

> Chronological session log. Prepend new sessions to the top. Capture
> what was done, what was decided, and what surprised us — anything a
> future agent or human would wish it knew, that's not derivable from
> `git log` or the retrospective.

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
