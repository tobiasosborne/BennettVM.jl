"""
    BeginInstruction / EndInstruction (M2.8)

The first two concrete control-flow instructions in BennettVM's
twelve-subclass RSSA taxonomy: rows 7 and 8 of
`docs/adr/0001-rc3-rvm-smoke.md` §Observations
(RC3 `BeginInstruction` / `EndInstruction`; candidate names
`SubBegin` / `SubEnd`). Both extend the `ControlInstruction`
intermediate already defined at M2.4 in `src/ir/instructions.jl`;
**this file does not redefine `ControlInstruction`** — see the
"Scoping" section below.

# What these are — and what they are *not*

`BeginInstruction` and `EndInstruction` are **subroutine** entry /
exit markers. RC3 spells them `begin l(x,...)` and `end l(y,...)`
respectively, with the implication that `l` names a subroutine and
the parenthesised lists are formal parameters / return values.

  * `BeginInstruction(label, params)` ↔ RC3 `begin l(x,...)`.
  * `EndInstruction(label, returns)`  ↔ RC3 `end l(y,...)`.

The matching `Begin`/`End` pair around a subroutine body is what
makes a `Call` site (M2.14) invertible: forward execution at a call
site enters the body at the `Begin` marker, runs through, leaves at
the `End` marker; reverse execution enters at the `End`, runs the
body in reverse, leaves at the `Begin`. The IR-graph-level conversion
"a `BeginInstruction` reversed is an `EndInstruction`" lands at M2.15
in `BasicBlock.reversed()`; at the dispatch level (this file), both
instructions are pc-only — see "Forward / inverse semantics" below.

These are **subroutine** delimiters, not basic-block delimiters. The
bead's loose wording ("marker instructions for basic-block
entry/exit") is reconciled here: block-level entry/exit lives in
M2.9 (`UnconditionalEntry`/`UnconditionalExit`, RSSA rows 9/10) and
M2.10 (`ConditionalEntry`/`ConditionalExit`, RSSA rows 11/12).
Confusing the two would prevent the M2.15 `BasicBlock.reversed()`
pass from knowing whether to flip the entire block (Uncond/Cond) or
to swap the surrounding call frame (Begin/End).

# Scoping: parameter / return-value transfer is NOT here

In a naive "subroutine" semantics one might expect `BeginInstruction`
to *bind* its `params` into `s.locals` on entry, and `EndInstruction`
to *unbind* `returns` on exit. **BennettVM Phase-2 does not do
that.** Per the RC3 hierarchy and PRD v4 §3.1, the actual
parameter-to-local and return-value-to-caller transfer is the
responsibility of `CallInstruction` (M2.14), which surrounds the
call site with the appropriate `SwapInstruction`-like exchanges
in the caller's frame.

Begin/End therefore reduce, at this dispatch layer, to **pc
markers**: they record the label + parameter / return list as
*metadata* (so the M2.15 `BasicBlock.reversed()` pass can pair
them and so future printers can render the subroutine signature),
but `forward` / `inverse` do nothing more than bump `pc`. They are
*structurally* injective — but injective by virtue of having no
state to corrupt, not by virtue of being a non-trivial bijection
like `SwapInstruction`.

This scoping decision is the single most likely source of confusion
for a future agent reading "Begin/End"; the docstring is deliberately
long here to forestall that.

# Constructor: no validation, by design

```julia
BeginInstruction(:my_routine, [:p, :q])
EndInstruction(:my_routine, [:r])
BeginInstruction(:no_args,    Symbol[])   # legal — no-arg main
EndInstruction(:no_returns,  Symbol[])   # legal — void return
```

The constructors do **not** validate:

  * **label-matching**. The contract that a `BeginInstruction` with
    label `L` is paired with an `EndInstruction` carrying the same
    label `L` is the caller's responsibility, eventually verified
    by M2.15's `BasicBlock` validation pass. We cannot check it at
    the per-instruction layer because each instruction sees only
    itself.
  * **parameter-list emptiness**. An empty `params` (or empty
    `returns`) is *legal* — a no-argument `main` routine, or a
    void-returning subroutine, are both well-formed RSSA programs.
  * **parameter-name uniqueness within the list**. Future work; not
    on the critical path for M2.8.

This is in contrast to `SwapInstruction` (M2.7), where the
constructor rejects degenerate cases that would corrupt
reversibility. Begin/End have no degenerate cases at the
per-instruction level — every parameter list is acceptable, every
label is acceptable. Rule 1 ("fail fast, fail loud") is satisfied
trivially because there is nothing to fail.

# Forward / inverse semantics — pc-only

```
forward(::BeginInstruction, s) → s with s.pc += 1
forward(::EndInstruction,   s) → s with s.pc += 1
inverse(::BeginInstruction, s, _) → s with s.pc -= 1
inverse(::EndInstruction,   s, _) → s with s.pc -= 1
```

The `prev` argument on `inverse` is **unused**: Begin/End are
injective at this layer (no locals are touched, so no state is
destroyed). Callers may pass `nothing`; the M3.x `step!` /
`unstep!` infrastructure never pushes a history entry for either
class. This is the same "no history needed" property as
`SwapInstruction` (M2.7), but for a structurally different reason
— `SwapInstruction` is a non-trivial bijection on `locals`;
Begin/End are no-ops on `locals`.

Note the inverse-pc-decrement is symmetric to forward-pc-increment;
the M3.x round-trip tests align forward and inverse frames by `pc`
alone, exactly as established by `ArithmeticAssignment` (M2.6) and
`SwapInstruction` (M2.7).

# Structural inverse vs. dispatch-level inverse

The *structural* inverse of a `BeginInstruction` is an
`EndInstruction` (and vice versa) — running a subroutine backwards
swaps entry-marker for exit-marker. **That conversion happens at
the IR-graph level**, in M2.15's `BasicBlock.reversed()` pass,
which rewrites the instruction stream rather than re-dispatching
the same instruction. At the per-instruction dispatch level (this
file), both classes are `pc`-bumpers; they do not "become" each
other under `inverse()`.

This distinction matters because a future agent might be tempted
to make `inverse(::BeginInstruction, ...)` *return* a different
instruction type, or mutate `locals` to "undo a bind that never
happened" — both would be wrong. The dispatch layer is local; the
graph-level rewrite is the right home for the Begin↔End flip.

# Ref

  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations rows 7 and 8 —
    the RC3 `BeginInstruction` / `EndInstruction` table entries
    and the `reverse() → EndInstruction` / `reverse() →
    BeginInstruction` decisions (load-bearing for M2.15).
  * `bennettvm_prd.md` (PRD v4) §3.1 — RSSA instruction taxonomy
    listing subroutine entry/exit as part of the twelve-class
    set.
  * `src/ir/instructions.jl` (M2.4) — defines `Instruction` and
    `ControlInstruction` abstract types. This file does NOT
    redefine them.
  * `src/ir/swap_instruction.jl` (M2.7) — the structural template
    for "injective instruction, no history needed". Begin/End
    inherit the same `inverse(_, _, prev)` signature with `prev`
    documented as unused.
  * CLAUDE.md Rule 11 (literate docstrings); Rule 1 (fail loud —
    here satisfied trivially: no degenerate cases at this layer).
"""

