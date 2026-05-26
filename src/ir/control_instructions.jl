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

# =============================================================================
# M2.9 — UnconditionalEntry / UnconditionalExit  (bd `bennettvm-08q`)
# =============================================================================

"""
    UnconditionalEntry / UnconditionalExit (M2.9)

The third and fourth concrete `ControlInstruction` subtypes — rows 9
and 10 of `docs/adr/0001-rc3-rvm-smoke.md` §Observations (RC3
`UnconditionalEntry` / `UnconditionalExit`; candidate names
`UncondEntry` / `UncondExit`). These are **basic-block** entry and
exit markers, in contrast to the M2.8 **subroutine** markers
(`BeginInstruction` / `EndInstruction`). Both extend the
`ControlInstruction` intermediate defined at M2.4 in
`src/ir/instructions.jl`.

# Bead-vs-ADR reconciliation: NO source-label encoding on Entry

The M2.9 bead (`bennettvm-08q`) description claimed that
`UnconditionalEntry` "carries the predecessor label (enabling
backward traversal without history). This is the source-label
encoding that makes jumps reversible — Ref: BobISA
(Axelsen-Yokoyama 2011)." **That claim is wrong** and is corrected
here:

  * ADR 0001 §Observations decision-table row "Source-label jumps"
    reads verbatim: **"NO. Use paired entry/exit with `lastLabel`-
    style runtime check."**
  * The ADR §Observations narrative makes the point sharper:
    "*Unconditional jumps do NOT encode the source label. … RC3 is
    following **Mogensen RSSA**, not BobISA.*" (See ADR lines
    467–479.)
  * Phase-2 BennettVM follows RC3, which follows Mogensen RSSA.
    `UnconditionalExit` carries only the *target* label `l`;
    `UnconditionalEntry` carries only its *own* block's label and
    the receiver list. Predecessor recovery is structural, not
    field-based — see "How reversibility actually works" below.

The bead text was inherited from an earlier draft that mis-cited
BobISA; this struct definition follows the ratified ADR. A future
agent reading the bead and reaching for a `predecessor::Symbol`
field on `UnconditionalEntry` should stop here and re-read the ADR.

# How reversibility actually works (without a source-label field)

When the interpreter (M3.x) steps backwards across a basic-block
boundary — i.e., `pc -= 1` past the start of a block whose first
instruction is an `UnconditionalEntry` — it necessarily lands at
the *end* of some predecessor block, which is necessarily an
`UnconditionalExit` (or `ConditionalExit`, M2.10) whose
`target::Symbol` field matches the current block's `label`. This
**structural pairing** between Exit.target and Entry.label — not a
field on Entry — is what makes the IR invertible.

The runtime mechanism that exploits this pairing is the
`LabelTable` lookup at the M3.x interpreter layer (analogous to
RC3's `lastLabel` check at `RSSAVM.java:595-597, 720-721`):
backward dispatch on an Entry consults the table for "which Exit
points here?", forward dispatch on an Exit consults the table for
"where is this target's Entry?". M2.9 just defines the structs;
the cross-block dispatch lands in M3.x.

# Field-naming distinction: `params` vs `args`

`UnconditionalEntry` carries `params::Vector{Symbol}` — the
*receiving* side: the formal parameters bound on block entry, in
the same positional sense as RC3's `BasicBlockReceiver` operand
list.

`UnconditionalExit` carries `args::Vector{Symbol}` — the
*passing* side: the SSA names whose values are transferred to the
destination block's `params` at the moment of jump. RC3 spells
this side `BasicBlockSender`.

The asymmetric naming (params on Entry, args on Exit) is
deliberate: it mirrors the function-call convention every Julia
reader is familiar with — formal *params* in the callee, actual
*args* at the call site — and the M3.x interpreter relies on the
asymmetry to align the two ends of a jump positionally:
`Entry.params[i]` receives the value previously bound to
`Exit.args[i]` for `i = 1:length(params)`.

  * `UnconditionalEntry(label, params)` ↔ RC3 `l(x,...) <-`.
  * `UnconditionalExit(target, args)`   ↔ RC3 `-> l(y,...)`.

Empty `params` / `args` are **legal**: control-flow-only blocks
(e.g., an unconditional join with no data passed) are well-formed
RSSA programs and must remain constructable.

# Forward / inverse semantics — pc-only at this layer

Per ADR 0001 row 9/10 ("Reversible via: paired entry/exit at
matching label"), the dispatch-level forward / inverse are
deliberately pc-only:

```
forward(::UnconditionalEntry, s) → s with s.pc += 1
forward(::UnconditionalExit,  s) → s with s.pc += 1
inverse(::UnconditionalEntry, s, _) → s with s.pc -= 1
inverse(::UnconditionalExit,  s, _) → s with s.pc -= 1
```

`prev` is unused on both inverses: these instructions are
injective at this layer (no `locals` are touched). The cross-block
dispatch — consulting `UnconditionalExit.target` to look up the
destination block, consulting `LabelTable` for predecessor
recovery on Entry — lands in M3.x's interpreter, NOT here.

This is intentionally the same pc-only pattern as M2.8
`BeginInstruction` / `EndInstruction`: the structural rewrite
(Exit ↔ Entry pairing across block boundaries) belongs at the
IR-graph layer (M2.15 `BasicBlock.reversed()`), not at the
per-instruction dispatch layer (this file). A future agent
tempted to bake the LabelTable lookup into `forward` should stop:
the per-instruction layer is local; the graph-level rewrite is
the right home for the cross-block dance.

# Constructor validation (Rule 1)

Light, scoped to the per-instruction layer:

  * `params` / `args` **may be empty** (legal — control-flow-only
    block).
  * `params` / `args` **must contain unique symbols** — within the
    list, no two slots may name the same SSA value. This is the
    RSSA single-assignment-within-a-receiver rule: the same name
    cannot be bound twice on block entry, and the same value cannot
    be sent twice from a block exit. Violations fail loud at
    construction time, in the same shape as `SwapInstruction`
    (M2.7).
  * Cross-block invariants (`Exit.target` ↔ `Entry.label`
    matching; `length(params) == length(args)` at every paired
    edge; type compatibility) are **not** enforced at the
    per-instruction layer — they require seeing the whole
    `BasicBlock` graph and are M2.15's responsibility.

# Ref

  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations rows 9 and 10 —
    the RC3 `UnconditionalEntry` / `UnconditionalExit` table
    entries.
  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations decision-table
    row "Source-label jumps" and the surrounding narrative
    ("Unconditional jumps do NOT encode the source label…") — the
    ratification that overrides the M2.9 bead's mis-citation of
    BobISA.
  * `bennettvm_prd.md` (PRD v4) §3.1 — RSSA instruction taxonomy
    listing block entry/exit as part of the twelve-class set.
  * `src/ir/instructions.jl` (M2.4) — defines `Instruction` and
    `ControlInstruction` abstract types.
  * `src/ir/swap_instruction.jl` (M2.7) — template for the inner-
    constructor uniqueness check.
  * `src/ir/control_instructions.jl` Begin/End block above
    (M2.8) — the file-cohesion neighbour and the pc-only-dispatch
    template.
  * CLAUDE.md hallucination-risk callout: *"BobISA jumps encode
    the source label"* — true in BobISA, NOT true in BennettVM.
"""

