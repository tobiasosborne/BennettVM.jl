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
`target` (`x`): after `forward`, `y` is no longer in `active_locals(s)` and
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
`active_locals(s)` at execution time) or literal `Int64` constants (used
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
#
# The optional third argument `ctx` is the `Instruction` performing the read,
# used ONLY to enrich the Rule-1 failure message when the name is unbound
# (`bennettvm-35yn`; `src/ir/unbound_ssa.jl`). It is threaded from the two
# generic arithmetic carriers — `Define` and `ArithmeticAssignment` — which is
# where operand reads overwhelmingly land, including every `bennettvm-rnhv`
# failure. Other call sites (revmap / select / array_index / memory_floor)
# pass nothing and get symbol + pc + frame stack + bound-name sample; the pc
# in that message locates the instruction exactly. Threading `ctx` through all
# ~25 remaining sites is mechanical and deliberately deferred rather than
# bundled into a correctness fix.
#
# `get(..., nothing)` keeps this to ONE dict probe: the happy path returns a
# `Union{Nothing,Int64}` that Julia union-splits, and all message building
# lives behind the `@noinline _unbound_ssa_error` call.
function _resolve(x::Symbol, s::IState, ctx = nothing)::Int64
    v = get(active_locals(s), x, nothing)
    v === nothing && _unbound_ssa_error(x, s, ctx)
    return v
end
_resolve(x::Int64, ::IState, ctx = nothing) = x

# Apply a binary operator to two `Int64` values at a given bit `width`,
# returning an `Int64`. Julia's native Int64 arithmetic gives wraparound
# on overflow, which is what RSSA semantics want (wrap is reversible;
# trapping is not). The dispatcher is a flat `if`-chain rather than a Dict
# lookup both for speed and so Rule 1 catches an unknown op at the final
# `error` clause — even though the relevant constructor has already
# validated.
#
# # Width-aware operation (ADR 0012 R1, bead `bennettvm-bgc`)
#
# `IState.locals` are `Int64`, but a source value of LLVM type i`w` lives
# in the low `w` bits. To make the VM agree with a native i`w` oracle even
# when an operation OVERFLOWS its width (e.g. `Int8(3) * Int8(50)` = 150,
# which wraps to `Int8(-106)`), each op must compute in i`w` semantics, not
# full Int64. The model (this is the load-bearing correctness invariant):
#
#   **each op EXTRACTS the low-`w` bits of each operand and RE-EXTENDS per
#   the operation's OWN signedness, then MASKS the result to low `w` bits.**
#
# Because every op re-extracts its operands, the stored representation's
# high bits never matter — so NO change is needed to `IState`, the casts,
# the select, or input-binding; the width discipline is self-contained
# here. `w == 64` is a NO-OP: `mask = -1` (all ones), `sext` at 64 is the
# identity, so every existing full-width call (`ArithmeticAssignment`'s
# default-64 calls, hand-built width-64 `Define`s) is byte-identical.
#
# Per-op classification (let `mask = _low_mask(w)`; reuse `_low_mask` /
# `_apply_cast(:sext, ·, w, 64)` from `cast_instruction.jl` — Law 2):
#
#   * **Sign-agnostic** (`:add :sub :mul :and :or :xor :shl`): two's-
#     complement low bits are signedness-independent for these — mask both
#     operands, do the op, mask the result.
#   * **Unsigned-interpreting** (`:udiv :urem :lshr`): zero-extend each
#     operand = mask it (nonnegative), do the UNSIGNED op (via
#     `reinterpret(UInt64, ·)`; the masked operands are nonnegative so the
#     UInt64 value equals the i`w` unsigned value), mask the result. This
#     replaces the old FULL-64-bit reinterpret, which used the high bits
#     and was WRONG at `w < 64`.
#   * **Signed-interpreting** (`:sdiv :srem :ashr`): SIGN-extend each
#     operand from `w` bits to a full Int64 (`_apply_cast(:sext, ·, w, 64)`)
#     so a negative i`w` value carries its true sign into the signed op, do
#     the signed op, mask the result.
#
# # Comparison predicates (ADR 0012 §D2) — `COMPARISON_OPERATORS`
#
# Each returns `Int64(1)` for true / `Int64(0)` for false (the interpreter's
# i1→Int64 "nonzero = true" convention). The result is an i1, so it is NOT
# masked to `width` — it is always 0/1. The OPERANDS are extended per the
# predicate's signedness BEFORE comparing (`width` is the operand width;
# IRICmp's result is always i1):
#
#   * **Equality** (`:eq` / `:ne`) — signedness-agnostic; compare the
#     `& mask` low bits.
#   * **Unsigned** (`:ult` / `:ule` / `:ugt` / `:uge`) — zero-extend
#     (`& mask`) each operand, then compare as `UInt64`. A masked operand is
#     nonnegative, so the UInt64 value IS the i`w` unsigned value; e.g.
#     `ult(-1, 0)` at w=8 compares `255 < 0` → false.
#   * **Signed** (`:slt` / `:sle` / `:sgt` / `:sge`) — SIGN-extend each
#     operand (`_apply_cast(:sext, ·, w, 64)`), then compare as signed
#     Int64; e.g. `slt(-1, 0)` at w=8 compares `-1 < 0` → true.
#
# Ref: docs/adr/0012-collatz-lowering.md §D2 (comparison operators), R1
#        (the per-`width` masking this implements; bead `bennettvm-bgc`);
#      src/ir/operators.jl (COMPARISON_OPERATORS — signed/unsigned split);
#      src/ir/cast_instruction.jl (`_low_mask`, `_apply_cast(:sext, …)`,
#        reused here — Law 2).
function _apply_binop(op::Symbol, a::Int64, b::Int64, width::Int=64)::Int64
    mask = _low_mask(width)
    # Low-`w`-bit operands for the sign-agnostic, unsigned, and equality
    # arms. The signed arms (`:sdiv`/`:srem`/`:ashr`/`:s{lt,le,gt,ge}`) do NOT
    # read `am`/`bm` — they call `_apply_cast(:sext, a, width, 64)` on the RAW
    # operand, which masks to the low `w` bits internally before sign-
    # extending, so raw `a`/`b` and `am`/`bm` carry identical low bits there.
    # LLVM-UB note (well-formed programs never reach these; behavior is
    # deterministic, not trapping): `:sdiv`/`:srem` of i`w`-typemin by -1 and a
    # shift amount >= `w` are LLVM poison; this kernel returns a masked
    # in-range value / Julia's shift-clamp result rather than trapping.
    am = a & mask
    bm = b & mask
    op === :add  ? (am + bm) & mask :
    op === :sub  ? (am - bm) & mask :
    op === :mul  ? (am * bm) & mask :
    op === :and  ? (am & bm) & mask :
    op === :or   ? (am | bm) & mask :
    op === :xor  ? (am ⊻ bm) & mask :
    op === :shl  ? (am << bm) & mask :
    # Unsigned-interpreting: zero-extended (`& mask`) operands, unsigned op,
    # mask the result. The masked operands are nonnegative, so the UInt64
    # bit-pattern equals the i`w` unsigned value.
    op === :lshr ? reinterpret(Int64, reinterpret(UInt64, am) >> bm) & mask :
    op === :udiv ? reinterpret(Int64, div(reinterpret(UInt64, am),
                                          reinterpret(UInt64, bm))) & mask :
    op === :urem ? reinterpret(Int64, rem(reinterpret(UInt64, am),
                                          reinterpret(UInt64, bm))) & mask :
    # Signed-interpreting: sign-extend operands from `w` bits, signed op,
    # mask the result.
    op === :sdiv ? div(_apply_cast(:sext, a, width, 64),
                       _apply_cast(:sext, b, width, 64)) & mask :
    op === :srem ? rem(_apply_cast(:sext, a, width, 64),
                       _apply_cast(:sext, b, width, 64)) & mask :
    op === :ashr ? (_apply_cast(:sext, a, width, 64) >> bm) & mask :
    # Comparison predicates (ADR 0012 §D2) — Int64(1)/Int64(0), NOT masked
    # to `width` (an i1 result is always 0/1). Operands extended per the
    # predicate's signedness before comparing (`width` is the operand width).
    op === :eq   ? Int64(am == bm) :
    op === :ne   ? Int64(am != bm) :
    op === :ult  ? Int64(reinterpret(UInt64, am) <  reinterpret(UInt64, bm)) :
    op === :ule  ? Int64(reinterpret(UInt64, am) <= reinterpret(UInt64, bm)) :
    op === :ugt  ? Int64(reinterpret(UInt64, am) >  reinterpret(UInt64, bm)) :
    op === :uge  ? Int64(reinterpret(UInt64, am) >= reinterpret(UInt64, bm)) :
    op === :slt  ? Int64(_apply_cast(:sext, a, width, 64) <
                         _apply_cast(:sext, b, width, 64)) :
    op === :sle  ? Int64(_apply_cast(:sext, a, width, 64) <=
                         _apply_cast(:sext, b, width, 64)) :
    op === :sgt  ? Int64(_apply_cast(:sext, a, width, 64) >
                         _apply_cast(:sext, b, width, 64)) :
    op === :sge  ? Int64(_apply_cast(:sext, a, width, 64) >=
                         _apply_cast(:sext, b, width, 64)) :
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

Execute `x := y ⊕ (lhs op rhs)` in-place on `s`. Reads `active_locals(s)` for
`source` and (if symbolic) `lhs` / `rhs`; deletes `source`; writes
`target`; bumps `pc`.
"""
function forward(instr::ArithmeticAssignment, s::IState)::IState
    # `instr` threaded for the Rule-1 unbound-operand message only
    # (`bennettvm-35yn`; `src/ir/unbound_ssa.jl`).
    lv = _resolve(instr.lhs, s, instr)
    rv = _resolve(instr.rhs, s, instr)
    e  = _apply_binop(instr.op, lv, rv)
    yval = _resolve(instr.source, s, instr)
    xval = _apply_modop(instr.modop, yval, e)
    delete!(active_locals(s), instr.source)
    active_locals(s)[instr.target] = xval
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

Inverts the role of `source` and `target`: reads `active_locals(s)[target]`,
deletes `target`, writes `source`; decrements `pc`.
"""
function inverse(instr::ArithmeticAssignment, s::IState, prev)::IState
    lv = _resolve(instr.lhs, s, instr)
    rv = _resolve(instr.rhs, s, instr)
    e  = _apply_binop(instr.op, lv, rv)
    xval = _resolve(instr.target, s, instr)
    yval = _apply_modop(dual_modop(instr.modop), xval, e)
    delete!(active_locals(s), instr.target)
    active_locals(s)[instr.source] = yval
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
operand symbols out of `active_locals(s)` at the post-forward state, and the
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

"""
    inverse(instr::ArithmeticAssignment, s::IState, payload::NamedTuple) -> IState

M7.4 NamedTuple specialisation per ADR 0002 §Design Decision 4
(bd `bennettvm-bk5`). The empty-payload finding from ADR 0002
§DeltaEntry payload schema (row 1) means the NamedTuple here is
expected to be `NamedTuple()` — the inverse needs nothing beyond
current state for any of the M2.6-locked modops
(`{:xor, :add, :sub}`). The payload is consumed only to satisfy the
M7.4 dispatch contract.

# Why both this method and `inverse(::ArithmeticAssignment, s, prev)`
# coexist

ADR 0002 §Design Decision 4 (verified at all 12 sites in the M7.1
review) — every existing `inverse(::T, s, prev)` method declares
`prev::Any`, so the M4 / M6.3 / per-step-inverse call sites that
pass `nothing` or another `Any`-typed argument continue to dispatch
to the existing method under the `::Any` slot. M7.4's
NamedTuple specialisation is strictly additive: a call site that
passes a `payload::NamedTuple` (the M7.4 fast-path in
`src/history/Replay.jl`) dispatches here, NOT to the existing
method. The two methods coexist for *contract symmetry* — the
prev::Any method documents the original M2.6 inverse semantics; the
NamedTuple method documents the M7.4 dispatch shape.

# Delegation

The body delegates to the existing `inverse(instr, s, nothing)`
method, since the empty payload carries no extra information for
this `T`. A future `bennettvm-ack` broadening that promotes `:add` /
`:sub` to injective (M6.1) makes this method *unreachable* (the M7.6
push site would skip the delta push for those modops); both
NamedTuple and prev::Any methods remain defined for contract
symmetry. The `:xor` modop is already M6.1-injective per the
value-level discrimination at `src/history/Injective.jl`, so this
method is only reached for `:add` and `:sub` at this milestone.

# Ref

  * `docs/adr/0002-enzyme-min-cut-mapping.md` §Design Decision 4 —
    additive `inverse` signature; verified-at-12-sites cross-check.
  * `docs/adr/0002-enzyme-min-cut-mapping.md` §DeltaEntry payload
    schema row 1 — empty-payload finding for `ArithmeticAssignment`.
  * `src/ir/arithmetic_assignment.jl` (this file, the
    `inverse(instr, s, prev)` method above) — the existing
    `prev::Any` method this delegates to.
  * `src/history/Replay.jl` (M7.4) — the unique current call site,
    via the L2 fast-path.
  * Bead `bennettvm-bk5` (M7.4) — this method's bead.
  * Bead `bennettvm-ack` — open follow-up that would make this
    method unreachable for `ArithmeticAssignment`.
"""
function inverse(instr::ArithmeticAssignment, s::IState,
                 payload::NamedTuple)::IState
    inverse(instr, s, nothing)
end
