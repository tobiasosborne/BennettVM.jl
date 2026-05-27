"""
    ArithmeticAssignment (M2.6)

The first concrete RSSA instruction in BennettVM's twelve-subclass
taxonomy (`docs/adr/0001-rc3-rvm-smoke.md` §Observations, row 1).
Implements the RC3 form

    x := y ⊕ (lhs op rhs)

where the modification operator `⊕` is one of `:xor` / `:add` / `:sub`,
the binary operator `op` is drawn from `BINARY_OPERATORS` (integer
opcodes only at this milestone), and `lhs` / `rhs` are RValues that may
each independently be either an SSA name (`Symbol`) or a literal
`Int64`. The instruction *destroys* `source` (`y`) and *creates*
`target` (`x`): after `forward`, `y` is no longer in `s.locals` and
`x` carries the computed value. Reverse execution swaps the two roles
and flips the modop via `dual_modop`.

# The RC3-faithful three-element modop set

`modop` is fixed to the set `{:xor, :add, :sub}` because that — and
*only* that — is what RC3's `ModificationOperator` enum admits (see
`docs/adr/0001-rc3-rvm-smoke.md` §Observations decision table row
"Modification operator invertibility": `XOR ↔ XOR, ADD ↔ SUB`). The
invertibility argument depends on each modop being self-inverse
(`:xor`) or having an explicit additive dual (`:add ↔ :sub`); admitting
any other modop (e.g. `:mul`, `:div`) without a delta-history entry
would silently break the round-trip invariant
`inverse(forward(s)) == s`. Rule 1 demands we reject such modops at
construction time, which the constructor below does explicitly.

Some earlier bead text loosely refers to "delta capture for other
modops in M7"; that wording predates the ADR's lock-in of the
three-element set and is **not** the design we ship. M7's delta
captures cover the non-injective `op` cases (`:udiv`, `:srem`, shifts,
etc.) — i.e. the *inner* binary operator, not the *outer* modop. The
modop set itself remains `{:xor, :add, :sub}` for the lifetime of the
Phase-2 IR.

# Operand kinds (Union{Symbol,Int64})

`lhs` and `rhs` may be either SSA references (`Symbol`, looked up in
`s.locals` at execution time) or literal `Int64` constants (used
verbatim). Julia's `Union` is the idiomatic representation: dispatch
on the runtime type via the `_resolve` helper, no separate `Atom` /
`Constant` wrapper class needed. This collapses two RC3 operand
subclasses (`Variable`, `Constant`) into a single field, consistent
with `src/ir/instructions.jl`'s top-of-module note that BennettVM
collapses several RC3 operand classes into fewer concretes.

# Integer-only `op` at this milestone

The constructor restricts `op ∈ BINARY_OPERATORS` (the 13-element
integer set), not `ALL_BINARY_OPERATORS`. FP arithmetic arrives via
`Bennett.IRCall` to SoftFloat wrappers (PRD v4 §3.6) and lands in a
separate M_FP bead; the M2.6 surface deliberately rejects `:fadd` /
`:fsub` / `:fmul` / `:fdiv` so an FP op accidentally appearing on the
IRBinOp arm fails loudly here rather than mis-executing as if it were
an integer op.

# pc symmetry and the unused `prev`

`forward` sets `s.pc += 1`; `inverse` sets `s.pc -= 1`. This per-step
±1 symmetry matches RC3's `RSSAVM` direction-flip dispatch (where the
`Direction` flag changes which way the PC moves through the same
visitor) and is what lets `RState`-level round-trip tests align
forward and inverse frames by `pc` alone.

`inverse` takes a `prev` argument because the dispatch signature
(set at M2.4 in `src/ir/instructions.jl`) requires it for instructions
that *do* need a history record. `ArithmeticAssignment` in Mogensen
form is structurally reversible — given `x`, the modop, and the
operands, `y` is recoverable as `dual_modop(modop)(x, op(lhs, rhs))`
— so `prev` is unused. The caller is free to pass `nothing`.

# Aliasing edge case (forbidden by use-discipline)

If `lhs` or `rhs` references `source` or `target` — e.g.
`ArithmeticAssignment(:x, :y, :xor, :y, :add, :b)` — the result is
*undefined*: forward execution would consume `y` mid-evaluation, and
the inverse would attempt to re-derive an operand that no longer
exists. Mogensen's RSSA use-discipline rules this out at the IR level
(every SSA name has exactly one defining instruction and is consumed
exactly once). This file does not detect it; M2.18's behavioural
probe is the right place for any sanity check. Until then, the
contract is "lowering passes must not generate such aliases."

# Ref

  * `references/PRD-v4.md` §3.1 — RSSA-derived instruction taxonomy.
  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations — twelve-subclass
    table (row 1 = `ArithAssign`); the modop-invertibility decision
    row that fixes `modop ∈ {:xor, :add, :sub}`.
  * RC3 source: `src/main/java/.../instances/ArithmeticAssignment.java`
    — the analogue our class mirrors. Behaviour cross-checked against
    RC3 `ArithmeticAssignment.execute()` (modop application order) and
    its inverse pass (`dual_modop` flip).
  * `src/ir/operators.jl` — `BINARY_OPERATORS` and `is_binary_operator`
    (the construction-time op guard below).
  * CLAUDE.md Rule 1 — constructor validates inputs; bad modop / bad
    op fail loud at construction time, not 500 lines later.
"""
struct ArithmeticAssignment <: Instruction
    target::Symbol
    source::Symbol
    modop::Symbol      # :xor | :add | :sub
    lhs::Union{Symbol,Int64}
    op::Symbol         # one of BINARY_OPERATORS (integer set)
    rhs::Union{Symbol,Int64}

    function ArithmeticAssignment(target::Symbol, source::Symbol,
                                  modop::Symbol,
                                  lhs::Union{Symbol,Int64},
                                  op::Symbol,
                                  rhs::Union{Symbol,Int64})
        modop === :xor || modop === :add || modop === :sub ||
            error("invalid modop $(modop); must be :xor, :add, or :sub ",
                  "(RC3 ModificationOperator set)")
        op in BINARY_OPERATORS ||
            error("invalid op $(op); not in BINARY_OPERATORS ",
                  "(integer-set only at M2.6; FP ops route via M_FP)")
        return new(target, source, modop, lhs, op, rhs)
    end
