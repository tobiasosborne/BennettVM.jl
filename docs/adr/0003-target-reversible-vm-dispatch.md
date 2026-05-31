# ADR 0003 — `target = :reversible_vm` dispatch surface (the keystone)

> Status: **PROPOSED** (2026-05-31). The consensus design from the Bennett-spqu
> research + design phase (BennettVM bead `bennettvm-a5j` ↔ Bennett.jl
> `Bennett-spqu`). Implementation of the Bennett.jl `src/` half is **gated on
> per-diff user approval (Rule 14)** and follows Bennett.jl's 3+1 + worklog +
> `bd dolt push` conventions, NOT BennettVM's. BennettVM pin `7915299`;
> Bennett.jl HEAD `7904560` (re-pin from `877341e` is docs-only-safe).

## Context — the keystone gap

`reversible_compile(f; target = :reversible_vm)` — the user-facing entry the
whole VM backend exists for — **does not exist in Bennett.jl today**. Verified
against source (3 independent read-only research agents, 2026-05-31):

- `target=` is an **optimization objective**, not a backend selector. It is a
  `CompileOptions` field defaulting to `:gate_count`
  (`Bennett.jl/src/Bennett.jl:145`), validated against `(:gate_count, :depth)`
  at `Bennett.jl/src/lowering/driver.jl:34-35`, and consumed only to flip
  `mul=:auto → :qcla_tree` when `:depth` (`driver.jl:39`). There is **no
  `:circuit` symbol**, no `:vm`, no `:reversible_vm` anywhere in `src/`.
- `BennettVM/BENNETT_JL_PIN.md`'s claim that a "`target=:circuit` dispatch"
  exists is **FALSE/aspirational** — it describes the post-keystone state, not
  the current source. (Side-fix below.)

The frontend is already shared and the consumer half already works: BennettVM
ingests a `Bennett.ParsedIR` via `lower_vm(parsed)::VMProgram`
(`BennettVM/src/lower_vm.jl:72`) and the `.ll`/`.bc` route
(`extract_parsed_ir_from_ll` → `lower_vm`) round-trips end-to-end today (SC9
Cases A/C/D). **Only the Julia-function dispatch arm is missing.**

Per Bennett-spqu (`Bennett.jl/Bennett-ReversibleVM-PRD.md` §3, §8): the front-end
is fully shared and "the two targets diverge only at the `lower`/`bennett`
stage." Per the cross-repo handoff §3 and PRD v4 §VIII.2: **the design phase
should RATIFY the contract BennettVM already implements, not redesign it.**

## Decision

### D1 — Canonical symbol: `:reversible_vm` (with `:circuit` for the existing path)

`target = :reversible_vm` selects the VM backend. Every normative document
(Bennett-spqu §5/§9, PRD v4 throughout, `src/BennettVM.jl` docstring, the
`call_instruction.jl` user-facing error messages) uses `:reversible_vm`; `:vm`
is diagram shorthand only (CLAUDE.md/README ASCII). We pin `:reversible_vm`.

`target=` thereby carries **two axes at once** (backend × objective): today's
`:gate_count`/`:depth` mean *circuit backend, that objective*; `:reversible_vm`
means *VM backend* (the VM does not gate-count-optimize, so the objective axis
is moot on that path). This overloading is **explicitly what Bennett-spqu §5
mandates** ("a new value of the existing `target=` dispatch"). (Alternative
considered: a separate `backend=` kwarg leaving `target=` purely objective —
cleaner axis separation, but diverges from the PRD's explicit direction;
rejected unless the user prefers it.)

**`:circuit` alias — DEFERRED to doc-only for v1 (hostile-review fix).**
Wiring `target=:circuit` as a working symbol requires a `:circuit → :gate_count`
normalization on *every* path that reaches `lower()`'s whitelist (`driver.jl:34`
rejects `:circuit` today) **and** the tabulate short-circuits — three sites. To
keep the Rule-14 Bennett.jl diff minimal and focused, v1 does NOT add the
`:circuit` symbol; `:gate_count`/`:depth` remain literally byte-unchanged
(satisfying Bennett-spqu §9's "circuit path unchanged" in substance). `:circuit`
stays a documentation alias; a follow-up bead wires it if the user wants the
symbol. So v1's accepted `target=` set is `{:gate_count, :depth, :reversible_vm}`.

### D2 — Dispatch mechanism: a registration hook (NOT a direct call; NOT a circular dep)

**`BennettVM` depends on `Bennett`** (`BennettVM/Project.toml [deps]`). Therefore
Bennett.jl's `reversible_compile` **cannot call `BennettVM.lower_vm` directly** —
adding `BennettVM` to Bennett.jl's `[deps]` makes `Bennett ⇄ BennettVM` a
circular hard dependency, which Julia's package resolver forbids. (This is the
load-bearing constraint the literal "call BennettVM.lower_vm" framing in the
cross-repo handoff §3 missed.)

