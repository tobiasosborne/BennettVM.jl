"""
Interpreter.jl — Forward/backward execution for the Bennett-1973 trace VM.

This module implements the six exported operations of the spike VM:

    initial_state(prog) -> RState
    step!(s, prog)      -> RState   # one forward transition
    unstep!(s, prog)    -> RState   # one backward transition
    run!(s, prog; max_steps) -> RState
    unrun!(s, prog)     -> RState
    is_halted(s)        -> Bool
    result(s)           -> Dict{Symbol,Int64}

Ground truth (per PHASE.md user override, Bennett-1973 PDF is off-disk;
citations are to the substitute secondary sources):

  * references/foundational/Bennett1989_time_space_tradeoffs.pdf §1
    Lemma 1: the three-stage construction. Stage 1 ("Untidy Stage")
    accumulates a history tape entry per step. Each entry is
    sufficient to *undo* the step in Cleanup Stage. The spike
    implements Stage 1 (`run!`) and the inverse of Stage 1
    (`unrun!`); Stages 2 (Output) and 3 (Cleanup proper) are out of
    scope per PRD v3 §5.2.
  * references/foundational/vitanyi-time-space-energy.pdf §2: "the
    machine keeps a record on the auxiliary history tape consisting
    of the sequence of quadruples executed on the original tape.
    Reversibly undoing a computation entails also erasing the record
    of its execution from the history tape" — that is exactly the
    Phase-0 invariant `unrun! ⇒ isempty(history)`.
  * references/foundational/buhrman-tromp-vitanyi-2001.pdf §1:
    modern formal restatement.

Phase-0 design decisions (record verbatim in RETROSPECTIVE.md Q2):

  Q2.1 (equality): `Base.==` is overridden on `IState` because Julia's
    default field-wise `==` on a struct containing a `Dict` reduces
    to `===` on the dict (object identity), and the round-trip
    invariant `unrun!(run!(s)) == initial_state(s)` demands
    *structural* equality. Without the override the load-bearing
    Phase-0 invariant (P0.6) silently never holds. Confirmed in a
    REPL probe before writing the override. We also override `hash`
    for consistency with `==` (Julia's hash-equality contract).

  Q2.2 (snapshot copy): `step!` performs a full `deepcopy` of
    `s.current` before pushing it. Justification: `IState.locals` is
    a `Dict{Symbol,Int64}`; if `forward` returned a new `IState`
    sharing the same `locals` dict object as the input (Pass 2 might,
    accidentally), the historical snapshot and the post-step state
    would alias, and a subsequent in-place mutation would corrupt
    the history. `deepcopy` is the conservative choice given Pass 2
    is being written in parallel by another agent. A shallow `copy`
    would work IF every concrete instruction's `forward` is required
    to return a fresh `Dict`; we do not want to depend on that
    discipline from a sibling subagent (Rule 1: fail-fast about
    invariants we cannot enforce locally).

  Q2.3 (error handling). `:error` is treated identically to `:halted`
    inside `step!`: the pre-step snapshot is pushed, and is then popped
    back off **only when the post-step state differs from the pre-step
    state in status alone** — i.e. pc and locals are unchanged. An
    error instruction whose `forward` ALSO mutates pc or locals retains
    its snapshot in history. This is intentional: such a step has
    observable side effects on the IState, and `unstep!` must be able
    to reverse them. The same discard-pop rule applies to `:halted`
    (Q2.4); the two terminal statuses share one code path.

  Q2.4 (halt-state push): on a transition into `:halted`, `step!`
    pushes the pre-step snapshot and then discard-pops it iff the
    transition is a pure status flip (status terminal AND pc unchanged
    AND locals unchanged) — the same discard-pop predicate as Q2.3;
    the two terminal statuses share one code path. A `Halt`
    instruction whose `forward` ALSO mutates pc or locals therefore
    retains its snapshot, so `unstep!` can reverse those side effects.
    For the idempotent-Halt case the snapshot is redundant and
    correctly dropped, and `unstep!` will never need to revive a
    halted state. (Concretely: after a halted `step!`, calling
    `step!` again is also a no-op, not an error — see Q2.7.)

  Q2.5 (max-steps trip): `run!` `error()`s with a message identifying
    the budget and the pc reached. We do *not* leave `s` partially
    advanced silently; the caller may inspect `s` after the error
    via `try/catch` if desired (the exception carries no state
    beyond the message). Rule 1.

  Q2.6 (max-steps history): if `run!` trips `max_steps`, history is
    left as-is — the snapshots accumulated up to the budget are
    valid; the caller may `unrun!` them back. Documented separately
    in case Pass 2's tests rely on this.

  Q2.7 (re-entry into halted/error): calling `step!` on a non-running
    state is a *silent no-op*. Justification: `run!` is a `while`
    loop, and the natural idiom is `while !is_halted(s) step!(s) end`;
    making the first post-halt `step!` throw would require every
    caller to guard. The fail-fast behaviour we *do* want is for
    `unstep!` with empty history — there the invariant is genuinely
    being violated.
"""

# Equality / hash overrides for IState — Q2.1 above.
# These are intentionally narrow: only IState gets structural ==.
# RState is mutable and identity-equal is fine; tests compare RState
# fields explicitly.
function Base.:(==)(a::IState, b::IState)
    a.pc == b.pc && a.status == b.status && a.locals == b.locals
