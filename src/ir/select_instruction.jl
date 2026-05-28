"""
    SelectInstruction (M_UNBOUNDED, ADR 0012 §D3)

The reversible **2-to-1 multiplexer**: it materialises a fresh SSA name
by choosing between two operands under a predicate that is *read but not
destroyed*. This is the lowering target for LLVM `IRSelect` in the
collatz vertical slice — e.g. `value_phi4 = .not ? __v6 : __v5` and
`or.cond = __v8 ? Const(-1) : __v9`, where the predicate and both arms
survive in `locals` for use by later instructions in the same iteration.

    target := (cond != 0) ? val_true : val_false   # operands READ, never deleted

# Why a dedicated `SelectInstruction` (a documented Law-2 exception)

LLVM `select` has **no RC3 analogue**: it arises from Julia ternaries,
and the Janus / RC3 source language is reversible-by-construction and
has no ternary-select primitive. Law 2 (reuse before reinvention) is
therefore satisfied vacuously — there is no published reversible MUX
instruction to port. ADR 0012 §D3 records this as the explicit
exception. The shape mirrors the sibling `Define` (the SSA-create that
*did* land, ADR 0012 §D1): both are non-destructive creates whose
operands survive, both are classified non-injective so the L3
checkpoint-replay layer reverses them, and both defer their
per-instruction `inverse()` (see below).

# The cross-iteration crux — why `is_injective = false` (load-bearing)

In a loop the temporaries `__v3, __v4, …` (and the φ-renamed select
outputs `value_phi4`, `or.cond`) are the *same SSA names redefined
every iteration*. The φ-rename at the back-edge carries only the
loop-carried variables; the temporaries persist in `locals`, so on
re-entry the loop body **overwrites** the previous iteration's value of
the same name. Overwriting a value without recording it is irreversible.

The static `is_injective` *type-level* trait cannot see runtime
freshness — it cannot distinguish "first definition of `value_phi4`"
(a true bijective create, injective) from "the third re-definition this
loop" (an overwrite, non-injective). Per Rule 1 ("fail safe — push the
history entry when in doubt") it must be conservatively `false`. The
M6.2/M7.6 push gate then emits L3 `CheckpointEntry`s around every
`SelectInstruction`, and `unstep!` reverses it via checkpoint-replay
(`src/history/Replay.jl`), which restores the nearest full `IState`
snapshot and **replays forward** — it never calls per-instruction
`inverse()`. Periodic full snapshots capture overwritten temporaries
automatically, so the loop reverses correctly regardless of name reuse.
Tightening the trait to recognise the never-overwritten case (a
genuinely injective select) is deferred — ADR 0012 §"Risks / deferred"
R3.

# Why `inverse` raises rather than implementing an L1/L2 inverse

Because `SelectInstruction` is reversed exclusively via the L3
checkpoint-replay path, its per-instruction `inverse()` is **not on any
live code path** at this milestone — the M7.6 push gate caches selects
as L3 checkpoints, and `compute_must_cache` (M7.5) does not select them
for L2 delta entries. Reaching `inverse(::SelectInstruction, ...)` would
mean `unstep!` tried an L1/L2 path on a select, which is a bug.
Note that even given the post-state, the select is genuinely *not*
locally invertible: a 2-to-1 MUX loses the unselected arm and the
overwritten prior value of `target`, so no structural inverse exists
without history. Per Rule 1 we raise descriptively rather than silently
no-op'ing (which would give the appearance of a successful reverse step
while the overwritten prior value was never restored — silent
reversibility corruption). This mirrors the `Define` and
`CallInstruction` deferral pattern (`src/ir/define_instruction.jl`,
`src/ir/call_instruction.jl`).

# Operand kinds (cond::Symbol; val_true / val_false::Union{Symbol,Int64})

`cond` is always a `Symbol` — the predicate is an SSA name produced by
an upstream `Define` with a comparison `op` (ADR 0012 §D2) and read
directly from `s.locals`; it is never a literal. The arms `val_true` /
`val_false` may each independently be an SSA reference (`Symbol`, looked
up in `s.locals`) or a literal `Int64` — the same `Union{Symbol,Int64}`
convention `Define` / `ArithmeticAssignment` use, because `or.cond`'s
true-arm is the literal `Const(-1)`. Arm resolution routes through the
reused `_resolve` helper (Law 2; `src/ir/arithmetic_assignment.jl`). The
predicate convention is **nonzero = true** — already the interpreter's
i1→Int64 convention (`Interpreter.jl` cross-block dispatch reads
`cond_val != 0`).

# Constructor validation (Rule 1)

The constructor rejects `target ∈ {cond, val_true, val_false}` at
construction time: an SSA name cannot be both defined and read by the
same instruction (RSSA single-assignment — every SSA name has exactly
one defining instruction). A literal `Int64` arm can never collide with
the `Symbol` target, so the check is only meaningful for symbolic
operands; the comparison `target === val_true` / `target === val_false`
is type-safe across the `Union` (a `Symbol === Int64` is simply
`false`). `cond` is always a `Symbol`, so `target === cond` is a direct
symbol comparison.

# pc symmetry

`forward` sets `s.pc += 1`, matching the per-step +1 of every M2.x
instruction. There is no symmetric `inverse` pc decrement here because
the inverse is the L3 replay path, not a per-step `inverse()` call; the
deferred `inverse` raises before touching `pc`.

# Ref

  * `docs/adr/0012-collatz-lowering.md` §D3 (the `SelectInstruction`
    decision; the LLVM-`select`-has-no-RC3-analogue Law-2 exception) and
    §"The cross-iteration reversibility crux" (the trace-tape / L3
    reasoning behind `is_injective = false`).
  * `src/ir/define_instruction.jl` — the sibling SSA-create whose file
    structure, constructor-validation style, and forward + raising-
    `inverse` pattern this file mirrors.
  * `src/ir/arithmetic_assignment.jl` — `_resolve`, reused here (Law 2).
  * `src/ir/call_instruction.jl` — the deferred-`inverse` error house
    style this file mirrors.
  * `src/history/Injective.jl` — where `is_injective(::Type{
    SelectInstruction}) = false` is wired (the M6.2/M7.6 L3 push gate
    consumes it).
  * `src/history/Replay.jl` — the L3 checkpoint-replay `unstep!` that
    actually reverses a `SelectInstruction`.
  * CLAUDE.md Rule 1 (fail loud), Rule 2 (reuse), Rule 11 (literate).
"""
struct SelectInstruction <: Instruction
    target::Symbol
    cond::Symbol                        # predicate in locals; nonzero = true
    val_true::Union{Symbol,Int64}
    val_false::Union{Symbol,Int64}

    function SelectInstruction(target::Symbol, cond::Symbol,
                               val_true::Union{Symbol,Int64},
                               val_false::Union{Symbol,Int64})
        (target === cond || target === val_true || target === val_false) &&
            error("SelectInstruction: SSA single-assignment violation — ",
                  "target $(target) also appears as an operand (cond=$(cond), ",
                  "val_true=$(val_true), val_false=$(val_false)); an SSA name ",
                  "cannot be both defined and read by the same instruction ",
                  "(RSSA: every name has exactly one defining instruction).")
        return new(target, cond, val_true, val_false)
    end
