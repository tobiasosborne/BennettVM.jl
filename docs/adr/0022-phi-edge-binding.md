# ADR 0022 — φ-edge args→params is a non-destructive BIND, not a MOVE

> **Status: ACCEPTED 2026-07-24.** Bead `bennettvm-rnhv` (P1, Core tier;
> `bennettvm-35yn` ships alongside as the Rule-1 mitigation). Two independent
> design analyses were run, they diverged, and the orchestrating reviewer
> adjudicated in favour of relaxing the transfer rather than inserting
> duplicating `Define`s. Implemented against `2efd6bc`; mutation-proved;
> trajectory-shape conservativity measured, not assumed.

## The bug

A 14-insert `Dict{Int8,Int8}` extracted (4 closed-world bodies) and lowered
(552 blocks) but died at RUN, at step 4603 of ~10790:

```
KeyError: key :__v327 not found
instruction: Define(:__v76, :value_phi135, :sub, :__v327, 64)
frames:      [:__entry, :setindex!, :rehash!]
```

`Dict{Int64,Int64}` at 14 inserts failed identically — the wall is
width-independent. Traced frame-exactly, the name is *defined correctly*, is
then **deleted** by the `UnconditionalExit(:rehash!#L117, [:__v327])` two steps
later, and a legitimate later use fails ~46 steps after that. Not a missing
definition; not a cross-frame SSA collision.

## Ground truth (Law 1)

