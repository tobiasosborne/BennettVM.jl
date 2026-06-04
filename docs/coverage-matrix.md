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
| 5 | `IRInsertValue` (:115) | — | falls through to `else` at ingest.jl:370 | **GAP** | test_opcode_coverage.jl (GAP assertion only) |
| 6 | `IRCast` (:126) | `CastInstruction` (sext/zext/trunc) | `_lower_body_inst` ingest.jl:248 | **COVERED** | test_opcode_coverage.jl, test_cast_instruction.jl, test_matrix_tri_roundtrip.jl |
| 7 | `IRPtrOffset` (:144) | — | falls through to `else` at ingest.jl:370 | **GAP** | test_opcode_coverage.jl (GAP assertion only) |
| 8 | `IRVarGEP` (:150) | `VarGEP(dest, base, index, stride=1)` | `_lower_body_inst` ingest.jl:283 | **COVERED** | test_opcode_coverage.jl, test_array_floor.jl, test_alloca_delta.jl, test_vec_vm_roundtrip.jl + 4 more |
| 9 | `IRLoad` (:157) | `MemoryLoad(dest, ptr_name)` | `_lower_body_inst` ingest.jl:271 | **COVERED** | test_opcode_coverage.jl, test_array_floor.jl, test_memory_floor.jl, test_memory_floor_cll.jl + 5 more |
| 10 | `IRStore` (:172) | `MemoryStore(ptr_name, val)` | `_lower_body_inst` ingest.jl:257 | **COVERED** | test_opcode_coverage.jl, test_array_floor.jl, test_memory_floor.jl, test_memory_floor_cll.jl + 5 more |
| 11 | `IRAlloca` (:262) | `Define(dest, base, :add, 0)` (static-N) or `DynAlloca(dest, n, base)` (dynamic-N) | `_lower_alloca!` ingest.jl:423; dispatched in body loop at ingest.jl:789 | **COVERED** | test_opcode_coverage.jl, test_array_floor.jl, test_alloca_delta.jl, test_memory_floor.jl + 6 more |
| 12 | `IRExtractValue` (:273) | — | falls through to `else` at ingest.jl:370 | **GAP** | test_opcode_coverage.jl (GAP assertion only) |
| 13 | `IRCall` (:281) | `SoftCall(dest, callee_name, args, arg_widths, ret_width)` for `soft_f*` callee; non-soft callee raises via `SoftCall` allowlist | `_lower_body_inst` ingest.jl:309 | **COVERED** (soft_f* only) | test_opcode_coverage.jl, test_fp_roundtrip.jl, test_softcall.jl, test_operators.jl |
| 14 | `IRBranch` (:314) | `ConditionalExit` / `UnconditionalExit` + critical-edge trampoline block | `_successors` ingest.jl:503; exit marker in `_lower_parsed_ir` ingest.jl:829 | **COVERED** | test_opcode_coverage.jl |
| 15 | `IRSwitch` (:320) | *(pre-expanded by frontend)* | `_successors` else-arm ingest.jl:512 (fail-loud if it ever arrives) | **N/A** | runtests.jl (doc note), test_opcode_coverage.jl (fail-loud belt-and-suspenders) |
| 16 | `IRPhi` (:334) | block parameter in `ConditionalEntry` / `UnconditionalEntry` params | `_collect_phi_params` + `_phi_incoming_for_edge` + returns `nothing` in `_lower_body_inst` ingest.jl:368 | **COVERED** | test_opcode_coverage.jl, test_dyn_roundtrip.jl |
| 17 | `IRMapInsert` (:214) | `BennettVM.IRMapInsert(key, value)` — reversible-map insert; L2 `(key,prior)` delta | `_lower_body_inst` ingest.jl:340 | **COVERED** | test_opcode_coverage.jl, test_dict_roundtrip.jl, test_revmap_roundtrip.jl, test_revmap.jl |
| 18 | `IRMapGet` (:231) | `BennettVM.IRMapGet(dest, key)` — reversible-map read; L3 baseline | `_lower_body_inst` ingest.jl:356 | **COVERED** | test_opcode_coverage.jl, test_dict_roundtrip.jl, test_revmap_roundtrip.jl, test_revmap.jl |
| 19 | `IRMapDelete` (:248) | `BennettVM.IRMapDelete(key)` — reversible-map delete; L2 `(key,old)` delta | `_lower_body_inst` ingest.jl:363 | **COVERED** | test_opcode_coverage.jl, test_dict_roundtrip.jl, test_revmap.jl |

## Tally

**15 COVERED / 3 GAP / 1 N/A** (total 19).

COVERED: `IRBinOp`, `IRICmp`, `IRSelect`, `IRRet`, `IRCast`, `IRVarGEP`,
`IRLoad`, `IRStore`, `IRAlloca` (static + dynamic-N VLA), `IRCall` (soft_f*
→ `SoftCall`; non-soft callee raises via the `_SOFT_DISPATCH` allowlist),
`IRBranch`, `IRPhi`, `IRMapInsert`, `IRMapGet`, `IRMapDelete`.

GAP: `IRInsertValue`, `IRPtrOffset`, `IRExtractValue`.

N/A: `IRSwitch` (pre-expanded by `_expand_switches` in Bennett.jl
`extract/module_walk.jl` before `ParsedIR` is returned; never reaches
BennettVM; fail-loud if it somehow arrives as a terminator).

## Fail-loud sites (GAP rows)

All three GAP subtypes are non-terminator body instructions. They reach the
shared fail-loud `else` branch at the bottom of `_lower_body_inst`:

- **`IRInsertValue`** — `src/ir/ingest.jl:370–381`
  Error message: `"lower_vm: unsupported IRInst body subtype Bennett.IRInsertValue — the slice handles IRBinOp / IRICmp / …"` (interpolates `typeof(inst)`).

- **`IRPtrOffset`** — `src/ir/ingest.jl:370–381`
  Error message: same `else`-arm message; also named in the deferred note at
  ingest.jl:268 and ingest.jl:380 (`"IRPtrOffset / IRExtractValue are deferred (Rule 1)."`).

- **`IRExtractValue`** — `src/ir/ingest.jl:370–381`
  Error message: same `else`-arm message; also named in the deferred note at
  ingest.jl:380.

All three are asserted in `test/test_opcode_coverage.jl` (rows 5, 7, 12):
each test calls `_coverage_raise` with a hand-built `ParsedIR` fragment and
asserts `e isa ErrorException` plus `occursin("<TypeName>", e.msg)`.

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
