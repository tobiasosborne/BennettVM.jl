# BennettVM IRInst coverage matrix

> Mirrors PRD v4 §3.6.1 (maximum-LLVM-opcode-coverage north-star).
> Verified 2026-06-04 against Bennett.jl `ir_types.jl` (all 19 `IRInst`
> subtypes read by hand) and BennettVM `src/ir/ingest.jl` (every dispatch
> arm and fail-loud site read by hand). Sources: `Bennett.jl/src/ir_types.jl`
> and `BennettVM.jl/src/ir/ingest.jl`.

## The taxonomy

Bennett.jl defines **19** concrete `IRInst` subtypes (verified by reading
`Bennett.jl/src/ir_types.jl` from the `abstract type IRInst` declaration
through all `struct … <: IRInst` definitions): 16 base opcodes plus the 3
language-neutral reversible-map ops (`IRMapInsert`/`IRMapGet`/`IRMapDelete`)
added in M_DICT (SC9 Case B, ADR 0008/0013).

BennettVM's ingest (`src/ir/ingest.jl`) dispatches on these subtypes in
three places:

- `_lower_body_inst` (line 217) — non-terminator body instructions
- `_lower_alloca!` (line 423) — `IRAlloca` (needs bump-allocator state, so
  dispatched in the body loop at line 789, not in `_lower_body_inst`)
- `_successors` (line 503) — terminator instructions only (`IRBranch` / `IRRet`)

The final `else` of `_lower_body_inst` (ingest.jl:370–381) is the shared
GAP fail-loud site for all unhandled non-terminator subtypes. It interpolates
`typeof(inst)` into the error message so the subtype name is always present.

## Coverage table

