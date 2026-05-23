# Phase-0 Spike Retrospective — BennettVM.jl

> **THIS IS THE PHASE-0 DELIVERABLE** (PRD v3 §1.2, §5.6). The spike
> itself is throwaway; this document is what survives. Phase-0 is not
> closed until every section below is filled in honestly. Empty
> sections = Phase-0 failure (PRD §7.1).

**Spike session date:** ____________
**Session duration:** ____________
**Lead agent (orchestrator):** ____________
**Sub-agents engaged:** ____________
**Spike repository path / commit SHA at close:** ____________
**Bennett.jl version pinned during spike:** ____________

---

## Q1. Which PRD v3 assumptions turned out wrong or underspecified?

> Concrete list. One bullet per assumption, with the section reference
> and the actual decision the spike converged on. The point of this
> question is to give PRD v4 a punch list — vague answers ("§5.3 was
> okay") help no one.

- Example shape:
  - **PRD v3 §X.Y** said *<verbatim>*. In practice we discovered
    *<concrete observation>* and resolved by *<the choice we made>*.

(Fill in.)

---

## Q2. Ambiguities resolved by Claude Code (and how)

> The PRD leaves several decisions to the spike. Document what the
> spike chose for each, so PRD v4 can ratify or override.

### Q2.1 Equality semantics for `IState`, `RState`, `HistoryStack`
- What was decided: ____________
- Why: ____________

### Q2.2 Copy / deepcopy semantics
- What was decided: ____________
- Why: ____________

### Q2.3 Error-state handling (division by zero, overflow, etc.)
- What was decided: ____________
- Why: ____________
- Is the error state itself reversible? ____________

### Q2.4 Halt-state propagation
- Does `step!` on a halted state error, no-op, or push a halt entry? ____________
- Why: ____________

### Q2.5 History representation
- `Vector{IState}` vs `Stack{IState}` vs a Channel vs `Tuple{Symbol, ...}` deltas? ____________
- Why: ____________
- Implication for `unstep!`: ____________

### Q2.6 `max_steps` semantics
- Does the guard count successful `step!` calls or attempted ones? ____________
- What happens to history on max-steps trip? ____________

### Q2.7 Anything else
- ____________

---

## Q3. What was unexpectedly hard or easy?

### Unexpectedly hard
- ____________

### Unexpectedly easy (faster than budgeted)
- ____________

### Surprises about Julia idioms in this domain
- ____________

### Surprises about reversibility semantics
- ____________

---

## Q4. What carries over to Phase 2?

> Concrete things — APIs, type names, test patterns, file layouts —
> that the spike got right and Phase 2 should adopt. Be specific:
> "the `RState` shape" is too vague; "the `RState.current::IState +
> RState.history::Vector{IState}` partition" is right.

- ____________

### Test patterns worth keeping
- ____________

### Naming conventions worth keeping
- ____________

### Anti-patterns the spike surfaced (do NOT carry over)
- ____________

---

## Q5. What does Phase 2 still need to design from scratch?

> The spike implements a tiny subset (PRD §5.1). Everything outside
> that subset is Phase-2 design work. List the load-bearing pieces
> Phase 2 must still figure out, with a sentence on what the spike
> revealed about each.

- **RSSA IR shape** (Mogensen 2016 + Bennett.jl extensions): ____________
- **Pendulum/BobISA instruction set adaptation**: ____________
- **Enzyme-style min-cut delta-history selector**: ____________
- **Bennett-1989 pebble-game lowering pass**: ____________
- **rr-style periodic-checkpoint mechanism**: ____________
- **Output-channel invariant (`OutputRef`)**: ____________
- **Floating-point reversibility scheme** (residual-tape / posit-sticky / opaque snapshot): ____________
- **Bennett.jl frontend integration boundary**: ____________
- **Lean formalization scope** (abstract VM semantics only, per §3.8): ____________
- **Other**: ____________

---

## Q6. Was anything the spike implemented already in RC3, janus-vesta, etc.?

> Honest cross-check, per PRD v3 §5.6 Q6. Open
> `references/implementations/RC3/`, `TOPPS-janus/`, `jana/`,
> `janus-vesta/`, `evincarofautumn-janus/`. For each piece of the
> spike — state representation, step function, history mechanism,
> round-trip test pattern — answer: does this exist there already?

| Spike component | Exists in RC3? | TOPPS-janus? | jana? | janus-vesta? | Notes |
|---|---|---|---|---|---|
| `IState` analogue | | | | | |
| `RState` analogue | | | | | |
| `HistoryStack` analogue | | | | | |
| `step!` / `unstep!` | | | | | |
| `run!` / `unrun!` | | | | | |
| Round-trip property test | | | | | |
| 8-instruction bytecode | | | | | |

> **If anything we built is essentially a rebuild of code in RC3 or
> janus-vesta, mark it explicitly.** Law 2 (Reuse before reinvention)
> applies to Phase 2 — the spike is allowed to ignore reuse, but
> learning what we duplicated is core to writing PRD v4 honestly.

---

## Q7. PRD v3 errata + spike-session overrides surfaced

> Anything in the PRD that turned out to be wrong on inspection (a
> miscited paper, an incorrect author tuple, an algorithm reference
> that doesn't say what we thought). Already-known pre-spike errata
> (e.g. the BobISA citation correction logged in
> `references/manifest/SOURCES.md §Citation-errata`) can be referenced
> rather than restated.

**Pre-spike user override (2026-05-23):** PRD §5.5 / CLAUDE.md Law 1
requires the Bennett 1973 PDF on disk before the spike opens. The
PDF could not be acquired (TIB does not cover the IBM JRD historical
IEEE Xplore volume; TIB ILL was the clean path). The user elected to
proceed without it, using the secondary sources listed in PHASE.md
as substitute ground truth. **Did this substitution hurt?** Answer
below — be specific. If a citation gap or a misremembered detail
about Bennett's construction surfaced during the spike, log it
here so PRD v4 can decide whether to re-require the original.

- Was the substitute-source coverage sufficient? ____________
- Did any Bennett-1973-specific detail (notation, exact tape
  semantics, halting convention) get fudged because we only had
  secondary sources? ____________
- Should PRD v4 re-require the original PDF, or accept secondary
  sources as adequate? ____________

**Other errata surfaced during the spike:**

- ____________

---

## Q8. Recommendations for PRD v4

> Concrete edits — not "consider X" but "change §Y from <quote> to
> <quote>." This is the input PRD v4's author will work from.

- ____________

---

## Q9. What was NOT learned by doing this spike?

> The spike is narrow (PRD §5.1). What does Phase 2 still need to
> design from scratch *despite* having done the spike? This is
> different from Q5 in that Q5 asks what Phase 2 must design; Q9
> asks what the spike specifically failed to inform.

- ____________

---

## Closing checklist

- [ ] Spike repository archived / marked read-only (PRD §7.8).
- [ ] PRD v4 ticket opened in beads, this retrospective attached.
- [ ] `PHASE.md` updated to "Phase 1 (archive); PRD v4 pending".
- [ ] Hand-off note written for the PRD-v4 author.
