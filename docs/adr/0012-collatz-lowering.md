# ADR 0012 — Collatz `ParsedIR` → `VMProgram` reversible lowering

> Status: **ACCEPTED** (2026-05-28). Keystone design for the M_UNBOUNDED
> vertical slice (bd `bennettvm-n67`, discovered-from `bennettvm-c39`).
> User-chosen direction (2026-05-28): prove the pipeline on
> `collatz_steps` end-to-end before generalizing the ingest.

## Context

`collatz_steps(::Int8)` is PRD v4 §3.6.2 Case D (unbounded `while`) and
the load-bearing SC9 motivating case. Bennett.jl's circuit backend
cannot compile it (needs `max_loop_iterations` unrolling); BennettVM's
job is to lower the **symbolic** loop and round-trip it.

This ADR was produced by a 3+1 design pass (Rule 6, Core tier): two
independent Opus design proposals, synthesized here, with one
orchestrator-caught correction the proposals missed (the
cross-iteration reversibility crux, below).

### Ground truth (verified, Bennett.jl pin `877341e`)

`Bennett.extract_parsed_ir(collatz_steps, Tuple{Int8})` already returns
the symbolic loop intact — **there is no "reject" to intercept** (the
`max_loop_iterations` reject lives only in the circuit-lowering path,
not in `extract_parsed_ir`). The `ParsedIR` is **3 blocks** using
exactly six `IRInst` types — `IRICmp`, `IRBranch`, `IRPhi`, `IRBinOp`,
`IRSelect`, `IRRet`:

- `top`: `IRICmp(__v1 = slt(x, 2))`; `IRBranch(__v1 → L46 | L8)`.
- `L8` (loop body, **self back-edge** `→ L8`): two loop-carried
  `IRPhi` (`value_phi17`=steps, `value_phi6`=val), then
  `and/mul/add/lshr` `IRBinOp`s and `eq/slt/ugt` `IRICmp`s producing
  temporaries `__v3..__v9`, two `IRSelect` (`value_phi4`, `or.cond`);
  `IRBranch(or.cond → L46 | L8)`.
- `L46` (exit): `IRPhi(value_phi1.lcssa)`; `IRRet`.

### Two findings already established (see bd `bennettvm-c39` notes)

1. **The interpreter already supports cyclic CFGs.** `_dispatch_to_block!`
   (`src/interpreter/Interpreter.jl:1188`) sets `pc` by `LabelTable`
   label lookup with no forward-only check, so `target_false=:L8`
   re-enters the block; `run!` terminates only on `is_halted`
   (its docstring names `collatz_steps` as the divergence case);
   history is **step_count-indexed**, so `unrun!` is loop-safe. No
   interpreter change is needed.

## The cross-iteration reversibility crux (the real problem)

Both design proposals initially concluded "zero history — collatz is
reversible by construction." **That is true only for straight-line
code.** In the loop, the temporaries `__v3, __v4, …` are the *same SSA
names redefined every iteration*. The φ-rename at the back-edge carries
only the loop-carried variables (`value_phi17`, `value_phi6`); the
temporaries persist in `locals`, so on re-entry the loop body
**overwrites** the previous iteration's `__v3`. Overwriting a value
without recording it is irreversible. This is precisely the
reversible-loop problem: Bennett-1973 trace-tape (record) vs Bennett-1989
pebble-game (uncompute).

**Decision (user, 2026-05-28): trace-tape, realized as the existing L3
checkpoint-replay history layer.** Pebble-game uncomputation is deferred
to M9.

This decision is what makes the slice tractable. `unstep!` on the L3
path (`src/history/Replay.jl`) restores the nearest `CheckpointEntry`
(a full `IState` snapshot) and **replays forward** to the target step —
it never calls per-instruction `inverse()`. Periodic full snapshots
capture overwritten temporaries automatically, so the loop reverses
correctly regardless of name reuse. The consequence for the new
instructions: they need only correct **forward** semantics and must be
classified `is_injective = false` (so the M6.2/M7.6 push gate emits L3
checkpoints around them). Their L1/L2 `inverse()` is **not on the L3
path** and is deferred (raise descriptively if reached — the
`CallInstruction` deferral pattern).

## Decisions

### D1 — SSA-create instruction: a dedicated `Define`

