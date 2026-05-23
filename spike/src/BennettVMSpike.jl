"""
BennettVMSpike — Phase-0 throwaway reversible VM (PRD v3 §5).

This is the Phase-0 spike package. It implements the Bennett-1973
three-tape reversible-TM construction, narrowed to scalars
(`Int64`, `Bool`) and eight bytecode instructions, with full-state
snapshot history (PRD v3 §5.1, §3.3). It is deliberately throwaway
(CLAUDE.md P0.7) and will be archived read-only at Phase-0 close.

The Bennett-1973 paper itself is not on local disk (per PHASE.md
user override, 2026-05-23). Ground truth for the construction is
drawn from three substitute sources:

  * `references/foundational/vitanyi-time-space-energy.pdf` §2
  * `references/foundational/Bennett1989_time_space_tradeoffs.pdf` §1–2
  * `references/foundational/buhrman-tromp-vitanyi-2001.pdf` §1

Per-file citations are inside `Types.jl` and `Interpreter.jl`.

Layout (Rule 10: ≤200 LOC per file):

  * `Types.jl`       — `IState`, `RState`, `AbstractInstruction`, `Program`.
  * `Interpreter.jl` — `initial_state`, `step!`, `unstep!`, `run!`,
                       `unrun!`, `is_halted`, `result`.
  * `Instructions.jl` (Pass 2) — the eight concrete bytecodes.

Pass 1 (this file plus the two above) defines `AbstractInstruction`
as an interface marker only. Pass 2 will introduce concrete
subtypes and the `forward` / `inverse` methods; Pass 3 writes tests
and the countdown program.
"""
module BennettVMSpike

# Pass 2 will define forward/inverse; we forward-declare them here as
# generic functions so Interpreter.jl can refer to them, and so Pass 2
# can `import BennettVMSpike: forward, inverse` and add methods.
function forward end
function inverse end

include("Types.jl")
include("Interpreter.jl")
include("Instructions.jl")

export IState, RState, AbstractInstruction, Program
export initial_state, step!, unstep!, run!, unrun!
export is_halted, result
export forward, inverse
export Const, Move, UnaryOp, BinaryOp, Jump, JumpIf, Return, Halt

end # module BennettVMSpike
