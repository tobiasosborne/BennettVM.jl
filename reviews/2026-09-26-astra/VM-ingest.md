# Astra review — VM-ingest — 2026-09-26
Status: IN PROGRESS
Scope: VM ingestion/frontend, call/control instructions, test suite, ADR/PRD consistency.
Method: Read-only source review and focused Julia probes with bounds checking; only this report is modified. No full suite, issue-tracker commands, commits, or CI.

## Executive summary

Pending completion.

## Findings

### F1 — [S1] The Float32 guard rejects ordinary closed-world Int32 calls
- Where: `src/ir/ingest_body.jl:343-375`.
- Evidence: VERIFIED-BY-EXECUTION. Construct `g(a::i32) = ret a` and `f(x::i32) = r=IRCall(:r,:g,[SSAOperand(:x)],[32],32); ret r`, package them as `lower_vm([:f=>caller,:g=>callee])`. Julia prints `IRCall to soft op :g ... touches Float32 (ret_width=32, arg_widths=[32])`. Both functions contain integers only. The guard runs before function-table resolution and does not require membership in `_SOFT_DISPATCH`.
- Failure scenario: A valid non-inlined integer function with a 32-bit argument OR return cannot compile. The error falsely describes it as floating-point double rounding.
- Fix: Resolve known VM callees before the floating-point-only guard, or restrict that guard to the explicitly identified soft-float callees whose positions represent f32. Preserve the nondeterminism/intrinsic precedence deliberately.
- Test: Real `@noinline g(::Int32)` extraction plus synthetic mixed-width signatures; compare forward output to Julia and reverse the complete state under L2 and L3. Keep actual f32 refusals.
- Already tracked? No matching open bead; `bennettvm-h0t` introduced the boundary guard but describes only genuine floating-point calls.

### F2 — [S1] A valid constant conditional branch crashes during lowering
- Where: `src/ir/ingest.jl:970-979`; `src/ir/ingest_phi.jl:57-63`; upstream `src/ir_types.jl:466-470`.
- Evidence: VERIFIED-BY-EXECUTION. A three-block `ParsedIR(64,[(:x,64)],...)` with entry terminator `IRBranch(ConstOperand(1),:yes,:no)` and both successors `IRRet(SSAOperand(:x),64)` fails with `FieldError: type Bennett.ConstOperand has no field name`. The branch lowering unconditionally reads `term.cond.name`. The IR type expressly permits a constant condition.
- Failure scenario: Unfolded LLVM `br i1 true`/`false` accepted by the frontend cannot become a VM program, although constant-select handling already accommodates the analogous shape.
- Fix: Validate the i1 constant and emit the selected unconditional edge; account for any pruned incoming edges consistently. Alternatively materialize a fresh normalized condition register. Do not merely convert the FieldError to a refusal for this ordinary supported control-flow shape.
- Test: Constants 0, 1 and -1, distinct successors with distinct observable results, phi incoming values, and full reversal; reject non-i1 literals descriptively.
- Already tracked? No matching open bead.
- Additional VERIFIED-BY-EXECUTION case: `IRBranch(SSAOperand(:c),:next,:next)` is valid but fails `ConditionalExit: target_true and target_false both equal e_entry_next`. Normalize identical successors and deduplicate predecessor edges during ingest; the VM constructor is right to require its normalized representation.

### F3 — [S1] Scalar literal returns remain unsupported, including ordinary constant functions
- Where: `src/ir/ingest.jl:930-935`; `src/ir/ingest_multi.jl:85-95`.
- Evidence: VERIFIED-BY-EXECUTION. `ParsedIR(64,[(:x,64)],[IRBasicBlock(:entry,IRInst[],IRRet(ConstOperand(42),64))],[64])` fails with `IRRet of a literal (42) is unsupported`. `_declared_returns` additionally classifies every non-SSA return as void, which must be corrected when adding the create.
- Failure scenario: `f(x)=42`, literal base cases, and optimized constant-return callees are valid scalar programs but cannot lower.
- Fix: Materialize a fresh constant-result register before End, and derive return arity from the return ABI rather than whether the first return operand happens to be SSA. Support mixed literal/SSA return blocks consistently.
- Test: Constant entry function, a callee returning a constant, and mixed branch returns; golden output and complete L2/L3 reversal.
- Already tracked? `bennettvm-cw4g` mentions literal returns, but its description conflates `ret void` with `ret const`: explicit void IRRet is implemented at `ingest.jl:918-929`; literal scalar returns are the surviving defect.

