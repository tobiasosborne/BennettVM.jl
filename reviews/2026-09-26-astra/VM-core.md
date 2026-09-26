# Astra review — VM-core — 2026-09-26
Status: COMPLETE
Scope: `src/BennettVM.jl`, `src/interpreter/Interpreter.jl`, `src/history/`, `src/ir/{RState,IState,memory_floor,memory_instructions,alloca,revmap}.jl`, `src/analysis/liveness.jl`; adjacent code and tests as needed.
Method: Read-only source and contract audit, followed by focused Julia probes and individual test files with bounds checks. No full suite, issue-tracker operations, or source changes.

## Executive summary

The VM core needs correctness fixes: 15 findings, including five S0 defects, all backed by execution.
Accepted programs lose byte data, copy zeros from ROM, and alias distinct allocations while full round-trip checks pass.
A separate L2 inverse loses stored-zero cells; complete replay masks that intermediate corruption.
Additional defects affect libc return pointers, UInt64 inputs, allocation validation, injectivity claims, exception safety, and history equality.
Finite checkpoint intervals can still produce quadratic reversal; the per-step test helper can loop forever on traps.
18 selected test files passed 2,657 assertions; 1,321,490 independent arithmetic cases matched their oracle.
Non-vacuous trapped-program reversal was independently confirmed. No full suite or source changes were made.

## Findings


### F1 — [S0] Accepted mixed-width memory accesses silently discard bytes or read the wrong cell

- Where: `src/ir/memory_floor.jl:156–184,212–290`; width discarded at `src/ir/ingest_body.jl:171–200`.
- Evidence: passed the following LLVM string through `Bennett._parsed_ir_from_ir_string`, `lower_vm`, ordinary `initial_state/run!`, and `unrun!` (bounds checking enabled):
  ```llvm
  define i64 @julia_probe() {
  entry:
    %p = alloca i64
    store i64 1234605616436508552, ptr %p ; 0x1122334455667788
    store i8 170, ptr %p
    %out = load i64, ptr %p
    ret i64 %out
  }
  ```
  Printed `narrow store ACCEPTED output=Dict(:p => 1, :out => -86)` and `roundtrip=true`. On the local little-endian target the correct result is `0x11223344556677aa`. A second accepted module replaced the narrow store with `%q = getelementptr i8, ptr %p, i64 1; %byte = load i8, ptr %q; %out = zext i8 %byte to i64` and returned `0` instead of `0x77`, again with `roundtrip=true`. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: LLVM permits accessing initialized object representations at narrower widths. The VM has one whole Int64 value per address; a narrow store overwrites the entire value, and a byte GEP can select an absent adjacent cell instead of a byte of the stored word. This is actual extraction-to-VM acceptance, not merely a malformed hand-built instruction. The byte-address scale work does not implement byte-accurate load/store semantics.
- Fix: either represent memory as bytes and assemble/disassemble width-aware scalar accesses, or enforce a uniform non-overlapping cell-access contract and reject mixed-width/partial-cell access during lowering. Retain access widths in MemoryLoad/MemoryStore; masking alone cannot fix preservation of the untouched bytes.
- Test: the exact two modules above, with an independent little-endian byte oracle, plus 16/32/64-bit overlapping stores, signed/unsigned narrow loads, and cross-call aliases. Require correct values or a deliberate lowering-time refusal.
- Already tracked? No matching current issue. `bennettvm-jb6w` concerns GEP scale stamping; this is a separate missing access-width/overlap contract. ADR 0014 §D4 documents width masking as deferred, but the current path accepts and silently misexecutes these inputs.

  Additional executed byte-tier witness: lower a ParsedIR containing `gc_alloc_obj(8,0)`, `memset(p,170,8)`, and `IRLoad(:out,p,64)`. The tier pass chooses IntrinsicMemsetBytes, and the VM prints `byte-tier nonzero memset wide load=170 expected=-6148914691236517206` (`0xaaaaaaaaaaaaaaaa`), followed by `roundtrip=true`. This is a full-width initialized read after a standard fill, not just a partial-overlap edge case. Zero-only memset tests cannot distinguish the broken representation.

### F2 — [S0] A callee's static alloca clobbers its caller's live dynamic allocation