end

"""
    dual_modop(m::Symbol) -> Symbol

The inverse of a modification operator. Self-inverse for `:xor`; flips
`:add ↔ :sub`. Used by `inverse(::ArithmeticAssignment, ...)` to
reconstruct the destroyed `source` value from the surviving `target`
value: if `forward` applied `y ⊕ e` to produce `x`, then `inverse`
applies `x (dual ⊕) e` to recover `y`.

Ref: `docs/adr/0001-rc3-rvm-smoke.md` §Observations decision table row
"Modification operator invertibility": XOR ↔ XOR, ADD ↔ SUB.
"""
function dual_modop(m::Symbol)
    m === :xor ? :xor :
    m === :add ? :sub :
    m === :sub ? :add :
    error("dual_modop: invalid modop $m")
end

# --- internal helpers ------------------------------------------------
#
# These are small, file-local, and exist only to keep `forward` /
# `inverse` readable. They are not exported; downstream code routes
# through `forward` / `inverse` exclusively.

# Resolve an RValue against the current locals. `Symbol` => lookup;
# `Int64` => literal.
_resolve(x::Symbol, s::IState) = s.locals[x]
_resolve(x::Int64,  ::IState)  = x

# Apply a binary operator from `BINARY_OPERATORS` to two `Int64`
# values. Julia's native Int64 arithmetic gives wraparound on overflow,
# which is what RSSA semantics want (wrap is reversible; trapping is
# not). The dispatcher is a flat `if`-chain rather than a Dict lookup
# both for speed and so Rule 1 catches an unknown op at the final
# `error` clause — even though the constructor has already validated.
function _apply_binop(op::Symbol, a::Int64, b::Int64)::Int64
    op === :add  ? a + b :
    op === :sub  ? a - b :
    op === :mul  ? a * b :
    op === :and  ? a & b :
    op === :or   ? a | b :
    op === :xor  ? a ⊻ b :
    op === :shl  ? a << b :
    op === :lshr ? reinterpret(Int64, reinterpret(UInt64, a) >> b) :
    op === :ashr ? a >> b :
    op === :udiv ? reinterpret(Int64, div(reinterpret(UInt64, a),
                                          reinterpret(UInt64, b))) :
    op === :sdiv ? div(a, b) :
    op === :urem ? reinterpret(Int64, rem(reinterpret(UInt64, a),
                                          reinterpret(UInt64, b))) :
    op === :srem ? rem(a, b) :
    error("_apply_binop: unsupported op $op (constructor should have caught this)")
end

# Apply a modop in the forward direction: `y ⊕ e`.
function _apply_modop(m::Symbol, y::Int64, e::Int64)::Int64
    m === :xor ? y ⊻ e :
    m === :add ? y + e :
    m === :sub ? y - e :
    error("_apply_modop: unsupported modop $m (constructor should have caught this)")
end

