"""
    BinaryOperator symbol set (M2.5)

The canonical enumeration of the operator symbols that BennettVM's
instructions are allowed to carry. Three categories live here:

  1. `BINARY_OPERATORS` — integer / bitwise / shift / divrem ops that
     arrive in `Bennett.ParsedIR` as `Bennett.IRBinOp` instances.
  2. `FP_BINARY_OPERATORS` — IEEE-754 floating-point ops that arrive
     in `ParsedIR` as `Bennett.IRCall` to Bennett.jl's SoftFloat
     wrappers (`soft_fadd` / `soft_fsub` / `soft_fmul` / `soft_fdiv`),
     **not** as `IRBinOp`. The M_FP milestone is responsible for
     translating the call form into an `ArithmeticAssignment` whose
     `modop` field is one of these four symbols; the operator-table
     entry lives here so the symbols are canonicalized in one place
     ahead of that pass.
  3. `COMPARISON_OPERATORS` — LLVM integer-comparison predicates that
     arrive in `Bennett.ParsedIR` as `Bennett.IRICmp` instances and
     lower (per ADR 0012 D2) to a `Define` carrying a comparison `op`.
     They are evaluated by `_apply_binop` (returning `Int64(0)`/`(1)`)
     but are deliberately **disjoint** from the two arithmetic sets and
     are **not** in `ALL_BINARY_OPERATORS` — see the `COMPARISON_OPERATORS`
     docstring for the membership rationale.

# Why these symbols and no others

The integer set is mirrored verbatim from Bennett.jl's
`_IR_BINOP_OPS` (the construction-time guard on `IRBinOp`). Any
opcode Bennett.jl will not emit is, by definition, not a downstream
BennettVM concern — and any opcode Bennett.jl *will* emit must be
representable here, or the lowering pass at M3.x will discover the
hole the hard way. Mirroring the upstream tuple, with a regression
test on its length (M2.5 test suite), turns the dependency into a
fail-loud contract: if Bennett.jl ever adds a 14th `IRBinOp` opcode,
the count assertion goes RED and forces a conscious update here.

The FP set is the four arithmetic operations that lower to
`Bennett.jl` SoftFloat dispatch (PRD v4 §3.6). Comparison and
conversion ops (`:fcmp`, `:fptosi`, `:sitofp`, ...) are deliberately
absent: they arrive as different `IRCall` callees and land under
different VM instructions (M_FP details, not M2.5).

# Ref

  * `references/PRD-v4.md` §3.6.1 — "maximum LLVM opcode coverage" as
    the north-star for what BennettVM must eventually handle.
  * `references/PRD-v4.md` §3.6 — FP inheritance via SoftFloat
    dispatch; the call-form vs. binop-form distinction below.
  * `/home/tobias/Projects/Bennett.jl/src/ir_types.jl` lines 5-7
    (`const _IR_BINOP_OPS`) — the upstream truth table our integer
    set mirrors; the M2.5 length-regression test guards the mirror.
  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations — the 12-subclass
    taxonomy; `ArithmeticAssignment` is row 1 and is the sole
    consumer of these symbols at construction time.
"""

"""
    BINARY_OPERATORS

Integer / bitwise / shift / divrem opcode symbols that
`ArithmeticAssignment` recognises and that arrive in `ParsedIR` as
`Bennett.IRBinOp` instances. Mirrors `Bennett._IR_BINOP_OPS` (see
`/home/tobias/Projects/Bennett.jl/src/ir_types.jl` lines 5-7);
length-regression test in `test/test_operators.jl` guards the
mirror.

# Special-case callouts

  * **`:xor` is the lone injective entry.** An
    `ArithmeticAssignment` of the form `x := x ⊕ rhs` (with
    `modop=:xor`) preserves enough information to invert without a
    history-tape entry: applying the same XOR twice is identity.
    The M6.1 "L1 injective-no-log" lowering bead leans on this
    property to skip history allocation for the `:xor` case; every
    other operator in this tuple is non-injective and *does* require
    a delta record.

  * **`:udiv` / `:sdiv` / `:urem` / `:srem` lose bits.** Integer
    division and remainder are non-injective even when the divisor
    is fixed (a quotient–remainder pair determines the dividend, but
    a quotient alone does not). The M7.x history-recording bead is
    responsible for capturing the destroyed source value on every
    div/rem `ArithmeticAssignment`; M2.5 only lists the symbols, it
    does not yet implement delta-recording.

  * **`:shl` / `:lshr` / `:ashr` also lose bits.** Shifts drop the
    out-shifted bits; same M7.x delta-recording obligation as
    div/rem applies.

Order in the tuple is the LLVM-natural reading order (arithmetic →
bitwise → shifts → divrem), matched against Bennett.jl's upstream
ordering so visual diffs of the two tuples line up.

Ref: `references/PRD-v4.md` §3.6.1; Bennett.jl `ir_types.jl` lines 5-7.
"""
const BINARY_OPERATORS = (
    # Integer arithmetic
    :add, :sub, :mul,
    # Bitwise (`:xor` is the only injective entry — see docstring)
    :and, :or, :xor,
    # Shifts (non-injective; M7.x must record delta)
    :shl, :lshr, :ashr,
    # Integer division / remainder (non-injective; M7.x must record delta)
    :udiv, :sdiv, :urem, :srem,
)