- Where: `src/ir/alloca.jl:227–229`; `src/ir/stack_alloca.jl:119–121`; `src/interpreter/Interpreter.jl:1596–1597`; `src/ir/IState.jl:320–326`.
- Evidence: lowered a two-function ParsedIR module. `main(n)` allocates one dynamic i64 cell `p`, stores 7, calls `callee()`, then returns `load p`; `callee()` statically allocates one i64 cell `q`, stores 99, and returns `load q`. For `n=1`, both default L3 and `compute_must_cache` L2 runs printed `output=99 expected=7`, followed by `roundtrip=true`. Verified: VERIFIED-BY-EXECUTION.
  ```julia
  using BennettVM; import Bennett
  B = BennettVM; N = Bennett; c = N.ConstOperand; v = N.SSAOperand
  cb = N.IRBasicBlock(:entry, N.IRInst[
      N.IRAlloca(:q,64,c(1)), N.IRStore(v(:q),c(99),64),
      N.IRLoad(:r,v(:q),64)], N.IRRet(v(:r),64))
  mb = N.IRBasicBlock(:entry, N.IRInst[
      N.IRAlloca(:p,64,v(:n)), N.IRStore(v(:p),c(7),64),
      N.IRCall(:c,:callee,N.IROperand[],Int[],64),
      N.IRLoad(:out,v(:p),64)], N.IRRet(v(:out),64))
  cp = N.ParsedIR(64,Tuple{Symbol,Int}[],[cb],[64])
  mp = N.ParsedIR(64,[(:n,64)],[mb],[64])
  vm = lower_vm([:main=>mp,:callee=>cp]; entry=:main)
  rs = initial_state(vm,Dict(:n=>1))
  run!(rs,vm; must_cache_set=B.compute_must_cache(vm))
  println(result(rs)[:out]) # 99, expected 7
  unrun!(rs,vm); println(rs.current == rs.initial) # true
  ```
- Failure scenario: `main` has static frame size zero. Its dynamic region starts at 1 using `heap_top`; call dispatch advances `stack_top` by zero, and the callee's StackAlloca also returns 1. Both accesses are in bounds in their source allocations. This is not the out-of-bounds-program case covered by pdqx: the allocator itself aliases two valid live objects.
- Fix: reserve static frames and dynamic objects from a unified allocation cursor, or place them in provably disjoint bounded address segments. As an immediate correctness gate, reject modules combining cross-frame static and dynamic allocations until implemented; do not merely add bounds checks to the two identically numbered regions.
- Test: the two-function n=1 witness under L2/L3, then the converse caller-static/callee-dynamic shape and recursive calls. Assert distinct pointer values, forward oracle 7, and every intermediate reverse state.
- Already tracked? `bennettvm-hyi6`, accurately described. Executed confirmation upgrades it from a latent P2 guard item to a demonstrated silent miscompile (S0).

### F3 — [S0] Bulk memory copies silently replace global ROM contents with zeros

- Where: `src/ir/intrinsics_bulk.jl:105–108,115–134` (cross-scope dependency of the memory-floor audit); compare `src/ir/memory_floor.jl:273–288`.
- Evidence: constructed a VM with global cells `GLOBAL_BASE=>41`, `GLOBAL_BASE+1=>42`, source pointing at `GLOBAL_BASE`, destination 1, and a 16-byte copy followed by MemoryLoad. Both `IntrinsicMemcpy` and `IntrinsicMemmove` printed `global source output=0 expected=41; dest=Dict(2 => 0, 1 => 0)` and then `roundtrip=true`. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: scalar loads correctly consult `s.globals.cells`; `_copy_range!` instead reads exclusively `s.memory` with default zero. A normal initialized constant-to-writable copy is a defined operation, yet its data vanishes. The same helper also bypasses the scalar global read-window trap.
- Fix: centralize cell reads and writes behind segment-aware helpers shared by scalar and bulk instructions. Read ROM sources from `globals`; apply the same missing-global and read-only-destination checks before mutation. Keep memmove's pre-read staging to preserve overlapping-copy semantics.
- Test: copy at least two distinct ROM cells to stack and arena destinations, then scalar-load both and compare with 41/42; cover memcpy and memmove, L2/L3, and partial as well as full reversal. Add out-of-window ROM-source rejection.
- Already tracked? No. `bennettvm-9uds` concerns byte-versus-word stride, a separate defect; this fails at the supported word tier.

  Extraction-to-VM confirmation: an in-memory LLVM module with `@rom = private constant [2 x i64] [i64 41,i64 42]`, `dst=malloc(16)`, `src=gep @rom,0,0`, `%unused=call ptr @memcpy(ptr %dst,ptr %src,i64 16)`, and `load i64,ptr %dst` was accepted by `Bennett._parsed_ir_from_ir_string(...;ptr_cells=true)`, lowered, and printed `libc ROM memcpy ACCEPTED ... :out => 0`, `roundtrip=true`. The corresponding `llvm.memcpy` intrinsic-to-arena extraction currently refuses this shape upstream; the ordinary libc call proves the defect is reachable nonetheless. A direct lowered ParsedIR global-to-stack memcpy independently returned 0 instead of 41.

