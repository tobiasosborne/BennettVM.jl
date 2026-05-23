"""
Types.jl — Core data types for the Bennett-1973 trace-VM spike.

This module defines the four nominal types of the spike VM:

  * `IState` — interpreter state: program counter, local variable map,
    status flag. The "instantaneous description" (ID) in the
    Turing-machine literature.
  * `RState` — reversible state: a current `IState` plus a history
    stack of past `IState` snapshots. The history tape of Bennett 1973
    §3, realised as a `Vector{IState}`.
  * `AbstractInstruction` — interface marker. Pass 2 (the
    instruction-set subagent) will introduce concrete subtypes plus
    `forward` / `inverse` methods. We export the marker now so the
    interpreter's dispatch points can be written without forward
    references to instructions that do not yet exist.
  * `Program` — a flat `Vector{AbstractInstruction}`. Address space
    is `1:length(prog.instructions)` (Julia 1-indexing); the pc lives
    in `IState`.

Ground truth (Bennett-1973 PDF is off-disk per PHASE.md user override;
the canonical secondary sources we cite in lieu are):

  * references/foundational/vitanyi-time-space-energy.pdf §2 —
    Vitanyi's restatement: the irreversible TM is made reversible by
    a 6-tuple rule set that, in addition to the original work, writes
    onto an auxiliary "history tape" the sequence of quadruples
    executed on the original tape, so that the computation may be
    retraced.
  * references/foundational/Bennett1989_time_space_tradeoffs.pdf §1
    Lemma 1, with the three-stage construction: (1) Untidy Stage
    accumulates a history tape entry per step encoding which
    quintuple was applied; (2) Output Stage copies output reversibly;
    (3) Cleanup Stage reverses Stage 1. The spike implements Stage 1
    (`run!`) and its exact inverse (`unrun!`); Stages 2 and 3 are out
    of scope per PRD v3 §5.2.
  * references/foundational/buhrman-tromp-vitanyi-2001.pdf §1 —
    modern formal framing: "the new 6-tuple rules have the effect
    that the machine keeps a record on the auxiliary history tape
    consisting of the sequence of quadruples executed on the
    original tape".

Phase-0 design choice (record for retrospective Q2):

Bennett 1989 §1 records on the history tape only the *quintuple index*
`(i, j)` sufficient to undo the step. The spike instead pushes a
*full* `IState` snapshot per step. This is the wasteful end of the
time-space curve (PRD v3 §3.3: "the worst point on the time-space
tradeoff curve and the Phase-0 spike exists to confirm that we hate
them"). It is the right Phase-0 mechanism precisely because Pass 2's
instruction subtypes do not yet need to be invertible-in-isolation —
the snapshot captures enough state to invert *any* instruction. Phase
2 must replace this with delta entries plus min-cut analysis (PRD v3
§3.3) — see RETROSPECTIVE.md Q1 / Q4.

Status sentinels are `Symbol`s, not an `@enum`, deliberately: an enum
would commit us to a closed set, but Pass 2 may want to introduce
new error sub-kinds. Pass-2 invariants on `status` are documented in
`Interpreter.jl`.

Rule 11 (literate programming). Rule 1 (fail-fast) is enforced in
`Interpreter.jl`; this file is data-only.
"""

"""
    IState(pc, locals, status)

The instantaneous description: program counter (1-indexed into
`Program.instructions`), the local variable map (`Symbol => Int64`,
per PRD v3 §5.1: scalars only, `Int64` and `Bool`; `Bool`s are
stored as `Int64` 0/1 in the spike), and a status sentinel:

  * `:running` — pc points at an executable instruction.
  * `:halted`  — terminal state; `step!` is a no-op.
  * `:error`   — invariant violated mid-step (e.g. unsupported op);
    `step!` is a no-op. Distinct from `:halted` so test code can
    distinguish "program completed" from "program faulted".
"""
struct IState
    pc::Int
    locals::Dict{Symbol, Int64}
    status::Symbol
end

"""
    RState(current, history)

A reversible state: the current `IState` plus a history of past
snapshots, ordered oldest-first. `step!` pushes; `unstep!` pops.
The Phase-0 invariant (PRD v3 §5.4, CLAUDE.md P0.6) is that after
`unrun!` we have `isempty(history)` and `current` equals the
result of `initial_state(prog)`.

History is mutable (`Vector{IState}`); `current` is replaced
wholesale by reassignment, hence `RState` itself is mutable (the
struct is declared `mutable` so `step!` / `unstep!` can rebind
the field — `IState` is immutable, so we never accidentally mutate
a snapshot in place).
"""
mutable struct RState
    current::IState
    history::Vector{IState}
end

"""
    AbstractInstruction

Interface marker. Pass 2 introduces concrete subtypes (`Const`,
`Move`, `UnaryOp`, `BinaryOp`, `Jump`, `JumpIf`, `Return`, `Halt`,
per PRD v3 §5.1) and provides

    forward(instr::AbstractInstruction, s::IState) -> IState
    inverse(instr::AbstractInstruction, s::IState, prev::IState) -> IState

The interpreter dispatches on this marker; it does not need to know
the concrete instruction types to function.

Why `inverse` takes both `s` (post-step) and `prev` (pre-step):
Phase-0 carries the full pre-step snapshot anyway, so `inverse` can
simply return `prev` — but the *signature* is the one Phase 2 will
keep, where `prev` becomes a delta and the body of `inverse`
becomes nontrivial. Keeping the signature stable across phases is
the one piece of API discipline the spike permits itself (Rule 9).
"""
abstract type AbstractInstruction end

"""
    Program(instructions)

A flat vector of instructions. The pc indexes into this 1-indexed.
Out-of-range pc with `status == :running` is a fail-fast error in
`step!` — there is no implicit halt-on-end; programs must contain
an explicit `Halt`. (Why: an implicit halt makes the inverse
ambiguous at the boundary — did the last step execute or not?)
"""
struct Program
    instructions::Vector{AbstractInstruction}
end
