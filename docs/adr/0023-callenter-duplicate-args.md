# ADR 0023 — Duplicate `CallEnter` args are legal: the arg list is COPY-read, not MOVE-consumed

> **Status: ACCEPTED 2026-07-30.** Bead `bennettvm-0fw7` (P2). Diagnosis-first:
> a scout established the root cause empirically (guard bypassed, full e2e
> round-trip verified under L2 and L3) before any fix was written; the
> orchestrator adjudicated F1 (relax) over F2 (duplicating `Define` at ingest)
> and F3 (front-end renaming), on the direct precedent of ADR 0022. Sibling
> beads filed, not folded in: `bennettvm-p3j2` (the `t in args` guard —
> **resolved 2026-07-30 by the Amendment at the end of this ADR: keep the
> behaviour, fix the rationale**),
> `bennettvm-guyl` (per-position widths), `bennettvm-4iet` (`_callconst_*`
> residual).

## The bug

A 14-insert `Dict` written as a `for` loop never reached the VM. It died at
LOWERING:

```
lower_vm(...) →
  CallEnter: duplicate arg names in [Symbol("new::Dict"), :value_phi, :value_phi]
    (an SSA name cannot be moved into a callee twice).
```

Identically at `Dict{Int8,Int8}` and `Dict{Int64,Int64}`. The straight-line
14-insert form of the same program — the one `test_rnhv_phi_multiuse.jl` §(4)
gates — runs and reverses fine, which is why the wall was first (mis)read as
loop-specific and deferred as "the loop analogue of ADR 0019 A.2 on the arg
side".

## It is not about loops

The diagnosis reproduced the failure with no loop at all:

```julia
@noinline g(a, b) = 3a + b
f(x) = g(x, x)                  # → CallEnter: duplicate arg names in [x::Int64, x::Int64]
```

and showed the loop form is only incidentally involved. `d[i] = i` lowers to
`setindex!(d, i, i)`: LLVM CSEs the key and the value onto the SAME SSA name
(`%value_phi`), so ONE call passes one value in two argument positions. A loop
whose body is `d[i] = v` — two distinct names — does NOT trip the guard. The
trigger is exactly "one call, one SSA name, two positions," and the IR is
ordinary and verifier-legal.

## Ground truth (Law 1)

- `references/reversible-isa/vieri-1995-pendulum-ms.pdf` p. 22 — *"the
  information is merely moved from one place to another rather than erased"*:
  the MOVE discipline the guard's message states.
- `docs/adr/0019-reversible-calls.md` §3 — the accepted call transition, whose
  pseudocode reads `argv = [...]; delete each a  # MOVE, not copy (Vieri p.22)`.
- `docs/adr/0019-reversible-calls.md` **Amendment A.1** (2026-06-10,
  hostile-review-ratified) — *"`CallEnter` now **copies** arg values into the
  fresh callee frame; the caller frame is untouched … the L1-injective/zero-
  history claim is *stronger* under COPY — nothing is erased."*
- `src/interpreter/Interpreter.jl`, `_handle_call_dispatch!` — the implemented
  semantics, verified by reading the code, not by recalling the ADR:

  ```julia
  for a in instr.args ... push!(argv, caller[a]) end          # READ ONLY
  for (p, v) in zip(fe.params, argv) callee_locals[p] = v end # DISTINCT keys
  ```

## Why the guard was wrong

Under a MOVE, `g(x, x)` is genuinely ill-formed: you cannot consume one value
twice, and there is no coherent answer to "which consumption wins". Under a
COPY, the arg list is a **read list**. Reading one key twice is idempotent; the
two values then land under two DIFFERENT param keys (`FunctionEntry.params` is
already distinct, and the arity check pairs them positionally). Nothing is
erased, nothing is overwritten, no ordering question arises.

So the guard was left over from a model the project had already abandoned at
this exact boundary six weeks earlier. Amendment A.1 changed the *transfer* and
the *docstrings* but not the *constructor*, and the constructor is what runs.

It was also **self-inconsistent**. Duplicate CONSTANT args already passed:
`src/ir/ingest.jl` (the `IRCall`-with-`ConstOperand` branch) mints a fresh
per-position `_callconst_<callee>_<n>` name for every constant operand, so
`g(3, 3)` lowers to two distinct synthetic names and constructs happily, while
`g(m, m)` was rejected. Same program shape, opposite verdicts, decided by
whether the front-end had happened to rename.