"""
    forward(instr::ArithmeticAssignment, s::IState) -> IState

Execute `x := y ⊕ (lhs op rhs)` in-place on `s`. Reads `s.locals` for
`source` and (if symbolic) `lhs` / `rhs`; deletes `source`; writes
`target`; bumps `pc`.
"""
function forward(instr::ArithmeticAssignment, s::IState)::IState
    lv = _resolve(instr.lhs, s)
    rv = _resolve(instr.rhs, s)
    e  = _apply_binop(instr.op, lv, rv)
    yval = s.locals[instr.source]
    xval = _apply_modop(instr.modop, yval, e)
    delete!(s.locals, instr.source)
    s.locals[instr.target] = xval
    s.pc += 1
    return s
end

"""
    inverse(instr::ArithmeticAssignment, s::IState, prev) -> IState

Undo a previous `forward` on `instr`. The `prev` argument is part of
the dispatch signature (M2.4 convention) but unused: Mogensen-form
arithmetic is structurally reversible — `(lhs op rhs)` is recomputable
from the surviving locals and `dual_modop(modop)` recovers the
destroyed `source` value from the surviving `target` value.

Inverts the role of `source` and `target`: reads `s.locals[target]`,
deletes `target`, writes `source`; decrements `pc`.
"""
function inverse(instr::ArithmeticAssignment, s::IState, prev)::IState
    lv = _resolve(instr.lhs, s)
    rv = _resolve(instr.rhs, s)
    e  = _apply_binop(instr.op, lv, rv)
    xval = s.locals[instr.target]
    yval = _apply_modop(dual_modop(instr.modop), xval, e)
    delete!(s.locals, instr.target)
    s.locals[instr.source] = yval
    s.pc -= 1
    return s
end

"""
    make_delta(instr::ArithmeticAssignment, s_pre::IState, step::Integer)
        -> DeltaEntry{ArithmeticAssignment}

L2 delta-entry constructor for `ArithmeticAssignment` (M7.3,
bead `bennettvm-vk8`). ADR 0002 §DeltaEntry payload schema finding:
the payload is an **empty `NamedTuple`** for all three modops in the
M2.6-locked set (`{:xor, :add, :sub}`).

# Why empty (verified at `src/ir/arithmetic_assignment.jl:220-230`)

`inverse(::ArithmeticAssignment, s, prev)` declares `prev::Any`
(untyped) and is empirically unused: the inverse recomputes
`(lhs op rhs)` from the surviving locals (`_resolve` reads the
operand symbols out of `s.locals` at the post-forward state, and the
operands are unchanged by `forward` per the read/write table in
ADR 0002 §Phase-2 RSSA dataflow row 1) and reconstructs the
destroyed `source` value via `dual_modop(modop)` applied to the
surviving `target` value. **No information from before `forward`
needs to be captured** — the inverse is structural.

The `s_pre` parameter is part of the dispatch signature for
symmetry with future `make_delta` methods that DO need pre-state
(e.g., a hypothetical `:mul`-by-constant modop, ADR 0002 §Open
Questions item 5). It is unused here.

# M6.1 / M7.6 interaction

Under M6.1's value-level trait (`src/history/Injective.jl`),
`ArithmeticAssignment` with `modop === :xor` is classified
injective and never reaches `make_delta` — M7.6's push gate skips
both L2 and L3 for it. `:add` and `:sub` are classified
non-injective by M6.1 (conservative) and DO reach this method,
but the delta they generate carries no information beyond the
instruction reference and the step index.

The open follow-up bead `bennettvm-ack` would promote `:add` /
`:sub` to injective once the broader trait change lands; this
method then becomes unreachable, which is fine. The method
remains defined so the M7.6 push site can call it unconditionally
on non-injective `ArithmeticAssignment`s without depending on the
M6.1 broadening landing first.

# Ref

  * `docs/adr/0002-enzyme-min-cut-mapping.md` §DeltaEntry payload
    schema — locks the empty-payload finding for this T.
  * `docs/adr/0002-enzyme-min-cut-mapping.md` §Design Decision 3 —
    `make_delta` co-located with `forward`/`inverse` per Rule 11.
  * `src/ir/arithmetic_assignment.jl:220-230` (this file, the
    `inverse` method just above) — the structural-inverse code
    that justifies the empty payload.
  * `src/history/Injective.jl` — the L1 gate that already filters
    `modop === :xor` to L1-skip.
  * Bead `bennettvm-vk8` (M7.3) — this method's bead.
  * Bead `bennettvm-ack` — open follow-up that would broaden M6.1
    to all three modops, collapsing this method's L2 pushes into
    L1-skips.
"""
function make_delta(instr::ArithmeticAssignment, s_pre::IState,
                    step::Integer)::DeltaEntry
    DeltaEntry(instr, NamedTuple(), step)
end