"""
    FP_BINARY_OPERATORS

IEEE-754 floating-point binary-arithmetic opcode symbols that
`ArithmeticAssignment` carries on lowered FP programs.

# The IRCall-vs-IRBinOp distinction (READ THIS)

**FP ops do NOT arrive in `Bennett.ParsedIR` as `Bennett.IRBinOp`.**
They arrive as `Bennett.IRCall` whose `callee` is one of
`Bennett.soft_fadd` / `soft_fsub` / `soft_fmul` / `soft_fdiv` —
Bennett.jl's SoftFloat library wrappers (PRD v4 §3.6).

**Landing target (M_FP.2, ADR 0011 §D1):** a SoftFloat call arrives
as an `IRCall` to a `soft_f*` callee and lowers to a dedicated
`SoftCall` instruction (`src/ir/softcall_instruction.jl`) — a
non-destructive bit-pattern SSA-create executed by calling the host
`soft_f*` function. It does **NOT** lower to an `ArithmeticAssignment`
(an earlier draft of this docstring said so; that was rejected because
`ArithmeticAssignment` destroys an operand, caps arity at 2 — breaking
`soft_fma` — and cannot carry the unary conversions `soft_fpext`/
`soft_fptrunc`; see the `SoftCall` docstring). This tuple is retained
only for op *classification* (e.g. `is_binary_operator`), not as a
lowering modop.

Any M2.x code that assumes `:fadd` etc. flow through the `IRBinOp`
dispatch arm will **silently fail** on FP programs: the IRBinOp arm
will never see them, and the IRCall arm — if not taught about
SoftFloat — will mis-classify them as generic calls. This is the
single most important Phase-2 lowering distinction; it is called out
in `references/PRD-v4.md` §3.6 ("FP inheritance via SoftFloat
dispatch") and is the reason this tuple exists separately from
`BINARY_OPERATORS` rather than being concatenated into it.

Ref: `references/PRD-v4.md` §3.6 (FP inheritance via SoftFloat
     dispatch).
"""
const FP_BINARY_OPERATORS = (:fadd, :fsub, :fmul, :fdiv)

"""
    ALL_BINARY_OPERATORS

Union of `BINARY_OPERATORS` and `FP_BINARY_OPERATORS`. The single
tuple downstream type checks (M2.7 `ArithmeticAssignment`
constructor; M3.x dispatcher) iterate when they need to accept
"either an integer op or an FP op." Keeping the two categories as
separate constants AND providing the union is deliberate: code that
needs to *distinguish* integer-form (IRBinOp-sourced) from FP-form
(IRCall-sourced) reads `BINARY_OPERATORS` or `FP_BINARY_OPERATORS`
directly; code that only cares "is this a known binary op?" reads
`ALL_BINARY_OPERATORS` (or calls `is_binary_operator` below).
"""
const ALL_BINARY_OPERATORS = (BINARY_OPERATORS..., FP_BINARY_OPERATORS...)

"""
    is_binary_operator(op::Symbol) -> Bool

Whether `op` is one of the recognised `ArithmeticAssignment` modop
symbols (integer **or** FP). The `ArithmeticAssignment` constructor
(M2.7) uses this to reject typos at construction time per Rule 1
("fail fast, fail loud"): `ArithmeticAssignment(:addd, ...)` raises
on construction rather than 500 lines later when the dispatcher
falls off the elseif chain.

# Examples

```julia
julia> is_binary_operator(:add)
true

julia> is_binary_operator(:fadd)
true

julia> is_binary_operator(:addd)   # typo
false

julia> is_binary_operator(:mod)    # Julia mod, not an LLVM HW op
false
```

Ref: CLAUDE.md Rule 1 — assertions, not silent returns.
"""
is_binary_operator(op::Symbol) = op in ALL_BINARY_OPERATORS

