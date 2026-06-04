# ADR 0016 — Case A `mem=:vm` Memory recognizer design (Julia `Vector` → `IRAlloca(dyn)+IRVarGEP+IRLoad/IRStore`)

> Status: **ACCEPTED** (2026-06-04). Synthesized from a Rule-6 Core 2+1 design
> pass (two independent Opus designers, "minimal-sound" + "robust/general")
> against the REAL LLVM IR of a dynamic-`Vector` function (`/tmp/fvec_O0.ll`
> vs `/tmp/fvec_O2.ll`). The linchpin of the opcode-coverage epic
> (`bennettvm-x49`): unlocks Case A (`bennettvm-xkl`) and, generalized, Case B
> (`bennettvm-tu9`). Front-end bead `Bennett-jfw6`; the BennettVM ingest side
> (`bennettvm-m9i`) is **already proven on the C `frtN.ll`** — this ADR is the
> Bennett.jl recognizer that makes Julia `Vector` IR isomorphic to that proven
> shape.

## Context

`mem=:auto`/`:heap` reject a dynamic `Vector{T}(undef,n)` at the GC/TLS wall.
The recognizer must strip Julia's GC/GenericMemory skeleton and emit the
language-neutral `IRAlloca(dyn)+IRVarGEP+IRLoad/IRStore` shape BennettVM
ingests. The existing `:heap` recognizer is hardwired for the OPPOSITE
(constant-N, loop-free, single-block collapse); this is a *generalization*.

## Decisions

**D1 — Extract at `optimize=false` (O0); hard-reject O2.** The `-O2` IR is a
*different program*: the optimizer deletes the read-back loop, SIMD-vectorizes
the write loop to `store <4 x i64>`, and computes the return from
`llvm.vector.reduce.add` over induction values (no memory read at all). It is
not recognizable as a `Vector` program and must not be. The recognizer pins to
O0 and **fails loud** on any `VectorType` store/load/phi, any
`llvm.vector.reduce.*`/`llvm.smul.with.overflow.*` callee, or the
`vector.body`/`middle.block`/`scalar.ph` block signature. (Mirrors the proven C
path: `frtN.ll` is clang `-O0`.) This is the #1 silent-miscompile guard.

**D2 — A PARTITION recognizer, not purely subtractive.** Unlike `:heap` M1
(where the whole skeleton is *dead*), the element data is **live into the
return**. Every instruction is positively classified into exactly one of
{dropped GC-machinery, recognized-and-re-rooted element traffic, passed-through
user computation, terminator}; anything unclassified **rejects loud**
(closed-world, the `dict_vm.jl` pattern). heap.jl's soundness obligations are
**generalized to the partition**: P-return (no *dropped* value is a
ret-ancestor; a *re-rooted* element load MAY be), P-escape, P-noload-into-live,
P-callee allowlist.

