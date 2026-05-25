# WORKLOG — BennettVM.jl

> Chronological session log. Prepend new sessions to the top. Capture
> what was done, what was decided, and what surprised us — anything a
> future agent or human would wish it knew, that's not derivable from
> `git log` or the retrospective.

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