### F4 — [S0] MemoryAssignment's empty delta loses explicitly stored zero cells

- Where: `src/ir/memory_instructions.jl:146–198,266–268,314–316`; `src/history/delta.jl:562`; `src/ir/IState.jl:504`.
- Evidence: `julia --project --compiled-modules=existing --check-bounds=yes -` probe: construct `IState(1, Dict{Symbol,Int64}(), :running, Dict(Int64(1)=>Int64(0)))`; apply `MemoryAssignment(Int64(1), :add, Int64(2), :add, Int64(3))` and its `inverse(..., NamedTuple())`. Printed `MemoryAssignment explicit zero restored=false memory=Dict{Int64, Int64}()`. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: the valid pre-state `{1=>0}` becomes `{1=>5}`, then reverses to `{}`. `MemoryStore` can create precisely this pre-state. The claimed delete-on-zero “true bijection” is false under the structural `IState` equality contract; absent and present-zero states merge. `compute_must_cache` selects this instruction's empty L2 delta.
- Fix: capture a `was_present` bit before MemoryAssignment and use it when restoring zero, as MemoryStore already does. Audit MemoryInterchange and MemorySwap for the identical sparse-memory representation issue before enabling their direct inverses.
- Test: execute a zero-valued MemoryStore followed by MemoryAssignment through `step!` with `compute_must_cache`; compare the state immediately after one `unstep!` against its saved predecessor, including the exact memory key set. Cover all modops, initially absent cells, and present nonzero cells.
- Already tracked? No matching defect in the issue snapshot. `bennettvm-c0e` proposes broadening injectivity and must first resolve this counterexample.

  Further executed evidence: a real single-block VM containing `Define(:p,1,:add,0)`, `MemoryStore(:p,0)`, `MemoryAssignment(:p,:add,2,:add,3)` with `compute_must_cache(vm)` printed `VM MemoryAssignment inverse equal=false expected_mem=Dict(1 => 0) actual_mem=Dict{Int64, Int64}()`. Continuing to `unrun!` printed `whole unrun masks bug=true`: later replay from the initial anchor hides the bad intermediate inverse. Direct forward/inverse probes of `MemoryInterchange(:x,1,:z)` and `MemorySwap(1,2)` also printed `inverse equal=false` for the same present-zero pre-state. Those two are additionally misclassified as injective (`Injective.jl:312,317`), although today's `unstep!` replays them instead of calling their inverses.

### F5 — [S0] Unchecked allocation arithmetic crosses address tiers and wraps live cursors

- Where: `src/ir/alloca.jl:228–229,277,308`; `src/ir/intrinsics.jl:248–261,282–288`; the disjoint-tier promise in ADR 0018 §A.
- Evidence: a sparse VM program allocates `n=ARENA_BASE` cells at dynamic base 1, stores 7 at its last valid cell, mallocs 8 bytes, stores 99 into that malloc, and reads the dynamic last cell. It printed `stack-arena alias output=99 expected=7; last=1099511627776 malloc=1099511627776`, followed by `roundtrip=true`. No large backing allocation was made. Additional constant-time probes printed `overflow accepted base=-9223372036854775808 heap_top=-9223372036854775808` after positive sizes `typemax(Int64)` then 1, and `calloc product wrap cells=0` for count `2^62`, size 4. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: three “disjoint” tiers are only numeric conventions. DynAlloca has no stack-ceiling check, arena allocation has no GLOBAL_BASE ceiling, and count multiplication/header addition/base addition/cursor advance use wrapping Int64 arithmetic. Legal positive sizes either alias another tier or produce negative/zero reservations rather than a descriptive capacity failure. This also invalidates unconditional region-deletion inverses.
- Fix: use checked add/multiply for all size, end-address, and cursor calculations; validate complete half-open allocation intervals against their tier limits before writing registers/cursors. Share these checks between predelta and forward. Check GenericMemory's header addition and calloc's two operands individually as well as their product.
- Test: sparse boundary probes at each tier end and `typemax(Int64)`, including overflowing calloc and header sizes; reject without mutation in L2/L3/fast mode. No huge allocation or huge reverse loop is necessary.
- Already tracked? No specific overflow/tier-ceiling item. Related to `bennettvm-pdqx` and `bennettvm-hyi6`, but distinct: these witnesses require neither an out-of-object access nor a cross-function call.

### F6 — [S1] Accepted libc memset/memcpy/memmove calls discard their return pointers

