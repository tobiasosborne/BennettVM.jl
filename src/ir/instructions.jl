"""
    Instruction / ControlInstruction / RValue — dispatch skeleton (M2.4)

The abstract type hierarchy and generic-fallback methods on which all
twelve concrete RSSA instruction subclasses (M2.7-M2.14) will hang. No
concrete subtype lives here yet; this file only lays down the
supertypes plus the `forward` / `inverse` "no method" sentinels that
guarantee an unknown instruction fails loudly (Rule 1) rather than
silently fingerprinting a method-dispatch failure.

# The 12-subclass taxonomy (locked at ADR 0001 §Observations)

Concrete `Instruction` subtypes — to be defined under
`src/ir/instructions/` across beads M2.7 through M2.14 — are exactly
the twelve drawn from the RC3 RSSA dispatch table
(`docs/adr/0001-rc3-rvm-smoke.md` §Observations, RC3 class →
candidate Phase-2 Julia name):

  1. `ArithAssign`  — arithmetic update (`x := y ⊕ (R1 ⊙ R2)`).
  2. `RegSwap`      — register exchange (`x, y := z, w`).
  3. `MemAssign`    — in-place memory update (`M[x] ⊕= y ⊙ z`).
  4. `MemExchange`  — register ↔ memory exchange (`x := M[y] := z`).
  5. `MemSwap`      — memory ↔ memory swap (`M[x] <-> M[y]`).
  6. `Call`         — procedure call/uncall, `Direction` flips on reverse.
  7. `SubBegin`     — subroutine entry (`begin l(x,...)`).        [control]
  8. `SubEnd`       — subroutine exit (`end l(y,...)`).            [control]
  9. `UncondEntry`  — unconditional block entry (`l(x,...) <-`).   [control]
 10. `UncondExit`   — unconditional block jump-out (`-> l(y,...)`).[control]
 11. `CondEntry`    — predicated block φ-merge (join).             [control]
 12. `CondExit`     — predicated block branch (split).             [control]

The six control-flow subclasses (7-12) additionally specialize
`ControlInstruction <: Instruction`; the other six are arithmetic /
data-movement and inherit directly from `Instruction`.

# "Sealed by convention"

Julia has no `sealed` keyword: any user can write
`struct UserInstr <: BennettVM.Instruction end` in their own module
without our permission. The Phase-2 contract treats the hierarchy as
**sealed by convention**: the only legal subtypes are the twelve
listed above, defined inside `src/ir/instructions/`. Any other
subtype will be missing `forward` / `inverse` methods, so the
generic fallbacks below catch it on the first dispatch attempt and
raise an `ErrorException` carrying both the offending type and the
machine state. That is the Rule 1 ("fail fast, fail loud") expression
of sealing — we cannot prevent the declaration, but we can guarantee
the declarator cannot quietly break reversibility.

# Why a separate `RValue` hierarchy

RC3 distinguishes *instructions* (twelve `Instruction` subclasses)
from *operands* — `BinaryOperand`, `Atom`, `Constant`, `Variable`,
`MemoryAccess`, `Value` — which it groups under the visitor base
type and which appear inside instruction fields rather than in the
program stream. `BennettVM` collapses several of those operand
classes into fewer concrete Julia types (per M5.3 survey), but
keeps the supertype `RValue` so that generic operand-handling
functions (`eval_operand`, future pretty-printing, future type
inference) can dispatch polymorphically. **Do not** add an
"instruction-13" for `BinaryOperand`: ADR 0001 §Observations is
explicit that the RC3 visitor entry for operands is a no-op, and
the same boundary holds here.

Ref: docs/adr/0001-rc3-rvm-smoke.md §Observations (the 12-subclass
     table, the "Future M2.x agents: do not add an instruction-13"
     note, and the `ControlInstruction` intermediate).
Ref: bennettvm_prd.md §3.1 (RSSA instruction taxonomy).
"""

"""
    Instruction

Abstract supertype of every RSSA instruction in BennettVM. The twelve
concrete subtypes are listed in this file's top-of-module docstring;
any other subtype hitting `forward` / `inverse` falls through to the
sentinel methods defined below and raises immediately.
"""
abstract type Instruction end

