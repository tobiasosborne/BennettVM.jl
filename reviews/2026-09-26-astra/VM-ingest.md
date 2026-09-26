# Astra review — VM-ingest — 2026-09-26
Status: COMPLETE
Scope: VM ingestion/frontend, call/control instructions, test suite, ADR/PRD consistency.
Method: Read-only source review and focused Julia probes with bounds checking; only this report is modified. No full suite, issue-tracker commands, commits, or CI.

## Executive summary

19 findings: **7 S0, 10 S1, 2 S2**; 17 have executed evidence, 2 are static code/document audits.
Seven silent-failure mechanisms include narrow GEP indices, loop allocation reuse, map-key widths, callee/global identity, generated names and legacy calls.
The real LLVM GEP probe returned 0 instead of 11; all seven silent-failure mechanisms admitted clean reversal in their witnesses.
Valid Int32 calls, Unicode names, literal control flow and several aggregate/global compositions also fail.
The property gate accepted a demonstrated wrong result; its determinism comparator equated programs returning 1 and 999.
Eleven selected existing test files passed **2,002 assertions**, including the included per-step scaffold; no full suite was run.
Scalar parallel phi swaps, three-way joins, modern recursive calls and the hsm3 certification gate passed focused checks.
Fix semantic boundaries before broadening “covered” claims; repairs and regression tests are specified per finding.

## Findings

### F1 — [S0] A computed narrow negative GEP index is interpreted as a positive offset

- Where: `src/ir/ingest_body.jl:207-225`; `src/ir/array_index.jl` VarGEP forward; upstream `src/ir_types.jl:248-253`, `src/extract/instructions.jl:7173`; `src/ir/arithmetic_assignment.jl:258`.
- Evidence: Verified: VERIFIED-BY-EXECUTION, including LLVM verifier and the real extraction path. The LLVM program below passes `Bennett.LLVM.verify`, is extracted by `Bennett._extract_from_module(mod,"idx",String[]; mem=:auto,ptr_cells=true)`, lowered, run and reversed. Printed `i8 GEP output=0 expected=11 index=255`, then `restored=true history_empty=true`.
```llvm
define i64 @idx() {
entry:
  %a = alloca i64, i64 3
  %b = getelementptr i64, ptr %a, i64 1
  store i64 11, ptr %a
  store i64 22, ptr %b
  %i = sub i8 0, 1
  %p = getelementptr i64, ptr %b, i8 %i
  %r = load i64, ptr %p
  ret i64 %r
}
```
- Failure scenario: LLVM sign-extends the i8 index -1 to the pointer index width, so p points back to a and must read 11. Width-aware subtraction stores 255; IRVarGEP has no index-width field and the VM adds that raw positive carrier, addressing an unrelated cell that reads as zero. This is an in-bounds native access, not poison or undefined memory in the source.
- Fix: Preserve the index width and sign-extend to the address-index width before pointer arithmetic, ideally normalizing it explicitly in ParsedIR. Handle the datalayout index-width contract as well; do not infer signedness from the Int64 carrier. Boundary rejection is preferable to accepting an unrepresentable index type.
- Test: Negative computed indices at i8/i16/i32, equivalent negative literal indices, positive indices with the sign bit clear, and both static/dynamic bases. Compare addresses/loads to a native or independent reference, then reverse completely.
- Already tracked? No matching open bead. `bennettvm-bgc` fixed arithmetic masking but did not audit pointer-index consumers of the newly zero-extended narrow carrier.

### F2 — [S0] Re-executing a static alloca in a loop aliases earlier still-live allocations

- Where: `src/ir/ingest_body.jl:649-675`; `src/ir/ingest.jl:457-474,625-638`; `src/ir/stack_alloca.jl` forward.
- Evidence: Verified: VERIFIED-BY-EXECUTION. Entry→loop→loop→done; loop phi i starts 0 and increments to 2. Each iteration executes `IRAlloca(:p,64,ConstOperand(1))`, stores `7+2*i`, and carries the FIRST pointer in a phi/select. Done loads that first pointer. VM prints `loop alloca output=9 expected=7`, then `restored=true history_empty=true`. Both executions use the same compile-time base plus the unchanged frame stack_top.
- Failure scenario: Legal LLVM alloca in a loop must allocate fresh storage each time; retaining the first pointer must retain the first object. The compile-time-per-instruction allocation scheme merges distinct dynamic allocation instances.
- Fix: At the correctness floor, reject static allocas in re-enterable/non-entry blocks until runtime allocation per execution is supported. The full fix needs a frame-scoped runtime cursor/lifetime model, including reversal and call isolation, not another fixed compile-time offset.
- Test: Two or more iterations retaining earlier pointers, writes to both objects, conditional allocation, and recursion combined with loop allocation. Forward oracle and full-state reversal must both hold.
- Already tracked? `bennettvm-347o` is the right guard task, but its explicit claim “sound under L3 today” is FALSE: L3 restores state after the wrong forward computation, as the probe demonstrates. P3 understates this silent miscompile. `bennettvm-9v84` concerns the separate dynamic-N re-execution refusal; `hyi6`/VM-core F2 concern cross-function static/dynamic overlap, not this same-instruction loop alias.

### F3 — [S0] Ingestion drops map key widths, so equal narrow keys become different dictionary entries

- Where: `src/ir/ingest_body.jl:432-467`; `src/ir/arithmetic_assignment.jl:241-258`; upstream `src/ir_types.jl:312-352`.
- Evidence: Verified: VERIFIED-BY-EXECUTION. One i8 block: `IRMapInsert(x,7,8,8); same=IRBinOp(:add,x,0,8); IRMapInsert(same,9,8,8); r=IRMapGet(x,8,8); ret r`. Input `x=Int64(-1)` gives printed `r=7, same=255, x=-1`, expected `9`; `restored=true history_empty=true` after unrun. The Julia oracle is `d=Dict{Int8,Int8}(); d[x]=7; d[x+Int8(0)]=9; d[x]` for `x=Int8(-1)`.
- Failure scenario: Narrow arithmetic canonicalizes to low-width bits, while raw signed inputs/constants retain sign extension. The map lowering erases `key_width`, so the two representations of the SAME key are distinct Int64 keys. A second insertion does not overwrite the first and returns a silently stale value.
- Fix: Preserve key/value widths in VM map instructions or insert canonicalization at every map boundary. All insert/get/delete operations must agree on the canonical representation; preserve value-width semantics too.
- Test: Negative Int8/Int16 keys computed by arithmetic versus passed directly, both insertion orders and deletion, forward comparison to Julia and complete L2/L3 reversal.
- Already tracked? No specific open bead. The arm comment calls width masking a `bennettvm-bgc` follow-on, but bgc's arithmetic masking is already implemented; it does not fix this map boundary and actually exposes the inconsistent representations.