"""
    COMPARISON_OPERATORS

LLVM integer-comparison predicate symbols that arrive in
`Bennett.ParsedIR` as `Bennett.IRICmp` instances and that
`_apply_binop` evaluates to a 0/1 `Int64` (ADR 0012 §D2). Mirrors
`Bennett._IR_ICMP_PREDS` verbatim — including order — so a visual diff
of the two tuples lines up; the length-regression test in
`test/test_operators.jl` pins `length(COMPARISON_OPERATORS) ==
length(Bennett._IR_ICMP_PREDS)`, turning the upstream dependency into a
fail-loud contract (Law 2): if Bennett.jl ever adds an 11th `IRICmp`
predicate the count assertion goes RED and forces a conscious mirror
update here.

# Signed vs. unsigned vs. equality

The ten predicates split three ways, exactly as LLVM `icmp` does:

  * **Equality** — `:eq` / `:ne` — width- and signedness-agnostic
    (`==` / `!=` on the raw `Int64`).
  * **Unsigned** — `:ult` / `:ule` / `:ugt` / `:uge` — compare the
    operands as `UInt64` (`reinterpret(UInt64, ·)`), matching the
    unsigned discipline already used by `:lshr` / `:udiv` / `:urem`
    in `_apply_binop`. A negative `Int64` reinterprets to a *large*
    `UInt64`, so e.g. `ult(-1, 0)` is **false**.
  * **Signed** — `:slt` / `:sle` / `:sgt` / `:sge` — compare the
    operands as signed `Int64` directly; `slt(-1, 0)` is **true**.

The signed/unsigned split is the load-bearing distinction and is
exercised by a discriminating test (`slt(-1,0)==1` vs `ult(-1,0)==0`).

# Why NOT in `ALL_BINARY_OPERATORS` (membership decision)

`ALL_BINARY_OPERATORS` is the union the **`ArithmeticAssignment`
constructor** validates against (`op in BINARY_OPERATORS`, M2.6) — that
instruction is a *destructive transform* (`x := y ⊕ (lhs op rhs)`) and
must continue to **reject** comparison predicates so an `IRICmp` op
never lands on the IRBinOp arm. Comparisons belong on the dedicated
non-destructive `Define` create (ADR 0012 §D1, a later bead). Keeping
`COMPARISON_OPERATORS` a separate set therefore leaves the
`ArithmeticAssignment` op-domain untouched while still letting
`_apply_binop(:slt, …)` evaluate the predicate. The shared evaluation
point is `_apply_binop`; the construction-time *domains* stay distinct.

# Ref

  * `docs/adr/0012-collatz-lowering.md` §D2 — comparison-operator spec;
    the i1→Int64 "nonzero = true" convention.
  * `/home/tobias/Projects/Bennett.jl/src/ir_types.jl` lines 8-10
    (`const _IR_ICMP_PREDS`, pin `877341e`) — the upstream truth table
    this set mirrors; the length-regression test guards the mirror.
  * `src/ir/arithmetic_assignment.jl` — `_apply_binop`, extended to
    evaluate these predicates with `reinterpret(UInt64, ·)` for the
    unsigned arm (matching the existing `:lshr` / `:udiv` discipline).
"""
const COMPARISON_OPERATORS = (
    # Equality (signedness-agnostic)
    :eq, :ne,
    # Unsigned (reinterpret(UInt64, ·) comparison)
    :ult, :ule, :ugt, :uge,
    # Signed (direct Int64 comparison)
    :slt, :sle, :sgt, :sge,
)

"""
    is_comparison_operator(op::Symbol) -> Bool

Whether `op` is one of the recognised LLVM integer-comparison
predicates (`COMPARISON_OPERATORS`). Analogous to `is_binary_operator`
but for the comparison set; the future `Define` constructor (ADR 0012
§D1) uses it together with `is_binary_operator` to accept either an
arithmetic op or a comparison predicate, while `ArithmeticAssignment`
keeps using `is_binary_operator` alone so it continues to reject
comparisons (Rule 1, fail fast).

# Examples

```julia
julia> is_comparison_operator(:slt)
true

julia> is_comparison_operator(:eq)
true

julia> is_comparison_operator(:add)   # arithmetic, not a comparison
false

julia> is_comparison_operator(:lt)    # not an LLVM icmp predicate name
false
```

Ref: `docs/adr/0012-collatz-lowering.md` §D2; CLAUDE.md Rule 1.
"""
is_comparison_operator(op::Symbol) = op in COMPARISON_OPERATORS
