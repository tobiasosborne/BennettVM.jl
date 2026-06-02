# BennettVM IRInst coverage matrix (M_OPCODE.1)

> Audit deliverable for bd `bennettvm-34c`. Originally verified against
> Bennett.jl pin `877341e` and BennettVM `e9dfd7f`, 2026-05-28.
> **Refreshed 2026-05-31 (ADR 0003 side-fix 2) against BennettVM HEAD
> `7915299`:** the memory quintet partially landed — `IRAlloca` (static +
> dynamic VLA), `IRStore`, `IRLoad`, `IRVarGEP`, and `IRCast` are now
> **DONE**; only `IRPtrOffset` remains of the original quintet. Tally at
> that refresh: 11 DONE / 4 GAP / 1 N/A, matching ADR 0003 §D4.
> **Updated 2026-06-02 (M_FP.2, bead `bennettvm-8ox`):** `IRCall`
> (soft_f* → `SoftCall`) moved GAP→DONE — new tally **12 DONE / 3 GAP /
> 1 N/A** (see body tally below). Mirrors PRD v4 §3.6.1
> (maximum-LLVM-opcode-coverage north-star).

## The taxonomy

Bennett.jl defines **16** concrete `IRInst` subtypes (the bead's "17 at
pin 5731cec" was off by one). Source: `Bennett.jl/src/ir_types.jl`
(grep `<: IRInst`). BennettVM's ingest (`src/ir/ingest.jl`) dispatches on
these in `_lower_body_inst` (line 202), `_successors` (line 416), and the
per-block `_lower_alloca!` (line 337, for `IRAlloca`).

| # | IRInst (ir_types.jl:line) | BennettVM counterpart | Status | Notes |
|---|---|---|---|---|
| 1 | `IRBinOp` (:58) | `Define(dest, lhs, op, rhs)` | **DONE** | 13 binops; ingest.jl:165 |
| 2 | `IRICmp` (:74) | `Define` w/ comparison op | **DONE** | `COMPARISON_OPERATORS` (operators.jl); ingest.jl:168 |
| 3 | `IRSelect` (:89) | `SelectInstruction` (2-to-1 MUX) | **DONE** | ingest.jl:171; pointer-typed (width=0) untested |
| 4 | `IRRet` (:105) | `EndInstruction(routine,[retval])` | **DONE** | ingest.jl:237/409; const-return raises loudly |
| 5 | `IRInsertValue` (:115) | — | **GAP** | aggregate insert (sret); needs multi-lane slot |
| 6 | `IRCast` (:126) | `CastInstruction` | **DONE** | sext/zext/trunc; non-destructive width-cast SSA-create; ingest.jl:223 (ADR 0013 §D-5) |
| 7 | `IRPtrOffset` (:144) | — | **GAP (mem)** | static byte offset; → `Define` address arithmetic. Last of the original memory quintet still open. |
| 8 | `IRVarGEP` (:150) | `VarGEP` | **DONE** | runtime-index GEP → cell-address create `dest := base + index*1`; ingest.jl:258 (ADR 0009 Decision 2b) |
| 9 | `IRLoad` (:157) | `MemoryLoad` | **DONE** | plain non-injective heap read (zero-init read); ingest.jl:246 (ADR 0014 §D2) |
| 10 | `IRStore` (:172) | `MemoryStore` | **DONE** | plain non-injective heap write; L2-delta history; ingest.jl:232 (ADR 0014 §D2) |
| 11 | `IRAlloca` (:187) | bump-allocator cursor | **DONE** | static + dynamic-N (VLA) seeding `IState.memory`; `_lower_alloca!` ingest.jl:337 (ADR 0014 §D1) |
| 12 | `IRExtractValue` (:198) | — | **GAP** | aggregate extract; multi-value returns |
| 13 | `IRCall` (:206) | `SoftCall` | **DONE** (soft_f*) | (a) SoftFloat wrappers (`soft_f*`) → `SoftCall`, non-destructive bit-pattern create; ingest.jl IRCall arm (ADR 0011 §D1, M_FP.2 / `bennettvm-8ox`). (b) general (non-soft) callee inline still raises loud via the `SoftCall` allowlist → separate milestone |
| 14 | `IRBranch` (:239) | `Conditional`/`UnconditionalExit` + trampoline | **DONE** | critical-edge split; `_successors` ingest.jl:416 (ADR 0012 §D4) |
| 15 | `IRSwitch` (:245) | *(pre-expanded by frontend)* | **N/A** | `_expand_switches` (module_walk.jl:262) rewrites every switch to IRICmp/IRBranch **before** ParsedIR is returned — never reaches BennettVM. No work needed. |
| 16 | `IRPhi` (:259) | block param + critical-edge trampoline | **DONE** | φ-resolution; ingest.jl:284/394 (Mogensen RSSA §3) |

**Tally (M_FP.2, bead `bennettvm-8ox`):** **12 DONE** (`IRBinOp`, `IRICmp`,
`IRSelect`, `IRRet`, `IRCast`, `IRBranch`, `IRPhi`, `IRAlloca`
[static+dynamic], `IRStore`, `IRLoad`, `IRVarGEP`, `IRCall` [soft_f* →
`SoftCall`]), **3 GAP** (`IRInsertValue`, `IRExtractValue`, `IRPtrOffset`),
**1 N/A** (`IRSwitch`, frontend-pre-expanded). The 2026-05-28 audit recorded
6 DONE / 9 GAP; the deltas since are `IRCast` (ADR 0013), four of the five
memory-quintet opcodes (`IRAlloca`/`IRStore`/`IRLoad`/`IRVarGEP`; ADR
0009/0014), and `IRCall` for `soft_f*` callees (ADR 0011, M_FP.2). The
remaining gaps are **`IRPtrOffset`** (last of the memory quintet), the
**aggregates** (`IRExtractValue`/`IRInsertValue`), and the **non-soft
`IRCall`** (general callee inline, a separate milestone — the soft_f* path
is DONE).

## Frontend reachability (the load-bearing finding)

A coverage gap is only reachable if `Bennett.extract_parsed_ir` produces
a `ParsedIR` containing that opcode. Verified this session:

- **Arithmetic + control flow** (`IRBinOp`/`IRICmp`/`IRSelect`/`IRRet`/
  `IRBranch`/`IRPhi`): reachable. `collatz_steps` (Case D) and the
  `while`-form `matrix_sum` (Case C, ADR 0010) extract and round-trip.
- **Width casts** (`IRCast`, ADR 0013): reachable; the width-mixing
  triangular nested loop extracts and round-trips.
- **Heap** (`IRAlloca`/`IRStore`/`IRLoad`/`IRVarGEP`): the BennettVM
  *ingest* path is DONE (ADR 0009/0014; static + dynamic-N alloca,
  cell-addressed GEP, L2-delta store/load). But Julia's native
  `Dict`/growable-`Vector` is **NOT reachable** through the Julia-function
  entry of `extract_parsed_ir` — GC allocation emits a thread-local
  GC-frame read (`call ptr asm "movq %fs:0,$0"` / `julia.get_pgcstack`)
  that the extractor rejects at
  `Bennett.jl/src/extract/instructions.jl:2103` (`Bennett-5oyt / U15`).
  `Dict` is additionally rejected by design (`Bennett-800b`). This holds
  for `mem=:auto`, `mem=:persistent`, and `optimize=false` alike. The
  memory opcodes are exercised today via the `.ll`/`.bc` route (SC9 Case
  A); **reaching them from Julia source is a Bennett.jl-frontend concern,
  not a BennettVM ingest gap.**

## Remaining gap priorities (HEAD `7915299`)

`IRCast` and four of the five memory-quintet opcodes have since landed
(see tally). The four open gaps, in priority order:

1. **`IRPtrOffset`** — static byte offset; the last of the original
   memory quintet. → `Define` address arithmetic over the cell-addressed
   bump allocator. Completes general GEP-chain support alongside the
   landed `IRVarGEP`.
2. **`IRExtractValue`/`IRInsertValue`** — aggregate/multi-value returns
   (sret); needs a multi-lane slot model.
3. **`IRCall`** — SoftFloat sub-case → M_FP; general callee inline → its
   own milestone.

## Refs

- `Bennett.jl/src/ir_types.jl` (the 16 subtypes); `module_walk.jl:262`
  (`_expand_switches`); `extract/instructions.jl:2103` (GC-frame reject).
- `src/ir/ingest.jl` (`_lower_body_inst`:164, `_successors`:230).
- PRD v4 §3.6.1 (coverage north-star), §3.6.2 (Cases A–D); ADR 0012
  (collatz lowering), ADR 0010 (nested loops).
- `MemoryInterchange`/`MemoryAssignment`/`MemorySwap`:
  `src/ir/memory_instructions.jl`. Vieri 1995 (PISA exchange-memory).
