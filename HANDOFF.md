# HANDOFF — BennettVM.jl

> What the next session needs to know. Read top to bottom; do not skim.

## Current state (2026-05-23)

- **Phase:** Phase 1 (archive). PRD v4 pending. Phase 2 NOT started.
- **Open bd issue:** `bennettvm-pb2` (P0 epic) — *Write PRD v4 from
  spike retrospective*.
- **Most recent commit:** `bcc49c5` Phase 0 → Phase 1 transition.
- **Git tag:** `spike-0-archived` marks the end of Phase 0.
- **Test suite (spike):** 789/789 passing (frozen at archival).

## What you (next session) are picking up

There are two natural next sessions:

### A. PRD v4 authoring (the obvious next step)

This is `bennettvm-pb2`. Before writing a single word of v4:

1. **Read every §2 reference in `references/`.** The PRD v3 Part II
   reading list is 43 papers; ~95% are on disk. Manifest at
   [`references/manifest/SOURCES.md`](./references/manifest/SOURCES.md).
   The handful that are still ⏸ DEFER (mostly ACM DL papers behind
   Cloudflare) are listed there with reasons.
2. **Read [`spike/RETROSPECTIVE.md`](./spike/RETROSPECTIVE.md) section
   by section.** Cross-reference each of its 9 answered questions
   into the v4 outline. Particularly:
   - Q1 (PRD v3 assumptions wrong): correct each in v4.
   - Q2 (ambiguities resolved): ratify or override each in v4.
   - Q4 (carries to Phase 2): adopt as v4 constraints.
   - Q5 (still needs Phase 2 design): these are v4's main content.
3. **Apply the errata logged during pre-Phase-0:**
   - BobISA citation → Thomsen-Axelsen-Glück 2012 (RC 2012), NOT
     Axelsen-Yokoyama 2011 (LATA). See
     `references/manifest/SOURCES.md §Citation-errata`.
   - Mogensen RIL is inside Mogensen 2015 LNCS 9138, not a standalone
     paper.
4. **Read RC3 source at [`references/implementations/RC3/`](./references/implementations/RC3/)**
   before writing any Phase-2 design. PRD v3 §2.2 explicitly says
   "Read the RC3 source before writing Phase-2 code." This is Law 2
   (Reuse before reinvention) made concrete.
5. **Resolve PRD v3 §VIII open questions** in v4:
   - Exact form of IR extensions to RSSA.
   - Integration boundary with Bennett.jl (which IR does Bennett.jl
     emit; does it emit RSSA directly or does BennettVM lower a less-
     reversible IR?).
   - Default numeric subset (Q-format vs FP earlier than expected?).
   - Whether to ship a pebble-game implementation in BennettVM or
     bind to Reqomp/Qurts via FFI.
   - Lean 4 (default) vs Coq vs Agda.
   - Publish at RC (Reversible Computation conference)?

### B. Bennett 1973 PDF acquisition (the blocker that wasn't blocking)

