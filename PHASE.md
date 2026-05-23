Phase 0 (spike session open)

Flipped: 2026-05-23.

## Gates met

- ✅ CLAUDE.md / AGENTS.md, PRD v3, BENNETT_JL_PIN (`5731cec`).
- ✅ references/ populated, 43 paper PDFs + 5 source clones + manifest.
- ✅ All P2 literature acquired.
- ✅ Yokoyama-Glück 2007 PEPM acquired.
- ✅ Spike sub-agent prompts + retrospective skeleton in `scripts/spike-templates/`.
- ✅ `spike/` scaffolded.
- ✅ beads initialized.

## Gate NOT met (user override, 2026-05-23)

- ⏸ **Bennett 1973** PDF not on disk. TIB does not include the IBM JRD
  historical archive; TIB ILL would resolve but the user has elected
  to **move on without it**. Per CLAUDE.md Law 1 / PRD §5.5 this would
  normally block Phase 0 — the user has explicitly overridden.

**Substitute ground truth for the Bennett-1973 construction** (already
on disk):

| Use | Path |
|---|---|
| Construction summary + three-tape mechanics | `references/foundational/vitanyi-time-space-energy.pdf` §2 (P.M.B. Vitanyi survey, CF'05; describes Bennett 1973 explicitly) |
| Bennett's own retrospective reference | `references/foundational/Bennett1989_time_space_tradeoffs.pdf` §1–2 (Bennett re-states the 1973 construction as the baseline for his 1989 pebble game) |
| Modern formal restatement | `references/foundational/buhrman-tromp-vitanyi-2001.pdf` §1 (BTV 2001 frames Bennett-1973 as the canonical baseline simulation) |
| Pebble-game analysis of Bennett-1973 | `references/foundational/Knill1995_bennett_pebble_analysis.pdf` |
| RSSA paper's citation context | `references/reversible-ir/mogensen-2016-rssa.pdf` (Mogensen cites Bennett 1973 in §1 as the foundational reversible-computation paper) |

These four secondary sources collectively describe the three-tape
reversible-TM construction with enough fidelity that the spike can
proceed. **The spike orchestrator MUST cite these secondary sources
in code comments** in place of the Bennett-1973 PDF citation that the
sub-agent prompts originally specified.

**Retrospective Q7 must record this override explicitly** — it is a
non-trivial deviation from PRD v3 and PRD v4 needs to know about it.

## Open Phase-0 actions

See `scripts/spike-templates/README.md` for the orchestration order.
Begin with the pre-flight checklist there, **except** the Bennett-1973
existence check — it has been waived per the override above.
