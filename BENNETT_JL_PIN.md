# Bennett.jl version pin

Per PRD v3 §7.5 and CLAUDE.md Rule 14, BennettVM.jl tracks a nominated
Bennett.jl commit during initial development to insulate against frontend
churn.

**How the dependency actually resolves.** BennettVM does *not* pin a git
revision. `Manifest.toml` carries a Julia **path / dev dependency**
(`[[deps.Bennett]] … path = "../Bennett.jl"`), so every build and test run
compiles against **whatever is currently checked out in the sibling
`../Bennett.jl` working tree** — never against a frozen SHA. The "pin"
recorded below is therefore **documentary**: it names the last Bennett.jl
commit this repo was validated against, so a reader can
`git -C ../Bennett.jl checkout <sha>` to reproduce a known-good state.
Keeping `../Bennett.jl` at (or additively ahead of) the recorded commit is a
convention, not a lockfile guarantee — the Manifest imposes no revision
constraint.

**Last validated against:** `13ce767` (Bennett-klgz: determinism classifier at the JIT-global reject)
**Validated date:** 2026-07-24 (previously `13ce767` of 2026-07-12; `e7454fd`/`fd4afea` same day; before that `31b63a6` of 2026-06-05)
**Bennett.jl HEAD commit summary at validation:**
`Bennett-a70z: exact constant-operand overflow bit — Dict{Int64,Int64} extracts and runs`
**Validation evidence:** BennettVM full `Pkg.test` **7820/7820** against this
exact Bennett.jl tree (2026-07-24, 3m33s); Bennett.jl suite **690398 Pass /
3 Broken** (all pre-existing — `@test_broken` counts byte-identical to the
pre-merge `main`), 28m37s, **heavy tests ON** (a strictly stronger gate than
the previous entry's `BENNETT_HEAVY_TESTS=0`).

> ⚠️ **Read the BVM number carefully — it went DOWN (9848 → 7820) and that is
> environmental, not a regression.** The 2026-07-12 validation ran on the
> `/home/tobias` box; this one ran on `/home/tobiasosborne`, where **clang is
> not installed** (rustc is). The clang-gated e2e blocks therefore self-skip
> per the documented T5-corpus convention (`test_global_array_vm.jl:81`
> `Sys.which("clang")`, `runtests.jl:656`), and `test_fast_mode.jl`'s E0 MVP
> sub-testset is opt-in (`BENNETTVM_MVP_TESTS=1`). a70z only ADDED a test file
> (+347) and cannot reduce counts. **Consequence: a "full suite green" from
> this box is ~20 % weaker than one from the pinned box, and only two easily
> missed `@info` lines say so.** Tracked as `bennettvm-5o86` (install clang
> and/or make the suite print a loud skipped-block banner).

**Repin rationale (2026-07-24).** `Bennett-a70z` made the front-end emit a new
instruction *combination* on the `ptr_cells` path — up to 2 `IRICmp`
(`:slt`/`:sgt`/`:ult`/`:ugt`) fused by a width-1 `IRBinOp(:or)` — where it
previously either emitted a constant-zero bit or failed loud. No new IR node
type and no BVM source change was required: the shapes ingest as ordinary
`Define`s. Verified end-to-end rather than argued — `Dict{Int64,Int64}` lowers
to a 552-block `VMProgram`, runs 664 steps to `fdict64(3,7) == 7`, and
`unrun!`s to the exact initial state with empty history under both L2 and L3
(`test/test_a70z_dict64_roundtrip.jl`, 347 assertions, mutation-proved).
Residual: the *one-sided* and *both-constant* emission shapes are not yet
exercised downstream (the real Dict corpus only produces the two-sided shape)
— tracked as `Bennett-tl1l`.

## Repin rationale (2026-06-05)

`Bennett-xv0u` added an additive `elem_width::Int` field to `IRPtrOffset`
(`src/ir_types.jl`) so the cell-addressed BennettVM recovers the element index
from the byte offset (`index = offset_bytes ÷ (elem_width÷8)`); the circuit
backend keeps using `offset_bytes` as bytes and ignores the field. BennettVM
`bennettvm-b5x` adds the `lower_vm` ingest arm that consumes it, so BennettVM
`test/test_ptroffset.jl` REQUIRES a Bennett.jl defining the field — repinned to
`31b63a6`. Additive (the circuit backend and all other `mem` modes are
byte-identical; all 8 IRPtrOffset construction sites updated). Validation at
pin: Bennett.jl full `Pkg.test` 688515 Pass / 1 pre-existing Broken; BennettVM
full `Pkg.test` **6450/6450** (path dep, orchestrator-verified, fresh
subprocess). Rule-14 `src/` change under standing cross-repo user approval
(2026-06-05). Also at this SHA: a `_narrow_inst` pass-through for `IRPtrOffset`
and a documented `mem=:heap` `offset_bytes`-holds-element-index quirk (a P3
reconciliation bead filed).

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

## How to check the last-validated commit still resolves

Because the dependency is a path dep, there is nothing to "unpin" — the
build always uses the current `../Bennett.jl` checkout regardless of the SHA
below. This check only confirms the last-validated commit is still reachable
so a known-good state can be reproduced:

```bash
cd ../Bennett.jl
git rev-parse 31b63a6efe6acf0636faf26499d530509f3635f7   # must resolve
git log --oneline 31b63a6 -1
# expected: 31b63a6 feat(xv0u): IRPtrOffset preserves elem_width for cell-addressed BennettVM (b5x)
```

If the SHA is unreachable (Bennett.jl history rewrite, GC), file a
beads issue immediately — losing the last-validated base breaks
reproducibility.
