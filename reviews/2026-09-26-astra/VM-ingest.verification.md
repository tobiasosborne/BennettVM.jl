# Verification of Astra VM-ingest review (F1–F17) — 2026-09-26

Verifier: independent re-execution, read-only. No edits under `src/`/`test/` in either repo, no `bd`, no commits, no full suite.
Environment: BennettVM HEAD `50bc02f` (`git diff --stat 9ddac09 HEAD -- src test` empty, so identical to the review base);
Bennett.jl HEAD `789bb6c` (drift since the review's `13c0a29` touches only `lowering/memory.jl`, `simulator.jl`, `pebbled_groups.jl`,
`diagnostics.jl`, `controlled.jl` and `fsin.jl`: nothing in `extract/` or `ir_types.jl`).
All probes: `julia --project --check-bounds=yes --compiled-modules=existing <scratch>/vi/fN.jl`, run from the BennettVM.jl root.
The scripts live in the session scratchpad. `common.jl` defines `rt(prog, inputs)`, which snapshots `rs.current`, then runs `run!`, `result`, `unrun!` and compares against the snapshot plus `isempty(history)`.
The review gives its reproducers as prose, so each one was rebuilt from the prose, keeping every name and value it states.

## Summary

| F# | Verdict | Sev ok? | Reachability from the real frontend | Dedup | Note |
|---|---|---|---|---|---|
| F1 | CONFIRMED | Yes (S0) | Real LLVM path (verify + `_extract_from_module`). Julia emits narrow `i32` GEP indices (e.g. `jl_boxed_int8_cache`), but they are zext'd and non-negative. Clang sext's to i64. So negative narrow indices need hand-written `.ll`. | NEW | `output=0 expected=11`, `:i=>255 :p=>257`, restored |
| F2 | CONFIRMED | Yes (S0) | Hand-built only. Clang/Julia put static allocas in the entry block, and the inliner hoists them there. Hand-written `.ll` can do it. | OVERLAPS 347o | `output=9 expected=7`, restored. 347o's "sound under L3" is refuted. |
| F3 | CONFIRMED | Yes (S0), hand-built | Not currently reachable. The real `mem=:vm` Dict recogniser refuses every `IRMapGet` shape for isbits keys (test_dict_roundtrip Part C, bead 0do). | NEW | `output=7 expected=9`, `same=255 x=-1`, restored |
| F4 | CONFIRMED | Yes (S0) | **Real Julia**: `U.malloc(a)=a+10` via `extract_parsed_ir_set_from_julia` lowers to `IntrinsicMalloc` | NEW | real: `1099511627776` vs native 18, restored |
| F5 | CONFIRMED | Yes (S0) | **Real `.ll`** 2-function module via `extract_parsed_ir_set_from_ll(ptr_cells=true)` | NEW | real: `r=0 expected=1`, restored |
| F6 | CONFIRMED | Yes (S0), low likelihood | Needs a user SSA/arg name beginning with `_phi_const_`. Julia (`x::Int64`, `__vN`, `value_phi`) and clang never produce one. | OVERLAPS 3ah | `output=2 expected=11`. 3ah's example indeed does not collide. |
| F7 | CONFIRMED | **No: S1/S2** | Unreachable from ingest: nothing constructs `CallInstruction` except `structural_inverse` of an existing one. Only a hand-built VMProgram reaches it. | OVERLAPS xo2v | unknown callee halts; real callee `output=3 expected=18` |
| F8 | CONFIRMED | Yes (S1) | **Real Julia** `@noinline g(::Int32)` rejected with a Float32 message | NEW | guard `ret_width==32 \|\| any(==(32),arg_widths)` |
| F9 | CONFIRMED | Yes (S1) | **Real Julia** function `α` → `StringIndexError` | NEW | `αf#…` works; names *ending* in multibyte fail |
| F10 | CONFIRMED | Yes (S1) | Real LLVM text path. `br i1 true` extracts as `IRBranch(ConstOperand(-1),…)`. Identical-successor br also extracts. Julia itself folds `if true`. | NEW | `FieldError …no field name` / `ConditionalExit … both equal` |
| F11 | CONFIRMED | **S2** (named refusal) | **Real Julia** `c42(x)=42` and `x>0 ? 1 : x` both refused | DUPLICATE-OF cw4g | cw4g explicitly names "ret const … synthetic create" |
| F12 | CONFIRMED (+extra) | S1 ok, S2 defensible | Not currently reachable: upstream refuses a raw `@G` operand in a phi (`unknown operand ref`) | NEW | phi: runtime `KeyError :G`. `ret @G`: accepted and silently returns no key. |
| F13 | CONFIRMED | **S2** (named refusal) | Real LLVM text `phi [2 x i64]` extracts cleanly, then VM refuses it. Julia scalarises tuple phis (`tp` ran correctly, 15). | NEW | refusal text is descriptive, not a crash |
| F14 | CONFIRMED | **No: S2/S3** | Unreachable: upstream emits `IRInsertBits` only as one contiguous in-block sret chain (`sret.jl:1108-1124`) | NEW | E,P,C → 7. E,C,P → named refusal. |
| F15 | PARTIALLY | **No: S2** | Unreachable from ingest (never emits `ArithmeticAssignment`). `run!`/`unrun!`/`unstep!` restore correctly (replay). Only direct `inverse()` corrupts. | NEW (rel. ack, 6xy0) | xor variant: `is_injective=true` yet inverse wrong |
| F16 | CONFIRMED | S1 borderline; S2 defensible | n/a (test) | NEW (rel. jpb) | real `_full_roundtrip!` accepted wrong result 2 (oracle 11) |
| F17 | CONFIRMED | **S2** | n/a (test) | DUPLICATE-OF jpb (notes) | `true` for 1 vs 999 and for add vs mul. Labels *are* compared. |

