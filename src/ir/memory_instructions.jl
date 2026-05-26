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

"""
    MemoryInterchange (M2.12)

The fourth concrete RSSA instruction in BennettVM's twelve-subclass
taxonomy (`docs/adr/0001-rc3-rvm-smoke.md` §Observations, row 4:
RC3 `MemoryInterchangeInstruction` / Pendulum-style exchange).
Implements the RC3 / Mogensen-RSSA register-memory exchange form

    x := M[y] := z

where `target` (`x`) is a *created* SSA name that receives the OLD
memory cell at address `y`, while `source` (`z`) is a *destroyed* SSA
name whose value moves into `M[y]`. The address operand `y` is either
an SSA name (read from `s.locals`) or a literal `Int64`. The exchange
is **atomic**: the read of the old memory value and the write of
`z`'s value happen as a single bijective step on the (register, cell)
pair.

# Why this is the canonical reversible load (Pendulum lesson)

A classical load `x := M[y]` is not reversible — it loses the
pre-load value of `x`. Vieri's Pendulum (Vieri 1995/1999) documents
this as a fatal design mistake; every reversible ISA since then —
PISA, BobISA, RSSA, RC3 — encodes load as an *exchange* that
simultaneously stores the destination register's old value back into
memory. In an SSA-shaped IR the "old value of x" doesn't exist
(every register name has exactly one defining instruction), so the
exchange takes the form above: `z`'s value (a fresh SSA name being
destroyed) is what gets written to memory, and `x` (a fresh SSA name
being created) receives what was in memory. The pair (register
slot, cell slot) is permuted bijectively; no information is lost.

This is the M2.12 instruction whose existence is gated by CLAUDE.md
"Hallucination-risk callouts" / "PISA memory access is always an
exchange". A non-exchange load is *forbidden* at this IR layer; if a
future lowering pass appears to need one for performance, the right
move is to read the callout again, not to add a second memory
instruction with weaker semantics.

# Self-inverse via target↔source swap

The inverse of `x := M[y] := z` is `z := M[y] := x` — exchange
`target` and `source` and run the same exchange semantics. This
matches RC3's `MemoryInterchangeInstruction.reverse()` which builds
a new instance with `left` and `right` swapped (see RC3 source at
`references/implementations/RC3/compiler/src/main/java/rc3/rssa/instances/MemoryInterchangeInstruction.java`
line 41-44). The instruction is therefore in the *injective* class
(M6.1) just like `SwapInstruction` — no history record needed.

# Zero-init convention (symmetric with M2.11)

Reading from an address that has never been written returns
`Int64(0)`. The implementation uses `get(s.memory, a, Int64(0))` for
the forward read; the inverse, after computing the value to restore,
**deletes the key from `s.memory` if that value is `0`**. This is
the same load-bearing rule as `MemoryAssignment` (see this file's
M2.11 top-of-module docstring and `src/ir/IState.jl`'s `memory`
field paragraph). Specifically:

  * Forward: if `M[y]` was unset, `target` receives `Int64(0)`; the
    forward write then *creates* the key with `z`'s value.
  * Inverse: if `target`'s value (which equals the pre-forward
    `M[y]`) is `Int64(0)`, the inverse path deletes the key after
    the swap so `s.memory` returns to the pre-forward state —
    *including the absence of the key*, not merely `memory[y] == 0`.

The round-trip invariant `inverse(forward(s)) == s` is what would
fail without delete-on-zero, exactly as in the M2.11 case. The
M2.12 test "MemoryInterchange with zero-init address" pins this.

# Constructor validation (Rule 1)

The constructor rejects three degenerate cases at construction time:

  1. `target === source` — the same SSA name appears on both sides
     of the exchange; the instruction would simultaneously create
     and destroy one register, losing information. (Also an SSA
     single-assignment violation in any case.)
  2. `addr === target` (when `addr isa Symbol`) — the address
     operand `y` is *read* during the exchange but `target` is
     being *created* by it; the SSA single-assignment rule forbids
     defining `target` while `y` (referring to the same name) is
     simultaneously a use site. Lowering must rename.
  3. `addr === source` (when `addr isa Symbol`) — `y` is read for
     the address while `source` is being destroyed; if they're the
     same name the read and the destroy operate on the same cell
     and the semantics become ambiguous (does the address resolve
     to `source`'s value BEFORE or AFTER its destruction?). Forbid
     at construction time rather than pin an order.

These match the M2.7 `SwapInstruction` rejections (target/source
overlap is an SSA single-assignment violation everywhere it
appears).

# pc symmetry

`forward` sets `s.pc += 1`; `inverse` sets `s.pc -= 1`. Matches the
per-step ±1 symmetry of every M2.x instruction; the M3.x `RState`
round-trip aligns frames by `pc` alone.

# Ref

  * `references/PRD-v4.md` §3.1 — RSSA instruction taxonomy (row 4
    of the ADR 0001 §Observations twelve-class table).
  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations row 4 —
    `MemoryInterchangeInstruction` / `x := M[y] := z` / "Self-inverse
    via target↔source swap".
  * RC3 source:
    `references/implementations/RC3/compiler/src/main/java/rc3/rssa/instances/MemoryInterchangeInstruction.java`
    — the analogue this struct mirrors; its `reverse()` method (line
    41-44) defines the target/source swap that produces the inverse.
    Javadoc cites Mogensen, *RSSA: A Reversible SSA Form*, p. 213
    (Perspectives of System Informatics 2015).
  * CLAUDE.md "Hallucination-risk callouts" → "PISA memory access is
    always an exchange. Vieri 1995/1999. A load that doesn't store
    back is not reversible — it loses the pre-load value of the
    destination register." This instruction is the canonical
    reversible load.
  * `src/ir/memory_instructions.jl` (this file) — the M2.11
    `MemoryAssignment` block above shares `_resolve` and the
    delete-on-zero rule; same module-level conventions.
  * CLAUDE.md Rule 1 — constructor validates inputs; degenerate
    cases fail loud at construction time.
"""
struct MemoryInterchange <: Instruction
    target::Symbol                  # x — created; receives the OLD memory value
    addr::Union{Symbol,Int64}       # y — address (SSA ref or literal)
    source::Symbol                  # z — destroyed; its value goes into M[y]

    function MemoryInterchange(target::Symbol,
                               addr::Union{Symbol,Int64},
                               source::Symbol)
        target === source &&
            error("MemoryInterchange: target === source (= $(target)); ",
                  "would simultaneously create and destroy the same SSA ",
                  "name, losing information")
        if addr isa Symbol
            addr === target &&
                error("MemoryInterchange: addr === target (= $(addr)); ",
                      "SSA single-assignment violation — the address ",
                      "operand is a use site for the same name being ",
                      "defined; lowering must rename")
            addr === source &&
                error("MemoryInterchange: addr === source (= $(addr)); ",
                      "the address read and the source destroy would ",
                      "alias; semantics ambiguous (pre- vs post-destroy ",
                      "address resolution); forbid at construction time")
        end
        return new(target, addr, source)
    end
