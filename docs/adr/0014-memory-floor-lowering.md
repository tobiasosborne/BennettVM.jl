# ADR 0014 — Memory-floor lowering (L3 baseline; addressing model)

> Status: **ACCEPTED** (2026-05-28). Implements ADR 0013 §D-2/§D-5 (the
> reversible-memory floor). Scopes the first increment (scalar
> alloca/store/load) and locks the addressing + reversibility model.
> Defers the PRD §3.7 L1 Exchange optimization (see §Decision D2) — the
> same trace-tape-now / optimize-later pattern the lead approved for
> collatz (ADR 0012 R3; pebble-game deferred to M9).

## Context

ADR 0013 made BennettVM a reversible VM over universal LLVM opcodes. The
memory floor is the next build. Verified this session (the
emitter-agnostic proof): a **C** function compiled with `clang-18 -O0`,

```c
int through_mem(int n) { int s; s = n + 1; return s; }
```

flows through Bennett's language-agnostic `extract_parsed_ir_from_ll`
into a clean `ParsedIR` (one block):

```
IRAlloca(:__v2, 32, ConstOperand(1))   # alloca i32, 1 elem -> pointer __v2
IRAlloca(:__v3, 32, ConstOperand(1))
IRStore(ptr=__v2, value=__v1, 32)      # store n
IRLoad(:__v5, ptr=__v2, 32)            # load
IRBinOp(:__v6, :add, __v5, Const(1), 32)
IRStore(ptr=__v3, value=__v6, 32)
IRLoad(:__v8, ptr=__v3, 32)
IRRet(__v8, 32)
```

`lower_vm` raises at `IRAlloca` (the gap). `IState.memory::Dict{Int64,Int64}`
(sparse, absent-key = 0) is the heap; `==`/`hash` already include it, so
it participates in L3 snapshots.

## Decision

**D1 — Addressing: bump allocator at lowering; pointer = Int64 base in
`locals`.** Each `IRAlloca(dest, elem_width, n_elems)` is assigned a fresh
`Int64` base address by a monotonic allocator in the ingest pass; the
pointer SSA value `dest` is materialised as that address via
`Define(dest, base, :add, 0)` (a constant create — so a pointer is just an
`Int64` in `locals`, consistent with the model). `n_elems = ConstOperand(N)`
reserves `N` consecutive cells `base … base+N-1` (cells default to 0 by the
zero-init convention). Address arithmetic for `IRPtrOffset`/`IRVarGEP`
(`addr := base + offset`) is deferred to v2.

**D2 — Reversibility: L3 baseline (defers PRD §3.7 L1 Exchange).** The
store/load lowerings are **forward-correct and non-injective**, reversed
exclusively via L3 checkpoint-replay (`IState.memory` is snapshotted), NOT
via the exchange form:
- `IRStore(ptr, value)` → forward `memory[resolve(ptr)] = resolve(value)`.
- `IRLoad(dest, ptr)` → forward `locals[dest] = get(memory, resolve(ptr), 0)`.
- Both `is_injective = false`; per-instruction `inverse()` deferred (raises),
  mirroring `Define`/`Cast`/`Select`.

PRD §3.7 / ADR 0013 D-2 mandate an `IRLoad`/`IRStore` → `Exchange` (L1,
no-history) lowering with zero-ancilla. That is the *optimization* (it
removes the L3 snapshot cost). It is **deferred**: like collatz's loop
(reversed by L3 trace-tape, pebble-game deferred to M9), the memory floor
ships L3-correct first, then the L1 Exchange form lands as a perf pass.
Filed as a bead. The round-trip invariant holds either way (L3 is always
sound); only history size differs.

**D3 — Reuse vs new.** Evaluate the existing `MemoryAssignment`
(`M[a] ⊕= expr`, modop) / `MemoryInterchange` (`x := M[y] := z`, exchange)
/ `MemorySwap`. Their forward semantics are exchange/modop, not a plain
read/overwrite; if none matches the L3 plain load/store cleanly, add
dedicated `MemoryLoad`/`MemoryStore` (the `Define`/`Cast` L3 template).
The L1 Exchange optimization (deferred) is where `MemoryInterchange` is
the natural reuse.

**D4 — v1 scope:** scalar (`n_elems = 1`) `IRAlloca`/`IRStore`/`IRLoad`.
Defer: `IRPtrOffset`/`IRVarGEP` (GEP/address-arith), arrays (`N>1`),
dynamic-N alloca (`SSAOperand` n_elems — Case A's actual need), width
masking, the L1 Exchange form, aliasing guard (no aliasing in scalar v1).

**D5 — Test (the emitter-agnostic gate):** the C `through_mem` via
`extract_parsed_ir_from_ll` on a **committed `.ll`** (no clang dependency
at test time) + a hand-built `ParsedIR`. Oracle `through_mem(n) = n + 1`.
Forward result matches the oracle; round-trips to empty history under L3.

## Consequences

- **Emitter-agnosticism demonstrated end-to-end** (C → BennettVM round-trip),
  satisfying the ADR 0013 D-1 / lead directive that BennettVM be useful to
  any LLVM emitter.
- **Case A (dynamic `Vector`)** needs v2+ (GEP, arrays, dynamic-N alloca)
  AND the Bennett.jl `mem=:vm` arm (ADR 0013 D-4, per-diff approval) to
  reach it from Julia source.
- **Deferred (filed as beads):** PRD §3.7 L1 Exchange lowering; GEP/arrays;
  dynamic-N; width masking; aliasing guard (RC3 port, needed once GEP
  enables multi-store ops).

## Reuse / Refs

Reuse: `IState.memory` model + zero-init convention; `Define` create (for
the pointer-address materialisation) + the `Define`/`Cast` L3
non-injective template; the existing ingest `_lower_body_inst` dispatch.
Refs: ADR 0013 §D-2/§D-5; PRD v4 §3.2/§3.7 (Exchange mandate — deferred),
§3.3 (L3); ADR 0012 R3 (L3-only precedent); `src/ir/IState.jl` (memory
model); `../Bennett.jl/src/extract/entry.jl` (`extract_parsed_ir_from_ll`);
`docs/coverage-matrix.md` (the memory quintet gap).