### F4 — [S0] Bare-name intrinsic dispatch silently replaces a supplied in-module function body

- Where: `src/ir/ingest_body.jl:269-287,372-432`; `src/ir/ingest_call.jl:169-176`; `src/ir/ingest_multi.jl:136-158`.
- Evidence: Verified: VERIFIED-BY-EXECUTION. Supply two ParsedIRs: `malloc(a::i64)` computes `v=a+10; ret v`; `f(x::i64)` calls `IRCall(:r,:malloc,[x],[64],64); ret r`. `lower_vm([:f=>f,:malloc=>g])` succeeds. With x=8 the VM prints `output=1099511627776 expected=18`, then `restored=true history_empty=true`. The explicit callee body is never executed: the heap-name check wins before function-table lookup.
- Failure scenario: User/module-defined functions sharing a runtime-intrinsic name (legal for a Julia function in another module, or an explicitly supplied IR body) silently acquire allocator/bulk semantics. Module qualification has already been discarded. Nondeterminism-name matches similarly reject otherwise deterministic supplied bodies.
- Fix: Carry resolved callee identity/provenance, and distinguish actual runtime declarations from supplied definitions. At minimum reject any module whose function table collides with reserved intrinsic names; never accept both interpretations and silently choose one.
- Test: Custom named `malloc`, `free`, and modeled-cell names; ensure body execution or a named ambiguity refusal. Test Function and Symbol IRCall forms, with golden results and reversal.
- Already tracked? No matching open bead. ADR 0018's guard-order rule explains the implementation but does not justify silently substituting a supplied definition.

### F5 — [S0] Multi-function lowering duplicates a shared global object and breaks pointer identity

- Where: `src/ir/ingest_multi.jl:180-213`; `src/ir/ingest.jl:260-281`.
- Evidence: Verified: VERIFIED-BY-EXECUTION. Both ParsedIRs carry `globals=Dict(:G=>(UInt64[7],64))`. Caller f passes `SSAOperand(:G)` to g; g computes `IRICmp(:eq,:eq,SSAOperand(:p),SSAOperand(:G),64)` and zexts it to i64. The VM prints `global pointer identity output=0 expected=1`, with exact restoration and empty history afterward. f's G lives at GLOBAL_BASE; g's G lives at GLOBAL_BASE+1. The code deliberately advances a per-function global cursor, allocating the same module object twice.
- Failure scenario: The address of a shared read-only global crosses a call, then is compared with that same global in the callee. Equal native pointers become unequal VM pointers. Certified singleton identity across separately extracted Julia bodies has the same architectural risk; that broader frontend case was not executed here.
- Fix: Allocate globals once at module scope using stable object identity/linkage, then pass one mapping into every function. Equal contents alone are insufficient for deduplication: distinct objects with equal bytes must remain distinct. Preserve provenance across the extraction boundary where separate bodies rename the same singleton.
- Test: One shared global referenced in two functions, distinct equal-valued globals, passing pointers through recursive calls, and a real certified empty-Memory singleton shared across bodies. Compare identity results and full round-trip state.
- Already tracked? No matching open bead. The old `bennettvm-h6c3`/416r.13 disjoint-window fix avoids accidental address collisions but does not preserve shared identity.

### F6 — [S0] Synthetic register names can overwrite legal input SSA names

- Where: `src/ir/ingest_phi.jl:120,135-136,150-151`; `src/ir/ingest.jl:417-421,905-908` (same unchecked namespace pattern for aggregate/call temporaries).
- Evidence: Verified: VERIFIED-BY-EXECUTION. ParsedIR argument `:_phi_const_entry_1=10`; entry branches to next; next has `a=phi [1,entry]`, then `r=add(arg,a)`. Lowering adds a `Define(:_phi_const_entry_1,1,:add,0)` to entry and silently overwrites the argument. Output is `2`, expected `11`; reversal restores the initial state and empties history.
- Failure scenario: A legal LLVM/ParsedIR identifier equals a synthesized temporary. No freshness scan or reserved-prefix validation exists. This is a forward miscompile, not merely an ugly error for unusual names.
- Fix: Build a per-function used-name set covering arguments, all instruction definitions, and global symbols; allocate every generated name through a freshness allocator. Do the equivalent for generated block labels.
- Test: Deliberate collisions with each synthetic family (`_phi_const_`, `_phi_ssadup_`, `_agg_`, `_callconst_`) and generated edge labels; verify either hygienic lowering or a clear boundary rejection, plus expected output and reversal.
- Already tracked? `bennettvm-3ah` partially covers synthetic-name hardening, but its recorded example is wrong: `(src=:a_1,value=3)` and `(src=:a,value=13)` produce DIFFERENT strings. The executed user-name collision above is real and more severe than the bead's P3 framing.

### F7 — [S0] Legacy CallInstruction silently executes no call, and its tests bless the no-op

- Where: `src/ir/call_instruction.jl:295-313,349-352`; `src/interpreter/Interpreter.jl:1517-1519`; `test/test_call_instruction.jl:82-109`.
- Evidence: Verified: VERIFIED-BY-EXECUTION. A one-block VMProgram with Begin(:main,[:x]), body `CallInstruction([:y],:missing,[:x],:call)`, End(:main,[:x]), input x=8, runs to `status=halted y_defined=false` and reverses exactly. No error is raised for the nonexistent callee. A second probe supplied a real `g(a)=a+10` FunctionEntry/body and an initial live caller target y=3; calling it with x=8 via legacy CallInstruction printed `output=3 expected=18`, then `restored=true empty=true`. Thus this is also a wrong-answer witness with an actual callee. The interpreter dispatches only CallEnter; the legacy forward merely increments pc. Current tests explicitly require unchanged locals after a purported call/uncall.
- Failure scenario: A constructible VMProgram using this retained instruction silently skips subroutine side effects/results, or ignores an unknown callee. Ingest currently emits CallEnter instead, so this does not implicate normal ParsedIR calls, but the supported instruction surface is not fail-loud.
- Fix: Remove the obsolete class from executable programs, or make its forward raise a clear migration error pointing to CallEnter/ReturnExit. Retain structural-only tooling only behind an explicitly non-executable representation. Replace pc-only execution tests with refusal tests or real call semantics.
- Test: Unknown callee, void call with a visible memory effect, value-returning call and uncall; no executable call opcode may silently skip its callee.
- Already tracked? `bennettvm-xo2v` says remove superseded CallInstruction. The description is directionally right but frames live silent acceptance as P3 dead-code cleanup. `bennettvm-7cg` tests pc symmetry, which cannot establish call semantics.