end

"""
    forward(instr::MemoryInterchange, s::IState) -> IState

Execute `x := M[y] := z` atomically on `s`:

  1. Resolve `a := y` (locals lookup for a `Symbol`, identity for an
     `Int64`).
  2. Read `zval := s.locals[source]` and `old := get(s.memory, a, 0)`
     (the zero-init convention: an unset address reads as `0`).
  3. Write `s.memory[a] := zval` (M[a] receives z's old value).
  4. Delete `s.locals[source]` (z is destroyed).
  5. Insert `s.locals[target] := old` (x is created with the old
     M[a]).
  6. Bump `pc`.

The order matters only for the locals dict ops (must read `zval`
before deleting `source`, and must compute `old` before overwriting
the cell); for `s.memory` the read of `old` happens before the
write of `zval` even though they target the same key, so the
single-cell exchange is well-defined.
"""
function forward(instr::MemoryInterchange, s::IState)::IState
    a    = _resolve(instr.addr, s)
    zval = s.locals[instr.source]
    old  = get(s.memory, a, Int64(0))      # zero-init: absent key reads as 0.
    s.memory[a] = zval                     # M[a] receives z's old value.
    delete!(s.locals, instr.source)        # destroy z.
    s.locals[instr.target] = old           # create x with the old M[a].
    s.pc += 1
    return s
end

"""
    inverse(instr::MemoryInterchange, s::IState, prev) -> IState

Undo a previous `forward` on `instr`. Implements the
target↔source-swapped exchange `z := M[y] := x`. The `prev`
argument is part of the dispatch signature (M2.4) but **unused** —
`MemoryInterchange` is injective (M6.1
`is_injective(MemoryInterchange) = true`), no history record is
ever pushed for it, and the caller may pass `nothing`.

# Steps

  1. Resolve `a := y`.
  2. Read `xval := s.locals[target]` (this equals the pre-forward
     `M[a]`).
  3. Read `cur := s.memory[a]` (this equals the pre-forward
     `s.locals[source]`).
  4. If `xval == 0`, delete `s.memory[a]` (zero-init delete rule
     — restores the absent-key state when `M[a]` was unset before
     forward); otherwise write `s.memory[a] := xval`.
  5. Delete `s.locals[target]` (x is destroyed).
  6. Insert `s.locals[source] := cur` (z is restored).
  7. Decrement `pc`.

# The delete-on-zero rule (load-bearing, symmetric with M2.11)

If the value being restored to memory is `Int64(0)`, **delete the
key from `s.memory`**. This restores the zero-init equivalence —
an address that was never written before `forward` should not
appear in `s.memory` after `inverse`. Without this, the round-trip
invariant `inverse(forward(s)) == s` would fail for the first-time-
exchange case (post-inverse `Dict` would carry an `addr → 0` entry
that the pre-forward `Dict` lacked). Pinned in
`test/test_memory_instructions.jl` via the "MemoryInterchange with
zero-init address" testset.
"""
function inverse(instr::MemoryInterchange, s::IState, prev)::IState
    a    = _resolve(instr.addr, s)
    xval = s.locals[instr.target]          # = pre-forward M[a].
    cur  = s.memory[a]                     # = pre-forward s.locals[source];
                                           # must exist post-forward (KeyError
                                           # surfaces a Rule-1 bug if not).
    if xval == Int64(0)
        # Delete-on-zero: restore the zero-init absent-key state.
        delete!(s.memory, a)
    else
        s.memory[a] = xval
    end
    delete!(s.locals, instr.target)        # destroy x.
    s.locals[instr.source] = cur           # restore z.
    s.pc -= 1
    return s
end