- Where: `src/ir/intrinsics_bulk.jl:44–64,78–88,115–134`; `src/ir/ingest_call.jl:90–106` (cross-scope lowering connection).
- Evidence: this complete LLVM function was extracted with `ptr_cells=true` and accepted by `lower_vm`:
  ```llvm
  declare ptr @malloc(i64)
  declare ptr @memset(ptr, i32, i64)
  define i64 @julia_probe() {
  entry:
    %p = call ptr @malloc(i64 8)
    %r = call ptr @memset(ptr %p, i32 0, i64 8)
    %out = load i64, ptr %r
    ret i64 %out
  }
  ```
  `run!` raised `unbound SSA name :r` at PC 4, with only `[:p]` bound. Correct result is 0. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: C libc bulk operations return their destination pointer, unlike void LLVM bulk intrinsics. The lowering discards `IRCall.dest`, and the VM instruction has no return destination. Any later use of that valid return value crashes; memcpy/memmove share the same destination-less representation and lowering.
- Fix: retain the libc return destination and define it to the original destination pointer, preserving any overwritten binding during reversal; a separate Define after the bulk operation can reuse the existing replay semantics. Keep void LLVM-intrinsic calls distinct.
- Test: use each libc bulk operation's result as the next load/store pointer, including inside a loop and across a call boundary; assert both native result and per-step reversal. Retain unused-return and void-intrinsic cases.
- Already tracked? No matching open issue.

### F7 — [S1] initial_state rejects half of the supported UInt64 input domain

- Where: `src/interpreter/Interpreter.jl:223–226`; PRD §3.6, supported `UInt8…UInt64` inputs.
- Evidence: an identity VM with a 64-bit input and `Define(:y,:x,:add,0)` rejects `initial_state(vm, Dict(:x=>typemax(UInt64)))`: `InexactError: convert(Int64, 0xffffffffffffffff)`. The same initializer accepts `1.0` as integer 1 despite its comment claiming Float64 inputs fail. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: unsigned inputs with bit 63 set are valid for the arithmetic kernel (which uses reinterpretation for unsigned ops), but the public initialization boundary attempts numeric narrowing to signed Int64 instead of preserving their bits. Callers must discover and apply an undocumented manual reinterpretation workaround.
- Fix: normalize UInt64 inputs with `reinterpret(Int64,v)` (or an explicitly specified bit-pattern carrier conversion); preserve the current signed/narrow integer behavior and validate input types explicitly. Document the public input/output carrier rules.
- Test: initialize and run an extracted UInt64 identity/udiv/icmp function at `0`, `2^63-1`, `2^63`, and `2^64-1`; decode the result as UInt64 and compare against native Julia. Decide and pin Float64-input rejection rather than relying on `Int64(v)`.
- Already tracked? No. `bennettvm-kmpg` concerns the narrow result carrier, not rejected valid UInt64 inputs.

### F8 — [S1] Allocation validity depends on whether the caller enables delta recording

- Where: `src/ir/alloca.jl:205–230,250–277`; `src/interpreter/Interpreter.jl:1021–1042,1837–1855`; related arena guards in `src/ir/intrinsics.jl:275–288`.
- Evidence: a one-block VM with `BeginInstruction(:entry,[:n])`, `DynAlloca(:p,:n,1)`, `EndInstruction(:entry,[:p])`, input `n=-1`: ordinary `run!` printed `negative n cache=false ACCEPTED heap_top=-1`; with `must_cache_set=compute_must_cache(vm)` it raised `DynAlloca.predelta_payload: runtime element count n=-1 ... is NEGATIVE`. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: the default empty cache set skips `predelta_payload`, which contains the only nonnegative-size check; `forward` decreases the supposedly monotone allocation cursor. Replay and `record=false` also skip the check. Arena same-destination checks likewise reside only in `predelta_payload`, so recording policy changes the accepted instruction domain.
- Fix: move all semantic validation into a pure allocation-validation helper called by forward and by predelta; predelta must only collect undo information. Decide explicitly whether same-destination allocation is supported and apply that decision uniformly to L2, L3, replay, and fast mode.
- Test: run identical valid and invalid allocation inputs under default L3, computed L2, direct forward, and `record=false`; require identical acceptance/rejection and no mutation when rejected.
- Already tracked? `bennettvm-9v84` tracks same-destination allocation support, not the negative-size check bypass or policy-dependent acceptance. The negative-size defect is new.

### F9 — [S1] The injectivity trait certifies phi-edge overwrites that merge distinct states