end

function Base.hash(s::IState, h::UInt)
    hash(s.locals, hash(s.status, hash(s.pc, hash(:IState, h))))
end

"""
    initial_state(prog::Program) -> RState

The initial reversible state: pc = 1, empty locals, `:running`,
empty history. (`prog` is taken to allow Pass-2-side extensions
that bake constants into the initial state; not used here.)
"""
function initial_state(prog::Program)
    isempty(prog.instructions) && error("initial_state: empty program")
    RState(IState(1, Dict{Symbol,Int64}(), :running), IState[])
end

"""
    is_halted(s::RState) -> Bool

True iff `s.current.status === :halted`. (`:error` is *not* halted —
that's a distinct terminal status; callers should test both.)
"""
is_halted(s::RState) = s.current.status === :halted

"""
    result(s::RState) -> Dict{Symbol,Int64}

The locals of the current state. Errors if not halted (Rule 1:
asking for the result of a still-running computation is a bug).
"""
function result(s::RState)
    is_halted(s) || error("result: state is :$(s.current.status), expected :halted")
    s.current.locals
end

"""
    step!(s::RState, prog::Program) -> RState

One forward transition. Semantics:

  * If `s.current.status !== :running`, no-op (Q2.7).
  * Otherwise fetch `instr = prog.instructions[s.current.pc]`,
    deepcopy `s.current` to snapshot, push snapshot, set
    `s.current = forward(instr, s.current)`.
  * If `forward` returns a state with `status === :halted` or
    `:error`, that snapshot push has *already happened* — the
    Halt instruction's `forward` is the no-op-on-locals form and
    advances the pc by zero (it is its own fixed point). The
    "do not push halted/error snapshot" rule of Q2.3 / Q2.4
    therefore only applies if `forward` *transitions into* a
    terminal state from a running one. We treat that case
    correctly by checking the status of the *post* state and
    discarding the just-pushed snapshot if the transition was
    purely a status flip (no pc change, no locals change). This
    keeps the invariant `length(history) == steps_taken` honest
    where "steps taken" means "real work done".

In practice Pass 2's `Halt` will likely produce an `IState`
identical to its input except `status = :halted`; in that case the
pre-push snapshot equals the post-step state modulo status, and
discarding the redundant snapshot keeps history clean.
"""
function step!(s::RState, prog::Program)
    s.current.status === :running || return s
    pc = s.current.pc
    (1 <= pc <= length(prog.instructions)) ||
        error("step!: pc=$pc out of range [1,$(length(prog.instructions))]; missing Halt?")
    instr = prog.instructions[pc]
    snapshot = deepcopy(s.current)
    # Compute the transition *before* mutating any RState field.
    # If `forward` throws, `s.history` and `s.current` are untouched —
    # the VM is left in a consistent pre-step state (Rule 1: fail-fast
    # without smearing invariants on the way out). See review finding 17.
    new_state = forward(instr, s.current)
    push!(s.history, snapshot)
    if new_state.status !== :running &&
       new_state.pc == snapshot.pc &&
       new_state.locals == snapshot.locals
        pop!(s.history)
    end
    s.current = new_state
    return s
end

"""
    unstep!(s::RState, prog::Program) -> RState

One backward transition. Fails loudly (Rule 1) if the history is
empty — that is the load-bearing Phase-0 invariant violation:
attempting to invert further than the recorded history allows.

Semantics: pop the most recent snapshot `prev`; ask the instruction
at `prev.pc` (the one that *produced* the just-popped step) for its
inverse from the current state back to `prev`. In Phase 0 the
inverse simply returns `prev` (the snapshot *is* the answer) but we
go through `inverse(instr, s.current, prev)` for signature
consistency with Phase 2 (see Types.jl docstring on
AbstractInstruction).
"""
function unstep!(s::RState, prog::Program)
    isempty(s.history) && error("unstep!: history is empty; cannot reverse further")
    prev = pop!(s.history)
    pc = prev.pc
    (1 <= pc <= length(prog.instructions)) ||
        error("unstep!: snapshot pc=$pc out of program range")
    instr = prog.instructions[pc]
    s.current = inverse(instr, s.current, prev)
    return s
end

"""
    run!(s::RState, prog::Program; max_steps=10_000) -> RState

Loop `step!` until the status leaves `:running` or `max_steps`
exhausted. On budget exhaustion: `error()` with diagnostic.
History is left intact and may be replayed backwards via `unrun!`.
"""
function run!(s::RState, prog::Program; max_steps::Int = 10_000)
    n = 0
    while s.current.status === :running
        n >= max_steps && error("run!: exceeded max_steps=$max_steps at pc=$(s.current.pc); history retained")
        step!(s, prog)
        n += 1
    end
    return s
end

"""
    unrun!(s::RState, prog::Program) -> RState

Loop `unstep!` until the history is empty. Load-bearing Phase-0
invariant (PRD v3 §5.4 / CLAUDE.md P0.6):

    s_after = unrun!(run!(initial_state(prog), prog), prog)
    @assert isempty(s_after.history)
    @assert s_after.current == initial_state(prog).current

The IState `==` override above is what makes the second assertion
meaningful (Q2.1).
"""
function unrun!(s::RState, prog::Program)
    while !isempty(s.history)
        unstep!(s, prog)
    end
    @assert isempty(s.history) "unrun! postcondition violated"
    return s
end
