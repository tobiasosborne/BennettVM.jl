"""
    CastInstruction (M_OPCODE / ADR 0013 §D-5 step 1, ADR 0012 §D1 template)

The reversible **width-cast SSA-create**: it materialises a fresh SSA
name by re-interpreting an operand at a different bit width. This is the
lowering target for LLVM `IRCast` (`sext` / `zext` / `trunc`) — the
remaining frontend-reachable, non-memory body-instruction gap
(`docs/coverage-matrix.md` row 6, the P1 gap). Width-mixing programs —
e.g. the triangular nested `while` loop whose counters are zero-extended
i8→i9 before an add and truncated i9→i8 after — emit `IRCast` and
currently fail `lower_vm` at the `_lower_body_inst` else-arm.

    target := cast(op, operand)     # operand READ, never destroyed
    op ∈ {:sext, :zext, :trunc}

# Why a dedicated `CastInstruction`, mirroring `Define` (ADR 0012 §D1)

`CastInstruction` is the **non-destructive SSA-create analogue of
`Define` for width casts** (`src/ir/define_instruction.jl`). Like
`Define`, it reads a single operand and writes a fresh `target` without
consuming the operand — the operand survives in `locals` for later
instructions in the same iteration (collatz / matrix_tri both keep the
cast source live). It is NOT a `Define`: a cast is a unary, width-aware
re-interpretation, not a binary `lhs op rhs`. The op domain is the
three-element `IRCast` set `{:sext, :zext, :trunc}` (Bennett.jl
`_IR_CAST_OPS`, `../Bennett.jl/src/ir_types.jl:11`), disjoint from
`BINARY_OPERATORS ∪ COMPARISON_OPERATORS`, so it carries its own `op`
field and validation rather than routing through `_apply_binop`.

# Forward semantics (LLVM `sext` / `zext` / `trunc` on `Int64` locals)

`IState.locals` are `Int64`; an i`from_width` value lives in the low
`from_width` bits. Each op produces the LLVM result interpreted into the
`Int64` slot (ADR 0013 R1: no per-`width` masking elsewhere yet, so the
cast is the one place that must get width right):

  * `:zext` — zero-extend. LLVM treats the source as UNSIGNED and
    zero-fills the high bits. The result is the unsigned value of the low
    `from_width` bits: `operand & ((1 << from_width) - 1)`. We mask the
    operand (it should already fit, but a sign-extended-on-arrival negative
    value would otherwise survive — Rule 1, fail safe). The result is
    nonnegative (no sign bit). Mirrors Bennett.jl's gate `lower_cast!`,
    which CNOT-copies `src[1:F]` into a freshly-zeroed `r`
    (`../Bennett.jl/src/lowering/arith.jl:542-543`).

  * `:sext` — sign-extend. LLVM treats the source as SIGNED (two's
    complement) and replicates the sign bit (bit `from_width-1`) into all
    higher bits. We compute the `Int64` sign-extension of the low
    `from_width` bits: take `v & low_mask`, then if the sign bit is set,
    OR in the complement of `low_mask` so bits `from_width..63` become 1.
    Mirrors Bennett.jl's gate `lower_cast!`, which copies `src[1:F]` then
    fans `src[F]` (the sign bit) into `r[F+1..T]`
    (`../Bennett.jl/src/lowering/arith.jl:544-546`).

  * `:trunc` — truncate. LLVM keeps the low `to_width` bits and discards
    the high bits (LOSSY): `operand & ((1 << to_width) - 1)`. Mirrors
    Bennett.jl's gate `lower_cast!`, which CNOT-copies `src[1:T]` into `r`
    (`../Bennett.jl/src/lowering/arith.jl:560`).

`to_width == 64` for the `:zext` / `:trunc` masks is the degenerate
all-ones mask; `(Int64(1) << 64)` is undefined-shift territory, so the
mask helper special-cases a full-width mask to `typemax`/`-1` (see
`_low_mask`). `from_width == 64` likewise: a 64-bit `:sext` is the
identity (no high bits to fill) and a 64-bit `:zext` keeps the raw bits.

# is_injective = false (conservative, exactly like `Define`) — load-bearing

In a loop the temporaries `__v4, __v5, __v8, …` are the *same SSA names
redefined every iteration*; the φ-rename at the back-edge carries only
the loop-carried variables, so on re-entry the cast **overwrites** the
previous iteration's value of the same name. Overwriting a value without
recording it is irreversible. Moreover `:trunc` is *intrinsically* lossy
even on a fresh create — the discarded high bits cannot be recovered from
the result alone.

The static type-level `is_injective` trait cannot see runtime freshness
(first-definition vs re-definition) and cannot recover the truncated bits,
so per Rule 1 ("fail safe — push the history entry when in doubt") it is
conservatively `false` (wired in `src/history/Injective.jl`). The
M6.2/M7.6 push gate then emits L3 `CheckpointEntry`s around every
`CastInstruction`, and `unstep!` reverses it via checkpoint-replay
(`src/history/Replay.jl`) — it restores the nearest full `IState` snapshot
and replays forward, never calling per-instruction `inverse()`. Periodic
full snapshots capture overwritten / truncated temporaries automatically.

# Why `inverse` raises rather than implementing an L1/L2 inverse

Because `CastInstruction` is reversed exclusively via the L3 checkpoint-
replay path, its per-instruction `inverse()` is **not on any live code
path** at this milestone. `:trunc` is genuinely not locally invertible
(the high bits are lost), and a loop re-definition of any op loses the
overwritten prior `target` — so this is a true deferral, not a missing
convenience. Per Rule 1 we raise descriptively rather than silently
no-op'ing (which would falsely report a successful reverse while the
lost information went unrestored — silent reversibility corruption). This
mirrors the `Define` / `SelectInstruction` / `CallInstruction` pattern
(`src/ir/define_instruction.jl`, `src/ir/select_instruction.jl`,
`src/ir/call_instruction.jl`).

# Operand kind (Union{Symbol,Int64}) and constructor validation (Rule 1)

`operand` may be an SSA reference (`Symbol`, looked up in `s.locals` via
the reused `_resolve`, Law 2) or a literal `Int64` — the same convention
`Define` / `ArithmeticAssignment` use; the matrix_tri casts are all
`SSAOperand`, but the union keeps a constant-source cast lowerable. The
constructor rejects an out-of-domain `op` (not in `_CAST_OPS`), a
`from_width`/`to_width` outside `1..64`, and `target === operand` (RSSA
single-assignment — an SSA name cannot be both defined and read by the
same instruction). The `target === operand` check is type-safe across the
`Union` (a `Symbol === Int64` is simply `false`).

# pc symmetry

`forward` sets `s.pc += 1`, matching the per-step +1 of every M2.x
instruction. There is no symmetric `inverse` pc decrement — the inverse
is the L3 replay path, not a per-step `inverse()` call; the deferred
`inverse` raises before touching `pc`.

# Ref

  * `docs/adr/0013-reversible-memory-architecture.md` §D-5 step 1 (IRCast
    is the immediate non-memory gap, lands in the reversible-memory floor
    build) and `docs/coverage-matrix.md` row 6 (the P1 gap).
  * `docs/adr/0012-collatz-lowering.md` §D1 + §"cross-iteration
    reversibility crux" — the dedicated-create + non-injective + deferred-
    inverse design this file mirrors from `Define`.
  * `../Bennett.jl/src/ir_types.jl:11,126` — `_IR_CAST_OPS` and the
    `IRCast` struct (op / operand / from_width / to_width fields).
  * `../Bennett.jl/src/lowering/arith.jl:536-566` — `lower_cast!`, the
    gate-level reference for the per-op bit semantics (CNOT-copy / sign-
    fan / low-bit copy) this `Int64` arithmetic reproduces.
  * `src/ir/define_instruction.jl` — the SSA-create template.
  * `src/ir/arithmetic_assignment.jl` — `_resolve`, reused here (Law 2).
  * `src/history/Injective.jl` — where `is_injective(::Type{
    CastInstruction}) = false` is wired.
  * `src/history/Replay.jl` — the L3 checkpoint-replay `unstep!` that
    actually reverses a `CastInstruction`.
  * CLAUDE.md Rule 1 (fail loud), Rule 2 (reuse), Rule 11 (literate).
"""

