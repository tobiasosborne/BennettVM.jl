# ADR 0020 — CW-C2 front-end contract: C `.ll` modules into the closed-world VM

> **Status: ACCEPTED 2026-06-10.** Beads `bennettvm-416r.9` (CW-C2) /
> `416r.4` (CW-A3 re-scope). Cross-repo interface decision (Bennett.jl
> extract surface ↔ BVM ingest), grounded in a live probe of
> `extract_parsed_ir_from_ll` against `test/reference/c/hashtable.O0.ll`
> (scout transcript archived in the 2026-06-10 session; exact error sites:
> Bennett.jl `src/extract/instructions.jl:2031-2110` call arm,
> `:2200-2214` U16 multi-index GEP, `:2472-2475` store-ptr,
> `src/extract/helpers.jl:22-99` deref parser, `src/ir_types.jl:297-328`).

## Probe result (the failure frontier)

The three pure-i64 leaves (`demo_key`, `demo_val`, `ht_hash`) extract
cleanly TODAY. Every function touching the C heap-pointer surface fails:
`ptr` parameters (deref-attribute parser assert), `store ptr`/`load ptr`
(fail-loud / silent-nothing), two-index struct GEP (U16 reject), in-module
and libc calls (no registered callee), void calls (void-width query), and
there is no multi-function module walk at all.

## Decisions

1. **`IRCall.callee` widens to `Union{Function,Symbol}`** (Bennett.jl
   `ir_types.jl`). A `.ll` callee has only a name; BVM consumes callees by
   name already (`nameof` → `_HEAP_DISPATCH` / guard-5 function table). No
   separate `IRCallByName` type (would fork every `isa IRCall` consumer —
   Law 2). The `Function` path is byte-unchanged; the three `nameof`
   error sites branch on the union.
2. **C `ptr` parameters become opaque cell-address args** (Int64), gated
   to the no-`dereferenceable` case so the Julia NTuple-by-ref/sret model
   is untouched.
3. **`store ptr`/`load ptr` lower as 64-bit cell `IRStore`/`IRLoad`** — a
   pointer is one Int64 cell in the VM address space (ADR 0018 §A).
4. **Two-index struct GEP → `IRPtrOffset(offset_bytes, elem_width=64)`**,
   byte offsets from `LLVMOffsetOfElement`/datalayout, never IR-text
   parsing (Bennett.jl Rule 5/8).
5. **Call emission on `_lookup_callee` miss:** whitelist
   {malloc, calloc, realloc, free, memset, memcpy, memmove} → `IRCall`
   with `Symbol` callee (BVM `_HEAP_DISPATCH` route); in-module `define`d
   name → `IRCall` with `Symbol` callee (BVM guard-5 route); void returns
   carry no dest. `free` MUST be emitted (BVM models the no-op; the
   front-end must not drop it as benign).
6. **Multi-function producer:** `extract_parsed_ir_set_from_ll(path) →
   Vector{Pair{Symbol,ParsedIR}}` walking every `define`d function —
   the exact input shape BVM `lower_vm(::Vector{<:Pair{Symbol,ParsedIR}})`
   (CW-B2b) consumes.
7. **CW-A3 (globals) is OFF the C-track critical path**: both fixture
   `.ll`s contain zero global definitions; the hashtable is pure-arena.
   Globals-as-segments is driven by CW-D (Julia interned singletons) and
   reuses the existing `ParsedIR.globals` field when it lands. Bead
   `416r.4` re-scoped accordingly (not closed — deferred to CW-D
   sequencing).

## Sequencing (Bennett.jl side; O0 first, O1 deferred)

Chunk A: decisions 1+2 (type widening + ptr params).
Chunk B: decisions 3+4 (ptr store/load + struct GEP).
Chunk C: decisions 5+6 (call emission + multi-function producer) →
hand-off to CW-C3 (BVM e2e vs `GOLDEN.txt`).

Every chunk gates on: `test_gate_count_regression.jl` byte-identical
(pinned circuit baselines — i8 58 / i16 114 / i32 226 / i64 450 gates,
Toffoli 12/28/60/124), targeted extract tests, and the fixture probe
frontier advancing as predicted. The full ~65-min Bennett.jl suite runs
once before any Bennett.jl push (HANDOFF house rule;
`SKIP_PUSH_TESTS=1` after manual gating). Circuit target, `mem=:heap`,
and Julia `:auto` extraction stay byte-identical throughout.

## Reuse

`IRPtrOffset.elem_width` cell addressing (Bennett `31b63a6` / BVM `b5x`);
BVM heap-intrinsic dispatch (ADR 0018 §C) and function-table guard-5
(ADR 0019 §2) consume the emitted `IRCall`s unchanged — the front-end
meets the VM at an interface that already exists on both sides.