### F4 — [S0] Ingestion drops map key widths, so equal narrow keys become different dictionary entries
- Where: `src/ir/ingest_body.jl:432-467`; `src/ir/arithmetic_assignment.jl:241-258`; upstream `src/ir_types.jl:312-352`.
- Evidence: VERIFIED-BY-EXECUTION. One i8 block: `IRMapInsert(x,7,8,8); same=IRBinOp(:add,x,0,8); IRMapInsert(same,9,8,8); r=IRMapGet(x,8,8); ret r`. Input `x=Int64(-1)` gives printed `r=7, same=255, x=-1`, expected `9`; `restored=true history_empty=true` after unrun. The Julia oracle is `d=Dict{Int8,Int8}(); d[x]=7; d[x+Int8(0)]=9; d[x]` for `x=Int8(-1)`.
- Failure scenario: Narrow arithmetic canonicalizes to low-width bits, while raw signed inputs/constants retain sign extension. The map lowering erases `key_width`, so the two representations of the SAME key are distinct Int64 keys. A second insertion does not overwrite the first and returns a silently stale value.
- Fix: Preserve key/value widths in VM map instructions or insert canonicalization at every map boundary. All insert/get/delete operations must agree on the canonical representation; preserve value-width semantics too.
- Test: Negative Int8/Int16 keys computed by arithmetic versus passed directly, both insertion orders and deletion, forward comparison to Julia and complete L2/L3 reversal.
- Already tracked? No specific open bead. The arm comment calls width masking a `bennettvm-bgc` follow-on, but bgc's arithmetic masking is already implemented; it does not fix this map boundary and actually exposes the inconsistent representations.

### F5 — [S0] Bare-name intrinsic dispatch silently replaces a supplied in-module function body
- Where: `src/ir/ingest_body.jl:269-287,372-432`; `src/ir/ingest_call.jl:169-176`; `src/ir/ingest_multi.jl:136-158`.
- Evidence: VERIFIED-BY-EXECUTION. Supply two ParsedIRs: `malloc(a::i64)` computes `v=a+10; ret v`; `f(x::i64)` calls `IRCall(:r,:malloc,[x],[64],64); ret r`. `lower_vm([:f=>f,:malloc=>g])` succeeds. With x=8 the VM prints `output=1099511627776 expected=18`, then `restored=true history_empty=true`. The explicit callee body is never executed: the heap-name check wins before function-table lookup.
- Failure scenario: User/module-defined functions sharing a runtime-intrinsic name (legal for a Julia function in another module, or an explicitly supplied IR body) silently acquire allocator/bulk semantics. Module qualification has already been discarded. Nondeterminism-name matches similarly reject otherwise deterministic supplied bodies.
- Fix: Carry resolved callee identity/provenance, and distinguish actual runtime declarations from supplied definitions. At minimum reject any module whose function table collides with reserved intrinsic names; never accept both interpretations and silently choose one.
- Test: Custom named `malloc`, `free`, and modeled-cell names; ensure body execution or a named ambiguity refusal. Test Function and Symbol IRCall forms, with golden results and reversal.
- Already tracked? No matching open bead. ADR 0018's guard-order rule explains the implementation but does not justify silently substituting a supplied definition.

### F6 — [S0] Multi-function lowering duplicates a shared global object and breaks pointer identity
- Where: `src/ir/ingest_multi.jl:180-213`; `src/ir/ingest.jl:260-281`.
- Evidence: VERIFIED-BY-EXECUTION. Both ParsedIRs carry `globals=Dict(:G=>(UInt64[7],64))`. Caller f passes `SSAOperand(:G)` to g; g computes `IRICmp(:eq,:eq,SSAOperand(:p),SSAOperand(:G),64)` and zexts it to i64. The VM prints `global pointer identity output=0 expected=1`, with exact restoration and empty history afterward. f's G lives at GLOBAL_BASE; g's G lives at GLOBAL_BASE+1. The code deliberately advances a per-function global cursor, allocating the same module object twice.
- Failure scenario: The address of a shared read-only global crosses a call, then is compared with that same global in the callee. Equal native pointers become unequal VM pointers. Certified singleton identity across separately extracted Julia bodies has the same architectural risk; that broader frontend case was not executed here.
- Fix: Allocate globals once at module scope using stable object identity/linkage, then pass one mapping into every function. Equal contents alone are insufficient for deduplication: distinct objects with equal bytes must remain distinct. Preserve provenance across the extraction boundary where separate bodies rename the same singleton.
- Test: One shared global referenced in two functions, distinct equal-valued globals, passing pointers through recursive calls, and a real certified empty-Memory singleton shared across bodies. Compare identity results and full round-trip state.
- Already tracked? No matching open bead. The old `bennettvm-h6c3`/416r.13 disjoint-window fix avoids accidental address collisions but does not preserve shared identity.

