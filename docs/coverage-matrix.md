# BennettVM IRInst coverage matrix (M_OPCODE.1)

> Audit deliverable for bd `bennettvm-34c`. Verified against Bennett.jl
> pin `877341e` (current HEAD) and BennettVM `e9dfd7f`, 2026-05-28.
> Mirrors PRD v4 §3.6.1 (maximum-LLVM-opcode-coverage north-star).

## The taxonomy

Bennett.jl defines **16** concrete `IRInst` subtypes (the bead's "17 at
pin 5731cec" was off by one). Source: `Bennett.jl/src/ir_types.jl`
(grep `<: IRInst`). BennettVM's ingest (`src/ir/ingest.jl`) dispatches on
these in `_lower_body_inst` (line 164) and `_successors` (line 230).

| # | IRInst (ir_types.jl:line) | BennettVM counterpart | Status | Notes |
|---|---|---|---|---|
| 1 | `IRBinOp` (:58) | `Define(dest, lhs, op, rhs)` | **DONE** | 13 binops; ingest.jl:165 |
| 2 | `IRICmp` (:74) | `Define` w/ comparison op | **DONE** | `COMPARISON_OPERATORS` (operators.jl); ingest.jl:168 |
| 3 | `IRSelect` (:89) | `SelectInstruction` (2-to-1 MUX) | **DONE** | ingest.jl:171; pointer-typed (width=0) untested |
| 4 | `IRRet` (:105) | `EndInstruction(routine,[retval])` | **DONE** | ingest.jl:237/409; const-return raises loudly |
| 5 | `IRInsertValue` (:115) | — | **GAP** | aggregate insert (sret); needs multi-lane slot |
| 6 | `IRCast` (:126) | — | **GAP (P1)** | sext/zext/trunc; **blocks width-mixing programs** (e.g. the triangular nested loop). Highest-value non-memory gap. |
| 7 | `IRPtrOffset` (:144) | — | **GAP (mem)** | static byte offset; → `Define` address arithmetic |
| 8 | `IRVarGEP` (:150) | — | **GAP (mem)** | runtime-index GEP; → `Define` address chain |
| 9 | `IRLoad` (:157) | (`MemoryInterchange`) | **GAP (mem)** | reversible load = exchange (Vieri/PISA); primitive exists, ingest path doesn't |
| 10 | `IRStore` (:172) | (`MemoryAssignment` / `MemoryInterchange`) | **GAP (mem)** | in-place modop store OR exchange-store; primitives exist, ingest path doesn't |
| 11 | `IRAlloca` (:187) | — | **GAP (mem)** | stack/heap alloc; seeds `IState.memory`; static + dynamic-n |
| 12 | `IRExtractValue` (:198) | — | **GAP** | aggregate extract; multi-value returns |
| 13 | `IRCall` (:206) | — | **GAP** | (a) SoftFloat wrappers → M_FP; (b) general callee inline → separate milestone |
| 14 | `IRBranch` (:239) | `Conditional`/`UnconditionalExit` + trampoline | **DONE** | critical-edge split; ingest.jl:231 (ADR 0012 §D4) |
| 15 | `IRSwitch` (:245) | *(pre-expanded by frontend)* | **N/A** | `_expand_switches` (module_walk.jl:262) rewrites every switch to IRICmp/IRBranch **before** ParsedIR is returned — never reaches BennettVM. No work needed. |
| 16 | `IRPhi` (:259) | block param + critical-edge trampoline | **DONE** | φ-resolution; ingest.jl:185/207 (Mogensen RSSA §3) |

**Tally:** 6 DONE, 1 N/A (`IRSwitch`), 9 GAP. The bead guessed the gaps
were `IRPhi`/`IRSwitch`/`IRSelect`; in fact those are DONE (collatz,
ADR 0012) or frontend-handled. The real gaps are **IRCast**, the
**memory quintet** (`IRAlloca`/`IRLoad`/`IRStore`/`IRPtrOffset`/`IRVarGEP`),
the **aggregates** (`IRExtractValue`/`IRInsertValue`), and **IRCall**.

## Frontend reachability (the load-bearing finding)

A coverage gap is only reachable if `Bennett.extract_parsed_ir` produces
a `ParsedIR` containing that opcode. Verified this session:

- **Arithmetic + control flow** (the 6 DONE rows): reachable. `collatz_steps`
  (Case D, done) and the `while`-form `matrix_sum` (Case C, ADR 0010)
  extract and round-trip.
- **Heap (the memory quintet)**: Julia's native `Dict`/growable-`Vector`
  is **NOT reachable** through the Julia-function entry of
  `extract_parsed_ir` — GC allocation emits a thread-local GC-frame read
  (`call ptr asm "movq %fs:0,$0"` / `julia.get_pgcstack`) that the
  extractor rejects at `Bennett.jl/src/extract/instructions.jl:2103`
  (`Bennett-5oyt / U15`). `Dict` is additionally rejected by design
  (`Bennett-800b`). This holds for `mem=:auto`, `mem=:persistent`, and
  `optimize=false` alike. **Reaching the memory quintet from Julia source
  is a Bennett.jl-frontend concern, not a BennettVM ingest gap.**

## Gap priorities

1. **`IRCast`** — immediate, frontend-reachable, blocks width-mixing
   programs (the triangular nested loop needs it). No architecture
   dependency. (M_OPCODE.2.)
2. **The memory quintet** (`IRAlloca`/`IRLoad`/`IRStore`/`IRPtrOffset`/
   `IRVarGEP`) — the **critical path for SC9 Cases A (dynamic memory) &
   B (Dict)**. The reversible primitives largely exist already
   (`MemoryInterchange` = reversible load/L1; `MemoryAssignment` =
   in-place store/L2; zero-init convention reused from Bennett.jl's
   persistent map). Gated on the **language-agnostic reversible-memory
   architecture ADR** (in progress) and a Bennett.jl-side change to emit
   Julia heap as universal `alloca`/`load`/`store`/`getelementptr` ops.
   This is where BennettVM's reason-to-exist is delivered.
3. **`IRExtractValue`/`IRInsertValue`** — aggregate/multi-value returns.
4. **`IRCall`** — SoftFloat sub-case → M_FP; general callee → its own
   milestone.

## Refs

- `Bennett.jl/src/ir_types.jl` (the 16 subtypes); `module_walk.jl:262`
  (`_expand_switches`); `extract/instructions.jl:2103` (GC-frame reject).
- `src/ir/ingest.jl` (`_lower_body_inst`:164, `_successors`:230).
- PRD v4 §3.6.1 (coverage north-star), §3.6.2 (Cases A–D); ADR 0012
  (collatz lowering), ADR 0010 (nested loops).
- `MemoryInterchange`/`MemoryAssignment`/`MemorySwap`:
  `src/ir/memory_instructions.jl`. Vieri 1995 (PISA exchange-memory).
