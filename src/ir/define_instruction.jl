"""
    Define (M_UNBOUNDED, ADR 0012 §D1)

The reversible **SSA-create** instruction: it materialises a fresh SSA
name from a binary operation on two operands that are *read but not
destroyed*. This is the lowering target for LLVM `IRBinOp` and `IRICmp`
in the collatz vertical slice — e.g. `__v4 = mul(value_phi6, 3)`, where
`value_phi6` survives in `locals` for use by later instructions in the
same iteration.

    target := lhs op rhs        # operands READ, never deleted

# Why a dedicated `Define`, distinct from `ArithmeticAssignment`

`ArithmeticAssignment` (M2.6, `src/ir/arithmetic_assignment.jl`) is a
*destructive transform* `x := y ⊕ (lhs op rhs)` that **destroys** its
`source` (`y`) — `countdown` uses it as `n_out := n_in - 1`, deleting
`n_in` (`test/reference/countdown.jl:178-191`). That form cannot express
a pure create whose operands must survive: there is no `source` to
consume, and the operands themselves are the surviving live values.

RC3 expresses creates via `assignWithoutDestroy` = `target := 0 ⊕ (lhs
op rhs)` (a `Constant(0)` source; `references/implementations/RC3/.../
instances/ArithmeticAssignment.java`). ADR 0012 §D1 **rejects** widening
`ArithmeticAssignment.source` to admit that form: the `… := 0 ⊕ e`
inverse is "delete target / set to 0", which does *not* restore an
**overwritten prior value** — wrong for the loop case (see below). We
adopt Proposal A's dedicated `Define` instead, classified non-injective
so the L3 checkpoint-replay layer reverses it.

# The cross-iteration crux — why `is_injective = false` (load-bearing)

In a loop the temporaries `__v3, __v4, …` are the *same SSA names
redefined every iteration*. The φ-rename at the back-edge carries only
the loop-carried variables; the temporaries persist in `locals`, so on
re-entry the loop body **overwrites** the previous iteration's value of
the same name. Overwriting a value without recording it is irreversible.

The static `is_injective` *type-level* trait cannot see runtime
freshness — it cannot distinguish "first definition of `__v4`" (a true
bijective create, injective) from "the third re-definition this loop"
(an overwrite, non-injective). Per Rule 1 ("fail safe — push the history
entry when in doubt") it must be conservatively `false`. The M6.2/M7.6
push gate then emits L3 `CheckpointEntry`s around every `Define`, and
`unstep!` reverses it via checkpoint-replay (`src/history/Replay.jl`),
which restores the nearest full `IState` snapshot and **replays
forward** — it never calls per-instruction `inverse()`. Periodic full
snapshots capture overwritten temporaries automatically, so the loop
reverses correctly regardless of name reuse. Tightening the trait to
recognise the never-overwritten case (a genuinely injective `Define`)
is deferred — ADR 0012 §"Risks / deferred" R3.

# Why `inverse` raises rather than implementing an L1/L2 inverse

Because `Define` is reversed exclusively via the L3 checkpoint-replay
path, its per-instruction `inverse()` is **not on any live code path**
at this milestone — the M7.6 push gate caches `Define`s as L3
checkpoints, and `compute_must_cache` (M7.5) does not select them for
L2 delta entries. Reaching `inverse(::Define, ...)` would mean `unstep!`
tried an L1/L2 path on a `Define`, which is a bug. Per Rule 1 we raise
descriptively rather than silently no-op'ing (which would give the
appearance of a successful reverse step while the overwritten prior
value was never restored — silent reversibility corruption). This
mirrors the `CallInstruction` v5-deferral pattern
(`src/ir/call_instruction.jl`).

# Operand kinds (Union{Symbol,Int64}) and operator domain

`lhs` / `rhs` may each independently be an SSA reference (`Symbol`,
looked up in `active_locals(s)`) or a literal `Int64` — the same
`Union{Symbol,Int64}` convention `ArithmeticAssignment` uses; resolution
routes through the reused `_resolve` helper (Law 2). The `op` domain is
`BINARY_OPERATORS ∪ COMPARISON_OPERATORS`: `Define` is the create that
*legitimately carries comparison predicates* (ADR 0012 §D2 — `IRICmp`
lowers to a `Define` with a comparison `op`), unlike
`ArithmeticAssignment`, which deliberately rejects comparisons so an
`IRICmp` op never lands on the IRBinOp arm. Both families are evaluated
by the reused `_apply_binop` (Law 2): arithmetic ops wrap on overflow,
comparison predicates return `Int64(1)` / `Int64(0)` under the
interpreter's "nonzero = true" i1→Int64 convention.

# The `width` field (ADR 0012 R1 RESOLVED, bead `bennettvm-bgc`)

`width::Int` is the LLVM operand bit-width of the source `IRBinOp` /
`IRICmp` (for a comparison it is the OPERAND width — the i1 result is
never masked). `forward` passes it to `_apply_binop`, which computes the
op in i`width` semantics: it extracts the low-`width` bits of each operand,
re-extends per the op's own signedness, does the op, and masks the result
to low `width` bits (see `_apply_binop`'s docstring for the per-op
classification). This makes a narrow-width create agree with a native
i`width` oracle even when the op OVERFLOWS its width (e.g.
`Int8(3) * Int8(50)` = 150 wraps to `Int8(-106)`), closing ADR 0012 R1.

The field **defaults to 64**, so every existing `Define(t, l, op, r)` call
— hand-built unit tests, the synthetic φ-incoming-constant `Define`s the
ingest emits — is unchanged: `_apply_binop` at width 64 is a verified
NO-OP (`mask = -1`, `sext` at 64 = identity), so all pre-existing
behavior is byte-identical. Only the ingest's `IRBinOp` / `IRICmp` arm
threads the real source `width` in.

# Constructor validation (Rule 1)

The constructor rejects `target ∈ {lhs, rhs}` at construction time: an
SSA name cannot be both defined and read by the same instruction (RSSA
single-assignment — every SSA name has exactly one defining
instruction). A literal `Int64` operand can never collide with the
`Symbol` target, so the check is only meaningful for symbolic operands;
the comparison `target === lhs` / `target === rhs` is type-safe across
the `Union` (a `Symbol === Int64` is simply `false`).

# pc symmetry

`forward` sets `s.pc += 1`, matching the per-step +1 of every M2.x
instruction. There is no symmetric `inverse` pc decrement here because
the inverse is the L3 replay path, not a per-step `inverse()` call; the
deferred `inverse` raises before touching `pc`.

# Ref

  * `docs/adr/0012-collatz-lowering.md` §D1 (the dedicated-`Define`
    decision; the `assignWithoutDestroy` rejection) and §"The
    cross-iteration reversibility crux" (the trace-tape / L3 reasoning
    behind `is_injective = false`).
  * `src/ir/arithmetic_assignment.jl` — `_resolve` / `_apply_binop`,
    reused here (Law 2); the destructive-transform contrast.
  * `src/ir/operators.jl` — `BINARY_OPERATORS`, `COMPARISON_OPERATORS`,
    `is_binary_operator`, `is_comparison_operator` (the op-domain guard).
  * `src/ir/call_instruction.jl` — the deferred-`inverse` error house
    style this file mirrors.
  * `src/history/Injective.jl` — where `is_injective(::Type{Define}) =
    false` is wired (the M6.2/M7.6 L3 push gate consumes it).
  * `src/history/Replay.jl` — the L3 checkpoint-replay `unstep!` that
    actually reverses a `Define`.
  * CLAUDE.md Rule 1 (fail loud), Rule 2 (reuse), Rule 11 (literate).
"""
struct Define <: Instruction
    target::Symbol
    lhs::Union{Symbol,Int64}
    op::Symbol                  # ∈ BINARY_OPERATORS ∪ COMPARISON_OPERATORS
    rhs::Union{Symbol,Int64}
    width::Int                  # LLVM operand bit-width (default 64; ADR 0012 R1)

    function Define(target::Symbol, lhs::Union{Symbol,Int64}, op::Symbol,
                    rhs::Union{Symbol,Int64}, width::Int=64)
        (is_binary_operator(op) || is_comparison_operator(op)) ||
            error("Define: invalid op $(op); must be in BINARY_OPERATORS ",
                  "∪ COMPARISON_OPERATORS (an arithmetic/bitwise/shift/",
                  "divrem op or an LLVM icmp predicate). Define is the ",
                  "create that legitimately carries comparisons (ADR 0012 ",
                  "§D2), unlike ArithmeticAssignment.")
        (target === lhs || target === rhs) &&
            error("Define: SSA single-assignment violation — target ",
                  "$(target) also appears as an operand ($(lhs), $(rhs)); ",
                  "an SSA name cannot be both defined and read by the same ",
                  "instruction (RSSA: every name has exactly one defining ",
                  "instruction).")
        1 <= width <= 64 ||
            error("Define: width=$(width) out of range 1..64 (IState.locals ",
                  "are Int64; op=$(op), target=$(target)). The width is the ",
                  "LLVM operand bit-width threaded from IRBinOp/IRICmp (ADR ",
                  "0012 R1, bead bennettvm-bgc).")
        return new(target, lhs, op, rhs, width)
    end