| Row | IRInst (ir_types.jl:line) | BennettVM Phase-2 construct | Lowering fn | Status | Test coverage |
|-----|---------------------------|-----------------------------|-------------|--------|---------------|
| 1 | `IRBinOp` (:58) | `Define(dest, lhs, op, rhs)` | `_lower_body_inst` ingest.jl:218 | **COVERED** | test_opcode_coverage.jl, test_define.jl, test_memory_floor.jl, test_memory_floor_cll.jl, test_operators.jl |
| 2 | `IRICmp` (:74) | `Define` w/ comparison predicate | `_lower_body_inst` ingest.jl:231 | **COVERED** | test_opcode_coverage.jl, test_define.jl |
| 3 | `IRSelect` (:89) | `SelectInstruction` (2-to-1 MUX) | `_lower_body_inst` ingest.jl:234 | **COVERED** | test_opcode_coverage.jl, test_select.jl |
| 4 | `IRRet` (:105) | `EndInstruction(routine, [retval])` | exit-marker in `_lower_parsed_ir` ingest.jl:822 | **COVERED** | test_opcode_coverage.jl + 12 other test files |
| 5 | `IRInsertValue` (:115) | N × `Define` per-slot family (`_agg_<dest>_slot<k>`) | body-loop special case in `_lower_parsed_ir` (ArrayType `[N x iW]` only) | **COVERED** | test_opcode_coverage.jl, test_aggregate_extract_insert.jl |
| 6 | `IRCast` (:126) | `CastInstruction` (sext/zext/trunc) | `_lower_body_inst` ingest.jl:248 | **COVERED** | test_opcode_coverage.jl, test_cast_instruction.jl, test_matrix_tri_roundtrip.jl |
| 7 | `IRPtrOffset` (:144) | — | falls through to `else` at ingest.jl:370 | **GAP** | test_opcode_coverage.jl (GAP assertion only) |
| 8 | `IRVarGEP` (:150) | `VarGEP(dest, base, index, stride=1)` | `_lower_body_inst` ingest.jl:283 | **COVERED** | test_opcode_coverage.jl, test_array_floor.jl, test_alloca_delta.jl, test_vec_vm_roundtrip.jl + 4 more |
| 9 | `IRLoad` (:157) | `MemoryLoad(dest, ptr_name)` | `_lower_body_inst` ingest.jl:271 | **COVERED** | test_opcode_coverage.jl, test_array_floor.jl, test_memory_floor.jl, test_memory_floor_cll.jl + 5 more |
| 10 | `IRStore` (:172) | `MemoryStore(ptr_name, val)` | `_lower_body_inst` ingest.jl:257 | **COVERED** | test_opcode_coverage.jl, test_array_floor.jl, test_memory_floor.jl, test_memory_floor_cll.jl + 5 more |
| 11 | `IRAlloca` (:262) | `Define(dest, base, :add, 0)` (static-N) or `DynAlloca(dest, n, base)` (dynamic-N) | `_lower_alloca!` ingest.jl:423; dispatched in body loop at ingest.jl:789 | **COVERED** | test_opcode_coverage.jl, test_array_floor.jl, test_alloca_delta.jl, test_memory_floor.jl + 6 more |
| 12 | `IRExtractValue` (:273) | `Define(dest, _agg_<agg>_slot<index>, :add, 0)` (slot copy) | `_lower_body_inst` IRExtractValue arm (ArrayType `[N x iW]` only) | **COVERED** | test_opcode_coverage.jl, test_aggregate_extract_insert.jl |
| 13 | `IRCall` (:281) | `SoftCall(dest, callee_name, args, arg_widths, ret_width)` for `soft_f*` callee; non-soft callee raises via `SoftCall` allowlist | `_lower_body_inst` ingest.jl:309 | **COVERED** (soft_f* only) | test_opcode_coverage.jl, test_fp_roundtrip.jl, test_softcall.jl, test_operators.jl |
| 14 | `IRBranch` (:314) | `ConditionalExit` / `UnconditionalExit` + critical-edge trampoline block | `_successors` ingest.jl:503; exit marker in `_lower_parsed_ir` ingest.jl:829 | **COVERED** | test_opcode_coverage.jl |
| 15 | `IRSwitch` (:320) | *(pre-expanded by frontend)* | `_successors` else-arm ingest.jl:512 (fail-loud if it ever arrives) | **N/A** | runtests.jl (doc note), test_opcode_coverage.jl (fail-loud belt-and-suspenders) |
| 16 | `IRPhi` (:334) | block parameter in `ConditionalEntry` / `UnconditionalEntry` params | `_collect_phi_params` + `_phi_incoming_for_edge` + returns `nothing` in `_lower_body_inst` ingest.jl:368 | **COVERED** | test_opcode_coverage.jl, test_dyn_roundtrip.jl |
| 17 | `IRMapInsert` (:214) | `BennettVM.IRMapInsert(key, value)` — reversible-map insert; L2 `(key,prior)` delta | `_lower_body_inst` ingest.jl:340 | **COVERED** | test_opcode_coverage.jl, test_dict_roundtrip.jl, test_revmap_roundtrip.jl, test_revmap.jl |
| 18 | `IRMapGet` (:231) | `BennettVM.IRMapGet(dest, key)` — reversible-map read; L3 baseline | `_lower_body_inst` ingest.jl:356 | **COVERED** | test_opcode_coverage.jl, test_dict_roundtrip.jl, test_revmap_roundtrip.jl, test_revmap.jl |
| 19 | `IRMapDelete` (:248) | `BennettVM.IRMapDelete(key)` — reversible-map delete; L2 `(key,old)` delta | `_lower_body_inst` ingest.jl:363 | **COVERED** | test_opcode_coverage.jl, test_dict_roundtrip.jl, test_revmap.jl |

## Tally

**17 COVERED / 1 GAP / 1 N/A** (total 19).

COVERED: `IRBinOp`, `IRICmp`, `IRSelect`, `IRRet`, `IRCast`, `IRVarGEP`,
`IRLoad`, `IRStore`, `IRAlloca` (static + dynamic-N VLA), `IRCall` (soft_f*
→ `SoftCall`; non-soft callee raises via the `_SOFT_DISPATCH` allowlist),
`IRBranch`, `IRPhi`, `IRMapInsert`, `IRMapGet`, `IRMapDelete`,
`IRInsertValue` (ArrayType `[N x iW]` → per-slot `Define` family),
`IRExtractValue` (ArrayType `[N x iW]` → slot copy).