- Where: `src/history/Injective.jl:287–307`; `src/interpreter/Interpreter.jl:1460–1477`; ADR 0022 §Soundness.
- Evidence: a VM edge `UnconditionalExit(:join,[:x])` into `UnconditionalEntry(:join,[:p])` was executed from two states differing only in preexisting `p` (10 versus 20), with `x=7`. Printed `edge prestates equal=false trait=true`, then `edge poststates equal=true histories empty=true`. The binding overwrites `p` with 7 in both. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: loop-entry parameter slots retain earlier values in the per-frame dictionary, precisely like the redefined Define destinations correctly classified as non-injective elsewhere. Keeping the sender's `x` does not retain the overwritten receiver's `p`. ADR 0022's claim that “Nothing is erased at the edge any more” is false; the conditional argument “if the old transfer is injective” does not prove the missing premise. Ordinary reversal currently survives through full checkpoint replay, so this is a false injectivity certificate, not an observed current whole-run reversal failure.
- Fix: distinguish “replay-recoverable without a per-step delta” from actual local injectivity. Classify overwrite-capable edge dispatch as non-injective or prove runtime/static freshness and preserve overwritten receiver values for a direct inverse. Amend the ADR proof to state its domain/preconditions. Do not remove the non-destructive COPY fix for live sender values.
- Test: require the trait's preconditions with colliding pre-state pairs and loop-carried parameters; test the actual dispatch transition rather than only the pc-only `forward(::UnconditionalExit)` method. Assert direct reverse correctness separately from replay round-trip correctness.
- Already tracked? `bennettvm-xtb` tracks missing direct backward dispatch and `bennettvm-axfr` tracks SSA validation; neither describes this incorrect injectivity certificate. F4 independently shows the same trait problem for sparse MemorySwap/MemoryInterchange.

### F10 — [S1] MemoryLoad/MemoryStore accept addresses outside the originating allocation

- Where: `src/ir/memory_floor.jl:212–226,242–290`; `src/ir/IState.jl:315–328`.
- Evidence: VM body `StackAlloca(:p,1); StackAlloca(:q,2); MemoryStore(:q,999); Define(:outofp,:p,:add,1); MemoryStore(:outofp,42); MemoryLoad(:out,:q)` printed `adjacent clobber result=42 expected-trap; q previously=999`. There is no region/provenance check before either scalar access. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: a bad pointer calculation escapes one object and hits a different live object's valid numeric address. Global segment checks alone cannot detect it; even adding a set of live address intervals would still consider the target address valid. This is unsound acceptance of an invalid access, rather than an oracle discrepancy for defined LLVM out-of-bounds behavior.
- Fix: preserve allocation identity/provenance through pointer operations and check each access against its originating object's extent (including access width), or enforce an equivalent static proof before accepting it. A region table plus raw numeric membership is insufficient for adjacent-object clobbers.
- Test: out-of-object accesses into an allocated neighbor on stack, arena, and byte tiers must reject before mutation; valid aliases within the same object must still work.
- Already tracked? `bennettvm-pdqx`, confirmed. The local JSONL description is partly wrong: it says the bump allocator “knows every reserved region” and names its region table, but IState contains three cursors and no region table. HANDOFF's correction is right: adjacent-allocation clobbers need provenance. Keep distinct from F2, which uses valid accesses and an allocator-created overlap.

### F11 — [S2] step! can raise after changing the state and step count, violating its exception contract

- Where: `src/interpreter/Interpreter.jl:1056–1070,1103–1127`; `src/history/delta.jl:392–399`; PRD §3.11.
- Evidence: VM body `[Define(:a,7,:add,0)]`; execute Begin, snapshot the RState, then `step!(rs,vm; must_cache_set=Set([(:entry,1)]))`. The unsupported L2 selection raises from `make_delta` after printing state evidence `bad L2 unchanged=false pc=3 steps=2 locals=Dict(:a => 7)`. A division-by-zero control probe preserved its pre-step state (`divzero unchanged=true`). Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: the public cache-set keyword accepts a slot that has no L2 inverse. The instruction runs and increments the count before discovering the bad policy. Dispatch validation after `forward` has the same ordering hazard. This violates the binding promise that failed steps leave `current` and `history` unchanged and permits callers to retry from an unexpected PC.
- Fix: validate selected slots with `is_l2_capable` and build every fallible delta component before forward; preflight cross-block/call resolution and arity before mutating PC/frames. Commit the count/history only after all checks succeed. Avoid an unconditional full-state copy in the hot loop.
- Test: assert full RState equality across failures from unsupported cache selection, bad target labels/arity, unknown callees, and arithmetic faults; also assert the subsequent valid retry executes the same instruction.
- Already tracked? No matching exception-safety issue. `bennettvm-axfr` addresses static dominance validation, not transactional step execution.

  Dispatch confirmation: a one-block VM ending in `UnconditionalExit(:missing,[])` changes `pc` from 2 to 3 before target lookup raises, with `step_count` still 1 (`bad target unchanged=false`). The instruction has neither committed successfully nor remained at its pre-state.

