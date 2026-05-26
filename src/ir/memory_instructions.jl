"""
    MemoryAssignment (M2.11)

The third concrete RSSA instruction in BennettVM's twelve-subclass
taxonomy (`docs/adr/0001-rc3-rvm-smoke.md` §Observations, row 3:
RC3 `MemoryAssignment` / candidate name `MemAssign`). Implements the
RC3 in-place memory-update form

    M[addr] ⊕= (lhs op rhs)

where `addr` is an address — either a `Symbol` looked up in `s.locals`
or a literal `Int64` — and `M[addr]` is read from / written to
`s.memory` (the `Int64 → Int64` sparse heap added in this same
milestone, see `src/ir/IState.jl`). The modification operator `⊕` is
one of `{:xor, :add, :sub}` (RC3 `ModificationOperator` set, locked
in ADR 0001) and the binary operator `op` is drawn from
`BINARY_OPERATORS` (the integer set; FP routes through M_FP).

# What makes this different from `ArithmeticAssignment`

`ArithmeticAssignment` (M2.6) consumes one SSA name (`source`) and
produces another (`target`); its reversibility is structural — given
`x`, the operator, and the operands, `y` is recoverable by
`dual_modop(modop)`. `MemoryAssignment` is structurally analogous —
the old memory cell content is recoverable by the same dual-modop
trick — but **there is no SSA lifecycle on the address**. `addr` is
neither created nor destroyed: it names a memory location, and the
location persists across the instruction. This is the cleanest
expression of why RC3 (and Mogensen RSSA, and Janus before either of
them) treat memory operations as a separate instruction class rather
than reusing the arithmetic form: the *target* of the modop is not
an SSA variable.

# Zero-init convention (the load-bearing rule)

Reading from an address that has never been written returns
`Int64(0)`. The implementation uses `get(s.memory, a, Int64(0))` for
this; the inverse, after applying `dual_modop`, **deletes the key
from `s.memory` if the resulting value is `0`**. This second half is
the load-bearing convention:

  * If `forward` was the first write to `addr`, then `s.memory`
    started without the key. The forward path inserts the key (with
    whatever value the modop computed). When `inverse` runs, it
    computes the dual-modop value and, if it happens to be `0`, it
    deletes the key so `s.memory` returns to its pre-`forward`
    state — *including the absence of the key*, not merely
    `memory[addr] == 0`.
  * If `forward` was a subsequent write to an already-present
    `addr`, then both `forward` and `inverse` leave the key
    present; the delete branch never fires.

Without the delete-on-zero rule, the round-trip invariant
`inverse(forward(s)) == s` would fail for first-time writes: the
post-inverse state would contain `memory[addr] = 0` where the
pre-forward state contained no such key, and `==` (content-comparing
on Dicts) treats the two as unequal. The zero-init equivalence —
"absent key" ≡ "key with value 0" — is the Phase-2 baseline
convention; a richer memory model (Bennett.jl `MemSSA`,
persistent-tree heap) may tighten or replace it. Documented here, in
the `inverse` docstring below, and in the M2.11 testset.

# Operand kinds (Union{Symbol,Int64})

All three operand fields (`addr`, `lhs`, `rhs`) admit either an SSA
reference (`Symbol`) or a literal `Int64` constant. The `_resolve`
helper defined in `src/ir/arithmetic_assignment.jl` handles both —
the same operand-evaluation primitive used by `ArithmeticAssignment`.
Reusing `_resolve` here is the Law-2-compliant choice: do not
reinvent operand evaluation per instruction.

# pc symmetry and the unused `prev`

`forward` sets `s.pc += 1`; `inverse` sets `s.pc -= 1`. Same
per-step ±1 symmetry as `ArithmeticAssignment`. The `prev` argument
is part of the dispatch signature (M2.4) but unused here —
`MemoryAssignment` in Mogensen form is structurally reversible, so
no history record is needed and the caller may pass `nothing`. If a
future memory-access pattern requires a delta record (e.g. for the
non-injective `op` cases — `:udiv`, `:srem`, shifts), M7.x will add
it via the same delta-history mechanism as `ArithmeticAssignment`,
not by changing this signature.

# Aliasing edge case (forbidden by use-discipline)

If `lhs` or `rhs` is a `Symbol` referencing a local that the
*address operand* happens to alias indirectly (e.g. via a prior
`MemoryExchange` writing into a local that's now read as `addr`),
the SSA use-discipline rules apply at the IR level: lowering passes
do not generate such aliases. This file does not detect them; the
behavioural probe at M2.18 is the right place for any sanity check.

# Ref

  * `references/PRD-v4.md` §3.1 — RSSA instruction taxonomy (row 3).
  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations — twelve-subclass
    table row 3 (`MemAssign`); modop-invertibility decision row that
    fixes `modop ∈ {:xor, :add, :sub}`.
  * RC3 source: `src/main/java/.../instances/MemoryAssignment.java`
    — the analogue this class mirrors.
  * `src/ir/arithmetic_assignment.jl` — supplies `_resolve`,
    `_apply_binop`, `_apply_modop`, `dual_modop` (all module-level
    in `BennettVM`; we reuse them rather than re-defining, per
    Law 2).
  * `src/ir/IState.jl` — the `memory::Dict{Int64,Int64}` field
    paragraph; documents the zero-init convention from the IState
    side. Both halves of the contract must agree.
  * CLAUDE.md Rule 1 — constructor validates inputs; bad modop / bad
    op fail loud at construction time.
"""
struct MemoryAssignment <: Instruction
    addr::Union{Symbol,Int64}        # address — SSA name or literal
    modop::Symbol                    # :xor | :add | :sub
    lhs::Union{Symbol,Int64}         # value operand 1
    op::Symbol                       # one of BINARY_OPERATORS
    rhs::Union{Symbol,Int64}         # value operand 2

    function MemoryAssignment(addr::Union{Symbol,Int64},
                              modop::Symbol,
                              lhs::Union{Symbol,Int64},
                              op::Symbol,
                              rhs::Union{Symbol,Int64})
        modop === :xor || modop === :add || modop === :sub ||
            error("invalid modop $(modop); must be :xor, :add, or :sub ",
                  "(RC3 ModificationOperator set)")
        is_binary_operator(op) ||
            error("invalid op $(op); not in ALL_BINARY_OPERATORS ",
                  "(constructor-time guard; M_FP routes FP ops separately)")
        # Reject FP ops at M2.11: this instruction's IRBinOp arm carries
        # only integer ops (same restriction as ArithmeticAssignment).
        op in BINARY_OPERATORS ||
            error("invalid op $(op); not in BINARY_OPERATORS ",
                  "(integer-set only at M2.11; FP ops route via M_FP)")
        return new(addr, modop, lhs, op, rhs)
    end
