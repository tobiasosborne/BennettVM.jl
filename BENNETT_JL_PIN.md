# Bennett.jl version pin

Per PRD v3 §7.5 and CLAUDE.md Rule 14, BennettVM.jl pins Bennett.jl
during initial development to insulate against frontend churn.

**Pinned SHA:** `5731cec22a1fd29efe02d4dc21c2a57e655ecb47`
**Pinned date:** 2026-05-23
**Bennett.jl HEAD commit at pin time:**
`worklog/075: cumulative measurement + 1eyg hotfix retrospective`

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
git rev-parse 5731cec22a1fd29efe02d4dc21c2a57e655ecb47   # must resolve
git log --oneline 5731cec -1
# expected: 5731cec worklog/075: cumulative measurement + 1eyg hotfix retrospective
```

If the SHA is unreachable (Bennett.jl history rewrite, GC), file a
beads issue immediately — losing the pinned base breaks reproducibility.