end

"""
    forward(instr::SelectInstruction, s::IState) -> IState

Execute `target := (cond != 0) ? val_true : val_false` in-place on `s`.
Reads `s.locals[cond]` for the predicate (always a `Symbol`), resolves
the selected arm via the reused `_resolve` (an unselected literal/`Symbol`
arm is *not* evaluated — but symbolic arms are read, never deleted),
writes the result into `s.locals[target]`, and bumps `pc`. The predicate
and arms are **read, never deleted** — the non-destructive create
property (contrast `ArithmeticAssignment.forward`, which `delete!`s its
`source`).

The predicate uses the interpreter's "nonzero = true" i1→Int64
convention: any nonzero `cond` selects `val_true`, `0` selects
`val_false`.

If `target` already exists in `s.locals` (the loop / cross-iteration
case), it is **overwritten** without error — that is the intended
forward semantics; reversibility of the overwrite is the L3
checkpoint-replay layer's responsibility (see this file's top-of-module
docstring "The cross-iteration crux").
"""
function forward(instr::SelectInstruction, s::IState)::IState
    s.locals[instr.target] = (s.locals[instr.cond] != 0) ?
        _resolve(instr.val_true, s) : _resolve(instr.val_false, s)
    s.pc += 1
    return s
end

"""
    inverse(instr::SelectInstruction, s::IState, prev) -> IState

**Always raises `ErrorException`.** `SelectInstruction`'s reverse is via
the L3 checkpoint-replay layer (`src/history/Replay.jl`), which never
calls per-instruction `inverse()`. Direct L1/L2 inverse is deferred (ADR
0012 §"Risks / deferred" R3); reaching this method means `unstep!` tried
an L1/L2 path on a select, which should not happen with an empty
`must_cache_set`. A 2-to-1 MUX is genuinely not locally invertible (the
unselected arm and the overwritten prior value of `target` are lost), so
this is a true deferral, not a missing convenience. This mirrors the
`Define` / `CallInstruction` deferral pattern. Rule 1: fail loud rather
than silently no-op (which would falsely report a successful reverse
while the overwritten prior value went unrestored).
"""
function inverse(instr::SelectInstruction, s::IState, prev)::IState
    error("SelectInstruction reverse is via L3 checkpoint-replay at ",
          "M_UNBOUNDED; direct L1/L2 inverse is deferred (ADR 0012 R3). ",
          "Reaching this means unstep! tried an L1/L2 path on a ",
          "SelectInstruction, which should not happen with empty ",
          "must_cache_set. State: pc=$(s.pc).")
end