LLVM `IRBinOp`/`IRICmp` are *pure creates from live operands*
(`__v4 = mul(value_phi6, 3)`; `value_phi6` survives). The existing
`ArithmeticAssignment` is a *transform* `target := source MODOP
(lhs op rhs)` that **destroys** `source` (`countdown` uses it as
`n_out := n_in - 1`, `test/reference/countdown.jl:178-191`) — it cannot
express a create whose operands must survive.

RC3 expresses creates via `assignWithoutDestroy` =
`target := 0 ⊕ (lhs op rhs)` (a `Constant(0)` source;
`references/implementations/RC3/.../instances/ArithmeticAssignment.java`).
Proposal B argued for widening `ArithmeticAssignment.source` to
`Union{Symbol,Int64}` to mirror this. **We reject that under the
trace-tape decision**: the `… := 0 ⊕ e` form's natural inverse is
"delete target / set to 0", which does *not* restore an overwritten
prior value — wrong for the loop. Instead we adopt **Proposal A's
dedicated `Define` instruction**, classified non-injective so L3
checkpoint-replay reverses it:

```
struct Define <: Instruction
    target::Symbol
    lhs::Union{Symbol,Int64}
    op::Symbol                      # ∈ BINARY_OPERATORS ∪ COMPARISON_OPERATORS
    rhs::Union{Symbol,Int64}
    # constructor: target ∉ {lhs, rhs}  (SSA single-assignment)
end
forward(d, s):  s.locals[d.target] = _apply_binop(d.op, _resolve(d.lhs,s), _resolve(d.rhs,s)); s.pc += 1
is_injective(::Type{Define}) = false        # may overwrite across iterations → L3 checkpoints
inverse(d, s, _): error("Define reverse is via L3 checkpoint-replay at M_UNBOUNDED; direct L1/L2 inverse deferred — see ADR 0012")
```

Reuses `_resolve`/`_apply_binop` (Law 2). Operands are read, never
destroyed.

### D2 — Comparison operators

`IRICmp` lowers to a `Define` with a comparison `op`. The predicates
(`slt`, `eq`, `ugt`, and the LLVM siblings, mirroring
`Bennett._IR_ICMP_PREDS`) are **not** in `BINARY_OPERATORS`
(`src/ir/operators.jl`) nor handled by `_apply_binop`
(`src/ir/arithmetic_assignment.jl`). Add a `COMPARISON_OPERATORS` set
and extend `_apply_binop` to return `Int64(0)`/`Int64(1)`, signed
(`<`,`==`) vs unsigned (`reinterpret(UInt64, ·)`) per predicate. The
i1→Int64 boolean convention is **nonzero = true** — already the
interpreter's convention (`Interpreter.jl` cross-block dispatch reads
`cond_val != 0`).

### D3 — `SelectInstruction` (reversible 2-to-1 MUX)

`IRSelect` has no RC3 analogue (documented Law-2 exception: LLVM
`select` arises from Julia ternaries; Janus/RC3 source has none). Add:

```
struct SelectInstruction <: Instruction
    target::Symbol
    cond::Symbol                        # nonzero = true
    val_true::Union{Symbol,Int64}
    val_false::Union{Symbol,Int64}
    # constructor: target ∉ {cond, val_true, val_false}
end
forward(i, s): s.locals[i.target] = (s.locals[i.cond] != 0) ? _resolve(i.val_true,s) : _resolve(i.val_false,s); s.pc += 1
is_injective(::Type{SelectInstruction}) = false      # may overwrite → L3
inverse(i, s, _): error("Select reverse is via L3 checkpoint-replay at M_UNBOUNDED; direct inverse deferred — see ADR 0012")
```

`val_true`/`val_false` are `Union{Symbol,Int64}` because `or.cond`'s
true-arm is the literal `Const(-1)`.

### D4 — `IRPhi` → `ConditionalEntry` params; `IRBranch` → `ConditionalExit`; `IRRet` → `End`

The args→params positional rename (`Interpreter.jl:1215`,
`_rename_args_to_params!`) **is** φ-resolution (φ on joins, Mogensen).
The L8 loop-carried φ → `ConditionalEntry(:L8, [:value_phi17,
:value_phi6], predecessor_true=:L8, predecessor_false=:top,
condition=Symbol("or.cond"))`; each predecessor's `*Exit.args` carries
the φ incoming values in φ order. `IRBranch` → `ConditionalExit(cond,
true_label, false_label, args)`; `IRRet` → `EndInstruction` in `L46`;
the whole routine is framed by a `BeginInstruction(:collatz_steps,
[:x])`. The `L8→L8` self-edge is just `target_false=:L8` (already
supported). Backward predecessor recovery is automatic: L3 `unstep!`
replays forward, so it deterministically retakes the same branch — no
per-edge source label needed (Mogensen, not BobISA).