"Already tracked?" beads named by the report all exist in `.beads/issues.jsonl` with matching titles:
347o, 9v84, hyi6, 3ah, xo2v, 7cg (closed), h0t (closed), cw4g, x3t0, axfr, ack, jpb, bgc (closed), 5js9, 37d, 8e7t, x49, 278, r8nc, 5o86, c39 (closed).
None of F1–F17 duplicates a VM-core triage bead. VM-core F1 (aul4, mixed-width cells) differs from F1 here (index width). hyi6 is cross-function, while F2 is a same-instruction loop. gn6o covers ROM *copies*, not identity.
The reviewer's "no bead" claims hold, with two exceptions. **F17: jpb's NOTES field explicitly records the `_structural_eq` types-only gap.** F11: cw4g's description already covers `ret const`.

---

## F1 — narrow negative GEP index (S0)
Script: the review's LLVM module verbatim. `L.verify(mod)`, then `_extract_from_module(mod,"idx",String[]; mem=:auto, ptr_cells=true)`, `lower_vm`, `rt`.
```
LLVM verify ok
  IRBinOp(:i, :sub, ConstOperand(0), ConstOperand(1), 8)
  IRVarGEP(:p, SSAOperand(:b), SSAOperand(:i), 64)        # no index-width field
i8 GEP output=Dict(:a => 1, :b => 2, :p => 257, :i => 255, :r => 0) expected=11
i8 GEP restored=true history_empty=true
```
Reachability: corpus grep found one narrow-index GEP in real Julia IR (`test/reference/fdict_O0.ll:360`, `gep [256 x ptr] @jl_boxed_int8_cache, i32 0, i32 %80`).
Its index is `zext i8 → i32`, so non-negative. The mechanism class is real, but a *negative* narrow index was only shown via hand-written `.ll`.