`references/reversible-ir/mogensen-2016-rssa.pdf`, §4 ("Combining SSA and RIL
to RSSA"), p. 210, the numbered list. Verified against the local PDF, not
recalled:

- **Note 1** — "An assignment to a variable introduces a new indexed version
  of the variable which is previously undefined, **and so does a parameter to
  a label in an entry point**."
- **Note 2** — "The first variable used on the right-hand side of an
  assignment is destroyed by that use. **Uses of variables as parameters to
  labels in exit points also destroy these variables.**"
- **Note 3** — "An assignment of the form `x := y ⊕ R1 ⊙ R2` is reversely
  executed as `y := x ⊙ R1 ⊙ R2`" — i.e. only `y` is destroyed; `R1` and `R2`
  must SURVIVE, or the inverse cannot recompute the expression.

`_rename_args_to_params!` (`src/interpreter/Interpreter.jl`) implemented the
second sentence of note 2 literally, with `delete!(locals, a)` per arg.

## Why note 2 does not transfer to BennettVM

**Note 2 presupposes a precondition BennettVM does not satisfy.**

RSSA blocks are **parameterized**. Mogensen's own construction (p. 209: "we
just add a parameter to the labels in the join point and in the jumps to the
join point") threads *every* value live across a block boundary through the
label parameter list. Under that discipline "this is an exit arg" and "this is
the value's last use in this block" are the same statement, which is exactly
what makes destroy-on-exit well-typed.

BennettVM's register file is a flat `Dict{Symbol,Int64}` **per frame**
(`active_locals(s) = s.frames[end].locals`, ADR 0019 §1). Non-φ values cross
blocks *implicitly*, by dict persistence, and are never mentioned in any
`args`/`params` list. Only φ-incomings appear there. So an exit arg carries no
information at all about whether the value is dead after the edge — and the
destructive half of note 2 was imported without the block parameterization
that grounds it.

Note 3 is the corroborating detail: RSSA is not fully linear even in Mogensen.
Destruction is a specific, targeted rule, not a general "uses consume" law.

## The failing shape is ordinary, verifier-legal SSA

```llvm
load133:  %__v327 = add %__v326, 1               ; preheader: initial probe index
L117:     %value_phi135 = phi [ %__v327, %load133 ], [ ..., latch ]
L131:     %__v76 = sub %value_phi135, %__v327    ; probe DISTANCE — the 2nd use
```

A φ-incoming with another use that outlives the edge. Julia emits this for
**every** loop whose preheader value is re-read in the body; it is in no way
Dict-specific.

## It was LATENT, not new

A static scan of the *lowered* `VMProgram` finds the identical hazard shape in
programs the suite already asserts GREEN:

| program | hazards |
|---|---|
| `Dict{Int8,Int8}`, ONE insert | ≥ 8 (incl. inside `rehash!`) |
| `Dict{Int64,Int64}`, ONE insert | same shape |
| collatz, matrix_tri, matrix_sum | 2 each |

Fourteen inserts merely make the `rehash!` GROW branch **reachable**. This is
why `test/test_rnhv_phi_multiuse.jl` §(5) asserts the hazard count on the
cheap one-insert fixture: a purely trajectory-dependent gate would stop
discriminating the moment the front-end changed which edge executes.

## Decision

**Remove the `delete!`.** `_rename_args_to_params!` becomes
`_bind_args_to_params!` — a non-destructive positional bind.

Kept unchanged:

- the **two-phase capture-then-assign** shape, still required for the
  permutation case (`args = [:x,:y]`, `params = [:y,:x]`), which an in-order
  single loop would stomp;
- the **arity guard** (Rule 1).

Renaming is not cosmetic: a reader who carries the "rename / MOVE" model
forward will re-derive the same bug.

`src/ir/ingest.jl` and `src/ir/ingest_phi.jl` are **not touched at all** —
including e4l's `_phi_ssa_dup_name` / `_phi_const_dup_name` and the
`allunique(args)` / condition-shadowing constructor guards, which become
redundant but whose removal would change lowering and disturb pinned shapes.

### Rejected alternative: insert a duplicating `Define` at non-linear φ-incomings

Emit `%dup = add %__v327, 0` in the preheader and send `%dup` on the edge,
preserving the MOVE. Rejected because:

1. **It does not restore linearity.** The original `%__v327` still is never
   destroyed by anything; the scheme launders the non-linearity rather than
   removing it. The claimed invariant would be false in exactly the same way,
   only less visibly.
2. It costs a step and an instruction per hazard site, on every iteration.
3. It would perturb the lowering of collatz / matrix_tri / matrix_sum — i.e.
   rewrite currently-green fixtures to fix a bug they do not have — and
   `src/ir/ingest.jl:370`'s const-sharing scheme pins Define counts
   byte-identical. The chosen design preserves that **by construction**,
   because ingest is untouched.

## Soundness

### No-harm proof (injectivity can only strengthen)

The old destructive transfer `D` factors as `D = π ∘ N`, where `N` is the new
non-destructive bind and `π : locals ↦ locals ∖ args` drops the arg keys. If
`D` is injective then so is `N`:

> `N(a) = N(b) ⟹ D(a) = π(N(a)) = π(N(b)) = D(b) ⟹ a = b`.

So the `is_injective(::Type{UnconditionalExit}) = true` /
`is_injective(::Type{ConditionalExit}) = true` claims in
`src/history/Injective.jl` are preserved or strengthened, never weakened, and
there is still nothing to log at these edges. Landauer-wise we erase strictly
less.

### Behavioural conservativity

Under `N` every name binds the same value at every step; the only difference
is extra surviving keys. Any instruction reading a key present under both
regimes gets the same value; one reading a key present only under `N` would
have thrown `KeyError` under `D`. Therefore **every previously-passing program
keeps a bit-identical trajectory**.

Measured, not assumed (`unrun!` verified to empty history in every row):

| fixture | steps | history len | checkpoints | deltas |
|---|---|---|---|---|
| collatz x ∈ {1,2,3,6,7,11} | 6/18/90/102/198/174 | 0/1/7/8/16/14 | same | 0 |
| matrix_sum n ∈ {0..4} | 7/19/41/73/115 | 0/1/3/5/7 | same | 0 |
| matrix_tri n ∈ {0..4} | 11/31/51/71/91 | 1/3/5/7/9 | same | 0 |

**Identical before and after, every column.** The only observable delta is the
predicted residual (below).

### In-project precedent — the DECISIVE argument

The project already ratified exactly this decision at the sibling boundary.
`docs/adr/0019-reversible-calls.md` **Amendment A.1** (hostile-review-ratified
2026-06-10):

> "C/LLVM SSA values are **multi-use** … The §3 MOVE (delete from caller)
> broke real programs (`KeyError: :found`). `CallEnter` now **copies** arg
> values into the fresh callee frame … the L1-injective/zero-history claim is
> *stronger* under COPY — nothing is erased."

`bennettvm-rnhv` is that same bug at the **φ-edge** instead of the call edge,
with the same root cause (multi-use LLVM SSA vs a MOVE discipline imported
from a reversible-by-construction source language) and the same fix.

## Costs

**Residual locals.** A genuinely dead arg name now lingers in `active_locals`
until its frame pops, inflating L3 snapshots and L2 residuals. Measured at
halt on the acceptance fixtures (these counts are a one-time MEASUREMENT, not a
suite-pinned invariant — `test_collatz_roundtrip.jl` asserts only
`step_count>0`/`==0`, so a future trajectory-shape drift would not trip a
test; see `bennettvm-axfr` for the note that a step-count pin is optional):

| fixture | locals before | after | Δ |
|---|---|---|---|
| collatz (x ≥ 2) | 13 | 16 | +3 |
| matrix_sum (n ≥ 1) | 10 | 15 | +5 |
| matrix_tri (n ≥ 1) | 22 | 30 | +8 |

Bounded by the number of distinct φ-edge arg names per frame — a static
property of the program, not a function of trip count. Note that all three
fixtures record **zero** `DeltaEntry`s, so today this cost lands only on L3
checkpoint size.

## Risks

**A malformed lowering can now read STALE instead of failing loud.** Before,
a genuinely missing definition on some path was often caught because the
destructive transfer had already removed the name. Now an unrelated leftover
binding of the same name may be found and read silently.

Mitigations:

1. **Shipped with this ADR** — `bennettvm-35yn`: `src/ir/unbound_ssa.jl`
   replaces the bare `KeyError` out of `_resolve` with an error naming the SSA
   symbol, the full instruction, the pc, the frame stack (`fname@pc` per
   activation) and the bound-name sample. The failure that *does* fire is now
   maximally localising. Pinned by `test_rnhv_phi_multiuse.jl` §(6).
2. **Deferred** — an SSA **dominance validator** over the lowered
   `VMProgram`: every operand read must be dominated by a definition on every
   path reaching it. That turns the stale-read class into a construction-time
   error and is the proper fix; it is the natural companion to M2.18's
   `validate(::VMProgram)` pass. Filed as `bennettvm-axfr` (P2) with the Rule-9
   forcing condition. Not blocking: no such lowering bug is known today, and
   the diagnostic above localises one in one run.

Note the risk is *bounded by SSA discipline*: a stale read can only find a
name that (a) collides exactly and (b) is in the same frame. Per-body `__vN`
names collide across bodies but not within a frame, and `CallEnter` pushes a
fresh frame.

## Deferred optimization — liveness-gated MOVE

Restore `delete!(locals, a)` for exactly those args a **backward liveness
pass** proves dead after the edge. This recovers the full erasure benefit with
none of the breakage, because the precondition Mogensen's parameterized blocks
supply structurally would then be *computed*.

This is the same optimization ADR 0019 §7 already promises for call args
("args provably dead after call → restore MOVE"), so the two should land as
one liveness tier, not separately. `src/analysis/liveness.jl` already exists
and is the natural home.

**Trigger condition** (Rule 9 — the exact condition that forces the work): when
L3-snapshot size or L2-residual size becomes the dominant history cost — i.e.
when a profiled program's history is dominated by `locals` breadth rather than
by step count or memory deltas. Until then the residual is a handful of Int64s
per frame and the simplicity is worth more.

## Validation

- Full `Pkg.test()` green, including three new hand-built witnesses, the
  14-insert `Dict{Int8,Int8}` + `Dict{Int64,Int64}` acceptance gate under both
  L2 and L3, and the trajectory-independent static hazard scan
  (`test/test_rnhv_phi_multiuse.jl`).
- Mutation-proof (Rule 5): re-inserting `delete!(locals, a)` turns §(1), §(2)
  and §(4) RED with `unbound SSA name`, while the §(3) control stays 41/41
  green — so the failures are attributable to the hazard, not the harness.
- Pinned trajectory shapes for collatz / matrix_tri / matrix_sum verified
  byte-identical (table above).

## Reuse (Law 2)

**Reuse:** Mogensen, *RSSA: A Reversible SSA Form* (2016) §4, p. 210 notes
1–3 — the args/params entry/exit discipline, adopted in full EXCEPT the
destroy-on-exit half of note 2, whose block-parameterization precondition this
IR does not satisfy. **Why not reuse further:** adopting note 2 also requires
adopting RSSA's parameterized blocks (thread every cross-boundary live value
through the label parameter list), which is a whole-IR redesign of
`src/ir/ingest*.jl` and is what the deferred liveness pass approximates at a
fraction of the cost. **Precedent:** ADR 0019 Amendment A.1, the identical
call-edge decision.