Resolution — a **registration hook** matching the dependency direction
(BennettVM reaches *up* into Bennett; Bennett never names BennettVM):

```julia
# Bennett.jl/src/Bennett.jl (core) — Bennett never references BennettVM.
const _REVERSIBLE_VM_BACKEND = Ref{Any}(nothing)

# in reversible_compile(parsed::ParsedIR; ...), BEFORE the lower()+bennett() block:
if target === :reversible_vm
    _REVERSIBLE_VM_BACKEND[] === nothing && error(
        "reversible_compile(target=:reversible_vm) requires the BennettVM " *
        "backend to be loaded: `using BennettVM` registers it. (Bennett.jl " *
        "does not depend on BennettVM — the VM backend plugs in; see " *
        "BennettVM ADR 0003.)")
    return _REVERSIBLE_VM_BACKEND[](parsed)   # → VMProgram
end
```

```julia
# BennettVM/src/BennettVM.jl — ADD an __init__ (none exists today). It runs at
# load time (not precompile), so assigning into Bennett's Ref is legal; `import
# Bennett` (already present) makes the name reachable. Idempotent under Revise.
function __init__()
    Bennett._REVERSIBLE_VM_BACKEND[] = lower_vm
end
```

**The intercept must catch the tabulate short-circuits (hostile-review fix —
the "single funnel" is NOT single).** `reversible_compile(f, ::Type)` has two
paths that `return bennett(lr)` BEFORE delegating to the `ParsedIR` overload:
explicit `strategy=:tabulate` (`src/Bennett.jl:337-344`) and `:auto` picking
tabulate for small-width mul/div (`:363-368`, `tabulate.jl`). If the intercept
lived ONLY in the `ParsedIR` overload, a small mul/div function compiled with
`target=:reversible_vm` would **silently return a circuit** (Rule-1 fail-silent).
Fix: guard BOTH tabulate short-circuits with `target !== :reversible_vm` (so a
VM compile falls through to the `:380` `ParsedIR` delegation where the intercept
fires), AND keep the intercept in `reversible_compile(parsed::ParsedIR)` (which
also covers users who call the `ParsedIR` overload directly). Net: the
`:reversible_vm` branch is unreachable by any circuit short-circuit.

Notes: the `Ref` is **write-once at `__init__`, lock-free read** (set before any
user compile; no data race with `_compile_cache_lock`). Type-piracy
(`function Bennett.reversible_compile(...)` defined in BennettVM) is rejected —
it would invalidate Bennett.jl's precompiled methods on `using BennettVM`; the
`Ref` hook avoids that.

Alternative considered: a **package extension** (`Bennett.jl` declares
`[weakdeps] BennettVM` + `ext/BennettVMExt.jl`). More "idiomatic Julia ≥1.9",
but it inverts the conceptual dependency direction (Bennett.jl's Project.toml
would name BennettVM) and adds the weakdep-of-a-package-that-depends-on-you
subtlety. The hook is simpler, keeps Bennett.jl's manifest free of any BennettVM
reference, and matches the architecture (the VM is the downstream plug-in).
**This is the primary design fork for user sign-off.**

### D3 — Return type: `Union{ReversibleCircuit, VMProgram}` at the boundary

`target=:reversible_vm` returns a `VMProgram` (BennettVM type), not a
`ReversibleCircuit`. The caller asked for `:reversible_vm`, so receiving a
`VMProgram` is self-consistent (the `simulate`/`verify_reversibility` circuit
API does not apply to a VM program). The `reversible_compile(parsed)` return
type widens to `Union{ReversibleCircuit, VMProgram}` on that one method.
**Cache:** the existing `_compile_cache::Dict{Tuple,ReversibleCircuit}`
(`Bennett.jl/src/Bennett.jl:401`) is typed for circuits; the `:reversible_vm`
arm **bypasses that cache** (returns before the `lock(_compile_cache_lock)`
block) in v1 — VM-program memoization is a later bead if profiling warrants it.

### D4 — Handoff-A contract (RATIFIED, not redesigned)

Bennett.jl emits a `Bennett.ParsedIR` (`src/ir_types.jl:347`): fields
`ret_width, args::Vector{(Symbol,Int)}, blocks::Vector{IRBasicBlock},
ret_elem_widths, globals, memssa, synth_ptr_provenance`. Structural guarantees:
`blocks[1]` is entry; `IRSwitch` is pre-expanded to `IRBranch`/`IRICmp` before
return (never reaches BennettVM); `IRPhi` only at join-block heads (classical
SSA); exactly one `IRBranch`/`IRRet` terminator per block; user-path operands
are `SSAOperand`/`ConstOperand` only.

BennettVM consumes it via `lower_vm(parsed::Bennett.ParsedIR; opts=nothing)
::VMProgram`. **In-scope IRInst subtypes (11, at HEAD `7915299`):** `IRBinOp`,
`IRICmp`, `IRSelect`, `IRRet`, `IRCast`, `IRBranch`, `IRPhi` (→ block param),
`IRAlloca` (static + dynamic VLA), `IRStore`, `IRLoad`, `IRVarGEP`. `IRSwitch`
N/A (pre-expanded). **Out-of-scope (4, raise loudly):** `IRInsertValue`,
`IRExtractValue`, `IRPtrOffset`, `IRCall`. **Known divergences (NOT part of the
ratified contract; deferred beads):** (i) width-masking — `IState.locals` are
`Int64`, arithmetic is not masked to the IRInst `width` (bead `bgc`; oracle
agreement holds for in-range inputs, round-trip is width-independent);
(ii) `IRLoad`/`IRStore` are realised as BennettVM-internal L2-delta history
(ADR 0014), not the RSSA `Exchange` form PRD §3.7 originally framed.

### D5 — Process for the Bennett.jl `src/` change (Bennett.jl conventions, NOT BennettVM's)

Both touched files (`src/Bennett.jl`, and the `:reversible_vm` whitelist entry —
either in `driver.jl:34` or bypassed) are **core**, so Bennett.jl's **3+1**
applies (2 independent proposers + implementer + reviewer). Plus: per-diff user
approval (Rule 14); `Bennett-<id>:` commit prefix + a `worklog/NNN_*.md` session
block; `bd dolt push` (not JSONL); `.beads/embeddeddolt/` bundled in the same
commit; **no LOC limit**; `Pkg.test()` (~28 min) green; single-file tests
`--check-bounds=yes`. A new Bennett.jl bead (child of `Bennett-spqu`) carries it.

## Side-fixes surfaced (BennettVM-side, no Rule-14)

0. **PREREQUISITE — strip/gate `lower_vm`'s stdout digest** (hostile-review
   fix). `src/lower_vm.jl:80-84` unconditionally `println`s a 5-line "lower_vm
   digest:" block (a spike-era M0.4 debug aid). On the dispatch path EVERY VM
   compile would spam stdout (and pollute `Pkg.test()`). Gate behind `@debug`
   or a `verbose=false` kwarg before wiring the hook — a library entry point
   must be quiet.
1. `BENNETT_JL_PIN.md`: correct the false "`target=:circuit` dispatch exists"
   claim (it does not, pre-keystone). Re-pin `877341e → 7904560` (docs-only).
2. `docs/coverage-matrix.md`: stale — shows `IRCast`/`IRAlloca`/`IRStore`/
   `IRLoad`/`IRVarGEP` as GAP; all are DONE at HEAD. Update to 11 DONE / 4 GAP /
   1 N/A.
3. Pin `:reversible_vm` as canonical in CLAUDE.md/README ASCII diagrams (they
   say `:vm`).

## Consequences

- Unlocks `reversible_compile(f, target=:reversible_vm)` for **Julia functions**
  (the `.ll` route already works without it), which in turn unlocks FP-in-VM
  (SoftFloat callees) and Dict-in-VM on Julia inputs once those land.
- Bennett.jl's circuit path is **byte-unchanged** (Bennett-spqu §9): the hook is
  inert until `using BennettVM` sets the `Ref`; `:gate_count`/`:depth` behave
  exactly as before.
- The hook's `Ref{Any}` is a small dynamic-dispatch boundary; acceptable for a
  once-per-compile call. VM-program caching deferred.

## Refs

- Research (2026-05-31, 3 read-only agents): dispatch surface
  (`Bennett.jl/src/Bennett.jl:145,269,450,470`; `src/lowering/driver.jl:34-39`);
  Handoff-A contract (`Bennett.jl/src/ir_types.jl:347`; `BennettVM/src/ir/
  ingest.jl`, `src/lower_vm.jl:72`); mandate (`Bennett-ReversibleVM-PRD.md`
  §3/§5/§8/§9).
- `Bennett.jl/Bennett-ReversibleVM-PRD.md` (Bennett-spqu) — the direction PRD.
- `bennettvm_prd.md` (PRD v4) §3.7 (Handoff A/B/C), §VIII.2 (boundary open).
- `docs/CROSS_REPO_HANDOFF.md` §1/§3/§5/§6/§7.
- CLAUDE.md Law 2 (reuse — ratify the contract), Rule 14 (per-diff approval).