## F2 — loop-re-executed static alloca aliases (S0)
Hand-built ParsedIR: entry→loop(×2)→done. `i` phi 0→1, `keep` phi, `IRAlloca(:p,64,C(1))`, store `7+2i`, `keepn = select(i==0, p, keep)`, `done: r = load keepn`.
```
loop alloca output=9 expected=7
loop alloca restored=true history_empty=true
  keepn=1 p(last)=1          # both iterations got the same address
```
347o's description really does say "sound under L3 today but unguarded". The forward result is wrong, so that claim is refuted.
Reachability: clang -O0 and Julia put static allocas in the entry block, and inlining hoists them there. Only a non-canonical `.ll` reaches this.

## F3 — map key width dropped (S0)
Hand-built: `IRMapInsert(x,7,8,8); same=add(x,0)@8; IRMapInsert(same,9,8,8); r=IRMapGet(x,8,8)`, input `x=-1`.
```
hand map output=7 expected=9      same=255 x=-1      julia oracle=9
hand map restored=true history_empty=true
```
Real-frontend attempts with `mem=:vm`: three `Dict{Int8,Int8}` shapes (`g1`–`g3`) are all refused by the recogniser, either with "surviving sext" or "no `ijl_gc_small_alloc`".
`test_dict_roundtrip.jl` Part C documents that inlined `getindex` for isbits keys is refused on purpose, so no real `IRMapGet` exists today.
The defect is latent for when that recogniser lands. The S0 label is right for accepted ParsedIR.

## F4 — reserved intrinsic name shadows a supplied body (S0)
Hand-built exactly as described: `lower_vm([:f=>f, :malloc=>g])`:
```
accepted; instrs: [:IntrinsicMalloc, :Define]
malloc shadow output=1099511627776 expected=18     restored=true history_empty=true
control :g output=18 expected=18
```
**Real Julia**: `module U; @noinline malloc(a::Int64)=a+10; f(x)=malloc(x)*1; end`, then `extract_parsed_ir_set_from_julia(U.f, Tuple{Int64}; ptr_cells=true)`:
```
keys: [Symbol("f#760157f3"), Symbol("malloc#4790275c")]   call malloc typeof(Main.U.malloc)
instrs: [:IntrinsicMalloc, :Define, :Define]
real U.malloc output=Dict(Symbol("x::Int64") => 8, :__v1 => 1099511627776, :__v2 => 1099511627776) expected=18
real U.malloc restored=true history_empty=true
```
This is the strongest finding in the report: plain Julia miscompiles silently. (Real extraction keys the input as `Symbol("x::Int64")`.)

## F5 — shared global duplicated per function (S0)
Hand-built (both ParsedIRs with `globals=:G=>([7],64)`, `g: icmp eq p, G; zext`): `global identity output=0 expected=1`, restored.
**Real `.ll`**: the module below, extracted with `extract_parsed_ir_set_from_ll(path; ptr_cells=true)`.
```llvm
@G = constant [2 x i64] [i64 7, i64 8]
define i64 @g(ptr %p) noinline { %q = getelementptr [2 x i64], ptr @G, i64 0, i64 0
  %c = icmp eq ptr %p, %q  %z = zext i1 %c to i64  ret i64 %z }
define i64 @f(i64 %x) { %q = getelementptr [2 x i64], ptr @G, i64 0, i64 0
  %r = call i64 @g(ptr %q)  ret i64 %r }
```
```
keys [:g, :f] globals [[:G], [:G]]
ll global identity output=Dict(:G => 281474976710658, :q => 281474976710658, :r => 0, :x => 0) expected=1
ll global identity restored=true history_empty=true
```
(Passing `@G` directly as the call operand is refused upstream with "unknown operand ref", so the GEP form is needed.)

## F6 — synthetic name overwrites user SSA name (S0)
The input arg is named `:_phi_const_entry_1`; `next: a=phi[(1,entry)]; r=add(arg,a)`.
```
name collision output=2 expected=11
name collision restored=true history_empty=true
3ah example: _phi_const_a_1_3 vs _phi_const_a_13      # 3ah's recorded collision is wrong, as the review says
```
Severity is right by category (silent, round-trips). Likelihood is low: no real frontend emits the `_phi_const_` prefix.

