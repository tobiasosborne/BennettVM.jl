"""
    UnreachableHalt — the reversible `:__unreachable__` halt sink
    (Bennett-utzc / CW-D; ADR 0017 §4)

The body instruction that materialises a **taken dead abort**. The
Bennett.jl frontend emits a provably-dead throw arm as an empty block
whose terminator is `IRBranch(nothing, :__unreachable__, nothing)` — an
unconditional branch to the reserved sentinel label `:__unreachable__`,
a branch TARGET with no matching source block (a dangling target). The
ingest pass (`src/ir/ingest.jl`) materialises a synthetic per-function
sink block for that target:

    UnconditionalEntry(<fn>#__unreachable__, []) /
        [UnreachableHalt()] /
        EndInstruction(routine, [])

`UnreachableHalt` is the sole body instruction of that sink. It HALTS ON
ENTRY: the moment control reaches the sink, `forward` sets
`status = :error` (the DOCUMENTED-but-until-now-never-produced third
`IState.status` value, `src/ir/IState.jl`) and bumps `pc`. The trailing
`EndInstruction` exit is vestigial — a halt-on-entry never reaches it —
present only to satisfy the `BasicBlock` invariant that the exit slot
hold an exit-direction control marker (`src/ir/basic_block.jl`).

# Why `:error`, not `:halted`

A normal `EndInstruction` halt sets `status = :halted` (`step!`,
`src/interpreter/Interpreter.jl`) and `run!` returns cleanly with a
`result`. A `:__unreachable__` sink is a TRAP: reaching it means a
provably-dead arm was TAKEN, which is a compiler/analysis contradiction
— the reversible program has trapped and there is no meaningful result.
Distinguishing it with a THIRD status (`:error`, reserved for exactly
this abnormal-termination role since M2.1) lets `run!` raise loudly
(Rule 1 fail-loud) rather than return a spurious "halted" state. This is
the FIRST producer of `:error` anywhere in `src/`.

# Reversibility (trivial)

`forward` mutates NOTHING that carries data — no `locals`, no `memory`,
no cursor. It touches only `status` and `pc`, both of which `inverse`
restores exactly (`:error → :running`, `pc -= 1`). So the sink reverses
trivially. It is L1-injective (`is_injective(::Type{UnreachableHalt}) =
true`, pinned beside `EndInstruction` / `IntrinsicFree` in
`src/history/Injective.jl`): the M6.2/M7.6 push gate records NO history
entry for it, and `structural_inverse` returns it unchanged (self-
inverse). In practice the per-instruction `inverse` is only reached by
the injective-class reversal path; the taken sink aborts `run!` before
any round-trip, and the not-taken sink is never executed at all — but
the method is defined for completeness and to keep the instruction a
first-class reversible citizen.

# Ref

  * ADR 0017 §4 (the reversible-throw halt-sink decision; Bennett-utzc).
  * `src/ir/ingest.jl` — `_lower_parsed_ir` materialises the sink block
    and injects this instruction into its body.
  * `src/ir/IState.jl` — `status::Symbol ∈ {:running, :halted, :error}`;
    this is `:error`'s first producer.
  * `src/interpreter/Interpreter.jl` — `run!`'s loop terminates on
    `status !== :running` and raises loud on the post-loop `:error`.
  * `src/history/Injective.jl` — the `is_injective` L1 pin.
  * CLAUDE.md Rule 1 (fail loud), Rule 11 (literate exposition).
"""
struct UnreachableHalt <: Instruction end

# Halt-on-entry trap (ADR 0017 §4). Set `status = :error` (distinct from
# `EndInstruction`'s `:halted`) and bump pc. Mutates NO `locals` / `memory` /
# cursor ⇒ reverses trivially. Matches the `forward(::Instruction, ::IState)
# ::IState` convention (`src/ir/instructions.jl`): mutate `s.current` in place
# and return `s`.
function forward(::UnreachableHalt, s::IState)::IState
    s.status = :error
    s.pc += 1
    return s
end

# Structural inverse of the halt-on-entry trap: restore `:error → :running`
# and un-bump pc. `prev` is unused — the forward step destroyed no data (only
# `status`/`pc` changed, both recovered structurally), so no cached payload is
# needed. Matches the `inverse(::Instruction, ::IState, prev)::IState`
# convention.
function inverse(::UnreachableHalt, s::IState, prev)::IState
    s.status = :running
    s.pc -= 1
    return s
end

# IR-graph-level inverse (`reversed(::BasicBlock)` / M9 pebble pass). Self-
# inverse: the instruction is its own structural inverse, so return it as-is.
# Defined here rather than deferred to the `basic_block.jl` fallback because
# `UnreachableHalt` is a plain body `Instruction`, not one of the six control-
# flow subtypes handled by the block-label-aware helpers.
structural_inverse(i::UnreachableHalt) = i
