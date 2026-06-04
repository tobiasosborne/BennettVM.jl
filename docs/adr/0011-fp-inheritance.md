# ADR 0011 — Float64 reversibility via inherited SoftFloat dispatch (M_FP.1)

> Status: **ACCEPTED** (2026-06-01). M_FP.1 milestone (bd `bennettvm-81y`).
> BennettVM pin `7915299`; Bennett.jl pin `7904560`.
> Resolves the v3 §VIII open question on floating-point reversibility
> (PRD v4 §8.1, parenthetical: "resolved in v4.1 by Bennett.jl's SoftFloat
> dispatch. No longer open."). Closes the FP column of PRD v4 §3.6.
> **This ADR documents a design decision, not an implementation.**
> The VM-side wiring that makes Float64 programs actually *run* is
> bead `bennettvm-8ox` (M_FP.2), which this bead blocks.

---

## Context

PRD v3 §3.6 listed three candidate FP-reversibility schemes — residual tape,
posit-with-sticky, and opaque snapshots — and deferred the choice. The v4
initial draft inherited that deferral. Between v3 and v4.1, Bennett.jl shipped
a fourth scheme — bit-exact SoftFloat dispatch — that obviates the choice
entirely. PRD v4 §3.6 item 3 (l.536–551) records the resolution: BennettVM
**inherits the mechanism wholesale and writes no FP-reversibility code of its
own**.

The mechanism: `reversible_compile(f, Float64)` in Bennett.jl wraps the user
function in a `UInt64`-typed lambda before LLVM IR extraction
(`../Bennett.jl/src/softfloat_dispatch.jl:107`, `N == 1` arm):

```julia
w = (x::UInt64) -> (@inline f(SoftFloat(x))).bits
return reversible_compile(w, UInt64; ...)
```

Float64 values therefore never appear in LLVM IR: they are carried as `UInt64`
bit patterns, and every Float64 arithmetic operation becomes a `call` to a
registered `soft_f*` callee (e.g. `call @j_soft_fadd`, `call @j_soft_fmul`).
`extract_parsed_ir` emits these as `IRCall` nodes with `UInt64`-width operands.
The resulting `ParsedIR` is **integer-only** — no float types, no float opcodes
— by the time BennettVM sees it.

BennettVM therefore needs no floating-point arithmetic, no FP-reversibility
scheme, and no FP-specific instruction. The existing integer RSSA representation
handles SoftFloat-dispatched Float64 transparently once the `IRCall` dispatch
layer is wired.

### What is NOT done today — the IRCall GAP (honesty constraint)

The `IRCall` instruction type is a **GAP** in BennettVM at this writing
(`docs/coverage-matrix.md` row 13, tally HEAD `7915299`): the BennettVM
ingest path at `src/ir/ingest.jl:287–294` raises loudly on any `IRCall`:

```
error("lower_vm: unsupported IRInst body subtype … IRCall are deferred (Rule 1).")
```

**A Float64 program that reaches BennettVM today raises at this GAP.** The
FP inheritance decision documented here — "reuse SoftFloat; write no
FP-reversibility code" — is sound and adopted. But adopting the decision does
not constitute implementing it. The VM-side `IRCall`→`soft_f*` dispatch wiring
is **bead `bennettvm-8ox` (M_FP.2)**, which this ADR's bead blocks
(dependency: `bennettvm-8ox` DEPENDS ON `bennettvm-81y`). Until 8ox lands,
`reversible_compile(f, Float64; target=:reversible_vm)` raises at the `IRCall`
GAP.

---

## Ground truth (verified; discrepancies noted)

**Finding 1 — The SoftFloat dispatch mechanism exists and is production-quality
(`../Bennett.jl/src/softfloat_dispatch.jl:1–184`, verified this session).** The
`SoftFloat` wrapper struct (`l.11–13`) and `reversible_compile(f, Float64...)`
overload (`l.79–127`) are present. The 1-, 2-, and 3-argument `UInt64` wrappers
are at `l.107`, `l.113`, `l.119`. The `@inline` at the call site (`l.107`:
`@inline f(SoftFloat(x))`) forces Julia to inline through the SoftFloat dispatch
chain, eliminating struct-passing ABI and producing clean integer IR with direct
`call @j_soft_f*` instructions that the callee registry recognizes (`l.103–106`
docstring). The `SoftFloat` operator dispatch covers: arithmetic (`+`, `-`, `*`,
`/`; `l.17–29`), comparison (`<`, `==`; `l.30–31`), `copysign`/`abs` (`l.32–34`),
`floor`/`ceil`/`trunc`/`round`/`sqrt` (`l.35–39`), `exp`/`exp2` (`l.40–41`),
`min`/`max` (`l.46–47`), and `^` (`l.52`).

**Finding 2 — The SoftFloatLib exports 60 public `soft_*` functions (not ~30
as the PRD §3.6 estimate; the comment "32 IEEE-754 primitives" in
`../Bennett.jl/src/softfloat/softfloat.jl:50–52` is stale).** Verified by
inspection of the `export` block (`softfloat.jl:53–69`; counted this session:
60 distinct symbols). The library spans 35 `.jl` files in
`../Bennett.jl/src/softfloat/` (including `softfloat.jl` itself), wrapped in
`module SoftFloatLib` (`l.13`). The public surface includes:
`soft_fadd`, `soft_fsub`, `soft_fmul`, `soft_fma`, `soft_fdiv`, `soft_fsqrt`,
`soft_fneg`; 10 `soft_fcmp_*` predicates; `soft_fpext`, `soft_fptrunc`,
`soft_fptosi`, `soft_fptoui`, `soft_sitofp`; `soft_round`, `soft_round_away`,
`soft_floor`, `soft_ceil`, `soft_trunc`; `soft_exp`, `soft_exp2`,
`soft_exp_fast`, `soft_exp2_fast`, `soft_exp_julia`, `soft_exp2_julia`;
`soft_log`, `soft_log2`, `soft_log10`; `soft_pow`, `soft_powi`, `soft_pow_julia`;
trig (`soft_sin`, `soft_cos`, `soft_tan`, `soft_atan`, `soft_atan2`, `soft_asin`,
`soft_acos`, `soft_tanh`, `soft_sinh`, `soft_cosh`, `soft_asinh`, `soft_acosh`,
`soft_atanh`); `soft_log1p`, `soft_expm1`; `soft_fmin`, `soft_fmax`,
`soft_fminimum`, `soft_fmaximum`, `soft_minimumnum`, `soft_maximumnum`.

**Finding 3 — PRD §3.6 cites `soft_uitofp` which does NOT exist.**
PRD v4 §3.6 l.544 lists `soft_fptosi`/`soft_fptoui`/`soft_sitofp`/`soft_uitofp`;
`grep -rn "soft_uitofp" ../Bennett.jl/src/` returns nothing. The unsigned-integer
→ float conversion is not among the 60 exported symbols. This is a minor PRD
inaccuracy; it does not affect the design decision (the mechanism is still
wholesale inheritance). Recorded per Rule 3; a PRD patch bead should correct
`soft_uitofp` → absent. The `soft_sitofp` (signed int → float) does exist.

**Finding 4 — Float32 is intentionally rejected upstream (Bennett-3rph).**
`reversible_compile(f, Float32)` is rejected at the validation step in
Bennett.jl (`CLAUDE.md` rule 13: "Float32 deviation (Bennett-3rph / U137):
there are no native f32 arithmetic primitives; f32 operations in mixed-precision
IR are routed through `soft_fpext → f64-op → soft_fptrunc`, which
**double-rounds** and is NOT bit-exact against hardware f32"). The double-
rounding occurs because hardware f32 rounds once at the f32 mantissa boundary
while the `fpext → f64-op → fptrunc` path rounds twice. BennettVM inherits the
same rejection (PRD v4 §3.6 item 4, l.552–555). `Float32` support is tracked
upstream as future work.

**Finding 5 — fpext/fptrunc gap is both upstream and downstream.**
`soft_fpext` and `soft_fptrunc` exist in the SoftFloatLib (Finding 2), but the
LLVM opcode dispatch is missing in Bennett.jl's `_convert_instruction`
(PRD v4 §3.6.1 coverage matrix row "FP ext/trunc opcodes", l.594: "⚠️ gap —
`soft_*` exist, dispatch missing in `_convert_instruction`"). A Float64 function
containing an `fpext`/`fptrunc` opcode would fail upstream before reaching
BennettVM. Bead `bennettvm-8ox` (M_FP.2) includes the BennettVM-side
`IRCall`→`soft_fpext`/`soft_fptrunc` dispatch; the upstream Bennett.jl gap may
need a separate fix or may resolve indirectly once the `IRCall` callee registry
recognizes them.

**Finding 6 — `frem` is a separate gap.**
PRD v4 §3.6.1 coverage matrix row "frem opcode", l.595: "⚠️ gap — wire missing
dispatch." `soft_frem` does not exist in the SoftFloatLib exports (Finding 2 —
verified by inspection). Bead `bennettvm-01w` (M_FP.3, blocked on `bennettvm-8ox`)
covers it. This ADR makes no claim about `frem` beyond recording the gap.

**Finding 7 — The dispatch arm (ADR 0003 keystone) is a prerequisite for
Julia-function FP inputs.** The SoftFloat dispatch fires during
`reversible_compile(f, Float64)`, which produces a `ParsedIR` with `IRCall`
nodes. For this to reach BennettVM, the `target=:reversible_vm` dispatch arm
must be wired (ADR 0003, now landed at `7915299`). The `.ll`/`.bc` route
(SC9 Case A) can also produce `IRCall` nodes from pre-lowered SoftFloat IR;
both routes require the same `IRCall` wiring in bead `bennettvm-8ox`.

---

## Decision

**D1 — BennettVM inherits Bennett.jl's SoftFloat dispatch wholesale. No
FP-reversibility code is written in BennettVM.**

Float64 values arrive at BennettVM as `UInt64` bit patterns via the SoftFloat
wrapper (`../Bennett.jl/src/softfloat_dispatch.jl:107`). Every Float64
arithmetic or math operation arrives as an `IRCall` with a `soft_f*` callee
(`../Bennett.jl/src/ir_types.jl:206–237`). BennettVM's integer RSSA
representation handles these transparently: from BennettVM's perspective, a
SoftFloat-dispatched Float64 program is an integer program that happens to call
`soft_f*` functions. The three v3 candidate schemes (residual tape,
posit-with-sticky, opaque snapshots) are all **rejected** under Law 2: the
existing bit-exact mechanism in Bennett.jl is the correct reuse target and
obviates all three alternatives (PRD v4 §3.6 l.557–561).

**D2 — Float32 is rejected at the BennettVM boundary, inheriting Bennett.jl's
rejection (Bennett-3rph, CLAUDE.md rule 13, PRD v4 §3.6 item 4).**

The double-rounding is a correctness defect, not a performance tradeoff. The
bit-exact contract extends only to Float64; BennettVM must raise loudly on
`Float32` input rather than silently return an approximately-reversible result.
The rejection is automatic today (no `IRCall` dispatch at all), but when `IRCall`
lands (bead `bennettvm-8ox`), the callee registry MUST explicitly exclude
`soft_fptrunc`-chained f32 paths or raise on `Float32`-typed entry.

**Update (bead `bennettvm-h0t`, M_FP.5):** the boundary guard now EXISTS. The
`IRCall` arm of `_lower_body_inst` (`src/ir/ingest.jl`) rejects any soft op that
*touches f32* (`ret_width == 32 || any(==(32), arg_widths)` — catching
`soft_fptrunc` ret-32, `soft_fpext` arg-32, and any f32-operand soft op), with a
Rule-1 message citing this decision. It is the belt-and-suspenders mirror of the
two-layer upstream Bennett.jl barrier (`_SUPPORTED_SCALAR_ARGS` + the
per-intrinsic `w == 64` FP-intrinsic guards; the fcmp arm lacks one but the
SoftFloat wrapper keeps accepted f64 IR f32-free): an accepted pure-Float64 program
emits no f32-touching soft op, so the guard is unreachable-by-construction on
accepted f64 IR and fires only if a mixed-precision `.ll` reaches ingest. It does
NOT over-reject any legal f64→intN conversion (emitted upstream with
`ret_width == 64` plus a separate `IRCast(:trunc, 64→32)`,
`../Bennett.jl/src/extract/instructions.jl:2322-2345`). Witness + defensive tests
in `test/test_fp_f32_reject.jl`.

**D3 — fpext/fptrunc and frem are deferred gaps, not design questions.**

These are wiring tasks (beads `bennettvm-8ox` / `bennettvm-01w`), not open
architectural choices. The design choice — inherit SoftFloat — is settled by D1.
The wiring is blocked on `IRCall` dispatch landing first.

**D4 — SC10's gate (`reversible_compile(x -> x*x + 3x + 1, Float64; target=:reversible_vm)`)
is blocked on bead `bennettvm-8ox`.**

SC10 (PRD v4 §Part VI, l.1061–1066) requires `IRCall` dispatch to `soft_f*`
callees. Until `bennettvm-8ox` lands, this program raises at the `IRCall` GAP
in `src/ir/ingest.jl:287–294`. A hand-built `ParsedIR` containing `IRCall`
nodes to `soft_fadd`/`soft_fmul` with `UInt64`-width operands would be
interpretable once `bennettvm-8ox` lands; no hand-built test is executable
before then.

---

## Consequences

- **`bennettvm-81y`** (this ADR) closes on commit of this file.
- **`bennettvm-8ox`** (M_FP.2, Wire fpext/fptrunc LLVM-opcode dispatch) is
  unblocked. Its scope: wire `IRCall`→`soft_f*` dispatch in BennettVM's ingest
  path so that `ParsedIR` containing SoftFloat-dispatched `IRCall` nodes reaches
  the interpreter without raising. Priority P1.
- **`bennettvm-01w`** (M_FP.3, Wire `frem` dispatch) remains blocked on
  `bennettvm-8ox`. `soft_frem` does not exist in the SoftFloatLib (Finding 6).
- **PRD patch** (minor, non-blocking): PRD v4 §3.6 l.544 lists `soft_uitofp`
  which does not exist (Finding 3). The function count "~30 files" (files, not
  functions) is accurate; the "32 IEEE-754 primitives" comment in
  `softfloat.jl:50–52` is stale (60 exports today, counted this session). Recommend a cosmetic PRD
  correction at next PRD edit.
- **No BennettVM source file is modified by this ADR.** The decision is a
  design ratification, not an implementation.
- **CLAUDE.md hallucination callout addressed.** The callout
  ("Floating-point reversibility is not solved — do not invent an FP scheme")
  warned against inventing one. This ADR does the opposite: it records why NO
  new scheme is needed, by identifying the existing mechanism as the correct
  reuse target. The warning was accurate as a guard against the wrong
  response (invent something); the right response (reuse Bennett.jl's
  SoftFloat dispatch) is what this ADR documents.

---

## Reuse (Law 2)

```
Reuse: Bennett.jl's bit-exact SoftFloat dispatch
  Source: ../Bennett.jl/src/softfloat_dispatch.jl (the wrapping mechanism),
          ../Bennett.jl/src/softfloat/ (the soft_* library, 35 files, 60 exports)
Why not reuse further: mechanism is adopted in full; no BennettVM extension
  is needed or made. The only remaining work is the IRCall interpreter-dispatch
  wiring (bead bennettvm-8ox), which is a routing/plumbing task, not a new
  FP-reversibility design.
```

The three v3 candidate schemes are rejected under Law 2:

- **Residual tape** (store the residual bits discarded by rounding, reverse by
  re-injecting): not needed — SoftFloat arithmetic is exact over integers, no
  rounding occurs in the integer representation, no residual to store.
- **Posit-with-sticky** (replace IEEE 754 with a posit encoding): not needed —
  the `UInt64` bit-pattern representation is lossless IEEE 754.
- **Opaque snapshots** (checkpoint the float value before every FP op): not
  needed — the operation is an integer call; the existing L3 checkpoint/replay
  or L2 delta applies uniformly with no FP-specific logic.

All three are worse points on the complexity-vs-coverage curve than inheriting
the existing mechanism.

---

## Refs

- `bennettvm_prd.md` (PRD v4): §3.6 item 3 (l.536–551; the mechanism and
  BennettVM wholesale-inheritance claim), §3.6 item 4 (l.552–555; Float32
  rejection), §3.6 v3→v4 rationale (l.557–561), §3.6.1 coverage matrix
  FP rows (l.581–600; esp. fpext/fptrunc gap l.594, frem gap l.595, Float32
  direct l.600), §Part VI SC10 (l.1061–1066; the Float64 round-trip gate),
  §8.1 parenthetical (l.1130–1132; "resolved in v4.1 … No longer open"),
  Part IV reuse map Float64 row (l.939).
- Bennett.jl (pin `7904560`):
  - `../Bennett.jl/src/softfloat_dispatch.jl:11–13` (`SoftFloat` struct),
    `:17–52` (operator dispatch), `:54–70` (docstring — UInt64-wrapper
    mechanism, `@inline` rationale; `:71–77` are the kwargs-constant declarations
    immediately following), `:79–127` (`reversible_compile(f, Float64...)`
    overload, the 1-/2-/3-arg UInt64 lambdas at l.107/113/119).
  - `../Bennett.jl/src/softfloat/softfloat.jl:13` (`module SoftFloatLib`),
    `:50–52` (stale "32 primitives" comment), `:53–69` (export block, 60 symbols, counted this session).
  - `../Bennett.jl/src/softfloat/fpconv.jl:1–37` (fpconv docstring: Float32
    double-rounding deviation, Bennett-3rph rationale).
  - `../Bennett.jl/src/ir_types.jl:206–237` (`IRCall` definition: `dest`,
    `callee::Function`, `args`, `arg_widths`, `ret_width`; struct closes at l.237).
  - `../Bennett.jl/CLAUDE.md` rule 13 (bit-exact Float64 contract; Float32
    rejection, Bennett-3rph / U137).
- BennettVM (pin `7915299`):
  - `docs/coverage-matrix.md` row 13 (l.34: `IRCall` → **GAP**, "SoftFloat
    wrappers → M_FP"), tally (l.39–47: 11 DONE / 4 GAP / 1 N/A).
  - `src/ir/ingest.jl:287–294` (the `IRCall` loud-error arm, confirmed present).
- `docs/adr/0003-target-reversible-vm-dispatch.md` (ADR 0003, keystone — the
  `target=:reversible_vm` dispatch arm prerequisite; D4 "out-of-scope IRCall"
  listed in known divergences l.155–160).
- Beads: `bennettvm-81y` (this ADR), `bennettvm-8ox` (M_FP.2, IRCall dispatch
  wiring, unblocked by this ADR), `bennettvm-01w` (M_FP.3, frem, blocked on 8ox).
- CLAUDE.md Laws 1 & 2, Rules 1, 3, 9; "Floating-point reversibility is not
  solved" hallucination callout (BennettVM.jl CLAUDE.md).