### F8 — [S1] The Float32 guard rejects ordinary closed-world Int32 calls

- Where: `src/ir/ingest_body.jl:343-375`.
- Evidence: Verified: VERIFIED-BY-EXECUTION. Construct `g(a::i32) = ret a` and `f(x::i32) = r=IRCall(:r,:g,[SSAOperand(:x)],[32],32); ret r`, package them as `lower_vm([:f=>caller,:g=>callee])`. Julia prints `IRCall to soft op :g ... touches Float32 (ret_width=32, arg_widths=[32])`. Both functions contain integers only. The guard runs before function-table resolution and does not require membership in `_SOFT_DISPATCH`.
- Failure scenario: A valid non-inlined integer function with a 32-bit argument OR return cannot compile. The error falsely describes it as floating-point double rounding.
- Fix: Resolve known VM callees before the floating-point-only guard, or restrict that guard to the explicitly identified soft-float callees whose positions represent f32. Preserve the nondeterminism/intrinsic precedence deliberately.
- Test: Real `@noinline g(::Int32)` extraction plus synthetic mixed-width signatures; compare forward output to Julia and reverse the complete state under L2 and L3. Keep actual f32 refusals.
- Already tracked? No matching open bead; `bennettvm-h0t` introduced the boundary guard but describes only genuine floating-point calls.

### F9 — [S1] Content-addressed Unicode function names fail at the digest-stripping boundary

- Where: `src/ir/ingest_multi.jl:57-61`.
- Evidence: Verified: VERIFIED-BY-EXECUTION. `_vm_funcname(Symbol("alpha#12345678"))` prints `alpha`; the identical call on `Symbol("α#12345678")` raises `StringIndexError: invalid index [2], valid nearby indices [1]=>α, [3]=>#`; `fα#12345678` fails at index 3. Julia string indices are byte indices, and `end-9` lands on the final continuation byte when the bare name ends with a multibyte character.
- Failure scenario: A valid Julia function named α (or any name ending in a multibyte character) receives a content-addressed extraction key, then lower_vm fails before processing its body. This affects the main closed-world Julia handoff.
- Fix: Strip the matched suffix using character-safe operations (`chop(s; tail=9)` for the ASCII suffix, or a regex replacement anchored to the suffix), then sanitize the bare name. Do not subtract bytes to obtain a character index.
- Test: ASCII, Greek, accented and supplementary-plane Unicode barenames, with and without closure markers, through actual multi-function lowering and forward/reverse execution.
- Already tracked? No matching open bead.

### F10 — [S1] A valid constant conditional branch crashes during lowering

- Where: `src/ir/ingest.jl:970-979`; `src/ir/ingest_phi.jl:57-63`; upstream `src/ir_types.jl:466-470`.
- Evidence: Verified: VERIFIED-BY-EXECUTION. A three-block `ParsedIR(64,[(:x,64)],...)` with entry terminator `IRBranch(ConstOperand(1),:yes,:no)` and both successors `IRRet(SSAOperand(:x),64)` fails with `FieldError: type Bennett.ConstOperand has no field name`. The branch lowering unconditionally reads `term.cond.name`. The IR type expressly permits a constant condition.
- Failure scenario: Unfolded LLVM `br i1 true`/`false` accepted by the frontend cannot become a VM program, although constant-select handling already accommodates the analogous shape.
- Fix: Validate the i1 constant and emit the selected unconditional edge; account for any pruned incoming edges consistently. Alternatively materialize a fresh normalized condition register. Do not merely convert the FieldError to a refusal for this ordinary supported control-flow shape.
- Test: Constants 0, 1 and -1, distinct successors with distinct observable results, phi incoming values, and full reversal; reject non-i1 literals descriptively.
- Already tracked? No matching open bead.
- Additional VERIFIED-BY-EXECUTION case: `IRBranch(SSAOperand(:c),:next,:next)` is valid but fails `ConditionalExit: target_true and target_false both equal e_entry_next`. Normalize identical successors and deduplicate predecessor edges during ingest; the VM constructor is right to require its normalized representation.

### F11 — [S1] Scalar literal returns remain unsupported, including ordinary constant functions

- Where: `src/ir/ingest.jl:930-935`; `src/ir/ingest_multi.jl:85-95`.
- Evidence: Verified: VERIFIED-BY-EXECUTION. `ParsedIR(64,[(:x,64)],[IRBasicBlock(:entry,IRInst[],IRRet(ConstOperand(42),64))],[64])` fails with `IRRet of a literal (42) is unsupported`. `_declared_returns` additionally classifies every non-SSA return as void, which must be corrected when adding the create.
- Failure scenario: `f(x)=42`, literal base cases, and optimized constant-return callees are valid scalar programs but cannot lower.
- Fix: Materialize a fresh constant-result register before End, and derive return arity from the return ABI rather than whether the first return operand happens to be SSA. Support mixed literal/SSA return blocks consistently.
- Test: Constant entry function, a callee returning a constant, and mixed branch returns; golden output and complete L2/L3 reversal.
- Already tracked? `bennettvm-cw4g` mentions literal returns, but its description conflates `ret void` with `ret const`: explicit void IRRet is implemented at `ingest.jl:918-929`; literal scalar returns are the surviving defect.

### F12 — [S1] Globals used only by phi incoming values or terminators are never initialized