end

"""
    forward(instr::MemoryAssignment, s::IState) -> IState

Execute `M[addr] ⊕= (lhs op rhs)` in-place on `s`. Reads `s.locals`
for any `Symbol`-typed operand; reads `s.memory[addr]` (defaulting to
`Int64(0)` if absent — the zero-init convention) for the old cell
value; writes the new cell value back. Bumps `pc`.
"""
function forward(instr::MemoryAssignment, s::IState)::IState
    a   = _resolve(instr.addr, s)
    lv  = _resolve(instr.lhs,  s)
    rv  = _resolve(instr.rhs,  s)
    e   = _apply_binop(instr.op, lv, rv)
    old = get(s.memory, a, Int64(0))     # zero-init: absent key reads as 0.
    s.memory[a] = _apply_modop(instr.modop, old, e)
    s.pc += 1
    return s
end

"""
    inverse(instr::MemoryAssignment, s::IState, prev) -> IState

Undo a previous `forward` on `instr`. The `prev` argument is part of
the dispatch signature (M2.4) but unused: `MemoryAssignment` is
structurally reversible — `(lhs op rhs)` recomputes from the
surviving locals and `dual_modop(modop)` recovers the old cell value
from the surviving cell value.

# The delete-on-zero rule (load-bearing)

After applying `dual_modop`, if the resulting cell value is `Int64(0)`,
**delete the key from `s.memory`**. This restores the zero-init
equivalence — an address that was never written before `forward`
should not appear in `s.memory` after `inverse`. Without this, the
round-trip invariant `inverse(forward(s)) == s` would fail for the
first-write case (post-inverse `Dict` would carry an `addr → 0`
entry that the pre-forward `Dict` lacked). Documented in the file's
top-of-module docstring and in `src/ir/IState.jl`'s `memory` field
paragraph; tested in `test/test_memory_instructions.jl` via the
"zero-init address" testset.

Decrements `pc`.
"""
function inverse(instr::MemoryAssignment, s::IState, prev)::IState
    a   = _resolve(instr.addr, s)
    lv  = _resolve(instr.lhs,  s)
    rv  = _resolve(instr.rhs,  s)
    e   = _apply_binop(instr.op, lv, rv)
    cur = s.memory[a]                    # must exist post-forward; KeyError
                                         # surfaces a Rule-1 bug if it doesn't.
    new_val = _apply_modop(dual_modop(instr.modop), cur, e)
    if new_val == Int64(0)
        # Delete-on-zero: restore the zero-init equivalence so a
        # first-time-write `forward` is a true bijection on `s.memory`.
        delete!(s.memory, a)
    else
        s.memory[a] = new_val
    end
    s.pc -= 1
    return s
end