### F12 — [S2] DeltaEntry/RState equality is broken for ordinary map and return histories

- Where: `src/history/delta.jl:306–307`; `src/ir/RState.jl:386–392`; `src/ir/revmap.jl:282–285,321–324`; `src/ir/call_transitions.jl:234–249`.
- Evidence: after a real L2 `IRMapInsert(5,0)` into an empty map, `last(rs.history) == last(rs.history)` printed `missing`; `rs == deepcopy(rs)` threw `TypeError: non-boolean (Missing) used in boolean context`. Payload was `(key = 5, prior = missing)`. A ReturnExit delta printed `return entry deepcopy equal=false instruction equal=false`, because ReturnExit's vector fields have no structural instruction equality. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: the absent-key sentinel leaks Julia's three-valued equality into a supposedly Boolean structural-state predicate. Return deltas use identity equality on vector-containing instructions. Neither follows the declared “structural equality” contract, so snapshot comparisons/checkers fail on valid states and cannot reliably express the reversible-wrapper invariant.
- Fix: use missing-safe structural equality (e.g. `isequal`) for delta payloads; define matching structural equality/hash for vector-containing instruction types such as ReturnExit. Ensure the public RState equality result is always Bool and hash follows the same equivalence.
- Test: `s == deepcopy(s)` after absent-key insertion/deletion and after a real nested return, plus equal/hash-equal independently built entries. Include present zero versus absent key, which must remain distinct.
- Already tracked? No matching equality defect.

### F13 — [S2] Periodic checkpointing can miss every checkpoint forever at the default K

- Where: `src/interpreter/Interpreter.jl:1104–1134`; `src/history/Replay.jl:385–460`.
- Evidence: constructed a main block (Begin, unconditional jump) followed by a self-loop `[Define(:x,:n,:add,1); UnconditionalExit(:loop,[:x])]` whose entry binds `:n`. `run!(...; max_steps=512, checkpoint_interval=64)` printed `limit raised=true`, `checkpoint starvation steps=512 history=0 value=255`; reversal succeeded. All 255 non-injective Defines occur on odd steps; every multiple of 64 is an injective exit, so the checkpoint branch is never considered. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: finite K does not bound replay distance. With no deltas/checkpoints, reversing those 512 steps invokes 130,816 forward replay steps (`sum(0:511)`); the same alignment persists for arbitrary run length. Enabling L2 can also remove the only checkpoint opportunities, leaving replay-only steps to reconstruct from the initial state through an ever-growing delta tape.
- Fix: schedule checkpoints by distance from the last checkpoint, and emit an overdue checkpoint at the next permitted instruction, or independently of the injectivity/delta gate. Implement a direct-inverse fast path before promising bounded-cost zero-log reversal. Explicitly document any history-space tradeoff.
- Test: the exact even-period loop with K=64 and K=2; assert a bound on checkpoint/replay distance, not merely final equality. Include mixed L2/replay-only loops whose K-multiples are delta steps.
- Already tracked? `bennettvm-w0a0` tracks slow L3 reversal; `bennettvm-xtb` tracks direct backward dispatch. Neither description identifies the finite-K phase-alignment starvation mechanism. `bennettvm-kuq` is not the fix: deltas cannot substitute for full restore snapshots simply by sharing a step accessor.

### F14 — [S2] The per-step reversal test scaffold loops forever after a real VM trap

- Where: `test/test_per_step_inverse.jl:256–262`; `src/interpreter/Interpreter.jl:294,910`; also similar loops in `test/test_zero_history_roundtrip.jl` and `test/test_delta_roundtrip.jl:418`.
- Evidence: loaded the real scaffold, then passed a one-block VM with `BeginInstruction(:m,[])`, body `[UnreachableHalt()]`, and `EndInstruction(:m,[])`. After `TRAP_SCAFFOLD_READY`, an external 0.5-second watchdog interrupted the still-running call. Julia's interrupt stack located it in `deepcopy` at `test/test_per_step_inverse.jl:261`; process exit was signal 2. No source was mutated. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: `UnreachableHalt` sets `status=:error`; `is_halted` recognizes only `:halted`; `step!` immediately returns for any non-running status. The scaffold therefore keeps copying/appending the same terminal state forever without increasing `step_count`. A regression that unexpectedly reaches a trap becomes a hang/memory blow-up instead of a useful test failure. There is also no forward-step budget for genuine infinite loops.
- Fix: loop while `status === :running`, require one-step progress, and enforce a configurable forward limit. At exit, explicitly accept and reverse an expected trap or report an unexpected one. Keep the inverse comparison against the saved pre-trap states.
- Test: an expected trap after a memory write must terminate the scaffold and reverse every step; an unexpected trap and an infinite loop must fail promptly with distinct diagnostics.
- Already tracked? No. `bennettvm-lwhz` concerns include guards in this file, not terminal-state handling.