- Where: `src/ir/ingest.jl:238-251,266-268`; `src/ir/ingest_phi.jl:85-97`.
- Evidence: Verified: VERIFIED-BY-EXECUTION for phi. With `globals=Dict(:G=>(UInt64[7],64))`, entry branches to next, whose only instructions are `p=IRPhi(:p,0,[(SSAOperand(:G),:entry)])` and `r=IRLoad(:r,p,64)`. Lowering accepts it; run fails `KeyError: key :G not found`. `_referenced_global_names` checks vector elements only when each element itself is SSAOperand; phi elements are tuples. `_global_segment` also never visits a block's terminator, so a global used only as `ret @G` has the same omission (exact code path, not separately executed).
- Failure scenario: A global address introduced through a pointer phi is unbound, despite a complete initializer being supplied. A direct global-address return is similarly invisible to the materializer.
- Fix: Use an explicit complete IR operand walker, including tuple-shaped phi inputs and terminators, rather than shallow field reflection. Seed every referenced global once in the entry frame.
- Test: Global-only phi input, select/call argument, direct global-address return, and multi-function versions, all with real value assertions and full reversal.
- Already tracked? No matching open bead.

### F13 — [S1] Aggregate phi/select values cannot flow through the slot-family lowering

- Where: `src/ir/ingest.jl:521-526,780-787`; `src/ir/ingest_phi.jl:32-35`; `src/ir/ingest_body.jl:153-155`.
- Evidence: Verified: VERIFIED-BY-EXECUTION. Build `agg=IRInsertValue(:agg,ZERO_AGG,x,0,64,2)`; forward it through `IRPhi(:p,128,[(SSAOperand(:agg),:entry)])` in a successor, then extract element zero. Lowering rejects `IRExtractValue agg=:p ... is NOT a known aggregate`. Replacing the phi with `IRSelect(:p,cond,agg,agg,128)` produces the same refusal. The aggregate registry includes only insertvalue/insertbits/multi-return-call definitions, never their phi/select results.
- Failure scenario: Aggregate construction/extraction individually work, but a valid aggregate moved through control flow ceases to be recognized. Simply relaxing the membership guard would instead emit scalar references to nonexistent keys: the phi/select operations themselves are also not decomposed.
- Fix: Track aggregate shapes through SSA, expand aggregate phi parameters and edge arguments into slot families, and lower aggregate selects per slot. Enforce shape agreement across predecessors. If intentionally deferred, explicitly document the missing composition in coverage claims.
- Test: `[2 x i64]` phi with distinct branch values, a loop-carried aggregate, and aggregate selection followed by extraction; compare each slot to an independent oracle and reverse completely.
- Already tracked? No specific open bead; `bennettvm-x3t0` concerns aggregate returns, not phi/select propagation.

### F14 — [S1] IRInsertBits lowering depends on physical block order rather than SSA dominance

- Where: `src/ir/ingest.jl:487-490,530-534,828-851`.
- Evidence: Verified: VERIFIED-BY-EXECUTION. CFG entry→producer→consumer. Producer defines `a=IRInsertBits(ZERO_AGG,x,0,64,128)`; consumer defines `b=IRInsertBits(a,9,64,64,128)` and extracts slot 0. Blocks `[entry,producer,consumer]` run to `7` for x=7. Identical CFG with vector order `[entry,consumer,producer]` fails `IRInsertBits agg is Bennett.SSAOperand (dest=b) — expected ... prior IRInsertBits dest`. `bits_index` is populated during emission, unlike `agg_dests`' explicit pre-scan.
- Failure scenario: A valid definition dominates its use in the CFG but appears later in the serialized block vector. Ordinary LLVM block layout need not be dominance order.
- Fix: Compute insertbits chain metadata independently of emission order (definition map plus dependency traversal with cycle/malformed-chain checks), then emit in the original desired order. A blanket block-order precondition would need explicit validation and an upstream guarantee that does not currently exist.
- Test: Permute non-entry blocks without changing CFG edges and demand identical forward results/full reversal, for both straight-line chains and chains across branches.
- Already tracked? No matching open bead.

### F15 — [S1] ArithmeticAssignment accepts aliasing that makes its empty history payload insufficient

- Where: `src/ir/arithmetic_assignment.jl:110-125,311-324,337-348,408-411,466-468`; `src/history/Injective.jl:607`.
- Evidence: Verified: VERIFIED-BY-EXECUTION. `instr=ArithmeticAssignment(:x,:y,:add,:x,:add,Int64(1))`, initial locals `Dict(:x=>3,:y=>5)`. Direct forward followed by direct inverse returns without error but prints `restored=false locals=Dict(:y => -1)`; the original x=3 is gone and original y=5 is wrong. Forward overwrites x with 9; inverse recomputes its expression from new x=9. Constructors validate only operator names and impose no alias/fresh-target preconditions.
- Failure scenario: A hand-built accepted instruction reads an operand it overwrites or destroys. Its expression is not available unchanged to the inverse, contrary to the claimed empty-delta proof. Normal ParsedIR arithmetic emits Define, so this is the lower-level RSSA API/checking boundary, not a claim that ordinary IRBinOp lowering uses this instruction.
- Fix: Enforce the reversible-assignment preconditions (source/target cannot occur in the expression, and a distinct target cannot overwrite a live value) at construction/runtime validation, or log the destroyed information and classify the instance accordingly. Apply the rule consistently to direct execution, L1 and L2.
- Test: All source/target/RHS alias combinations and live-target overwrite; each must fail before mutation or round-trip exactly with adequate history. Include a two-state collision witness for any instance still declared injective.
- Already tracked? `bennettvm-axfr` covers a future general validator, but no dedicated alias/precondition bead was found. `bennettvm-ack` must not broaden injectivity to add/sub until these preconditions are enforced.

### F16 — [S1] The random-program property gate never checks forward semantics against an independent oracle

- Where: `test/test_property_roundtrip.jl:176-216`; `test/test_per_step_inverse.jl:240-315`; `test/generators/random_program.jl:164-171`.
- Evidence: Verified: VERIFIED-BY-EXECUTION. Loaded the actual `_full_roundtrip!` definition from the test file and ran the synthetic-name-collision program above (oracle 11, actual 2). It printed `known wrong result=2 oracle=11` and `actual property helper accepted=true`. `_full_roundtrip!` runs, checks only halt, immediately un-runs, and compares restored states. `_sweep_one!` adds per-step inverse checks whose reference snapshots were generated by the same VM forward implementation. The generator returns only `(vm, inputs)`, with no reference evaluator/expected result, and neither property file nor generator calls `result` to check an independent answer. The only mutation here targets inverse's modop flip, not forward semantics.
- Failure scenario: A deterministic wrong forward computation that replays consistently can satisfy every L3 check and the aggregate round-trip. The executed silent-forward findings above demonstrate why reversal alone is insufficient. PRD §3.14 and the review's required golden-master leg are missing from this capstone gate.
- Fix: Generate a source-level semantic model/oracle alongside each program and compare forward outputs (and observable memory where applicable) before reversing. The oracle must not delegate to VM forward or `_apply_binop`.
- Test: Mutation-prove a forward-only wrong result under L3 becomes red; retain the independent inverse mutation tests too.
- Already tracked? No specific open bead; `bennettvm-jpb` concerns generator hardening but does not replace the missing oracle.