## F7 — legacy CallInstruction is a silent no-op (review S0 → S1/S2)
Hand-built VMProgram. (a) `CallInstruction([:y],:missing,[:x],:call)`:
```
(a) status=halted y_defined=false        (a) restored=true empty=true
```
(b) a real `g(a)=a+10` in the function table, with live target y=3:
```
(b) legacy call output=3 expected=18     (b) legacy call restored=true history_empty=true
```
The mechanism is confirmed. `grep "CallInstruction(" src` outside `call_instruction.jl` finds only `basic_block.jl:353` (structural_inverse of an existing instance), and ingest never emits it.
So no ParsedIR can hit this path; it is live unsound acceptance on the low-level VMProgram API only. S1, or S2 because it is dead code already slated for removal by xo2v, is more accurate than S0.

## F8 — Float32 guard rejects Int32 calls (S1)
Hand-built as described:
```
THREW ErrorException: lower_vm: IRCall to soft op :g (dest=r) touches Float32 (ret_width=32, arg_widths=[32]) — REJECTED …
```
**Real Julia**: `@noinline g(a::Int32)=a+Int32(1); f(x::Int32)=g(x)*Int32(2)` gives the same error (`dest=__v1`).
The cause is at `ingest_body.jl:343`: `if inst.ret_width == 32 || any(==(32), inst.arg_widths)`, which has no soft-float callee check.

## F9 — Unicode function names (S1)
```
alpha#12345678 -> alpha
THREW StringIndexError: invalid index [2], valid nearby indices [1]=>'α', [3]=>'#'     # α#12345678
THREW StringIndexError: invalid index [3] …                                             # fα#12345678
αf#12345678 -> αf
real keys [Symbol("f#25103329"), Symbol("α#5fc36a03")]  → lower_vm THREW StringIndexError   # real Julia @noinline α
```
The cause is `ingest_multi.jl:61`, `s[1:end-9]`.

## F10 — constant / identical-successor conditional branch (S1)
Hand-built: `FieldError: type ConstOperand has no field `name``. For `IRBranch(S(:c),:next,:next)` the error is `ConditionalExit: target_true and target_false both equal e_entry_next`.
Real LLVM text (`_parsed_ir_from_ir_string`, needs a `julia_` prefix):
```
extracted terms: IRInst[IRBranch(ConstOperand(-1), :a, :b), …]  → FieldError …no field `name`
extracted terms: IRInst[IRBranch(SSAOperand(:c), :n, :n), …]    → ConditionalExit … both equal e_entry_n
```
Julia's own codegen folds `if true` (`h` produced a bare `IRRet`). Both are crashes on valid, extractor-accepted IR, so S1 holds.

## F11 — literal scalar return (review S1 → S2; duplicate)
Both the hand-built case and real Julia `c42(x)=42` give `lower_vm: IRRet of a literal (42) is unsupported … (Rule 1)`.
`c2(x)= x>0 ? 1 : x` gives `IRRet of a literal (1)`. These are ordinary Julia functions, so the gap matters.
It is a deliberate, named refusal, though, not a crash, so S2 (coverage gap) fits better.
cw4g's description says "a genuine void function (ret void / ret const) … synthetic create for a const return". That is a duplicate, and cw4g's framing should drop "void" because void is implemented at `ingest.jl:918`.

## F12 — globals reached only via phi / terminator (S1)
Phi case exactly as described: `lowering accepted` → `THREW KeyError: key :G not found`.
Extra, beyond the review's static claim: the `ret @G` terminator case runs *without error* and silently omits the return:
```
ret-G lowering accepted
ret @G output=Dict(:x => 0) expected=GLOBAL_BASE addr        # returned name :G absent from result
ret @G restored=true history_empty=true
```
Reachability: `.ll` with `phi ptr [ @G, %a ], …` fails upstream with `unknown operand ref for: @G …`, so the extractor does not produce this shape today.