"""
    UnconditionalEntry <: ControlInstruction

Basic-block entry marker (RC3 `l(x,...) <-`; ADR 0001 §Observations
row 9). Carries the block's own `label` (its identity, not the
predecessor's — see the file-level docstring for the bead-vs-ADR
reconciliation) and the formal-parameter list `params` populated by
the preceding `UnconditionalExit`. Forward and inverse are pc-only
at this dispatch layer; cross-block jump resolution lands in
M3.x's interpreter via the `LabelTable`.

  * `label::Symbol` — this block's own identity. Matched against
    the `target::Symbol` field of the predecessor's
    `UnconditionalExit` (or `ConditionalExit`) at the M3.x
    interpreter layer; not at this per-instruction layer.
  * `params::Vector{Symbol}` — SSA names of the formal parameters
    bound on block entry (RC3 `BasicBlockReceiver` semantics).
    Aligned positionally with the predecessor's
    `UnconditionalExit.args`. Empty vector legal.
"""
struct UnconditionalEntry <: ControlInstruction
    label::Symbol
    params::Vector{Symbol}

    function UnconditionalEntry(label::Symbol, params::Vector{Symbol})
        allunique(params) ||
            error("UnconditionalEntry: duplicate param names in $(params) ",
                  "(SSA single-assignment-within-receiver violation — the ",
                  "same SSA name cannot be bound twice on block entry)")
        return new(label, params)
    end