The 2026-05-23 user override to proceed without Bennett 1973 was
adequate for Phase 0 Stage 1 (forward + reverse with full snapshots).
Phase 2 implements Bennett's Stage 2 (Output channel) and Stage 3
(Cleanup, the foundation for pebble-game lowering) — and the
substitute sources (Vitanyi CF'05, Bennett 1989, BTV 2001) become
insufficient at that point.

Recommended path:

```
To: fernleihe@tib.eu
Subject: ILL request — Bennett 1973, IBM JRD 17(6)
DOI: 10.1147/rd.176.0525
Citation: Bennett, C.H., "Logical reversibility of computation,"
          IBM J. Res. Dev. 17(6):525–532, November 1973.
```

Drop the resulting PDF at
`references/foundational/bennett-1973-logical-reversibility.pdf`.
Update `references/manifest/SOURCES.md` (flip ⏸ DEFER → ✅ HAVE,
append SHA256 to the hash log). Edit `PHASE.md` to remove the
override section.

## What to NOT do

- **Do NOT promote spike code into Phase 2.** PRD §1.4 / §7.8 /
  CLAUDE.md P0.7. Phase 2 starts from an empty `src/`+`test/` tree.
  The spike is tagged `spike-0-archived` and `chmod -R -w` for a
  reason. Use it as a *pattern source*, not source-to-fork. If you
  catch yourself running `cp spike/src/* src/`, stop.
- **Do NOT change PRD v3.** Move it to `docs/prd/bennettvm_prd_v3.md`
  when v4 lands and put v4 at the root. v3 is part of the historical
  record.
- **Do NOT modify the spike retrospective.** It's a frozen artifact.
  Corrections to its conclusions belong in PRD v4, not in retrospect-
  rewriting.
- **Do NOT skip the literature reading.** PRD v3 Part II is a long
  list but every entry is non-trivial. Law 2 enforcement requires
  citing what published work each Phase-2 decision replaces.

## Tools you should know about

- **`bd ready`** — find available work. Currently shows only
  `bennettvm-pb2` (PRD v4 epic).
- **`playwright-cli` with `--browser chromium --headed`** — works
  for paywall acquisition via TIB VPN. See `WORKLOG.md` Session 1
  §2 for the pattern. ACM DL is genuinely blocked even with this
  (Cloudflare cookie context issue) — skip-fast on `dl.acm.org`.
- **`spike/`** is chmod -w. If you need to re-run a probe (e.g., to
  verify a finding for v4), `chmod -R u+w spike/`, run the probe,
  then `chmod -R -w spike/` again. Do NOT modify spike contents.
- **References are not in git.** `references/` subdirectories are
  ~126 MB and intentionally untracked. The manifest at
  `references/manifest/SOURCES.md` IS tracked and is the canonical
  inventory with SHA256s. If you clone fresh on another machine,
  you'll need to re-acquire (see the manifest's "Acquisition
  workflow" section).

## Bennett.jl pin

- Pinned SHA: `5731cec22a1fd29efe02d4dc21c2a57e655ecb47`.
- Pin date: 2026-05-23.
- See [`BENNETT_JL_PIN.md`](./BENNETT_JL_PIN.md) for repinning policy.

Phase 0 didn't integrate with Bennett.jl (PRD §5.2). Phase 2 will,
through a documented IR interface. If you change the pin, document
the new SHA + the reason in `BENNETT_JL_PIN.md`.

## Open questions for the user

(Carry-overs from PRD v3 §VIII that the user has not yet decided.)

1. **Pebble-game scope.** Ship a pebble-game lowering implementation
   in BennettVM directly, or bind to Reqomp/Qurts via FFI for the
   quantum oracle synthesis subset?
2. **Floating-point reversibility.** Residual-tape FP vs
   posit-with-sticky vs opaque snapshots. PRD v3 §3.6 leaves this
   for v4; the spike did not exercise it.
3. **Bennett.jl integration boundary.** Which IR does Bennett.jl
   emit? Does BennettVM consume RSSA directly, or does Bennett.jl
   emit a less-reversible IR that BennettVM lowers to RSSA?
4. **Publish at RC?** PRD v3 §VIII §6 suggests yes. User should
   decide before Phase 2 wraps.
5. **References in git.** Decide between: (a) keep untracked, manifest
   only (current state); (b) git-lfs for the PDFs; (c) external
   shared storage with sync script. ~126 MB is borderline for git;
   the user has explicitly chosen (a) for now.

## Quick session-start checklist

When a new agent arrives:

- [ ] `cat PHASE.md` — confirm what phase we're in.
- [ ] `bd ready` — what's claimable.
- [ ] `bd show bennettvm-pb2` — what PRD v4 epic says.
- [ ] Read this `HANDOFF.md` top to bottom.
- [ ] Read `CLAUDE.md` top to bottom (it's the rules; re-read after
      every context compression per Rule 16).
- [ ] Read `bennettvm_prd.md` if not done in prior session.
- [ ] Read `spike/RETROSPECTIVE.md`.

Only then start work.