**D3 — Reuse heap.jl machinery (Law 2).** Reuse `_heap_is_allowlisted_tls_asm`,
the taint seed+closure, `_heap_return_ancestors`, `_collapse_bounds_diamond`,
`_assert_memory_layout` (Julia-1.12/x86-64 version pin), and the M2/M3 re-root
pattern — but re-root element traffic onto a **`DynAlloca` base** (simpler than
M2's const-N synthetic alloca).

**D4 — `n_elems` is the element COUNT, triple-witnessed (NOT the byte size).**
Emit `IRAlloca(dest, elem_width, n_elems=SSAOperand(%n))` reading the count from
the Memory **length-field store** (`store i64 %n, <mem+offset>`), cross-checked
against the `smul(%n, stride_bytes)` byte size and the source `%n`. Disagreement
→ fail loud. A wrong choice (using the byte size) over-allocates `stride×` and
the `DynAlloca` `(base,n)` retract reverses the wrong region.

**D5 — `julia.gc_loaded` is a 2-arg identity launder** (value = the element-data
pointer). The MemoryRef chain + `gc_loaded` + the Memory-header GEPs are
DROPPED; the element address is re-rooted onto the `DynAlloca` base. The callee
shape (arity, which arg is the data pointer) is asserted; any other shape →
fail loud. **Law 1: confirm `gc_loaded` semantics against a local Julia source
before writing the rewrite — do not paraphrase from memory.**

**D6 — Byte-offset → element-index uses the RECOGNIZED stride, never a hardcoded
÷8.** The cell-addressed VM wants the element index (one cell/element, `VarGEP`
stride 1). Recover it as `byte_offset ÷ stride_bytes`, where `stride_bytes` is
read from BOTH the `mul %offset, K` and the GEP source element width and
asserted equal. Hardcoding ÷8 miscompiles i8/i32 (the same class as the `b5x`
IRPtrOffset trap). Non-even division (a sub-element/struct field) → fail loud
(that is the BG3/U16 path).

**D7 — Preserve the multi-block loop CFG.** Case A must NOT collapse to a single
block (the `:heap`/Dict behavior). Recommended: reuse the existing generic
second-pass walker with two hooks — **suppress** `inst ∈ skel` (the existing
`sret_writes.suppressed` idiom) and **rewrite** the recognized
alloc/GEP-chain/store/load to their `IR*` forms; everything else
(loop φ, `add`/`icmp`/`sub`, back-edges) flows through unchanged, producing the
multi-block ParsedIR natively. **All hooks gated behind `mem === :vm` so `:auto`
stays byte-identical** (the deciding risk; flagged for the implementer).
Skeleton-conditioned diamonds collapse; real user branches (loop exit) are kept.
φ incomings from dropped-skeleton predecessor edges are dropped.

**D8 — Case A ships on SINGLE dynamic array; Case B needs `uil` first.** The
frozen-base single-dynamic-array floor (`alloca.jl`) holds ONE region. A Dict
has TWO GenericMemory backings (keys + vals), so **Case B route-(b)
(`bennettvm-tu9`/`7xa`) is BLOCKED on the multi-dynamic-array runtime bump
pointer (`bennettvm-uil`)** — Case A is not. Design the recognizer parameterized
over "the set of recognized backings," but do not let Case B's two-backing need
bloat Case A. Hash arithmetic (`IRBinOp`/`IRCast`) and the `KeyError`
diamond reuse the generic walker + diamond-collapse; no new primitive (ADR 0015).

## Fail-loud matrix (the non-negotiables — Rule 1/2)

Reject loud, never miscompile: O2/`VectorType`/vector-reduce (D1); any
instruction the closed-world partition can't classify; a dropped value that is a
ret-ancestor (P-return); a dropped store to non-skeleton/non-global memory
(P-escape); a kept load reading a dropped store (P-noload); non-allowlisted
callee or inline-asm (P-callee — allowlist: `jl_alloc_genericmemory_unchecked`,
`julia.gc_loaded`, `julia.gc_alloc_obj` AND `ijl_gc_small_alloc`,
`julia.get_pgcstack`, `j_throw_boundserror`, `jl_argument_error`,
`llvm.memcpy/memset/lifetime`); `invoke`/`callbr`/`atomicrmw`/`cmpxchg`/`fence`;
≥2 `jl_alloc_genericmemory_unchecked` (→ `uil`); `gc_loaded`/MemoryRef of
unexpected shape; layout/version drift.

## Test plan

Positive (round-trip from Julia source under `target=:reversible_vm`, mirroring
`test_dyn_roundtrip.jl`): `vec_undef(n)=Vector{Int8}(undef,n)`+write loop (the
gate); `fvec(n)` Int64 write+read+reduce (golden-master vs the irreversible
oracle, then `unrun!`→empty history); an Int32 variant (proves D6 stride);
**structural cross-check** that the Julia ParsedIR is congruent to the proven C
`frtN.ll` ingest. Adversarial (must fail loud): `optimize=true` `fvec` (D1); two
Vectors (→`uil`); a Vector escaping into `push!`/`@noinline` (P-callee); nested
loop (multi-block). Mutation-proof (Rule 5): flip the element-store
classification skeleton↔traffic → confirm RED → restore.

## Open questions resolved at implementation

- **Q1 (gating):** does Bennett.jl's extract reach the recognizer at
  `optimize=false`, or is `optimize=true` hardwired? If the latter, threading an
  `optimize=false` path for `mem=:vm` is a prerequisite (Rule 14). *Determines
  whether Case A from Julia source works at all today.*
- **Q2:** allocator symbol differs O0 (`julia.gc_alloc_obj`) vs O2
  (`ijl_gc_small_alloc`) — allowlist both (moot if D1 forces O0, but keep).
- **Q3 (Law 1):** confirm `julia.gc_loaded` identity-launder semantics from a
  local Julia source before the D5 rewrite.

## Refs

ADR 0013 §D-2 (store floor), ADR 0015 (Dict route-b), ADR 0009/0014 (DynAlloca,
memory floor). Bennett.jl `src/extract/heap.jl` (reuse), `dict_vm.jl` (the
`mem=:vm` partition+fail-loud pattern), `module_walk.jl` (routing, reject ~198),
`instructions.jl` (~2118-2511, TLS ~2103), `ir_types.jl`. BennettVM
`src/ir/ingest.jl` (`_lower_alloca!`), `array_index.jl`, `alloca.jl`,
`test_dyn_roundtrip.jl` (the proven `frtN` gate). The 2+1 design pass
(2026-06-04) against `/tmp/fvec_{O0,O2}.ll`. Beads `Bennett-jfw6`,
`bennettvm-m9i`, `bennettvm-xkl`, `bennettvm-tu9`, `bennettvm-uil`.