"""
    BeginInstruction <: ControlInstruction

Subroutine-entry marker (RC3 `begin l(x,...)`; ADR 0001 §Observations
row 7). Carries the subroutine `label` and the formal-parameter list
`params` as metadata only — `forward` and `inverse` do not bind
params into `s.locals`; that transfer is `CallInstruction`'s job
(M2.14). See this file's top-of-module docstring for the full
scoping rationale.

  * `label::Symbol` — the subroutine name (RC3 `l`). Pairing with
    a matching `EndInstruction` carrying the same `label` is the
    caller's responsibility (verified at M2.15 `BasicBlock`
    validation).
  * `params::Vector{Symbol}` — SSA names of the formal parameters.
    Empty vector legal (a no-arg `main`).
"""
struct BeginInstruction <: ControlInstruction
    label::Symbol
    params::Vector{Symbol}
end

"""
    EndInstruction <: ControlInstruction

Subroutine-exit marker (RC3 `end l(y,...)`; ADR 0001 §Observations
row 8). Carries the subroutine `label` and the return-value list
`returns` as metadata only — `forward` and `inverse` do not unbind
returns from `s.locals`; that transfer is `CallInstruction`'s job
(M2.14). See this file's top-of-module docstring for the full
scoping rationale.

  * `label::Symbol` — the subroutine name; MUST match the paired
    `BeginInstruction`'s `label` (caller-responsibility; verified
    at M2.15 `BasicBlock` validation).
  * `returns::Vector{Symbol}` — SSA names of the values being
    returned. Empty vector legal (a void-returning subroutine).
"""
struct EndInstruction <: ControlInstruction
    label::Symbol
    returns::Vector{Symbol}
end

"""
    forward(instr::BeginInstruction, s::IState) -> IState

Bump `pc` by 1 and return `s`. `locals` and `status` untouched —
the subroutine-entry semantics live at the call site
(`CallInstruction`, M2.14), not at the marker. See this file's
top-of-module docstring.
"""
function forward(instr::BeginInstruction, s::IState)::IState
    s.pc += 1
    return s
end

"""
    forward(instr::EndInstruction, s::IState) -> IState

Bump `pc` by 1 and return `s`. `locals` and `status` untouched —
the subroutine-exit semantics live at the call site
(`CallInstruction`, M2.14), not at the marker.
"""
function forward(instr::EndInstruction, s::IState)::IState
    s.pc += 1
    return s
end

"""
    inverse(instr::BeginInstruction, s::IState, prev) -> IState

Decrement `pc` by 1 and return `s`. `prev` is unused (Begin/End are
injective at the dispatch layer; no history record is ever pushed
for them — see this file's top-of-module docstring on "structural
inverse vs. dispatch-level inverse").
"""
function inverse(instr::BeginInstruction, s::IState, prev)::IState
    s.pc -= 1
    return s
end

"""
    inverse(instr::EndInstruction, s::IState, prev) -> IState

Decrement `pc` by 1 and return `s`. `prev` is unused (Begin/End are
injective at the dispatch layer; no history record is ever pushed
for them).
"""
function inverse(instr::EndInstruction, s::IState, prev)::IState
    s.pc -= 1
    return s
end