### F17 — [S1] The determinism checker declares different programs structurally equal

- Where: `test/generators/random_program.jl:463-476`; determinism testsets in that file and `test/test_property_roundtrip.jl`.
- Evidence: Verified: VERIFIED-BY-EXECUTION. Load the actual generator definitions via `include_string` up to `# 6. Testsets`. Construct two otherwise identical single-block VMPrograms with `Define(:r,1,:add,0)` versus `Define(:r,999,:add,0)`. `_structural_eq(p1,p2)` prints `true`; executing them prints `result=1` and `result=999`. The comparator checks instruction TYPES only, never fields; entry/exit labels, operands, literal values, operators and branch destinations can differ undetected.
- Failure scenario: Generator nondeterminism or a changed random program can pass the claimed exact same-program test while computing a different function. A successful round-trip of each program does not detect that discrepancy.
- Fix: Compare every semantic instruction/control field and all relevant program metadata structurally, or serialize a canonical semantic representation. Avoid using identity equality for mutable vectors/dicts.
- Test: Perturb one literal, operator, operand, branch destination, call target and width at a time and assert inequality; equivalent independent allocations must remain equal.
- Already tracked? `bennettvm-jpb` is related generator hardening; no specific open bead for this comparator was found.

### F18 — [S2] Random “looping” coverage contains no loop back-edges or loop-carried phi values

- Where: `test/generators/random_program.jl:164-170,349-393,450-456`; `test/test_property_roundtrip.jl:17-20,233-250`; PRD §3.15.
- Evidence: Verified: REASONED-ONLY (exact generator path). `random_program(default_rng(); shape=:looping, size_hint=6)` dispatches to `_random_unrolled_loop`; it builds one `b_iter_k` block per iteration, targeting only `b_iter_(k+1)` or `b_done`. `_classify_shape` labels it looping from the NAME prefix alone. No generated edge returns to an earlier block, no SSA destination is redefined across iterations, and no loop-carried binding is exercised.
- Failure scenario: The 100-program property gate cannot detect the cross-iteration errors most relevant to an unbounded-loop VM (including the loop-allocation failure above), despite being presented as the PRD's bounded-loop random coverage.
- Fix: Add actual bounded cyclic CFG generation with a runtime induction value and loop-carried parameters, plus an independent termination bound and oracle. Keep unrolled chains as a separate shape.
- Test: Assert an SCC/back-edge exists for every generated loop case and that at least one selected case executes its back-edge multiple times. Add phi swap, multi-use and nested-loop variants.
- Already tracked? `bennettvm-jpb` is related; the stale generator comment still says true loops wait for `bennettvm-c39`, which is already implemented.

### F19 — [S2] The coverage matrix and “Current coverage (HEAD)” plan disagree with shipped ingestion

- Where: `docs/coverage-matrix.md:14-17,65-92,104-143`; `docs/opcode-coverage-plan.md:13-20`; `src/ir/ingest.jl:801-855,936-967`; `src/ir/ingest_body.jl:359-432`.
- Evidence: Verified: REASONED-ONLY for the documentary comparison; shipped InsertBits execution is independently VERIFIED in F14. The matrix declares IRInsertBits N/A/never reaching BVM and all aggregate returns deferred, yet insertbits and inner multi-return lowering plus dedicated tests exist. It describes IRCall as soft-only, despite closed-world CallEnter and heap intrinsics. The plan still states 15/19 with IRPtrOffset/InsertValue/ExtractValue gaps, while the matrix states 18/20 and those lowerings are implemented. Conversely “IRRet COVERED” omits literal returns and “IRPhi COVERED” omits aggregates. The code/test paths cited by line number often moved to split files long ago.
- Failure scenario: Future work is prioritized from false gaps; broad green rows conceal unsupported compositions and tell reviewers to ignore a live instruction family.
- Fix: Rebuild the matrix from current subtype/dispatch inventories; distinguish supported shapes, deliberate boundary refusals, and tests of execution versus tests of rejection. Label frozen plan state with a date instead of HEAD. Update SoftCall's coverage to its actual four imported groups.
- Test: A lightweight inventory check can assert each current IR subtype has a documented disposition and at least one corresponding test; semantic support still requires real end-to-end tests.
- Already tracked? `bennettvm-x49` is the coverage epic; `bennettvm-278` covers older factual PRD/ADR corrections, but not these complete current discrepancies.

## Unconfirmed suspicions

- ADR 0021 B says the GC-disabled classification window contains no yield point “(asserted).” `_gc_pinned` (`../Bennett.jl/src/extract/jlglobal_cert.jl:153-165`) checks thread identity only at exit. That does not detect yielding and resuming on the same thread, or migration away and back. No failing classification/GC scenario was established here; do not promote this to a soundness finding without one.
- ADR 0021 B explicitly discloses that distinct empty singleton **data** pointers share one sentinel. The data-pointer equality observer needed to turn that residual into an accepted end-to-end wrong-answer program was not established here. This is separate from the executed shared-global **object-address** duplication finding.
- Scalar SelectInstruction reads only the selected operand, while LLVM select requires both operand definitions to exist (unselected poison is another matter). A malformed ParsedIR can hide an unbound name behind the unselected arm; no valid frontend program was shown to exploit this. The general dominance-validator bead `bennettvm-axfr` is the right home.


## What is sound (brief)

