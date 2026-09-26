# Verification of Astra VM-core review (F1–F10) — 2026-09-26

Verifier: independent re-execution, read-only. No edits under `src/`/`test/`, no `bd`, no commits, no full suite.
Environment: BennettVM HEAD `9ddac09` (src/test byte-identical to the review's `3618565`: `git diff --stat 3618565 HEAD -- src test` empty);
Bennett.jl HEAD `13c0a29`. All probes: `julia --project --check-bounds=yes --compiled-modules=existing <script>` from the BennettVM.jl root.
Scripts lived in the session scratchpad (not in the repo); their full bodies are condensed below.

## Summary

| F# | Verdict | Severity agree? | Note |
|----|---------|-----------------|------|
| F1 | CONFIRMED | Yes (S0) | Both LLVM modules accepted via extraction; wrong output (`-86`, `0`) + `roundtrip=true`. Byte-tier memset witness also reproduces (hand-built ParsedIR; the upstream LLVM route refuses `llvm.memset` on a gc_alloc_obj dst). |
| F2 | CONFIRMED | Yes (S0) | Reviewer's code ran verbatim: `output=99 expected 7`, `roundtrip=true` under L2 and L3. hyi6 exists and matches. |
| F3 | CONFIRMED | Yes (S0) | Reproduced through the full LLVM→`ptr_cells=true`→`lower_vm` path for both libc memcpy and memmove: `:out => 0` (expected 41), `roundtrip=true`. Root cause visible in `_copy_range!` (reads only `s.memory`). |
| F4 | CONFIRMED (mechanism) | **No — overstated; S2** | Present-zero cell becomes absent after inverse (direct + real `unstep!` with `compute_must_cache`). But a present-zero and an absent cell are indistinguishable to every load (`get(...,0)`), so no program output is ever wrong. This is a structural per-step-equality violation, masked by `unrun!`. Interchange/Swap claims reproduce (Swap's *forward* already drops the key). |
| F5 | CONFIRMED | Mostly (S0/S1 borderline) | Exact outputs reproduced (`output=99 expected=7`, `base=heap_top=typemin`, `calloc … cells=0`). Witnesses need ≥8 TiB or overflowing sizes; natively these return NULL/fail, so it is a silent divergence on allocation-failure semantics rather than an everyday miscompile. The calloc-wrap case (native NULL vs VM valid pointer) justifies S0. |
| F6 | CONFIRMED | Yes (S1) | memset: `unbound SSA name :r` at pc 4 (only `[:p]` bound); memcpy variant also crashes at pc 5. Loud crash on valid input. |
| F7 | CONFIRMED | Yes (S1, weak) | `InexactError: convert(Int64, 0xffff…)` and for `0x8000…`; `1.0` accepted as 1; `1.5` rejected. PRD §3.6 routes Float64 as UInt64 bit patterns, so any negative-double input hits this; in-repo tests use a manual `reinterpret(Int64, …)` workaround. Loud, not silent. |
| F8 | CONFIRMED | Yes (S1) | `n=-1`: default run ACCEPTED `heap_top=-1`, `record=false` ACCEPTED, L2 run raises the NEGATIVE-n error. Acceptance depends on recording policy. |
| F9 | CONFIRMED | Yes-ish (S1; S2 defensible) | Pre-states differ (p=10 vs 20), post-edge states equal, history empty, trait `true`. No observable failure today: per-step `unstep!` and `unrun!` restore p via replay. False certificate, not a live miscompile. |
| F10 | CONFIRMED | Yes (S1; S2 defensible) | `adjacent clobber result=42 … q previously=999`, `roundtrip=true`. Input is LLVM out-of-bounds UB, so this is unsound acceptance, not a valid-program miscompile. pdqx exists; its "region table" wording is indeed wrong: IState has only `heap_top`/`arena_top`/`stack_top` cursors. |

"Already tracked?" claims: every named bead exists in `.beads/issues.jsonl` with a matching title (details at the end).
Regex sweeps of the JSONL for mixed-width, ROM memcpy, MemoryAssignment zero, allocation overflow, libc return, UInt64/InexactError and negative-size topics found no existing issue covering F1, F3–F8.
So the reviewer's "No" claims hold.

---

## F1 — mixed-width memory access

Script (f1.jl): `p = Bennett._parsed_ir_from_ir_string(ir); vm = lower_vm(p); rs = initial_state(vm, Dict{Symbol,Int}()); run!(rs, vm); … unrun!(rs, vm)` over the two modules
exactly as in the review (narrow `store i8 170` over an i64; `gep i8 %p, 1` + `load i8` + `zext`).
```
narrow store ACCEPTED output=Dict(:p => 1, :out => -86) out_hex=ffffffffffffffaa
narrow store roundtrip=true
byte gep load ACCEPTED output=Dict(:p => 1, :byte => 0, :out => 0, :q => 2) out_hex=0
byte gep load roundtrip=true
```
Correct values: `0x11223344556677aa` and `0x77`. Note that the narrow store also sign-extends the byte (`-86`).

Byte-tier witness. First tried via LLVM (`julia.gc_alloc_obj` + `llvm.memset.p0.i64` + `load i64`, `ptr_cells=true`). Upstream extraction refuses it with:
`llvm.memset.p0.i64: memset dst operand is not alloca-backed … Tracked in Bennett-8bys`.
Then reproduced as a hand-built ParsedIR (f1c.jl):
```julia
b = N.IRBasicBlock(:entry, N.IRInst[
  N.IRCall(:p, :gc_alloc_obj, N.IROperand[c(8), c(0)], [64,64], 64),
  N.IRCall(:u, :memset, N.IROperand[v(:p), c(170), c(8)], [64,32,64], 64),
  N.IRLoad(:out, v(:p), 64)], N.IRRet(v(:out), 64))
```
```
DataType[BennettVM.IntrinsicGCAlloc, BennettVM.IntrinsicMemsetBytes, BennettVM.MemoryLoad]
byte-tier nonzero memset wide load=170 expected=-6148914691236517206
roundtrip=true
```
Assessment: S0 is correct. Two LLVM-extracted modules are silently wrong while round-trip passes. The byte-tier sub-witness is valid at `lower_vm` level, but I did not reproduce it from real LLVM.

## F2 — callee static alloca aliases caller's dynamic alloca

I ran the review's Julia block verbatim, adding an L3 loop.
```
L2 output=99 expected 7; p=1
L2 roundtrip=true
L3 output=99 expected 7; p=1
L3 roundtrip=true
```
Assessment: S0 is correct for accepted ParsedIR. I did not establish reachability from real Julia extraction, since a dynamic alloca in a caller plus a static alloca in a callee is uncommon in Julia IR.

## F3 — bulk copy from ROM yields zeros

Script (f3.jl): the review's in-memory libc module (`@rom = private constant [2 x i64] [i64 41, i64 42]`, `malloc(16)`, `gep @rom,0,0`, `call ptr @memcpy`, `load i64`), `_parsed_ir_from_ir_string(ir; ptr_cells=true)`:
```
DataType[BennettVM.Define, BennettVM.IntrinsicMalloc, BennettVM.VarGEP, BennettVM.IntrinsicMemcpy, BennettVM.MemoryLoad]
libc ROM memcpy ACCEPTED Dict(:dst => 1099511627776, :rom => 281474976710656, :src => 281474976710656, :out => 0) expected out=41
memory=Dict(1099511627776 => 0, 1099511627777 => 0)
roundtrip=true
```
The same result with `memmove` substituted (f3b.jl) was `:out => 0`, `roundtrip=true`.
Source confirms the cause: `src/ir/intrinsics_bulk.jl:105` `_copy_range!` reads `get(s.memory, src + i, 0)` and never consults `s.globals.cells`.
Assessment: S0 is correct. I did not re-run the reviewer's direct hand-built VM variant, because the extraction path is the stronger witness and it reproduces.

## F4 — MemoryAssignment inverse loses explicit zero

Script (f4.jl):
```julia
s = B.IState(1, Dict{Symbol,Int64}(), :running, Dict(Int64(1)=>Int64(0)))
i = B.MemoryAssignment(Int64(1), :add, Int64(2), :add, Int64(3)); pre = deepcopy(s)
B.forward(i, s); B.inverse(i, s, NamedTuple())
# real VM: Begin(:m,[]); Define(:p,1,:add,0); MemoryStore(:p,0); MemoryAssignment(:p,:add,2,:add,3); End(:m,[:p])
# step! with compute_must_cache until halted, snapshotting; then unstep! comparing to snapshots; then unrun!
```
```
after forward mem=Dict(1 => 5)
MemoryAssignment explicit zero restored=false memory=Dict{Int64, Int64}()
must_cache=Set([(:m, 2), (:m, 3)])
final status=halted mem=Dict(1 => 5) steps=5 hist=2
after unstep -> compare snap 5 equal=true  expected_mem=Dict(1 => 5) actual_mem=Dict(1 => 5)
after unstep -> compare snap 4 equal=false expected_mem=Dict(1 => 0) actual_mem=Dict{Int64, Int64}()
whole unrun equal initial=true
interchange fwd locals=Dict(:x => 0) mem=Dict(1 => 5)
MemoryInterchange inverse equal=false mem=Dict{Int64, Int64}()
swap fwd mem=Dict{Int64, Int64}()
MemorySwap inverse equal=false mem=Dict{Int64, Int64}()
is_injective Interchange=true Swap=true Assignment=false
```
Every claim reproduces, including the L2 selection of slot 3 and `unrun!` masking the bad intermediate state.
Severity: I **disagree** with S0.
- `MemoryLoad.forward` (`memory_floor.jl:~289`) reads non-global cells as `get(s.memory, a, 0)`, and the global tier never lives in `s.memory`. So `{1=>0}` versus `{}` is observationally identical to every program.
- No forward result and no final reversed state is wrong. The damage is a violation of the structural `IState ==` per-step inverse contract.
- A per-step checker would flag it loudly (`equal=false`), not silently.

S2 fits best: a contract/invariant bug with no wrong answer. The true-bijection docstring claim and the Interchange/Swap `is_injective=true` classification are nonetheless false, as stated.

## F5 — unchecked allocation arithmetic

Script (f5.jl), single-block VMs:
```julia
[DynAlloca(:p,:n,1), Define(:nm1,:n,:sub,1), Define(:last,:p,:add,:nm1), MemoryStore(:last,7),
 IntrinsicMalloc(:mp,8), MemoryStore(:mp,99), MemoryLoad(:out,:last)]      # n = ARENA_BASE
[DynAlloca(:p1,:a,1), DynAlloca(:p2,:b,1)]                                  # a = typemax(Int64), b = 1
[IntrinsicCalloc(:cp,:a,:b)]                                                # a = 2^62, b = 4
```
```
stack-arena alias output=99 expected=7; last=1099511627776 malloc=1099511627776
roundtrip=true
overflow accepted base=-9223372036854775808 heap_top=-9223372036854775808
calloc product wrap cells=0
```
The outputs match the review exactly. Source confirms the defect: `DynAlloca.forward` does `heap_top += n` unchecked, and `_alloc_cells(::IntrinsicCalloc)` multiplies unchecked. There is no tier ceiling.
Assessment: borderline S0/S1.
- The aliasing witness needs an 8 TiB allocation, which natively fails. It is silent, but no practical program observes it.
- The calloc-overflow case is a defined C behaviour (native calloc returns NULL) that the VM turns into a valid zero-cell pointer. That is a silent divergence, so S0 is defensible.

## F6 — libc bulk-op return pointer discarded

Script (f6.jl): the review's memset module, plus a memcpy variant using two mallocs and `%r = call ptr @memcpy(...)`, `load i64, ptr %r`.
```
memset lower_vm ACCEPTED: DataType[BennettVM.IntrinsicMalloc, BennettVM.IntrinsicMemset, BennettVM.MemoryLoad]
memset ERROR: unbound SSA name :r — the VM read a register that is not bound in the active frame.
  pc          : 4
memcpy lower_vm ACCEPTED: DataType[BennettVM.IntrinsicMalloc, BennettVM.IntrinsicMalloc, BennettVM.IntrinsicMemcpy, BennettVM.MemoryLoad]
memcpy ERROR: unbound SSA name :r … pc : 5 … bound here : 2 name(s) — [:p, :q]
```
Assessment: S1 is correct (a loud crash on valid input). A caveat I did not verify: in a loop where `%r` stayed bound from a previous iteration, the read could turn into a silent stale read.

## F7 — UInt64 inputs with bit 63 rejected

Script (f7.jl): identity VM `Begin(:m,[:x]); Define(:y,:x,:add,0); End(:m,[:y])`, run with several inputs.
```
0xffffffffffffffff -> InexactError: convert(Int64, 0xffffffffffffffff)
0x8000000000000000 -> InexactError: convert(Int64, 0x8000000000000000)
0x7fffffffffffffff -> accepted y=9223372036854775807
1.0 -> accepted y=1
1.5 -> InexactError: Int64(1.5)
```
PRD §3.6 (`bennettvm_prd.md:531-547`) lists `UInt8…UInt64` as supported and routes Float64 as UInt64 bit patterns. `test/test_fp_roundtrip.jl:37,312` work around the rejection with `reinterpret(Int64, x)`.
Assessment: S1 is acceptable but weak. It is a loud rejection at the API boundary with an in-repo workaround. The more dangerous half is the silent `Float64 1.0 → 1` value conversion: under the bit-pattern FP convention, that input is almost certainly a caller mistake the VM should refuse.

## F8 — allocation validity depends on recording policy

Script (f8.jl): `Begin(:entry,[:n]); DynAlloca(:p,:n,1); End(:entry,[:p])`, with `n = -1`.
```
negative n cache=false ACCEPTED heap_top=-1 p=1
  roundtrip=true
negative n cache=L2 ERROR: DynAlloca.predelta_payload: runtime element count n=-1 (operand :n) is NEGATIVE — …
negative n record=false ACCEPTED heap_top=-1 p=1
must_cache=Set([(:entry, 1)])
```
Assessment: S1 is correct. The only `n >= 0` check lives in `predelta_payload` (`alloca.jl:~262`), not in `forward`.

## F9 — injectivity trait on overwriting phi edges

Script (f9.jl): `b1 = BasicBlock(:m, Begin(:m,[:x,:p]), [], UnconditionalExit(:join,[:x]))` and `b2 = BasicBlock(:join, UnconditionalEntry(:join,[:p]), [], End(:m,[:p]))`.
Run with inputs x=7 and p∈{10,20}. The script snapshots after Begin, steps across the edge, and compares.
```
edge prestates equal=false trait Exit=true Entry=true
edge poststates equal=true histories empty=true pcA=4 locals=Dict(:p => 7, :x => 7)
A whole unrun equal initial=true p restored=Dict(:p => 10, :x => 7)
unstep to snap 3 equal=true … unstep to snap 2 equal=true locals=Dict(:p => 10, :x => 7) … per-step all equal=true
```
`_bind_args_to_params!` (`Interpreter.jl:~1470`) does `locals[p] = v` unconditionally, so two distinct states merge with no history. The certificate is false.
Assessment: the mechanism is confirmed. I also confirmed the reviewer's caveat: per-step `unstep!` and `unrun!` both still restore `p` through replay.
- S1 as a "vacuous/false certificate" is defensible, and S2 is equally defensible, because there is no current observable failure.
- The witness pre-binds the receiver via an entry parameter, which is contrived. The realistic case is a loop-carried parameter, which I did not separately run.

## F10 — out-of-object access clobbers a neighbour

Script (f10.jl): the review's body verbatim.
```
adjacent clobber result=42 expected-trap; q previously=999; p=1 q=2
roundtrip=true
```
The `IState` fields (`IState.jl:315-324`) are `pc, frames, status, memory, revmap, heap_top, arena_top, stack_top, globals`. There is no region table, which confirms the reviewer's correction of the pdqx wording.
Assessment: S1 as unsound acceptance holds. The input is LLVM OOB UB, so this is not a valid-program miscompile, and S2 is also defensible.

---

## "Already tracked?" bead check (`.beads/issues.jsonl`)

| Bead | Status/P | Title (abridged) | Review's use accurate? |
|------|----------|------------------|------------------------|
| bennettvm-jb6w | open/P2 | C-tier literal {i64,ptr} GEP mis-stamp (clang SysV spill) | Yes: a GEP-stamping issue, distinct from F1 |
| bennettvm-hyi6 | open/P2 | guard: cross-function mixed static+DynAlloca segment overlap | Yes: exactly F2's mechanism |
| bennettvm-9uds | open/P3 | IntrinsicMemcpy word-tier-only, 8x misaddress for byte-tier | Yes: distinct from F3 (stride, not ROM source) |
| bennettvm-c0e | open/P2 | MemoryAssignment value-level is_injective discrimination | Yes: a broadening proposal, not the F4 defect |
| bennettvm-pdqx | open/P2 | bounds-check MemoryStore/MemoryLoad against live reserved regions | Yes: F10; its "allocator knows every region" text is inaccurate as noted |
| bennettvm-kmpg | open/P3 | Document/expose narrow-width result() carrier | Yes: result carrier, not F7's input rejection |
| bennettvm-9v84 | open/P3 | In-loop same-dest dynamic alloca re-exec | Yes: not the negative-size bypass (F8) |
| bennettvm-xtb | open/P3 | `_handle_backward_cross_block_dispatch!` for direct-inverse unstep! | Yes: not the false-injectivity certificate (F9) |
| bennettvm-axfr | open/P2 | SSA-dominance validator `validate(::VMProgram)` | Yes: not F9 |

A regex sweep of all JSONL titles and descriptions found no issue covering F1, F3, F4, F5, F6, F7 or F8.
For F5, the only "overflow" hit, `bennettvm-bsng`, is about an upstream smul prover and is unrelated.
