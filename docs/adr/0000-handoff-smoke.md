# ADR 0000 — Bennett.jl Handoff-A Smoke

**Status:** Accepted (M0 closed 2026-05-26).

**Date:** 2026-05-26.

**Bead:** `bennettvm-8g1` (M0.4) — depends on M0.1 / M0.2 / M0.3.

**PRD anchor:** PRD v4 §3.7 (Handoff A — `ParsedIR` is the input
contract), §6 SC1 (BennettVM package exists and loads against a real
`ParsedIR`), §3.6.2 Case D (`collatz_steps` — the SC9 motivating case
this ADR digests).

**Bennett.jl pin:** `877341e` (per `BENNETT_JL_PIN.md`; supersedes the
v4-authoring-time pin `5731cec` — diff is docs-only, see commit
`156dfdc`).

---

## Motivation

PRD v4 §3.7 specifies that BennettVM consumes Bennett.jl through a
**documented IR interface** — specifically `Bennett.ParsedIR`. M0 is
the milestone that proves the interface holds *before* any Phase-2
IR design (M2.x) goes near it. The deliverable is a four-field
digest of a real motivating-case `ParsedIR`, captured under the
current Bennett.jl pin, with field-by-field cross-reference against
the v4 §3.7 assumptions.

This ADR exists so that future M2.x sub-agents can ground their
design decisions in **observed** ParsedIR shape, not in
"what the PRD said the shape should be". Law 1 self-applied to the
upstream contract.

## What was done (chain of evidence)

| Bead | Milestone | Artifact |
|---|---|---|
| `bennettvm-fgd` | M0.1 | `Project.toml`, `src/BennettVM.jl` skeleton, `Pkg.develop(path="../Bennett.jl")` succeeds. |
| `bennettvm-i61` | M0.2 | `src/ir/VMProgram.jl` stub + `src/lower_vm.jl` digest function. |
| `bennettvm-c72` | M0.3 | `test/test_handoff_smoke.jl` exercising `lower_vm` on `collatz_steps(::Int8)`. `Pkg.test()` is 18/18. |
| `bennettvm-8g1` | M0.4 | **This file.** |

## The digest

Captured 2026-05-26 against Bennett.jl pin `877341e` from
`/home/tobias/Projects/BennettVM.jl/test/test_handoff_smoke.jl`. The
`collatz_steps` body is verbatim from
`/home/tobias/Projects/Bennett.jl/test/test_y986_loop_header_dispatch.jl:129-140`:

```julia
function collatz_steps(x::Int8)
    steps = Int8(0); val = x
    while val > Int8(1) && steps < Int8(20)
        if val % Int8(2) == Int8(0)
            val = val >> Int8(1)
        else
            val = Int8(3) * val + Int8(1)
        end
        steps += Int8(1)
    end
    return steps
end
```

Piped through `lower_vm` it emits:

```
lower_vm digest:
  blocks       = 3
  instructions = 17
  args         = [8]
  returns      = [8]
```

Returned: `VMProgram(blocks=3, instructions=17)`.

## ParsedIR shape (observed vs v4 §3.7)

Field-by-field cross-reference against the contract in `Bennett.jl/
src/ir_types.jl:347-372`. All assumptions held.

| ParsedIR field | Type | Value for `collatz_steps(::Int8)` | Surprises |
|---|---|---|---|
| `ret_width` | `Int` | `8` | None — Bennett.jl returns Int8 → 8 bits, as v4 §3.7 expects. |
| `args` | `Vector{Tuple{Symbol, Int}}` | `[(Symbol("n::Int8"), 8)]` | The argument name carries the **Julia type tag** as part of the symbol (`"n::Int8"`, not just `"n"`). This is a Bennett.jl convention not called out in v4 §3.7. M2.x must strip / ignore the tag if it wants the bare variable name. |
| `blocks` | `Vector{IRBasicBlock}` | 3 entries: `:top`, `:L8`, `:L46` | None — block count and ordering match v4 §3.7's "LLVM-derived CFG" wording. |
| `ret_elem_widths` | `Vector{Int}` | `[8]` | None — scalar return decomposes to a 1-element width vector. |
| `globals` | `Dict{Symbol, Tuple{Vector{UInt64}, Int}}` | empty `Dict` | None — `collatz_steps` has no globals. M3.x will exercise this field on `fdict` (Case A). |
| `memssa` | `Union{Nothing, MemSSAInfo}` | `nothing` | None — register-only function. `Nothing` is the documented zero value. |
| `synth_ptr_provenance` | `Set{Tuple{Symbol, Int, Int}}` | empty `Set` | None. |

**Bottom-line surprises:** one. The argument name carries the Julia
type tag inside the `Symbol`. Documented here so M2.x doesn't
discover it by accident.

## Block-level observations

```
Block 1 :top — 1 non-terminator + 1 terminator = 2 instructions
Block 2 :L8  — 12 non-terminator + 1 terminator = 13 instructions
Block 3 :L46 — 1 non-terminator + 1 terminator = 2 instructions
Total: 17 (matches digest)
```

This is the classical SSA loop-CFG decomposition:

- **`:top`** — entry. Computes the loop predicate, conditional
  branch into `:L8` (body) or `:L46` (exit).