### D5 — Constant φ-incomings need synthetic creates

`*Exit.args::Vector{Symbol}` is symbol-only, but `value_phi17`'s
incoming from `top` is the literal `0`. Lower it by emitting a synthetic
`Define(:steps_init, Int64(0), :add, Int64(0))` (= 0) in `top` and
passing `:steps_init` as the arg. (Alternative — widen `args` to
`Union{Symbol,Int64}` — is rejected for the slice to keep the change
surface small; filed as a follow-up.)

## Risks / deferred (follow-up beads)

- **R1 — i8 vs Int64 width (correctness). RESOLVED 2026-06-04 (bead
  `bennettvm-bgc`).** `locals` are `Int64` but collatz is i8; `mul(val,3)`
  overflows i8 and `slt/ugt` differ by width. **Resolution:** option (a) —
  carry a `width` on `Define` (default 64) and mask in `forward`. The
  ingest threads the source `IRBinOp.width` / `IRICmp.width` into the
  `Define`; `Define.forward` calls the now-width-aware `_apply_binop`,
  which extracts the low-`w` bits of each operand, RE-EXTENDS per the op's
  OWN signedness (`_apply_cast(:sext, …)` for the signed arm; `& mask`
  zero-extend for the unsigned arm), does the op, and masks the result to
  low `w` bits (comparisons return an unmasked i1 0/1). Because every op
  re-extracts, the stored high bits never matter — no change to `IState` /
  cast / select / input-binding. `width == 64` is a verified no-op, so all
  pre-existing full-width behavior is byte-identical. The **golden-master
  agreement** now holds for ANY input, including ones whose trajectory
  OVERFLOWS the source width; masking is part of the deterministic forward,
  so the **round-trip** (P0.6) is unaffected. Gate:
  `test/test_width_masking.jl` (`(Int8(3)*x)÷Int8(2)` at x=50 → 203,
  pre-fix 75). Pebble-game / non-i64 general widths still exercised only as
  the test surface grows.
- **R2 — `ConditionalExit` sends one arg-list to two targets** with
  potentially different params. For collatz, use reconcilable
  param-lists / in-successor renames; per-target arg-lists filed as a
  follow-up.
- **R3 — `Define`/`Select` L1/L2 inverse + injectivity tightening**
  (a fresh, never-overwritten `Define` is injective; only the
  overwrite case needs history). Deferred — L3 is correct for the slice.
- **R4 — pebble-game uncomputation** (zero-history loops) is M9.

## Implementation plan (beads filed under M_UNBOUNDED)

1. Comparison operators in `operators.jl` + `_apply_binop` (D2).
2. `Define` instruction (D1).
3. `SelectInstruction` (D3).
4. The `lower_vm` ingest pass: collatz `ParsedIR` → `VMProgram`
   (D1–D5; φ/branch/ret/back-edge assembly, synthetic zero-creates).
5. `collatz_steps_ref` oracle + round-trip test (M_UNBOUNDED.3,
   `bennettvm-hvx`): run! under L3, steps==oracle on a non-overflowing
   input, `unrun!` → initial state + empty history.

## References

- `bennettvm_prd.md` (PRD v4) §3.3 (three-layer history), §3.6.2 Case D,
  §6 SC9, P0.6 (round-trip invariant).
- `docs/adr/0001-rc3-rvm-smoke.md` — the 12-instruction RSSA taxonomy.
- `references/implementations/RC3/.../instances/ArithmeticAssignment.java`
  — `assignWithoutDestroy` (`target := 0 ⊕ e`).
- `src/interpreter/Interpreter.jl` (`_dispatch_to_block!:1188`,
  `_rename_args_to_params!:1215`, cyclic-CFG support), `src/history/Replay.jl`
  (L3 checkpoint-replay), `src/history/Injective.jl` (the push gate),
  `src/ir/arithmetic_assignment.jl` / `src/ir/operators.jl` (the create/op
  reuse), `test/reference/countdown.jl` (the existing convention).
- Bennett.jl `src/ir_types.jl` (`ParsedIR`, `IRInst`, `_IR_ICMP_PREDS`),
  pin `877341e`.