GAP: `IRPtrOffset`.

N/A: `IRSwitch` (pre-expanded by `_expand_switches` in Bennett.jl
`extract/module_walk.jl` before `ParsedIR` is returned; never reaches
BennettVM; fail-loud if it somehow arrives as a terminator).

## Aggregate coverage scope (rows 5 / 12 — bead `bennettvm-acq`)

`IRInsertValue` / `IRExtractValue` are emitted by Bennett.jl ONLY for
homogeneous scalar-element **ArrayType** `[N x iW]` aggregates; StructType
aggregates fail loud UPSTREAM in Bennett.jl extract (U10 / Bennett-tu6i), so
they never reach BennettVM. BennettVM models an aggregate SSA value as a
FAMILY of N synthetic per-slot keys (`_agg_<name>_slot<k>`), since
`IState.locals` is a flat `Dict{Symbol,Int64}`. `insertvalue` rebuilds the
family via N non-destructive `Define`s; `extractvalue` reads one slot. This
scopes **scalar-consumed** aggregates — a RETURNED `[N x iW]` aggregate is
DEFERRED: the IRRet aggregate-return guard fails loud (the multi-key return
keyed off `ret_elem_widths` is the follow-on bead).

## Fail-loud sites (GAP / deferred rows)

`IRPtrOffset` is the sole remaining GAP subtype — a non-terminator body
instruction reaching the shared fail-loud `else` branch at the bottom of
`_lower_body_inst`:

- **`IRPtrOffset`** — the shared `_lower_body_inst` `else` arm.
  Error message: `"lower_vm: unsupported IRInst body subtype Bennett.IRPtrOffset — …"` (interpolates `typeof(inst)`); IRPtrOffset is named in the `else`-arm deferred note.

A RETURNED aggregate (`IRInsertValue` / `IRExtractValue` build-up dangling
into `IRRet`) hits the ingest IRRet aggregate-return guard, which fails loud
naming the deferral (`"… returning a `[N x iW]` aggregate is DEFERRED (bead
`bennettvm-acq` …)"`).

These are asserted in `test/test_opcode_coverage.jl` (row 7) and
`test/test_fail_loud_completeness.jl` (F2 IRPtrOffset; F2 deferred aggregate
IRRet): each builds a hand-built `ParsedIR` fragment and asserts
`e isa ErrorException` plus the cause-naming `occursin`.

The N/A case (`IRSwitch` as a terminator) has its own fail-loud site at
`_successors` ingest.jl:512–515:
`"lower_vm: unsupported terminator subtype … — the M_UNBOUNDED slice (ADR 0012) handles IRBranch / IRRet only (Rule 1)."`.

## Notes on N/A (IRSwitch)

`IRSwitch` is pre-expanded by `_expand_switches` (Bennett.jl
`extract/module_walk.jl`) into `IRICmp`/`IRBranch` chains before `ParsedIR`
is returned. BennettVM consumes Bennett.jl only through the `ParsedIR`
interface (Rule 14) and does not verify this frontend invariant at runtime.
The belt-and-suspenders fail-loud in `_successors` (ingest.jl:512) fires if
a malformed handoff or a future frontend regression passes an `IRSwitch` as
a block terminator.

## Refs

- `Bennett.jl/src/ir_types.jl` — all 19 `IRInst` subtypes (lines cited per row)
- `src/ir/ingest.jl` — `_lower_body_inst` (line 217), `_lower_alloca!`
  (line 423), `_successors` (line 503), shared GAP `else` (line 370)
- `src/lower_vm.jl` — `lower_vm` entry point delegating to `_lower_parsed_ir`
- `test/test_opcode_coverage.jl` — executable mirror of this matrix (bead `bennettvm-d7t`)
- PRD v4 §3.6.1 (coverage north-star); ADR 0009, 0011, 0012, 0013, 0014