- **`:L8`** — loop body **with header** (Phi nodes at the start;
  self-loop terminator back to `:L8`).
- **`:L46`** — exit. Single Phi (the LCSSA `value_phi.lcssa`)
  combining the two reaching values, then `IRRet`.

### Instruction taxonomy actually seen

Six of Bennett.jl's ~38 LLVM opcodes appear:

| Bennett.jl `IRInst` subtype | Count | Where | What it does |
|---|---|---|---|
| `IRICmp` | 3 | `:top`, `:L8` (two of them) | Integer compare; produces an `i1` flag operand. |
| `IRBranch` | 2 (terminators) | `:top` → `:L17`/`:L7`, `:L8` → self/exit | Conditional branch on an `IRICmp` result. |
| `IRPhi` | 3 | `:L8` (two — loop-header SSA values for `val` and `steps`), `:L46` (LCSSA exit-Phi) | Block-entry Phi node; chooses an incoming value per predecessor. **CLASSICAL-SSA placement: at joins only.** |
| `IRBinOp` | 6 | `:L8` (`and`, `ashr`, `mul`, `add`, `add`) | Two-operand arithmetic with a result width. |
| `IRSelect` | 1 | `:L8` | The ternary `(cond, true_val, false_val)` for the if-then-else that picks the next `val`. |
| `IRRet` | 1 (terminator) | `:L46` | Return statement; carries the SSA operand and width. |

**No** `IRStore` / `IRLoad` / `IRCall` / `IRSwitch` / `IRCast` /
`IRGEP` / floating-point ops. `collatz_steps` is the simplest
non-trivial Case D the suite has, and it exercises ≈ 16% of
Bennett.jl's opcode surface. M_OPCODE will need broader-coverage
examples (likely `matrix_sum`, `fdict`).

## Lessons load-bearing for M2.x

These are the concrete observations that should shape the IR
foundation milestone. **M2.x sub-agents should re-read this section
before starting.**

1. **`IRPhi` placement is classical SSA — at joins only.** The
   observed Phi nodes (`:L8`'s loop-header Phis with predecessors
   `(:L8, :top)`; `:L46`'s LCSSA Phi with predecessors `(:top, :L8)`)
   are at *merge points*. RC3-style RSSA requires Phi-equivalents at
   *both joins AND splits* (Mogensen 2016 §3, confirmed in ADR 0001
   §Observations). **Implication:** M2.x lowering must synthesize a
   *split-side dual* for each `IRBranch` — an `UnconditionalExit` or
   `ConditionalExit` carrying the predicate, paired against the
   `Entry` at the destination block. The ParsedIR-side Phi alone is
   not enough.

2. **`IRSelect` is a classical-SSA pattern with no RSSA equivalent.**
   `IRSelect(cond, t, f)` in `:L8` picks between `(val >> 1)` and
   `(3*val + 1)` without branching. RSSA has no select instruction:
   the same control flow is expressed as two basic blocks with a
   `ConditionalExit` from the predecessor. **Implication:** M2.x
   needs an `IRSelect → (CondExit + two single-instruction blocks +
   CondEntry)` lowering rule. Cost is +3 blocks per `IRSelect`.

3. **`IRBranch` is the only branching terminator in this example.**
   No `IRSwitch`. This simplifies M2.7's `BasicBlock.terminator`
   field at the cost of generality — M_OPCODE must add `IRSwitch`
   coverage explicitly.

4. **The argument-name Symbol carries `::Type` tags.** Strip
   conservatively in M2.x's IR-emission code; never assume
   `parsed.args[i][1]` is a bare identifier.

5. **`memssa = nothing` for `collatz_steps` confirms the
   memory-aware path is dormant.** M3.x can develop the register-
   only interpreter against this case before flipping on `memssa`-
   driven instruction lowering (which `fdict` and `matrix_sum` will
   exercise).

## Regression-anchor contract

The four digest numbers (`3 / 17 / [8] / [8]`) are baked into
`test/test_handoff_smoke.jl` as exact-equality assertions. If a
future Bennett.jl bump changes `extract_parsed_ir`'s output for
`collatz_steps`, `Pkg.test()` goes RED on the digest assertions
*before* any M2.x or later code is exercised. The repair path is:

1. Inspect what changed: `cd ../Bennett.jl && git diff <old-pin>..HEAD -- src/extract/`.
2. Decide whether the change is benign (formatting, allocation
   reduction) or load-bearing (instruction renaming, block-layout
   shift).
3. If benign: rebaseline the test's four numbers and re-emit this
   ADR's "The digest" section with the new values. Bump the
   Bennett.jl pin and note the rebaseline in the commit message.
4. If load-bearing: open a bd issue, do the design work, *then*
   rebaseline.

Either way, the rebaselining is a conscious act, not silent
acceptance.

## Exit criterion (M0.4 / M0 close)

Per `bennettvm-8g1`:
"`docs/adr/0000-handoff-smoke.md` committed with the four-field
digest + observations; `Pkg.test()` green."  **Met.**

M0 (Bennett.jl handoff smoke) is complete. The Phase-2 IR
foundation (M2.x, ~18 chained beads) is unblocked.
