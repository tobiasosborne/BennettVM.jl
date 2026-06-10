"""
    ParsedIR ingest — operand lowering helpers (M_UNBOUNDED.1, ADR 0012)

Split out of `src/ir/ingest.jl` per bead `bennettvm-u110` / Rule 10 (the
~200-LOC ceiling): a PURE MOVE of the operand-lowering layer — the three
`_lower_*operand` helpers that translate a Bennett.jl `IROperand` into a
BennettVM operand (`Symbol | Int64`). Included into the same `BennettVM`
module immediately before the body / call / driver halves, which all
consume these helpers. Controlling decisions live in the original
`ingest.jl` docstring and `docs/adr/0012-collatz-lowering.md` §D1–D5
(operand lowering), with `_lower_ptr_operand` grounded in ADR 0018 §E.
"""

# ---------------------------------------------------------------------
# Operand lowering: Bennett IROperand → BennettVM operand (Symbol|Int64).
# ---------------------------------------------------------------------

"""
    _lower_operand(op::Bennett.IROperand) -> Union{Symbol,Int64}

`SSAOperand(name)` → its `name::Symbol`; `ConstOperand(value)` → the
literal coerced to `Int64`. Any other `IROperand` subtype (the extractor
sentinels) is rejected loudly (Rule 1) — none arise in the collatz slice,
and a sentinel reaching here means an unhandled IR shape, not a value.
"""
function _lower_operand(op::Bennett.IROperand)::Union{Symbol,Int64}
    if op isa Bennett.SSAOperand
        return op.name
    elseif op isa Bennett.ConstOperand
        return Int64(op.value)
    else
        error("lower_vm: unsupported IROperand subtype ", typeof(op),
              " — only SSAOperand / ConstOperand are handled in the ",
              "M_UNBOUNDED slice (ADR 0012). A sentinel operand here ",
              "indicates an unhandled IR shape (Rule 1).")
    end
end

"""
    _lower_bool_operand(op, width) -> Union{Symbol,Int64}

Lower a binop operand, masking an i1 (`width == 1`) `ConstOperand` to its low
bit. LLVM renders the i1 literal `true` as the sign-extended `-1`; the unmasked
Int64 VM needs the 1-bit value (`-1 → 1`) so the boolean-NOT idiom `%c ⊻ true`
computes the logical NOT for `%c ∈ {0,1}`. For `width > 1`, or for an SSA
operand, this is identical to `_lower_operand`. See `_lower_body_inst`'s i1 note
(full-width masking — bead `bennettvm-bgc` — now threads `inst.width` into the
`Define`; for `width == 1` the in-op `& mask` collapses to `& 1`, agreeing with
this const-operand mask).
"""
function _lower_bool_operand(op::Bennett.IROperand, width::Int)::Union{Symbol,Int64}
    lowered = _lower_operand(op)
    (width == 1 && lowered isa Int64) ? (lowered & Int64(1)) : lowered
end

# Lower an operand that MUST be an SSA pointer (a `free` / `realloc` / `memcpy`
# pointer arg — an `Int64` cell address living in `locals`). A constant
# pointer is malformed under the segment model (Rule 1, ADR 0018 §E).
function _lower_ptr_operand(op::Bennett.IROperand, callee::Symbol, dest)::Symbol
    op isa Bennett.SSAOperand ||
        error("lower_vm: heap intrinsic :", callee, " (dest=", dest, ") has a ",
              "non-SSA pointer operand ", typeof(op), " — a pointer is an ",
              "Int64 cell address materialised by malloc/alloca and named by an ",
              "SSAOperand (ADR 0018 §E; Rule 1 fail-loud).")
    return op.name
end