# The three LLVM cast ops BennettVM lowers, mirroring Bennett.jl's
# `_IR_CAST_OPS` (`../Bennett.jl/src/ir_types.jl:11`). A tuple (not a
# `Set`) — three elements, membership is a cheap linear scan, and the
# tuple renders cleanly in the constructor error.
const _CAST_OPS = (:sext, :zext, :trunc)

struct CastInstruction <: Instruction
    target::Symbol
    op::Symbol                    # ∈ _CAST_OPS
    operand::Union{Symbol,Int64}
    from_width::Int
    to_width::Int

    function CastInstruction(target::Symbol, op::Symbol,
                             operand::Union{Symbol,Int64},
                             from_width::Int, to_width::Int)
        op in _CAST_OPS ||
            error("CastInstruction: invalid op $(op); must be one of ",
                  _CAST_OPS, " (the LLVM IRCast set, Bennett.jl ",
                  "_IR_CAST_OPS).")
        1 <= from_width <= 64 ||
            error("CastInstruction: from_width=$(from_width) out of range ",
                  "1..64 (IState.locals are Int64; op=$(op), target=",
                  "$(target)).")
        1 <= to_width <= 64 ||
            error("CastInstruction: to_width=$(to_width) out of range ",
                  "1..64 (IState.locals are Int64; op=$(op), target=",
                  "$(target)).")
        target === operand &&
            error("CastInstruction: SSA single-assignment violation — ",
                  "target $(target) also appears as the operand; an SSA ",
                  "name cannot be both defined and read by the same ",
                  "instruction (RSSA: every name has exactly one defining ",
                  "instruction).")
        return new(target, op, operand, from_width, to_width)
    end