"""
    ControlInstruction <: Instruction

Abstract intermediate for the six control-flow instructions
(`SubBegin`, `SubEnd`, `UncondEntry`, `UncondExit`, `CondEntry`,
`CondExit`). Concrete subtypes declare `<: ControlInstruction` so
that block-level passes (the M3.x dispatcher, the M6.x pebble-game
lowering) can pattern-match on "is this a control-flow op?" without
enumerating six concrete types. Mirrors RC3's
`instances/ControlInstruction.java` intermediate.

Ref: docs/adr/0001-rc3-rvm-smoke.md §Observations
     ("Control-flow subclasses extend the sealed abstract
     `ControlInstruction`").
"""
abstract type ControlInstruction <: Instruction end

"""
    RValue

Operand supertype. Concrete subtypes (variables, constants,
memory-access expressions) appear as *fields* of `Instruction`
subtypes, not as program elements in their own right. The supertype
exists so that generic operand-handling code — evaluation, type
checking, pretty-printing — can dispatch on `::RValue` without
enumerating concrete subtypes.

Ref: docs/adr/0001-rc3-rvm-smoke.md §Observations
     (RC3 operand classes: `BinaryOperand`, `Atom`, `Constant`,
     `Variable`, `MemoryAccess`, `Value`; BennettVM collapses to
     fewer concretes but keeps `RValue` as the supertype).
"""
abstract type RValue end

"""
    forward(instr::Instruction, s::IState) -> IState

Apply `instr` to the interpreter state `s` in the forward direction,
returning the post-execution `IState`. The concrete method per
instruction type lands at M2.7-M2.14; this file defines only the
generic fallback.

# The fallback contract (this method)

When dispatch lands here, the offending `instr` is of a type whose
concrete `forward` method was never defined — either because a new
instruction was added to `src/ir/instructions/` without a matching
`forward(::ThatType, ::IState)` method, or because a user-defined
subtype of `Instruction` from outside the sealed-by-convention set
(see this file's top-of-module docstring) reached the dispatcher.

Per Rule 1 ("fail fast, fail loud"; CLAUDE.md), an `ErrorException`
is raised that carries both the offending instruction type AND the
interpreter state at the moment of failure. The default Julia
`MethodError` message ("no method matching forward(::SomeInstr,
::IState)") is too terse — it omits `pc`, `status`, and any clue
that the missing method is a reversibility bug rather than a
typo. The wording below is therefore the deliberate, project-wide
form for "instruction has no forward semantics".
"""
function forward(instr::Instruction, s::IState)::IState
    error("BennettVM: no `forward` method for instruction of type ",
          typeof(instr),
          ". This usually means the instruction was added without ",
          "implementing the forward semantics. State at error: pc=",
          s.pc, ", status=", s.status, ".")
end

"""
    inverse(instr::Instruction, s::IState, prev) -> IState

Apply `instr` to the interpreter state `s` in the *inverse*
direction, returning the pre-execution `IState`. Concrete methods
land at M2.7-M2.14 alongside their `forward` counterparts; this file
defines only the generic fallback.

# The `prev` argument

`prev` is the per-step history record that `step!` produced when
`instr` ran forward. For *non-injective* instructions (those that
discard source-side information — `ArithAssign` with a `:=`
overwrite, `MemAssign` whose old memory cell content is lost, etc.)
the inverse needs `prev` to recover the destroyed value; for
*injective* instructions (`RegSwap`, `MemSwap`) the inverse is
self-contained and `prev` can legitimately be `nothing`.

The argument is **deliberately untyped** at this milestone. The
eventual type is `Union{AbstractHistoryEntry, Nothing}` once
`AbstractHistoryEntry` lands at M2.6; until then, leaving it
untyped lets concrete instruction methods specialize freely
without forcing a placeholder dummy supertype. The convention is
documented here rather than enforced by the type system — the same
"sealed by convention" pattern as `Instruction` itself.

# The fallback contract

Same shape as `forward` above: raise an `ErrorException` carrying
the instruction type and state context. Reversibility violations
are correctness bugs (Rule 1) and must not be papered over by a
silent default.
"""
function inverse(instr::Instruction, s::IState, prev)::IState
    error("BennettVM: no `inverse` method for instruction of type ",
          typeof(instr),
          ". This usually means the instruction was added without ",
          "implementing the inverse semantics. State at error: pc=",
          s.pc, ", status=", s.status, ".")
end