## F13 — aggregate phi/select (review S1 → S2)
Hand-built phi and select both fail with `IRExtractValue agg=:p (dest=e) is NOT a known aggregate …`. The control without a phi gives 5 and round-trips.
Real LLVM text `%p = phi [2 x i64] [%a1,%a],[%a0,%entry]; extractvalue` extracts cleanly and then hits the same refusal.
Real Julia `tp(x)=(t = x>0 ? (x,2x) : (3x,x); t[1]+t[2])` is scalarised by Julia (two scalar `IRPhi`s) and gives 15, round-trip OK.
Because the refusal is loud and descriptive, this is a coverage gap (S2) rather than a crash.

## F14 — IRInsertBits depends on block order (review S1 → S2/S3)
```
order E,P,C output=7 expected=7     restored=true
order E,C,P THREW … IRInsertBits agg is SSAOperand (dest=b) — expected ZERO_AGG or … prior IRInsertBits dest (… Rule 1 fail-loud)
```
Upstream's only producer is `_synthesize_sret_bits` (`Bennett.jl/src/extract/sret.jl:1108-1124`). It emits one contiguous chain feeding the `IRRet` in a single block.
A cross-block, out-of-order chain is therefore not producible. The claim that "ordinary LLVM block layout" triggers this is irrelevant for a synthetic node.

## F15 — ArithmeticAssignment aliasing (PARTIALLY; review S1 → S2)
The review's exact instance, `ArithmeticAssignment(:x,:y,:add,:x,:add,1)`, with `x=3,y=5`:
```
after forward locals=Dict(:x => 9)
direct: restored=false locals=Dict(:y => -1)        # matches review
is_injective trait: false
L3 default / compute_must_cache: fwd=Dict(:x => 9) restored=true locals=Dict(:y => 5, :x => 3) hist=0
```
The `:xor` modop variant gives `is_injective=true`, the direct inverse gives `restored=false` (`y=>3`), and `run!`/`unrun!` plus a per-step `unstep!` loop still restore exactly.
So the corruption is visible only through a direct `inverse()` call; the interpreter's backward paths replay. The injectivity trait is a false certificate for aliased instances, a close cousin of VM-core F9 (6xy0).
Ingest never emits `ArithmeticAssignment`. PARTIALLY: the mechanism is real, but no end-to-end wrong result or failed round-trip occurs.

## F16 — property gate has no forward oracle (S1 borderline)
Reading `test_property_roundtrip.jl:176-216`: `_full_roundtrip!` checks halt, `unrun!` and state equality only. Grepping both files for `result(`/oracle finds nothing, and the generator returns `(vm, inputs)` only.
Mutation in a scratch script: `_full_roundtrip!` was loaded verbatim from the test file via `Meta.parseall` and fed the F6 program.
```
loaded _full_roundtrip! from test file
known wrong result=2 oracle=11
property helper accepted=true
```
The gate is not vacuous for its *stated* reversal contract: its `inverse(::ArithmeticAssignment)` mutation proof goes RED. What is missing is the forward/golden leg.
S1 (vacuous as a semantics checker) is defensible, and so is S2 (a missing test leg). No bead covers a forward oracle; jpb is generator hardening.

## F17 — determinism checker compares types only (review S1 → S2; duplicate)
The generator defs were loaded via `include_string` up to `# 6. Testsets` (no testsets run):
```
_structural_eq(p1,p2)=true        p1 result=1        p2 result=999
_structural_eq(add-vs-mul)=true
```
Correction to the review: `_structural_eq` *does* compare `entry_label`, block labels, block and instruction counts, and entry/exit/instruction *types*.
It does not compare fields: operands, literals, operators or exit targets.
**Duplicate:** jpb's NOTES say `_structural_eq … compares block/instruction TYPES but not field constants … a constants-drift generator regression would slip past.`
Generation is seeded and deterministic today, so this is a weak check rather than a live miss: S2.