end

"""
    forward(instr::Define, s::IState) -> IState

Execute `target := lhs op rhs` in-place on `s`. Resolves `lhs` / `rhs`
against `active_locals(s)` (or uses the literal `Int64`), applies `op` via the
reused `_apply_binop` **at `instr.width`** (i`width` semantics — ADR 0012
R1; `width == 64` is a no-op), and writes the result into
`active_locals(s)[target]`, bumping `pc`. The operands are **read, never deleted**
— the non-destructive create property (contrast
`ArithmeticAssignment.forward`, which `delete!`s its `source`).

If `target` already exists in `active_locals(s)` (the loop / cross-iteration
case), it is **overwritten** without error — that is the intended
forward semantics; reversibility of the overwrite is the L3
checkpoint-replay layer's responsibility (see this file's top-of-module
docstring "The cross-iteration crux").
"""
function forward(instr::Define, s::IState)::IState
    # `instr` is threaded into `_resolve` purely so an unbound operand fails
    # loud WITH the instruction in the message (`bennettvm-35yn`;
    # `src/ir/unbound_ssa.jl`). No effect on the happy path.
    lv = _resolve(instr.lhs, s, instr)
    rv = _resolve(instr.rhs, s, instr)
    # Width-aware: `_apply_binop` computes in i`width` semantics (ADR 0012
    # R1, bead bennettvm-bgc). `width == 64` (the default) is a no-op, so a
    # synthetic / hand-built Int64 Define is byte-identical to before.
    active_locals(s)[instr.target] = _apply_binop(instr.op, lv, rv, instr.width)
    s.pc += 1
    return s
end

"""
    inverse(instr::Define, s::IState, prev) -> IState

**Always raises `ErrorException`.** `Define`'s reverse is via the L3
checkpoint-replay layer (`src/history/Replay.jl`), which never calls
per-instruction `inverse()`. Direct L1/L2 inverse is deferred (ADR 0012
§"Risks / deferred" R3); reaching this method means `unstep!` tried an
L1/L2 path on a `Define`, which should not happen with an empty
`must_cache_set`. This mirrors the `CallInstruction` deferral pattern
(`src/ir/call_instruction.jl`). Rule 1: fail loud rather than silently
no-op (which would falsely report a successful reverse while the
overwritten prior value went unrestored).
"""
function inverse(instr::Define, s::IState, prev)::IState
    error("Define reverse is via L3 checkpoint-replay at M_UNBOUNDED; ",
          "direct L1/L2 inverse is deferred (ADR 0012 R3). Reaching this ",
          "means unstep! tried an L1/L2 path on a Define, which should not ",
          "happen with empty must_cache_set. State: pc=$(s.pc).")
end
