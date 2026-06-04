# Bennett.jl version pin

Per PRD v3 §7.5 and CLAUDE.md Rule 14, BennettVM.jl pins Bennett.jl
during initial development to insulate against frontend churn.

**Pinned SHA:** `231bde6` (jfw6: Case A hardening — fail-loud cond_skel + P-callee)
**Pinned date:** 2026-06-04 (repinned from `b234496` of 2026-06-02)
**Bennett.jl HEAD commit at pin time:**
`fix(jfw6): Case A hardening — fail-loud cond_skel + P-callee (Bennett-bal6/msob)`

## Repin rationale (2026-06-04)

SC9 Case A (dynamic `Vector`) landed its front-end recognition arm in Bennett.jl
`src/extract/vector_vm*.jl` (5 new files) + routing in `module_walk.jl` (the
`mem=:vm` Case A branch) + `ir_extract.jl` includes (ADR 0016; bead `Bennett-jfw6`
+ hardening `Bennett-bal6`/`msob`). The recognizer strips the Julia
GC/GenericMemory skeleton at `optimize=false` and emits the language-neutral
`IRAlloca(dyn)+IRVarGEP+IRLoad/IRStore` ParsedIR that BennettVM ingest consumes, so
BennettVM's `test/test_vec_vm_roundtrip.jl` MUST run against a Bennett.jl that
defines it — repinned to `231bde6`. Additive (`mem=:auto`/`:heap`/`:persistent` and
Case-B-Dict byte-identical — the routing is gated behind `mem===:vm` + a Vector
recognition check). Validation at pin: BennettVM full `Pkg.test` **4722/4722**
(orchestrator-verified, fresh subprocess). The dynamic Julia `Vector{T}(undef,n)` +
indexed loop now round-trips e2e under `target=:reversible_vm`. Rule-14 Bennett.jl
`src/` change under standing user approval (2026-06-04). Also at this SHA: the
route-(b) Dict decision record (`Bennett-800b` note + reversible-VM PRD callout;
BennettVM ADR 0015) and the cross-repo opcode-coverage beads (BG1–BG5, `xv0u`).

## Repin rationale (2026-06-02)

SC9 Case B (Dict) landed its front-end recognition arm in Bennett.jl
`src/extract/dict_vm.jl` + three new `IRInst` types (`IRMapInsert`/
`IRMapGet`/`IRMapDelete`) in `ir_types.jl`, fed by the new `mem=:vm`
extraction mode (`module_walk.jl` / `entry.jl`). BennettVM's ingest now
consumes those `IRMap*` ParsedIR nodes, so BennettVM MUST test against a
Bennett.jl that defines them — repinned to `b234496`. Additive change
(`mem=:auto`/`:heap`/`:persistent` byte-identical). Validation at pin:
Bennett.jl full `Pkg.test` 688504 Pass / 1 pre-existing Broken; BennettVM
full suite 4558/4558. The `setindex!` write side + VM-side reversible map
are proven (`test/test_dict_roundtrip.jl` Parts A+B); the bare-`fdict`
read is blocked on an inlined-`getindex` recogniser (bead `bennettvm-9i1`
/ Bennett-800b read-side). Rule-14 Bennett.jl `src/` change made under
explicit user approval (2026-06-02).

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
