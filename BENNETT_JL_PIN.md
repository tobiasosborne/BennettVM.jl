# Bennett.jl version pin

Per PRD v3 §7.5 and CLAUDE.md Rule 14, BennettVM.jl pins Bennett.jl
during initial development to insulate against frontend churn.

**Pinned SHA:** `f73a5ed` (Bennett-33zr: target=:reversible_vm dispatch arm)
**Pinned date:** 2026-05-31 (repinned from `877341ec388004a69636ac4530d4d9abf2439486` of 2026-05-26)
**Bennett.jl HEAD commit at pin time:**
`Bennett-33zr: target=:reversible_vm dispatch arm — registration hook to BennettVM`

## Repin rationale (2026-05-31)

The keystone (bead `bennettvm-a5j` / ADR 0003) landed the `target=:reversible_vm`
dispatch arm in Bennett.jl `src/Bennett.jl` (the registration-hook `Ref` +
intercept + tabulate guards). BennettVM's `__init__` now writes `lower_vm` into
`Bennett._REVERSIBLE_VM_BACKEND`, so BennettVM MUST be tested against a Bennett.jl
that defines that `Ref` — repinned to `f73a5ed`. (The dep is a path dep,
`../Bennett.jl`, so the working tree is authoritative; this SHA documents the
tested-against commit.) Bennett.jl full `Pkg.test` GREEN at `f73a5ed`
(688498 Pass / 2 pre-existing Broken / 0 fail); BennettVM full suite GREEN with
the `__init__` active.

## Repin rationale (2026-05-26)

`git diff --stat 5731cec…ecb47 877341e…9486` shows ONLY docs/beads
deltas. Zero `src/` changes. Specifically:

- `CLAUDE.md`: 10-line delta.
- `README.md`: 53-line delta (architectural-limits documentation).
- `worklog/075_…md`: new file, retrospective.
- `.beads/`: routine tracker churn.

`ParsedIR` (`Bennett.jl/src/ir_types.jl`), `IRBasicBlock`, `IRInst`,
the LLVM extractor, `lower_circuit` — all unchanged at the source
level. Phase-2 integration (Handoff A) is therefore unaffected; repin
is safe.

> **Correction (2026-05-31, ADR 0003 side-fix 1).** Earlier revisions of
> this file referred to a `target=:circuit` *dispatch* in Bennett.jl.
> That is **false** pre-keystone. Verified against
> `Bennett.jl/src/lowering/driver.jl:34`: `target` is whitelisted against
> `(:gate_count, :depth)` only — there is **no `:circuit` symbol, no
> `:vm`/`:reversible_vm` symbol, and no `target=`-based backend
> dispatch** anywhere in `Bennett.jl/src/`. `target=` is purely an
> **optimization objective** (`:gate_count` default; `:depth` flips
> `mul=:auto → :qcla_tree`), not a backend selector. The backend-dispatch
> arm (`target=:reversible_vm` → the VM, `:gate_count`/`:depth` → the
> circuit) is introduced by the keystone, not present today. The pinned
> SHA below does **not** change with this correction; **the pin SHA
> updates with the `target=:reversible_vm` keystone (bead `bennettvm-a5j`
> / ADR 0003)**, when the Bennett.jl `src/` hook lands under Rule 14.

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