- Executed four loop-carried phi-swap cases (n=0..3), each with an independent 12/21 alternating oracle and exact reversal, plus all three incoming paths of a three-predecessor join. Scalar phi binding is a genuine two-phase parallel copy: `_bind_args_to_params!` captures all values first (`src/interpreter/Interpreter.jl:1469-1477`). It also preserves multi-use source names under ADR 0022. Do not reintroduce destructive MOVE merely to match old comments.
- Ordinary arithmetic width/signedness handling and casts are substantially implemented, not placeholders. The selected width gate passed 1,464 assertions; direct casts and instruction/control constructors passed their tests. The remaining width findings concern consumers outside that arithmetic kernel.
- Calls use separate frame-local dictionaries; COPY arguments, return residuals, overwritten caller targets and `stack_delta` are implemented. The nested and recursive-factorial tests, in-callee checkpoints and explicit `target_olds` inverse checks passed.
- ≥3-predecessor joins intentionally rely on replay, per ADR 0019 A.4. Absence of a per-edge predecessor register is not by itself a present execution bug. It remains a limitation for a future direct backward dispatcher (`bennettvm-r8nc`), and the core review separately examines the overly strong injectivity trait.
- SoftCall delegates to actual Bennett functions from four FP groups. No duplicate handwritten floating-point arithmetic was found in this layer. Unsupported FP groups remain a coverage limitation, not evidence of numeric drift within the admitted registry.
- A custom unknown IRInst subtype was rejected at ingest with its subtype named; no blanket skip of unknown nodes was found. IRPhi is the deliberate `nothing` case because it becomes block parameters. IRSwitch is normalized upstream; a residual switch is rejected.
- `test_hsm3_literal_certification_vm.jl` passed 48 assertions. It tests real extraction refusals, native-Julia outputs for certified singleton cases, exact reversal and the non-null trap sentinel. The old “jl_global name implies singleton” miscompile is not still present on those tested paths.
- `test_57hd_value_identity_vm.jl` checks nonzero materialized cells, equality to the actually stored address, distinct neighboring fields, escaping sizes/indices, both history regimes and per-step reversal. It is not a vacuous `0-0==0` test. Read but not executed here because its fixture builder writes a temporary file, prohibited by this review's one-file rule.


## Nits (S4)

- Several diagnostics and comments still describe MOVE after COPY/BIND amendments, e.g. constant-call args at `ingest.jl:475-479` and phi duplicates at `ingest_phi.jl:145-148`; update the explanation without undoing correct semantics.
- `lower_vm(multi)`'s default `entry=first(funcs).first` runs before its explicit empty-vector check, so the intended descriptive error cannot handle the default empty call. `frame` in `_lower_parsed_ir` is unused.
- Standalone early test files such as `test_arithmetic_assignment.jl` depend on suite imports. The documented single-file command needs `using Test, BennettVM; include(...)` for those files. This is a harness usability nit, not evidence their assertions fail under normal suite setup.
- ADR 0017 §4b says “exactly three declarations” immediately before listing P1–P5. `BENNETT_JL_PIN.md`'s last-validated SHA is f904d0d, but its final example still checks 31b63a6.


## Coverage log

### Revision and execution conditions

- Read root `CLAUDE.md` in full first. Its mutation/issue/push workflow is overridden by the user's review-only restrictions. Phase is production, not the archived spike.
- Review started at BennettVM `9ddac09`; sibling Bennett was `13c0a29`. `BENNETT_JL_PIN.md` names `f904d0d` as the documentary last validation, but the manifest is a path dependency. Results here describe the checked-out sibling, not a checkout of the documentary pin.
- Only this report was written. No source/test edits, issue commands, git commits/checkouts/stashes, CI, network access, package installation or full `Pkg.test()` occurred. Julia probes used `--startup-file=no --history-file=no --compiled-modules=existing --project --check-bounds=yes`. Source/LLVM fixtures were kept in memory. Other reviewers' report/tracker changes appeared in the shared worktree and were left alone.
- Focused existing-test invocation: `julia --startup-file=no --history-file=no --compiled-modules=existing --project --check-bounds=yes -e 'using Test, BennettVM; for f in (...); include(joinpath("test",f)); end'`. The first attempt lacked the suite imports and failed at `@testset`; the corrected invocation passed all selected files below. No product finding is based on that harness mistake.

| Selected existing file | Observed result |
|---|---|
| `test_arithmetic_assignment.jl` | 28 assertions passed |
| `test_cast_instruction.jl` | 33 passed |
| `test_control_instructions.jl` | 55 passed |
| `test_softcall.jl` | 75 passed |
| `test_label_table.jl` | 22 passed |
| `test_basic_block.jl` | 74 passed |
| `test_vmprogram.jl` | 18 passed |
| `test_width_masking.jl` | 1,464 passed |
| `test_call_roundtrip.jl` | 108 passed, plus its included per-step scaffold's 21 passed |
| `test_416r14_const_cond_select.jl` | 56 passed |
| `test_hsm3_literal_certification_vm.jl` | 48 passed |

Other executed probes are recorded per finding. The real LLVM GEP probe used `Bennett.LLVM` (LLVM is transitive, not a direct package dependency), `LLVM.verify`, and the same `_extract_from_module` path used by `.ll` ingest, with `mem=:auto, ptr_cells=true`. An initial `mem=:vm` attempt correctly refused because that mode expects a recognized Dict/Vector source shape; it was not evidence for the GEP finding.

### Source coverage and deliberate limits

- Read executable paths/constructors of every named in-scope source file: `ingest.jl`, `ingest_body.jl`, `ingest_call.jl`, `ingest_multi.jl`, `VMProgram.jl`, `basic_block.jl`, `label_table.jl`, `operators.jl`, `arithmetic_assignment.jl`, `cast_instruction.jl`, `intrinsics.jl`, `softcall_instruction.jl`, `call_instruction.jl`, `call_frames.jl`, `call_transitions.jl`, `control_instructions.jl`. Also read `ingest_operands.jl`, `ingest_phi.jl`, relevant Define/Select/VarGEP/StackAlloca/map operations and lower_vm wrapper. Long prose comments were sampled around contracts and pitfalls, not all reprinted.
- Followed cross-scope paths only as needed: Interpreter block binding, call dispatch, return synthesis, replay/injectivity boundaries; frame equality; memory's absent-cell convention. The separate VM-core report already covers mixed-width memory, cross-frame static/dynamic overlap, ROM bulk copies, address limits, UInt64 inputs, checkpoint cadence and trap-loop scaffolding; those are not duplicated here as new findings.
- Upstream: current IR types, operand/type widths, scalar/phi/select/GEP conversion, module entry/set walking, callgraph and closed-world checks, semantic literal certification, confined-value admission and value-identity analysis. No claim of a complete audit of the ~8,000-line upstream instruction converter or of every possible LLVM intrinsic.
- Documentation: PRD v4 numeric/frontend/control/testing requirements and milestone context; HANDOFF latest September/August entries; pin; ADR 0017/0021 normative sections in detail; ADR 0012, 0019, 0022, 0023 control/call amendments; decision sections/cross-references of ADR 0001/0002/0003/0008–0016/0018/0020; both coverage documents. Historical literature/performance claims were not independently re-proved from PDFs.
- All **93** `test/test_*.jl` files are registered in `runtests.jl`; whole-directory scans covered assertions, forward/backward calls, imports, mutation mechanisms, environment/toolchain gates and source-writing helpers. Deep reads concentrated on ingestion/opcode, phi/call, widths/casts, FP, property/generator, aggregate, symbol/name, global/certification and ADR 4a/4b tests. This is not a claim to have read every assertion in every history/core test or run all 93 files.