## Empirical verification, before choosing a fix

With the guard bypassed (no other change), the 14-insert **for-loop**
`Dict{Int8,Int8}`:

| property | result |
|---|---|
| `lower_vm` | succeeds, 334 blocks |
| forward | halts at the native-Julia-oracle value |
| `unrun!` | empty history, exact initial state |
| regimes | verified under BOTH L2 (`compute_must_cache`) and L3 (checkpoint) |
| coverage | includes the `rehash!` GROW path (14 inserts crosses the load factor) |

So the guard was not protecting a real invariant; it was the whole wall.

## Decision

**Remove `allunique(args)` from the `CallEnter` inner constructor**
(`src/ir/call_transitions.jl`). Relax the superseded `CallInstruction` stub
(`src/ir/call_instruction.jl`) identically, in lockstep, so the two constructors
cannot give a reader two different answers — even though that class is dead on
the lowering path (only `BasicBlock.reverse()` in `src/ir/basic_block.jl` and
tests construct it).

Kept unchanged, and pinned by `test/test_0fw7_dup_call_args.jl` §(4):

- `allunique(targets)` — an SSA name still cannot receive two returns. This one
  is a genuine write-side conflict and survives the MOVE→COPY change untouched.
- the **`t in args` target/arg overlap** guard — behaviour deliberately
  untouched here, pending its own diagnosis and evidence. Filed as
  `bennettvm-p3j2`; a cross-reference comment sits on the guard so the next
  reader does not mistake this ADR for having settled it. *(Settled since, by
  the Amendment at the end of this ADR: the guard STAYS, as a tripwire; only
  its stated rationale was wrong.)*
- both **callee-shadow** guards (dispatch ambiguity).
- the run-time `_handle_call_dispatch!` checks: closed-world callee resolution
  (ADR 0019 §6a), **arity** (§6b — now load-bearing for the duplicated case),
  and arg-absent-from-caller-frame (§6f).
- `UnconditionalExit` / `ConditionalExit`'s `allunique(args)`
  (`src/ir/control_instructions.jl`): a different list — BLOCK-exit args, where
  `src/ir/ingest.jl` already mints fresh per-occurrence names and where removal
  would perturb pinned `Define` counts (ADR 0022 §Decision). Cross-referenced,
  not changed.

The renaming discipline is the point: a guard that states a model must be
deleted with the model, or the next reader re-derives the model from the guard.

## Alternatives rejected

### F2 — emit a duplicating `Define` at ingest for repeated call args

Mint `%dup = add %value_phi, 0` before the call and pass `%dup` in the second
position, preserving a MOVE-shaped arg list. Rejected:

1. **ADR 0022 already adjudicated this exact trade** at the φ-edge and chose
   relaxation, for reasons that transfer verbatim: a duplicating `Define`
   **does not restore linearity** (the original is still not destroyed by
   anything), so it launders the property rather than establishing it.
2. It costs an instruction and a step per duplicated argument position, on
   every call, on every iteration.
3. It is strictly worse in history: each synthetic name is non-injective at
   creation (L3) and then lingers in the caller frame and in the callee's
   `ReturnExit` residual — the cost family already observed for
   `_callconst_*` and filed as `bennettvm-4iet` / `bennettvm-h4q4`. F2 would
   deliberately multiply it.
4. It perturbs the lowering of currently-green fixtures for a bug they do not
   have (the ADR 0022 §Rejected-alternative argument, restated).

### F3 — have the Bennett.jl front-end rename duplicated SSA args

Rejected on two counts. It violates Bennett.jl's LLVM-**transcription**
discipline (the front-end's job is to carry the IR faithfully, not to
pre-massage it into a downstream consumer's constructor invariants — a rename
here would also break the guyl width-per-position contract, since the two
positions can legally carry different widths). And it would require editing
`../Bennett.jl/src/`, which CLAUDE.md **Rule 14** forbids without explicit user
approval; a fix that must reach across the repo boundary to satisfy a guard
this repo has already superseded is the wrong fix.

## Consequences

