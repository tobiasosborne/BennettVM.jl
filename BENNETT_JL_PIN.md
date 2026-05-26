# Bennett.jl version pin

Per PRD v3 §7.5 and CLAUDE.md Rule 14, BennettVM.jl pins Bennett.jl
during initial development to insulate against frontend churn.

**Pinned SHA:** `877341ec388004a69636ac4530d4d9abf2439486`
**Pinned date:** 2026-05-26 (repinned from `5731cec22a1fd29efe02d4dc21c2a57e655ecb47` of 2026-05-23)
**Bennett.jl HEAD commit at pin time:**
`Bennett-7kzr + Bennett-jefu: docs refresh — README architectural limits + drift fixes`

## Repin rationale (2026-05-26)

`git diff --stat 5731cec…ecb47 877341e…9486` shows ONLY docs/beads
deltas. Zero `src/` changes. Specifically:

- `CLAUDE.md`: 10-line delta.
- `README.md`: 53-line delta (architectural-limits documentation).
- `worklog/075_…md`: new file, retrospective.
- `.beads/`: routine tracker churn.

`ParsedIR` (`Bennett.jl/src/ir_types.jl`), `IRBasicBlock`, `IRInst`,
the LLVM extractor, `lower_circuit`, `target=:circuit` dispatch — all
unchanged at the source level. Phase-2 integration (Handoff A) is
therefore unaffected; repin is safe.

Bd issue `bennettvm-18b` closes with this commit.

## Phase-0 scope

The spike does NOT integrate with Bennett.jl (PRD §5.2). This pin is
recorded now so PRD v4 has a concrete baseline to design Phase-2
integration against.

## Phase-2 integration boundary

Phase 2 consumes Bennett.jl through a *documented IR interface*, not
internal API surfaces. The exact integration boundary (which IR
Bennett.jl emits; whether it emits RSSA directly or BennettVM lowers
a less-reversible IR) is PRD v4 open question §VIII.2.

## Repinning policy

- Phase 0: no repin (spike is standalone).
- Phase 1 (post-spike, pre-v4): repin only if the retrospective surfaces
  a concrete integration concern that requires a newer Bennett.jl.
- Phase 2: repin at v4 ratification; record new SHA in this file with
  date and the Bennett.jl HEAD commit summary.

## How to check the pin is intact

```bash
cd ../Bennett.jl
git rev-parse 877341ec388004a69636ac4530d4d9abf2439486   # must resolve
git log --oneline 877341e -1
# expected: 877341e Bennett-7kzr + Bennett-jefu: docs refresh — README architectural limits + drift fixes
```

If the SHA is unreachable (Bennett.jl history rewrite, GC), file a
beads issue immediately — losing the pinned base breaks reproducibility.