### F15 — [S3] The width-64 compatibility test compares the arithmetic implementation with itself

- Where: `test/test_width_masking.jl:203–229`; `src/ir/arithmetic_assignment.jl:241`.
- Evidence: every assertion in the “width-64 no-op (existing behavior byte-identical)” test is `_ab(op,a,b) == _ab(op,a,b,64)`. In a disposable Julia process, redefined only the four-argument method to return `Int64(0)` for EVERY opcode, then executed the exact sample/op/skip/assertion matrix from this test: `width64 test matrix with every opcode mutated to zero: comparisons=1438 failures=0`. An independent check printed `add(2,3)=0 expected=5`. No file was changed; the process ended after the probe. Verified: VERIFIED-BY-EXECUTION.
- Failure scenario: changing 64-bit signed/unsigned arithmetic incorrectly can preserve every assertion in this purported compatibility gate. The sign-sensitive sample set does not supply an independent expected result.
- Fix: compare against explicit golden values or independent BigInt/UInt64/native arithmetic with defined overflow and shift domains. Retain a single default-argument equality assertion if API-default delegation is worth pinning, but do not count the expanded matrix as arithmetic coverage.
- Test: a deliberate wrong result for one 64-bit operation must fail the oracle assertion; retain the good independent narrow-width golden tests.
- Already tracked? No matching test-quality issue.

## Unconfirmed suspicions

- **Full push! / _growend! corpus:** not claimed to run. The VM still rejects Julia-tier IntrinsicMemcpy/IntrinsicMemmove at `intrinsics_genericmemory.jl:192–197` (tracked `bennettvm-rxgy` / `bennettvm-9uds`). ADR 0017 §4a/§4b predicates live upstream; the VM receives ordinary integer/pointer-cell operations and no runtime proof certificate. This review confirms substrate defects and synthetic execution behavior, not a new bypass of the upstream value-identity or confined-use predicate. The real corpus's outstanding admission/runtime walls remain outside this review's execution coverage.
- **Sentinel/TLS distinction:** direct scalar reads at `2^48` without ROM data and at the empty-data sentinel `2^48+2^47` rejected as intended. Absent reads at `TLS_BASE-2^32` and `typemax(Int64)` returned 0. This confirms the already disclosed `bennettvm-9sqy` band weakness; no accepted native-defined source program laundering a live read into that band was established here, so it is not promoted to an additional miscompile finding.
- **Current complete reversal:** the intermediate corruption in F4 is verified; no extra claim is made that all normal complete `unrun!` paths fail. The initial-anchor replay can restore a fully equal final state while hiding a bad intermediate inverse or a wrong forward answer. No `verify_vm_reversibility` implementation was found in `src/`; the claims here concern the actual exported run/unrun APIs and test predicates, not an invented verifier API.

## What is sound (brief)

- Independently executed a trap after a real memory write with a live MemoryStore delta, at K=1,2,64. Each run reached `status=:error`, step 4, memory `{1=>123}`, and one delta. Every `unstep!` matched its saved predecessor; final state equalled initial with empty history. The claimed non-vacuous trapped-program reversal is substantiated.
- The 512-step checkpoint-starvation probe also confirms max-step interruption leaves a reversible state; the problem there is replay cost, not recovery correctness.
- Independent arithmetic oracle: 1,321,490 cases at widths 1,2,4,8, exhaustively covering each operand pair for the integer/bitwise/comparison operations and defined shift/division cases, produced zero mismatches. Signed values were reconstructed independently before signed comparisons/div/rem; wraparound was checked by masking. The existing width-masking golden tests also passed.
- MemoryStore's `(addr, old_value, was_present)` delta and RevMap's missing-aware inverse branches preserve present-zero versus absent state correctly. The defect in F12 is equality of the history wrapper, not the map undo operation itself.
- Checkpoint construction and replay restoration both deep-copy mutable execution state; frames, memory, map, heap/arena/stack cursors participate in IState comparison. Result queries return a copy and reject non-halted states. The shared ROM is deliberately excluded and assumes immutable program data; no guest instruction that mutates the ROM dictionary itself was found.
- Current call/return, arena, map, checkpoint-boundary, and trap regression files passed. The backward search's restriction to CheckpointEntry is correct for finding a restore snapshot; the older `bennettvm-kuq` suggestion to make it symmetric with truncation should not be applied mechanically to deltas.