**The Rule-1 surface shrinks for hand-built programs.** A hand-written
`CallEnter` that duplicates an arg BY MISTAKE (rather than by intent) now
constructs. What still catches it: the arity check, if the duplication changed
the count; the absent-arg check, if the name is not bound; and the value
assertions of any test worth the name. What does NOT catch it: nothing, if the
program is otherwise well-formed — but in that case it is also *correct*, since
the two positions receive the value the author named. This is a real reduction
in construction-time strictness and is recorded as such; the proportionate
permanent replacement is the deferred SSA-**dominance validator**
(`bennettvm-axfr`, M2.18 `validate(::VMProgram)`), which subsumes this class
and several others.

**The reachable program set grows.** Every `for i in 1:N; d[i] = i; end` and
every `g(x, x)` now lowers. The 14-insert loop `Dict` at both widths is a
regression gate from this commit (`test/test_0fw7_dup_call_args.jl` §(3)).

**One deliberate asymmetry in the superseded stub.**
`structural_inverse(::CallInstruction)` (`src/ir/basic_block.jl`) swaps
`targets` ↔ `args`, so a duplicate-arg `CallInstruction` inverts to a
duplicate-TARGET one and is rejected — correctly, since two returns cannot land
on one name. A dup-arg call is thus constructible but not structurally
invertible in that class. Harmless today (the class is dead on the lowering
path, and `CallEnter` / `ReturnExit` do not use `structural_inverse`); recorded
in the `CallInstruction` docstring so a future revival lands the two positions
through the callee's params rather than by a naive list swap.

**No trajectory changes for existing programs.** The change is purely a
construction-time rejection removed: any program that constructed before
constructs identically now, with the same instructions in the same order.
There is no new instruction, no new history entry, no new residual. (Contrast
ADR 0022, which had a measurable residual-locals cost.)

**Follow-ups, filed not folded:**

- `bennettvm-p3j2` (P2, bug) — the `t in args` guard carries the same stale
  MOVE-era rationale. **Filed with the premise "`x = g(x)` is routine at
  `-O0`"; that premise was WRONG — see the Amendment below, which resolves
  this follow-up.**
- `bennettvm-guyl` (P3) — one arg NAME can now carry TWO widths at one call
  site (the i8 loop-`Dict` fixture passes `:value_phi` at `arg_widths`
  `[64, 8, 8]`). Benign today (no VM-side width masking exists — ADR 0012 R1 /
  bead `bgc`), but a future masking pass must key on POSITION, not name.
- `bennettvm-4iet` (P3) — the `_callconst_*` `Define`s minted per constant
  occurrence linger in the caller frame and the callee residual; same
  dead-after-call cost family ADR 0019 §7 defers to the liveness tier
  (`bennettvm-h4q4`).

**ADR 0019 is amended.** Amendment A.1 ratified COPY-args but left §6's
constructor-guard family stating MOVE. A banner and cross-reference now point
from 0019 to this ADR.

## Validation

- `test/test_0fw7_dup_call_args.jl`, written and run RED against unmodified
  `src/` first (Rule 5). §(1) hand-built witness, §(2) straight-line
  `f(x) = g(x, x)` e2e, §(3) 14-insert for-loop `Dict` at i8 AND i64, §(4')
  the constructor relaxation — all RED with the exact `duplicate arg names`
  message; §(4), the surviving-guard set, GREEN throughout. That split is what
  makes the RED attributable to the guard rather than to the harness.
- Forward values are checked against the IRREVERSIBLE native Julia oracle
  everywhere (the M8.2 lesson: `unrun!` of a wrong computation is still a clean
  `unrun!`), plus per-step inverse sweeps on the two cheap fixtures.
- Both history regimes on every round-trip: L2 (`compute_must_cache`) and L3
  (empty must-cache, checkpoint-replay).
- Trajectory-independent non-vacuity: each lowered fixture is asserted to
  CARRY a duplicate-arg `CallEnter`, so the gate cannot go quietly vacuous if
  the front-end stops emitting the shape.
- Neighbour files re-run individually: `test/test_rnhv_phi_multiuse.jl`,
  `test/test_a70z_dict64_roundtrip.jl`, `test/test_call_roundtrip.jl`,
  `test/test_call_instruction.jl`.

## Reuse (Law 2)

**Reuse:** `docs/adr/0022-phi-edge-binding.md` — the relax-don't-duplicate
adjudication, applied here at the call edge instead of the φ-edge; and
`docs/adr/0019-reversible-calls.md` Amendment A.1, whose COPY semantics this
ADR merely finishes propagating into the constructor layer. **Why not reuse
further:** 0022's soundness argument (the destructive transfer factors as
`π ∘ N`) is not needed here — this change removes a *construction-time
rejection*, not a state transition, so there is no injectivity or
conservativity obligation to discharge. **Precedent:** ADR 0019 A.1 (MOVE→COPY
at the call edge), ADR 0019 A.2 (fail-loud → OVERWRITE for live targets),
ADR 0022 (destroy → bind at the φ-edge). This is the fourth member of one
family: an ISA rule imported from a reversible-BY-CONSTRUCTION source language
does not survive contact with irreversible-source LLVM IR.