end

# Low-`w`-bits mask as an `Int64`, special-casing the full 64-bit width
# (`Int64(1) << 64` is undefined-shift behaviour). `w == 64` → all ones
# (`-1` / `typemax`-as-bitpattern); else `(1 << w) - 1`.
_low_mask(w::Int)::Int64 = w >= 64 ? -1 % Int64 : (Int64(1) << w) - Int64(1)

"""
    _apply_cast(op::Symbol, v::Int64, from_width::Int, to_width::Int) -> Int64

Apply one LLVM width cast to the `Int64`-backed value `v`. See this
file's top-of-module docstring for the per-op LLVM semantics and the
Bennett.jl gate-level cross-reference. A flat `if`-chain (not a `Dict`)
so Rule 1's final `error` clause catches an unknown op even though the
constructor has already validated.
"""
function _apply_cast(op::Symbol, v::Int64, from_width::Int, to_width::Int)::Int64
    if op === :zext
        # Unsigned value of the low `from_width` bits (zero-fill high).
        return v & _low_mask(from_width)
    elseif op === :sext
        # Signed value of the low `from_width` bits, sign-extended to Int64.
        low = _low_mask(from_width)
        masked = v & low
        sign_bit = Int64(1) << (from_width - 1)
        # If the source sign bit is set, fill bits from_width..63 with ones.
        return (masked & sign_bit) != 0 ? masked | ~low : masked
    elseif op === :trunc
        # Keep the low `to_width` bits, discard the rest (LOSSY).
        return v & _low_mask(to_width)
    else
        error("_apply_cast: unsupported cast op $op (constructor should ",
              "have caught this).")
    end
end

"""
    forward(instr::CastInstruction, s::IState) -> IState

Execute `target := cast(op, operand)` in-place on `s`. Resolves `operand`
against `s.locals` (or uses the literal `Int64`) via the reused `_resolve`,
applies the width cast via `_apply_cast`, writes the result into
`s.locals[target]`, and bumps `pc`. The operand is **read, never deleted**
— the non-destructive create property (contrast `ArithmeticAssignment.
forward`, which `delete!`s its `source`).

If `target` already exists in `s.locals` (the loop / cross-iteration
case), it is **overwritten** without error — that is the intended forward
semantics; reversibility of the overwrite (and of a `:trunc`'s discarded
high bits) is the L3 checkpoint-replay layer's responsibility (see this
file's top-of-module docstring).
"""
function forward(instr::CastInstruction, s::IState)::IState
    v = _resolve(instr.operand, s)
    s.locals[instr.target] = _apply_cast(instr.op, v, instr.from_width,
                                         instr.to_width)
    s.pc += 1
    return s
end

"""
    inverse(instr::CastInstruction, s::IState, prev) -> IState

**Always raises `ErrorException`.** `CastInstruction`'s reverse is via the
L3 checkpoint-replay layer (`src/history/Replay.jl`), which never calls
per-instruction `inverse()`. Direct L1/L2 inverse is deferred: `:trunc`
loses the high bits (genuinely not locally invertible) and a loop
re-definition of any op loses the overwritten prior `target`. Reaching
this method means `unstep!` tried an L1/L2 path on a `CastInstruction`,
which should not happen with an empty `must_cache_set`. This mirrors the
`Define` / `SelectInstruction` / `CallInstruction` deferral pattern.
Rule 1: fail loud rather than silently no-op (which would falsely report a
successful reverse while the lost information went unrestored).
"""
function inverse(instr::CastInstruction, s::IState, prev)::IState
    error("CastInstruction reverse is via L3 checkpoint-replay at ",
          "M_OPCODE; direct L1/L2 inverse is deferred (ADR 0013 §D-5, ",
          "ADR 0012 R3) — :trunc is lossy and a loop re-definition loses ",
          "the overwritten prior target. Reaching this means unstep! ",
          "tried an L1/L2 path on a CastInstruction, which should not ",
          "happen with empty must_cache_set. State: pc=$(s.pc).")
end