### Test contract audit

| Test area | Forward oracle and reverse coverage actually present / missing |
|---|---|
| Property/generator capstone | Reverse and per-step checks exist, independent forward oracle absent; “loops” are unrolled and structural comparison is incomplete (findings above). |
| `test_symbol_callee_ingest.jl:37-95` | Positive malloc/in-module/void cases assert emitted instruction type/fields only. No run, Julia/native oracle, or reversal in these cases. Related call-runtime tests exist elsewhere; these particular ingestion combinations are not executed here. |
| `test_handoff_smoke.jl` | Compile/digest contract only; not an execution or reversal proof. |
| `test_define.jl:172`, `test_select.jl:186` | Positive run! cases have value assertions, no unrun! in these files. Instruction classes are reversed in other integration tests. |
| `test_forward_interpreter.jl:60-100`, `test_matrix_sum_forward.jl:93-111` | Golden forward tests, no backward leg in these files; separate roundtrip files cover related factories/inputs. The review's per-case three-leg requirement is therefore not universally satisfied. |
| `test_width_masking.jl:119-123,189-195` | `_wm_run` returns a forward value without reversing; a dedicated overflowing multiply/divide case reverses separately. Signed-remainder and unsigned-divide sweeps do not each exercise reversal. The 64-bit self-comparison weakness is already VM-core F15, not a new finding here. |
| `test_fp_roundtrip.jl` | Strong native-bit-pattern polynomial oracle, full roundtrips and per-step checks; an extra headline x=2 run at 328-330 is forward-only. This is not all SoftFloat operations or all Float64 values. |
| Calls and returns | Nested calls, recursion, residuals, target overwrites and frame equality tested and passed. Legacy CallInstruction's pc-only test is the substantive mock-like semantic gap; tests of CallEnter are real VM execution. |
| ADR 0017 4a/4b | Synthetic downstream tests assert materialized pointer identities and live escaping effects, not just halt/no-throw. Upstream supplies the negative admission tests. Their mktempdir fixture builders prevented running them under this review's only-report write rule. |
| Broken/skipped/gated tests | No `@test_broken` or `@test_skip` in test/. `test_global_array_vm.jl:81-88` silently omits clang-dependent blocks except an info message; clang is absent here, rustc is present. `test_fast_mode.jl:148` gates the emulator MVP behind `BENNETTVM_MVP_TESTS=1` (default off), with an info message. No evidence supports claiming that nobody ever runs it. Existing `bennettvm-5o86` correctly records coverage variability. Committed C hashtable/VLA fixtures do run without clang; do not call all C tests skipped. |
| Mutation tests | They replace Julia methods in memory and restore them; they do not mock the whole VM. L2 inverse mutation tests are meaningful for inverse semantics, not substitutes for a forward oracle. The `@test true` lines in call tests follow a throwing per-step checker, so they are not independently vacuous no-throw smoke tests. |

### ADR 0017 / 0021 enforcement map

Each row maps the operative clause to its enforcement, or its boundary. This is a code audit, not blanket certification of upstream proofs.