## Nits (S4)

- `src/BennettVM.jl:21–54` still calls the package a skeleton with no interpreter/history/ingest and reverses the PRD's Case A/Case B descriptions. Update the top-level module help; keep historical milestone narratives clearly historical.
- `src/history/delta.jl:277–282` says payload/instruction fields are all immutable value shapes, but bulk deltas contain vectors and ReturnExit contains vectors. Current producers generally allocate independent payload vectors; the comment must not be treated as a future alias-safety guarantee.
- `src/ir/IState.jl:68–75` implies division/overflow faults set `status=:error`; the division-zero probe leaves status `:running` and throws, whereas only UnreachableHalt produces the modeled error status. Document these distinct fault mechanisms.

## Coverage log

- Read `CLAUDE.md` in full, `PHASE.md`, `BENNETT_JL_PIN.md`, and open-issue inventory. Phase 2 confirmed. The review-specific prohibition on writes, beads, and commits overrides ordinary session-close rules.
- Read all executable definitions in the requested scope, including initial_state/result, instruction lookup, cross-block binding, call dispatch, terminal transitions, history gates, delta dispatch, checkpoint search/truncation/replay, every MemoryStore/Load/Assignment/Interchange/Swap method, DynAlloca, map primitives, state equality/hash/constructors, and compute_must_cache. Read the surrounding contracts and comments, emphasizing claims used by the code. Arithmetic semantics reside in `arithmetic_assignment.jl`, not the interpreter's dispatch file; that kernel and Define/cast support were followed across scope.
- Cross-scope reads: `stack_alloca.jl`, `intrinsics.jl`, `intrinsics_bulk.jl`, `intrinsics_genericmemory.jl`, `call_transitions.jl`, `call_frames.jl`, `swap_instruction.jl`, `unreachable_halt.jl`, relevant ingest_body/ingest_call/ingest_multi/global-materialization arms, and upstream in-memory extraction entry points. These reads were to establish reachability/semantics, not a full frontend or heap-intrinsic review.
- Contracts: PRD §§2–3 and normative verification sections; HANDOFF top entries; ADR 0001's taxonomy/semantic conclusions, 0002's dataflow/payload/composition decisions, 0008/0009 map/dynamic-memory decisions, 0011's FP boundary, 0014, 0017 (including §4a/§4b), and relevant 0018/0019/0022 sections. Consulted the three prior hostile-review reports under `reviews/2026-07-12-*`; did not rely on their “refuted” labels as proof.
- Probes use Julia 1.12.3, `--project --compiled-modules=existing --check-bounds=yes`, source supplied on stdin; no probe files created. Initial VM fixture attempts had constructor-name/arity mistakes; corrected attempts are the evidence cited above.
- Existing tests: 18 selected files, **2,657 passing assertions** (305 + 1,906 + 446; includes transitive/repeated scaffold assertions): `test_istate`, `test_rstate`, `test_checkpoint_entry`, `test_delta_entry`, `test_memory_instructions`, `test_revmap`, `test_injective`, `test_liveness`, `test_store_delta`, `test_alloca_delta`, `test_delta_roundtrip`, `test_unrun`, `test_width_masking`, `test_call_roundtrip`, `test_arena_roundtrip`, `test_revmap_roundtrip`, `test_checkpoint_push`, and `test_utzc_unreachable_sink` (all `.jl`). Files were included serially in isolated modules in small Julia batches. The first batch's module harness lacked `include`, so it stopped at test_liveness after 305 passes; the helper was corrected and the six remaining files then passed 1,906 assertions. This was a review-harness error, not a repository failure.
- Test-source audit additionally covered per-step inverse, mutation proof, zero-history/property scaffolding, allocation/store delta tests, multi-DynAlloca, and the bvmd/jbko/hsm3 witness families at the memory-contract/round-trip assertions. sy29/57hd/p06b were inspected at the named oracle/shape/reversal assertions, not run end-to-end. No full suite, toolchain corpus rebuild, or 30-minute frontend test run was attempted.
- Environment: BennettVM HEAD `3618565c65193a9c788859b9848dea9b333e8d47`; sibling Bennett HEAD `f829f3db587316fc2d0e42b982b4adc708b61948`. The sibling is ahead of the documentary pin, as permitted by the dev dependency; it was not checked out or changed. No bd invocation, source/test edits, commits, stashes, checkout, or remote operations were performed.