---

## Amendment / follow-through (`bennettvm-p3j2`, 2026-07-30)

> **Decision F2: the `t in args` overlap guard KEEPS its behaviour; only its
> stated rationale changes.** Diagnosis-first, orchestrator-ratified the same
> day this ADR was accepted. Bead downgraded P2 → P3.

### The premise this ADR shipped with was wrong

The follow-up list above filed `bennettvm-p3j2` on the claim that
"`x = g(x)` is routine at `-O0`". It is routine **at source level** and never
survives into IR. LLVM SSA renames every definition, so the assignment becomes
`%x.1 = call @g(%x.0)` — a *fresh* dest. More strongly, the **verifier's
dominance rule forbids** a call being its own operand: an operand must be
dominated by its definition, and an instruction does not dominate itself. So
`dest ∉ operands` is not a happy accident of our front-end; it is a property of
well-formed LLVM.

Measured, not assumed (p3j2 diagnosis): **135/135 raw call sites** and
**105/105 extracted `IRCall`s**, across the C, Rust and Julia corpora, satisfy
`dest ∉ operands`. The synthesis paths preserve it by construction as well —
sret out-parameter synthesis, and the `_agg_*` / `_callconst_*` name-minting
namespaces, all allocate fresh names.

### Would it break if allowed?

**No.** The empirical check confirmed what A.1 + A.2 already imply: with the
guard bypassed, an overlapping call round-trips. Args are COPY-read (A.1), so
the arg value is taken before anything lands; the target overwrite is captured
in the `target_olds` payload (A.2) and restored on the inverse. The MOVE-era
rationale printed in the error — "cannot be simultaneously moved-out and
landed-into" — was therefore **false**, in exactly the same way the dup-arg
message was.

### F2, and why F1 was declined

Relaxing (F1, the 0fw7 move) buys **zero capability**: no reachable program is
unblocked, because no reachable program has the shape. What relaxing *costs* is
the loss of a check with a measured **zero false-positive rate** — precisely
the kind of cheap Rule-1 net that catches hand-built `VMProgram`s and future
front-end name-synthesis bugs. So: keep the behaviour, delete the false story.
The permanent successor is the SSA **dominance validator**
(`bennettvm-axfr`), which subsumes this check and several others at build time;
`axfr` is annotated with the `_agg_*`-namespace invariant this diagnosis
established.

The general rule this pair of beads establishes: **a guard whose rationale is
obsolete is not automatically a guard whose behaviour is wrong.** 0fw7's guard
blocked reachable programs and had to go; p3j2's blocks nothing and stays. The
common defect is the *sentence*, not the `error()`.

### Do NOT misapply 0023's `structural_inverse` asymmetry

The main text records that `structural_inverse(::CallInstruction)` swaps
`targets` ↔ `args`, so a duplicate-**arg** instance inverts to a
duplicate-**target** one and is (correctly) rejected. The overlap case is
different and symmetric: swapping the two lists maps an overlap to an overlap,
so an overlapping `CallInstruction` inverts to another overlapping one — the
guard fires identically in both directions and no asymmetry arises.

### Beads filed with this amendment

- `bennettvm-xl1q` — follow-up from the p3j2 corpus sweep.
- `Bennett-ms0o` (upstream Bennett.jl) — stale `.ll` fixtures found while
  sweeping the corpora.
- `bennettvm-axfr` — annotated with the `_agg_*` fresh-name invariant, which is
  part of what the dominance validator will be able to assume.

### Validation

Documentation/comment change only: **no executable line is modified except the
two `error()` string literals.** `test/test_0fw7_dup_call_args.jl` and
`test/test_call_instruction.jl` re-run individually and stay green with
unchanged assertion counts (the §(4') message pin asserts `"appears in BOTH"`,
a factual clause deliberately preserved in the new message).