### F7 — [S0] Synthetic register names can overwrite legal input SSA names
- Where: `src/ir/ingest_phi.jl:120,135-136,150-151`; `src/ir/ingest.jl:417-421,905-908` (same unchecked namespace pattern for aggregate/call temporaries).
- Evidence: VERIFIED-BY-EXECUTION. ParsedIR argument `:_phi_const_entry_1=10`; entry branches to next; next has `a=phi [1,entry]`, then `r=add(arg,a)`. Lowering adds a `Define(:_phi_const_entry_1,1,:add,0)` to entry and silently overwrites the argument. Output is `2`, expected `11`; reversal restores the initial state and empties history.
- Failure scenario: A legal LLVM/ParsedIR identifier equals a synthesized temporary. No freshness scan or reserved-prefix validation exists. This is a forward miscompile, not merely an ugly error for unusual names.
- Fix: Build a per-function used-name set covering arguments, all instruction definitions, and global symbols; allocate every generated name through a freshness allocator. Do the equivalent for generated block labels.
- Test: Deliberate collisions with each synthetic family (`_phi_const_`, `_phi_ssadup_`, `_agg_`, `_callconst_`) and generated edge labels; verify either hygienic lowering or a clear boundary rejection, plus expected output and reversal.
- Already tracked? `bennettvm-3ah` partially covers synthetic-name hardening, but its recorded example is wrong: `(src=:a_1,value=3)` and `(src=:a,value=13)` produce DIFFERENT strings. The executed user-name collision above is real and more severe than the bead's P3 framing.

### F8 — [S1] Globals used only by phi incoming values or terminators are never initialized
- Where: `src/ir/ingest.jl:238-251,266-268`; `src/ir/ingest_phi.jl:85-97`.
- Evidence: VERIFIED-BY-EXECUTION for phi. With `globals=Dict(:G=>(UInt64[7],64))`, entry branches to next, whose only instructions are `p=IRPhi(:p,0,[(SSAOperand(:G),:entry)])` and `r=IRLoad(:r,p,64)`. Lowering accepts it; run fails `KeyError: key :G not found`. `_referenced_global_names` checks vector elements only when each element itself is SSAOperand; phi elements are tuples. `_global_segment` also never visits a block's terminator, so a global used only as `ret @G` has the same omission (exact code path, not separately executed).
- Failure scenario: A global address introduced through a pointer phi is unbound, despite a complete initializer being supplied. A direct global-address return is similarly invisible to the materializer.
- Fix: Use an explicit complete IR operand walker, including tuple-shaped phi inputs and terminators, rather than shallow field reflection. Seed every referenced global once in the entry frame.
- Test: Global-only phi input, select/call argument, direct global-address return, and multi-function versions, all with real value assertions and full reversal.
- Already tracked? No matching open bead.

### F9 — [S1] Aggregate phi/select values cannot flow through the slot-family lowering
- Where: `src/ir/ingest.jl:521-526,780-787`; `src/ir/ingest_phi.jl:32-35`; `src/ir/ingest_body.jl:153-155`.
- Evidence: VERIFIED-BY-EXECUTION. Build `agg=IRInsertValue(:agg,ZERO_AGG,x,0,64,2)`; forward it through `IRPhi(:p,128,[(SSAOperand(:agg),:entry)])` in a successor, then extract element zero. Lowering rejects `IRExtractValue agg=:p ... is NOT a known aggregate`. Replacing the phi with `IRSelect(:p,cond,agg,agg,128)` produces the same refusal. The aggregate registry includes only insertvalue/insertbits/multi-return-call definitions, never their phi/select results.
- Failure scenario: Aggregate construction/extraction individually work, but a valid aggregate moved through control flow ceases to be recognized. Simply relaxing the membership guard would instead emit scalar references to nonexistent keys: the phi/select operations themselves are also not decomposed.
- Fix: Track aggregate shapes through SSA, expand aggregate phi parameters and edge arguments into slot families, and lower aggregate selects per slot. Enforce shape agreement across predecessors. If intentionally deferred, explicitly document the missing composition in coverage claims.
- Test: `[2 x i64]` phi with distinct branch values, a loop-carried aggregate, and aggregate selection followed by extraction; compare each slot to an independent oracle and reverse completely.
- Already tracked? No specific open bead; `bennettvm-x3t0` concerns aggregate returns, not phi/select propagation.