| Normative clause | Enforcement / result |
|---|---|
| 0017 D1: transitive closed world | `../Bennett.jl/src/extract/callgraph.jl:34-39,67-73`, `julia_set.jl:258-300,359` gather typed invokes and reject unresolved/ambiguous sets; multi ingestion checks duplicate bare names. Unicode name failure and reserved-name dispatch substitution are findings. |
| 0017 D2: reversible call/return, source site recoverable | `call_transitions.jl:270-301,320-405` and Interpreter call dispatch; frame.link stores return pc, residual and target_olds recover discarded register state. COPY amendment is implemented. Legacy class does not implement the promise. |
| 0017 D3: deterministic arena, no-op reclamation, initialized globals | `intrinsics.jl:246-303,325-339,381-405`; `_global_segment`. Monotone arena avoids host-address dependence. Shared-global identity and missing phi/terminator discovery are gaps. Overflow/region issues are VM-core scope. |
| 0017 D4: bounded modeled intrinsics, unknowns fail loud, unreachable traps | `_NONDETERMINISTIC_CALLEES`, `_HEAP_DISPATCH`, `_BENIGN_CELL_DISPATCH`, SoftCall allowlist; synthetic sink in `ingest.jl:347-357,600-607`. Unknown-node probe passed. Name-only substitution and legacy CallInstruction are exceptions described above. |
| 4a(i): positive producer whitelist, named/not suppressed; load-address sentinel caveat | `_foz5_cert_src_kind`, upstream `instructions.jl:1726-1746`; `_foz5_confined_dead_bounds:1803-1808`. Load directly from GlobalVariable excluded; GEP recursively checks its base; phi/select excluded as direct producers. The depth-0 load caveat is accurately disclosed. |
| 4a(ii): nonempty uses, each two-operand i64 sub with ptrtoint sibling | `_foz5_confined_dead_bounds:1809-1827`; saw flag and width/opcode/arity/sibling checks. |
| 4a(iii–iv): all sub uses comparisons; i1-only use closure ending in conditional dead-edge branches | `instructions.jl:1828-1841`, `_foz5_i1_confined:1764-1789`; cycle/depth/use caps, nonempty use requirement and actual condition-operand identity are checked. |
| 4a oracle-match first refusal; no fabricated guard; circuit gate | Entry/admission disjunctions at `instructions.jl:6458-6460,6482-6484`, ptr_cells gating and emitted cell-identity node. Arithmetic/comparison/branch nodes stay on ordinary lowering paths. No new contradictory result established for this predicate. |
| 4a return-same-or-trap claim / possible missed or spurious throw | The syntactic confinement predicate supports the declared boundary; the VM materializes `:__unreachable__`. The ADR explicitly declines a full native guard-equivalence proof, so the disclosed uncertainty is not presented as a newly discovered bug. Global memory soundness still depends on the separate core findings. |
| 4a determinism and circuit isolation | No host addresses are injected by the admission; ptr_cells gates it. Address hashing's proposed long-term guard relocation is a design note, not an implemented permission to execute arbitrary host calls. |
| 4b(i–ii): certified sources on both sides; every use i64 sub | `_57hd_certified:2499-2506`; `_57hd_value_identity_cluster:2528-2574` checks every use and sibling. |
| 4b(iii): same block, same canonical value, store-forward / same-slot-load only | `_57hd_value_identity_cluster:2536-2548,2569-2571`; `_57hd_canon:2376-2464` restricts canonicalization to pointer-result loads in the one block and program-order windows. It neither follows arbitrary cross-block phis nor claims an interprocedural proof. |
| 4b(iv): every forwarded store targets a certified cell | `_57hd_canon:2415-2422` checks `_p06b_cell_ptr_target_kind` before forwarding. |
| 4b fail-closed writers and LLVM attributes | `_57hd_mem_effects:2066-2071`, decode/unknown-bit guards `2076-2082`, `_57hd_write_footprint:2226-2260`, `_57hd_clobbered:2297-2313`; missing effects, unknown writers, non-provably-disjoint writes and exhausted scan budget block the proof. |
| 4b loop safety and bounded analysis | One-block program order, source-parent equality and no phi-source certification provide the stated per-entry reasoning; depth/scan caps return original refs or clobbered, not invented equivalence. No contrary executed witness established in this review. |
| 4b first/second refusal; no fabrication; no circuit widening | Same ordered 583s→foz5→57hd disjunctions; ordinary sub/div/branch emission and ptr_cells gate. The native-attribute truthfulness and LLVM layout/iteration premises remain external input-contract assumptions, not dynamically verified facts. |
| 0021 D1 + A: typed identity; CodeInstance shim; optimized edges / unoptimized bodies | `callgraph.jl:34-39,67-73`; `julia_set.jl:359-392`, default optimize=false. Broad linkage is implemented; reduced bare-name identity has explicit ambiguity refusals and the intrinsic collision defect. |
| 0021 D2: Vector{Pair{Symbol,ParsedIR}}, symbol calls and closed-world check | `julia_set.jl:258-300`, module set walker `module_walk.jl:66-83`, `ingest_multi.jl:126-158`. No silent skip of an unknown supplied IR node found. |
| 0021 D3: type tags never read as data; literal globals as segments | `ingest_call.jl:62-79`; IntrinsicGCAlloc/GenericMemoryAlloc type_tag is metadata, allocation resolves only byte counts (`intrinsics.jl:256-261`). Certification supplies the modeled singleton header; _global_segment copies its values verbatim. |
| 0021 D4: GC-only runtime operations require prior mutation audit | Current finite modeled-cell whitelist is explicit (`ingest_call.jl:214-217,245-265`); dropped ptls/tag fields are visibly unread. This review did not reproduce the historical upstream GC mutation audit or certify arbitrary future benign prefixes. Unverified callees still hit closed-world/allowlist refusals. |
| B: names alone insufficient; K used only for classification, never dereferenced/emitted | `jlglobal_cert.jl:114-140,234-266`; membership table enumerates rooted T.instance objects; certificate stores strings/bools/opaque key, not K. The live producing wrapper surrounds emission and classification (`304-321`). |
| B: GC window opens before emission, closes afterward, no yield “asserted” | `_live_ir_and_certs` and `_gc_pinned` enforce GC disable/restore and detect final-thread mismatch. The stronger no-yield assertion is an unconfirmed concern above. |
| B: uncertified literals fail on first surviving use; dead uses allowed | `_assert_no_refused_jl_global_use:393-435` uses complete SSA-use counts including terminators; refuses raw slot, refused object key and unaliased slot-load result. Executed hsm3 gate passed. |
| B: no live session means no certificates; opt-in live session; imaging/O1 refusal | `_ingest_jl_global_certs:339-344`, `_classify_jl_globals:243-247`, `_jl_global_address:211-224`, direct JIT-alias guard later in the file; no numeric address payload is materialized. Live-session assertion is a documented trust choice. |
| B: one key for equal K, 16-cell ew8 header, length 0, non-null trap sentinel | `_classify_jl_globals:239,254` coalesces equal K **within one module**; `_certified_header_blob:367-370` and seed `373-380`. Executed header/sentinel tests passed. Multi-function object identity is not preserved by the VM's per-function allocation (finding). |
| B: deterministic/cacheable serialized ParsedIR; distinct singleton sentinel residual | No K/certificate survives in ParsedIR. Caching const bindings is explicitly a staleness assumption. Shared sentinel data identity is a disclosed residual, not a newly confirmed reachable miscompile here. |

### Prior-review and tracker claims checked

- `bennettvm-37d` is stale: ingestion now mints duplicate SSA-edge copies (`ingest.jl:398-412`), so the recorded missing-duplicate branch is present. It should not be repeated as an open defect.
- `bennettvm-5js9`'s i1-sub limitation is stale after width-aware `_apply_binop`: all arithmetic results, including sub, mask to width 1. The remaining map/GEP carrier problems are distinct.
- `bennettvm-cw4g` conflates literal and void return; void exists, literal does not. `bennettvm-x3t0`'s description is stale for inner multi-return callees, though entry multi-return is still explicitly deferred.
- `bennettvm-8e7t` correctly warns the first-IRRet names are not authoritative, but “void-flag-only” is outdated: guard-5 now reads return arity for aggregate landing. Actual runtime End supplies each exit's return names, so differing scalar names alone do not currently mis-return.
- `bennettvm-3ah`'s numeric-suffix example does not collide; the executed collision with a legal user SSA name does. `bennettvm-347o`'s “sound under L3” claim is refuted by the loop-allocation probe.
- Existing review directories and VM-core headlines were consulted for duplicate detection. This report does not reassert the old name-based singleton miscompile that hsm3 fixed, nor the phi MOVE/multi-use issue that ADR 0022 fixed.