end

"""
    UnconditionalExit <: ControlInstruction

Basic-block exit marker (RC3 `-> l(y,...)`; ADR 0001 §Observations
row 10). Carries the destination block's `target` label and the
`args` list whose values are transferred (positionally) to the
destination's `UnconditionalEntry.params`. Forward and inverse are
pc-only at this dispatch layer; the actual cross-block jump (PC
relocation to the destination block's first instruction) is
resolved by the M3.x interpreter's `LabelTable` lookup, NOT here.

  * `target::Symbol` — the destination block's label. Matched
    against the destination `UnconditionalEntry.label` at M3.x.
  * `args::Vector{Symbol}` — SSA names whose values are passed to
    the destination's `params` (RC3 `BasicBlockSender` semantics).
    Empty vector legal.
"""
struct UnconditionalExit <: ControlInstruction
    target::Symbol
    args::Vector{Symbol}

    function UnconditionalExit(target::Symbol, args::Vector{Symbol})
        allunique(args) ||
            error("UnconditionalExit: duplicate arg names in $(args) ",
                  "(SSA single-assignment-within-sender violation — the ",
                  "same SSA name cannot be sent twice from a block exit)")
        return new(target, args)
    end
end

"""
    forward(instr::UnconditionalEntry, s::IState) -> IState

Bump `pc` by 1 and return `s`. `locals` and `status` untouched —
cross-block dispatch via `LabelTable` lookup lands in M3.x's
interpreter, NOT at this per-instruction layer (see this file's
M2.9 block docstring).
"""
function forward(instr::UnconditionalEntry, s::IState)::IState
    # Cross-block dispatch via LabelTable lookup lands in M3.x's
    # interpreter; UnconditionalEntry's `label` field is consulted
    # there (for predecessor recovery on backward steps), not at
    # this dispatch level.
    s.pc += 1
    return s
end

"""
    forward(instr::UnconditionalExit, s::IState) -> IState

Bump `pc` by 1 and return `s`. `locals` and `status` untouched —
cross-block dispatch via `LabelTable` lookup of `instr.target` is
M3.x's job; this layer only advances the pc.
"""
function forward(instr::UnconditionalExit, s::IState)::IState
    # Cross-block dispatch via LabelTable lookup lands in M3.x's
    # interpreter; UnconditionalExit's `target` field is consulted
    # there, not at this dispatch level.
    s.pc += 1
    return s
end

"""
    inverse(instr::UnconditionalEntry, s::IState, prev) -> IState

Decrement `pc` by 1 and return `s`. `prev` is unused (Uncond
entry/exit are injective at the dispatch layer; no history record
is ever pushed for them — see this file's M2.9 block docstring on
the pc-only / cross-block-dispatch-deferred-to-M3.x design).
"""
function inverse(instr::UnconditionalEntry, s::IState, prev)::IState
    s.pc -= 1
    return s
end

"""
    inverse(instr::UnconditionalExit, s::IState, prev) -> IState

Decrement `pc` by 1 and return `s`. `prev` is unused.
"""
function inverse(instr::UnconditionalExit, s::IState, prev)::IState
    s.pc -= 1
    return s
end