### F10 — [S0] Re-executing a static alloca in a loop aliases earlier still-live allocations
- Where: `src/ir/ingest_body.jl:649-675`; `src/ir/ingest.jl:457-474,625-638`; `src/ir/stack_alloca.jl` forward.
- Evidence: VERIFIED-BY-EXECUTION. Entry→loop→loop→done; loop phi i starts 0 and increments to 2. Each iteration executes `IRAlloca(:p,64,ConstOperand(1))`, stores `7+2*i`, and carries the FIRST pointer in a phi/select. Done loads that first pointer. VM prints `loop alloca output=9 expected=7`, then `restored=true history_empty=true`. Both executions use the same compile-time base plus the unchanged frame stack_top.
- Failure scenario: Legal LLVM alloca in a loop must allocate fresh storage each time; retaining the first pointer must retain the first object. The compile-time-per-instruction allocation scheme merges distinct dynamic allocation instances.
- Fix: At the correctness floor, reject static allocas in re-enterable/non-entry blocks until runtime allocation per execution is supported. The full fix needs a frame-scoped runtime cursor/lifetime model, including reversal and call isolation, not another fixed compile-time offset.
- Test: Two or more iterations retaining earlier pointers, writes to both objects, conditional allocation, and recursion combined with loop allocation. Forward oracle and full-state reversal must both hold.
- Already tracked? `bennettvm-347o` is the right guard task, but P3 understates the executed silent miscompile. `bennettvm-9v84` concerns the separate dynamic-N re-execution refusal; `hyi6`/VM-core F2 concern cross-function static/dynamic overlap, not this same-instruction loop alias.

### F11 — [S0] Legacy CallInstruction silently executes no call, and its tests bless the no-op
- Where: `src/ir/call_instruction.jl:295-313,349-352`; `src/interpreter/Interpreter.jl:1517-1519`; `test/test_call_instruction.jl:82-109`.
- Evidence: VERIFIED-BY-EXECUTION. A one-block VMProgram with Begin(:main,[:x]), body `CallInstruction([:y],:missing,[:x],:call)`, End(:main,[:x]), input x=8, runs to `status=halted y_defined=false` and reverses exactly. No error is raised for the nonexistent callee. The interpreter dispatches only CallEnter; the legacy forward merely increments pc. Current tests explicitly require unchanged locals after a purported call/uncall.
- Failure scenario: A constructible VMProgram using this retained instruction silently skips subroutine side effects/results, or ignores an unknown callee. Ingest currently emits CallEnter instead, so this does not implicate normal ParsedIR calls, but the supported instruction surface is not fail-loud.
- Fix: Remove the obsolete class from executable programs, or make its forward raise a clear migration error pointing to CallEnter/ReturnExit. Retain structural-only tooling only behind an explicitly non-executable representation. Replace pc-only execution tests with refusal tests or real call semantics.
- Test: Unknown callee, void call with a visible memory effect, value-returning call and uncall; no executable call opcode may silently skip its callee.
- Already tracked? `bennettvm-xo2v` says remove superseded CallInstruction. The description is directionally right but frames live silent acceptance as P3 dead-code cleanup. `bennettvm-7cg` tests pc symmetry, which cannot establish call semantics.

### F12 — [S1] IRInsertBits lowering depends on physical block order rather than SSA dominance
- Where: `src/ir/ingest.jl:487-490,530-534,828-851`.
- Evidence: VERIFIED-BY-EXECUTION. CFG entry→producer→consumer. Producer defines `a=IRInsertBits(ZERO_AGG,x,0,64,128)`; consumer defines `b=IRInsertBits(a,9,64,64,128)` and extracts slot 0. Blocks `[entry,producer,consumer]` run to `7` for x=7. Identical CFG with vector order `[entry,consumer,producer]` fails `IRInsertBits agg is Bennett.SSAOperand (dest=b) — expected ... prior IRInsertBits dest`. `bits_index` is populated during emission, unlike `agg_dests`' explicit pre-scan.
- Failure scenario: A valid definition dominates its use in the CFG but appears later in the serialized block vector. Ordinary LLVM block layout need not be dominance order.
- Fix: Compute insertbits chain metadata independently of emission order (definition map plus dependency traversal with cycle/malformed-chain checks), then emit in the original desired order. A blanket block-order precondition would need explicit validation and an upstream guarantee that does not currently exist.
- Test: Permute non-entry blocks without changing CFG edges and demand identical forward results/full reversal, for both straight-line chains and chains across branches.
- Already tracked? No matching open bead.

## Unconfirmed suspicions

## What is sound (brief)

## Nits (S4)

## Coverage log

- Read root `CLAUDE.md` in full before all other repository files. The user's review-only restrictions override its mutation and session-push workflow.
