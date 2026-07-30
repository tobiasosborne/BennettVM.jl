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
to *bind* its `params` into `active_locals(s)` on entry, and `EndInstruction`
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
params into `active_locals(s)`; that transfer is `CallInstruction`'s job
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
returns from `active_locals(s)`; that transfer is `CallInstruction`'s job
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
        # RETAINED, behaviour unchanged. This is a BLOCK-EXIT arg list, not a
        # CALL arg list: `src/ir/ingest.jl` (the const-sharing comment) mints a
        # FRESH name for every repeated φ-incoming within one edge, so this
        # never fires on a real lowering, and removing it would perturb pinned
        # `Define` counts (ADR 0022 §Decision). The sibling `CallEnter` check
        # WAS removed (ADR 0023 / bead `bennettvm-0fw7`) because calls COPY
        # their args; relaxing this one is a separate, independent change.
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

# =============================================================================
# M2.10 — ConditionalEntry / ConditionalExit  (bd `bennettvm-du4`)
# =============================================================================

"""
    ConditionalEntry / ConditionalExit (M2.10)

The fifth and sixth concrete `ControlInstruction` subtypes — rows 11
and 12 of `docs/adr/0001-rc3-rvm-smoke.md` §Observations (RC3
`ConditionalEntry` / `ConditionalExit`; candidate names `CondEntry` /
`CondExit`). These complete the RSSA twelve-class control-flow group:
M2.8 covered subroutine markers (Begin/End), M2.9 covered the
*unconditional* basic-block markers, and **M2.10 covers the
predicate-bearing pair** that makes branching reversible without a
history tape.

# φ-nodes appear at splits AND joins — this is the load-bearing lesson

Classical SSA places φ-nodes only at **joins** — points where two
predecessor blocks flow into one successor and the φ records which
predecessor supplied each value. Mogensen 2016 §3 RSSA places
φ-equivalents at **both splits AND joins**, because under the
reverse dispatch:

  * Forward execution sees a **split** at `ConditionalExit` — two
    possible targets (`l1` / `l2`) chosen by the predicate `c`.
  * Backward execution sees a **join** at `ConditionalExit` — control
    came from either `l1` or `l2`, recovered via the very same `c`.
  * Forward execution sees a **join** at `ConditionalEntry` — control
    came from one of two predecessors (`l1` / `l2`); the predicate
    tells us which.
  * Backward execution sees a **split** at `ConditionalEntry` —
    depart toward either `l1` or `l2` based on `c`.

Because the predicate `c` is **the same SSA symbol** referenced by
both halves of the Entry/Exit pair, and that symbol is **live in
locals** at the moment of every transition, the pair is invertible
*without a history record*. This is the structural reason RSSA does
not need a per-instruction history tape (ADR 0001 §Observations
Structural-Pattern point 1): join points "remember" the predecessor
because the predicate value that selected the branch is still in
scope when the dual dispatch arrives. ADR 0001 §Observations
Structural-Pattern point 2 records the same fact:

> φ-nodes appear at BOTH splits AND joins (Mogensen 2016 §3 —
> directly confirmed). `ConditionalExit` is the split: predicate +
> two target labels. `ConditionalEntry` is the join: predicate +
> two source labels, and the entry asserts which source the control
> came from. The assertion is what makes RSSA invertible — join
> points are not "lossy" because they record the predicate.

CLAUDE.md hallucination-risk callout: *"RSSA φ-nodes appear on
splits AND joins."* This file is the place that fact is encoded; if
you find yourself thinking "φ is just a join construct" you are
applying the classical-SSA intuition to RSSA and will produce
un-invertible IR.

# Field-order rationale — mirror the RC3 source syntax

The RC3 source forms (ADR 0001 §Observations table rows 11 / 12) are:

  * `ConditionalEntry`: `l1(x,...)l2 <- c` — *"this block joins from
    `l1` if `c` is true, else from `l2`"*. The label `l1` (true
    predecessor) appears leftward of `l2` (false predecessor); both
    sit *before* the `<-` arrow; the predicate `c` follows the arrow.
  * `ConditionalExit`: `c -> l1(y,...)l2` — *"branch from this block
    to `l1` if `c` is true, else to `l2`"*. The predicate `c` leads;
    the arrow `->` separates it from the target pair; `l1` (true
    target) sits leftward of `l2` (false target).

The struct field order — `predecessor_true` before `predecessor_false`
on `ConditionalEntry`, and `target_true` before `target_false` on
`ConditionalExit` — is chosen to mirror this leftward-of pairing.
The mnemonic "true-branch on the left" is **the same convention** as
RC3's source form; do not flip it on a hunch.

The predicate-symbol-as-a-`Symbol` (rather than embedded in the
target / predecessor pair) is also deliberate: the predicate is a
*reference* into `locals`, not a structural feature of the branch.
At dispatch (M3.x), the interpreter consults `active_locals(s)[condition]`
and chooses between `target_true` / `target_false` (forward) or
`predecessor_true` / `predecessor_false` (backward). The pair is
positional; the symbol is by-name.

# Forward / inverse semantics — pc-only at this layer

The conditional branch's *dispatch* — consulting `active_locals(s)[condition]`
to pick the target (forward) or predecessor (backward) and relocating
`pc` to the destination block's first instruction — is the **M3.x
interpreter's** responsibility, using the M2.16 `LabelTable`. At the
per-instruction layer (this file), `ConditionalEntry` and
`ConditionalExit` are pc-only markers, matching the established
M2.8 / M2.9 pattern:

```
forward(::ConditionalEntry, s) → s with s.pc += 1
forward(::ConditionalExit,  s) → s with s.pc += 1
inverse(::ConditionalEntry, s, _) → s with s.pc -= 1
inverse(::ConditionalExit,  s, _) → s with s.pc -= 1
```

`prev` is unused on both inverses. These instructions are
structurally injective at this layer because the predicate is live
in `locals` at the moment of the transition — no history record is
ever pushed for either class.

This is intentionally the same pc-only pattern as the M2.8 / M2.9
markers: the cross-block rewrite (Exit ↔ Entry pairing, label
resolution, predicate-driven target selection) belongs at the IR-
graph / interpreter layer, not at the per-instruction dispatch
layer. A future agent tempted to bake `active_locals(s)[condition]` lookup
into `forward` here should stop: the per-instruction layer is local;
the graph-level dispatch is the right home for the conditional
dance.

# Constructor validation (Rule 1)

Light, scoped to the per-instruction layer:

  * `params` (Entry) and `args` (Exit) **may be empty** —
    control-flow-only conditional blocks (predicate-only, no data
    passed) are well-formed RSSA programs.
  * `params` / `args` **must contain unique symbols** — same RSSA
    single-assignment-within-receiver / -sender rule as M2.9.
  * `predecessor_true !== predecessor_false` (Entry) and
    `target_true !== target_false` (Exit) — collapsing both branches
    onto the same label is a degenerate `UnconditionalEntry` /
    `UnconditionalExit` case and must be expressed using those
    classes, not this one. Rejecting the collapse at construction
    time prevents a downstream IR-graph validation pass (M2.15) from
    silently treating a conditional as an unconditional.
  * The predicate `condition` **must NOT appear** in `params`
    (Entry) or `args` (Exit). The predicate is read from existing
    `locals`, not freshly bound on entry / not freshly transferred
    on exit. If `condition` shadowed a name in the param/arg list,
    the dispatch ordering would be ambiguous: is the value read
    before or after the binding? Forbidding the shadow at
    construction time eliminates the ambiguity. (Cross-block
    constraints — that the *same* `condition` symbol must appear
    on the paired Entry and Exit, and that its type must be
    boolean-coercible — are M2.15's responsibility.)

Cross-block invariants (`Exit.target_*` ↔ `Entry.label` /
predecessor-chain matching; `length(params) == length(args)` at
every paired edge; predicate-symbol equality between paired Entry
and Exit) are **not** enforced at this layer — they require seeing
the whole `BasicBlock` graph and are M2.15's responsibility.

# Structural inverse vs. dispatch-level inverse

The *structural* inverse of a `ConditionalEntry` is a
`ConditionalExit` (and vice versa) — running a conditional branch
backwards swaps join-with-predicate for split-with-predicate, with
the same predicate symbol and a positional swap of the target /
predecessor pair. **That conversion happens at the IR-graph level**,
in M2.15's `BasicBlock.reversed()` pass, which rewrites the
instruction stream rather than re-dispatching the same instruction.
At the per-instruction dispatch level (this file), both classes are
`pc`-bumpers; they do not "become" each other under `inverse()`.

Same caveat as M2.8 / M2.9: a future agent tempted to make
`inverse(::ConditionalEntry, ...)` *return* a different instruction
type, or mutate `locals` to "undo the predicate read", would be
wrong. The dispatch layer is local; the graph-level rewrite is the
right home for the Entry↔Exit flip.

# Ref

  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations rows 11 and 12 —
    the RC3 `ConditionalEntry` / `ConditionalExit` table entries
    and the `reverse() → ConditionalExit` / `reverse() →
    ConditionalEntry` decisions (load-bearing for M2.15).
  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations Structural-
    Pattern point 2 — "φ-nodes appear at BOTH splits AND joins
    (Mogensen 2016 §3 — directly confirmed)". The conceptual
    grounding for this file.
  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations note 3 / 4 —
    block-level instruction-count swap and the
    conditional-entry/exit dispatch as the load-bearing primitive;
    the LabelTable mechanism that resolves the predicate-driven
    target / predecessor in both directions (M2.16 + M3.x).
  * `bennettvm_prd.md` (PRD v4) §3.1 — RSSA instruction taxonomy
    listing conditional block entry/exit as part of the twelve-
    class set.
  * `src/ir/instructions.jl` (M2.4) — defines `Instruction` and
    `ControlInstruction` abstract types.
  * `src/ir/control_instructions.jl` M2.9 block above — the
    Uncond entry/exit pair this file completes the
    conditional-flavoured counterpart to; the file-level
    cohesion neighbour and the pc-only-dispatch template.
  * CLAUDE.md hallucination-risk callout: *"RSSA φ-nodes appear on
    splits AND joins."* — the textbook lesson this struct pair
    embodies.
"""

"""
    ConditionalEntry <: ControlInstruction

Conditional basic-block entry marker (RC3 `l1(x,...)l2 <- c`; ADR
0001 §Observations row 11). A join point with a live predicate: the
block was entered from `predecessor_true` if `condition` evaluated
true, otherwise from `predecessor_false`. The same `condition`
symbol appears on the paired predecessor `ConditionalExit`,
allowing backward dispatch to recover the predecessor without a
history record. See this file's M2.10 block docstring for the
"φ-nodes appear at splits AND joins" narrative and the field-order
rationale.

  * `label::Symbol` — this block's own identity. Matched against
    the `target_true` / `target_false` field of each paired
    predecessor `ConditionalExit` at the M3.x interpreter layer.
  * `params::Vector{Symbol}` — SSA names of the formal parameters
    bound on block entry (RC3 `BasicBlockReceiver` semantics).
    Aligned positionally with each predecessor's
    `ConditionalExit.args`. Empty vector legal.
  * `predecessor_true::Symbol` — the predecessor block's label
    when `condition` is true (RC3 `l1`). Field-order rationale:
    "true-branch on the left", mirroring the RC3 source form
    `l1(x,...)l2 <- c`.
  * `predecessor_false::Symbol` — the predecessor block's label
    when `condition` is false (RC3 `l2`). Must differ from
    `predecessor_true` (else the block is a degenerate
    `UnconditionalEntry`).
  * `condition::Symbol` — SSA name of the predicate (lives in
    `locals` at every transition). Must NOT appear in `params`
    (shadowing forbidden — see Constructor-validation in the file
    docstring).
"""
struct ConditionalEntry <: ControlInstruction
    label::Symbol
    params::Vector{Symbol}
    predecessor_true::Symbol
    predecessor_false::Symbol
    condition::Symbol

    function ConditionalEntry(label::Symbol,
                              params::Vector{Symbol},
                              predecessor_true::Symbol,
                              predecessor_false::Symbol,
                              condition::Symbol)
        allunique(params) ||
            error("ConditionalEntry: duplicate param names in $(params) ",
                  "(SSA single-assignment-within-receiver violation — the ",
                  "same SSA name cannot be bound twice on block entry)")
        predecessor_true !== predecessor_false ||
            error("ConditionalEntry: predecessor_true and predecessor_false ",
                  "both equal $(predecessor_true) — a conditional join with ",
                  "a single predecessor is degenerate; express it as an ",
                  "UnconditionalEntry instead (M2.10 constructor invariant; ",
                  "see file docstring)")
        !(condition in params) ||
            error("ConditionalEntry: condition symbol $(condition) shadows a ",
                  "param in $(params) — the predicate must be read from ",
                  "existing locals, not freshly bound on entry (M2.10 ",
                  "constructor invariant; see file docstring)")
        return new(label, params, predecessor_true, predecessor_false, condition)
    end
end

"""
    ConditionalExit <: ControlInstruction

Conditional basic-block exit marker (RC3 `c -> l1(y,...)l2`; ADR
0001 §Observations row 12). A split point with a live predicate:
control departs to `target_true` if `condition` evaluates true,
otherwise to `target_false`. The same `condition` symbol appears on
the paired successor `ConditionalEntry`, allowing forward dispatch
to record the predecessor implicitly (the predicate value at the
exit is the same as the value re-read at the entry). See this
file's M2.10 block docstring for the "φ-nodes appear at splits AND
joins" narrative and the field-order rationale.

  * `condition::Symbol` — SSA name of the predicate (lives in
    `locals` at every transition). Must NOT appear in `args`
    (shadowing forbidden — see Constructor-validation in the file
    docstring).
  * `target_true::Symbol` — the successor block's label when
    `condition` is true (RC3 `l1`). Field-order rationale:
    "true-branch on the left", mirroring the RC3 source form
    `c -> l1(y,...)l2`.
  * `target_false::Symbol` — the successor block's label when
    `condition` is false (RC3 `l2`). Must differ from `target_true`
    (else the block is a degenerate `UnconditionalExit`).
  * `args::Vector{Symbol}` — SSA names whose values are passed to
    the chosen successor's `params` (RC3 `BasicBlockSender`
    semantics). Empty vector legal.
"""
struct ConditionalExit <: ControlInstruction
    condition::Symbol
    target_true::Symbol
    target_false::Symbol
    args::Vector{Symbol}

    function ConditionalExit(condition::Symbol,
                             target_true::Symbol,
                             target_false::Symbol,
                             args::Vector{Symbol})
        # RETAINED, behaviour unchanged — same rationale as `UnconditionalExit`
        # above (block-exit args, not call args; ADR 0022 §Decision). ADR 0023
        # relaxed only the `CallEnter` sibling.
        allunique(args) ||
            error("ConditionalExit: duplicate arg names in $(args) ",
                  "(SSA single-assignment-within-sender violation — the ",
                  "same SSA name cannot be sent twice from a block exit)")
        target_true !== target_false ||
            error("ConditionalExit: target_true and target_false both equal ",
                  "$(target_true) — a conditional branch with a single target ",
                  "is degenerate; express it as an UnconditionalExit instead ",
                  "(M2.10 constructor invariant; see file docstring)")
        !(condition in args) ||
            error("ConditionalExit: condition symbol $(condition) shadows an ",
                  "arg in $(args) — the predicate must be read from existing ",
                  "locals, not freshly transferred on exit (M2.10 constructor ",
                  "invariant; see file docstring)")
        return new(condition, target_true, target_false, args)
    end
end

"""
    forward(instr::ConditionalEntry, s::IState) -> IState

Bump `pc` by 1 and return `s`. `locals` and `status` untouched —
the conditional join's predicate-driven predecessor recovery
(consulting `active_locals(s)[instr.condition]` to verify which of
`predecessor_true` / `predecessor_false` the control arrived from)
lives in M3.x's interpreter, NOT at this per-instruction layer
(see this file's M2.10 block docstring).
"""
function forward(instr::ConditionalEntry, s::IState)::IState
    # Cross-block dispatch via LabelTable + predicate lookup lands in
    # M3.x's interpreter; this layer only advances the pc.
    s.pc += 1
    return s
end

"""
    forward(instr::ConditionalExit, s::IState) -> IState

Bump `pc` by 1 and return `s`. `locals` and `status` untouched —
the conditional split's predicate-driven target selection
(consulting `active_locals(s)[instr.condition]` to choose `target_true` vs
`target_false`) is M3.x's job; this layer only advances the pc.
"""
function forward(instr::ConditionalExit, s::IState)::IState
    # Cross-block dispatch via LabelTable + predicate lookup lands in
    # M3.x's interpreter; this layer only advances the pc.
    s.pc += 1
    return s
end

"""
    inverse(instr::ConditionalEntry, s::IState, prev) -> IState

Decrement `pc` by 1 and return `s`. `prev` is unused (Cond
entry/exit are injective at the dispatch layer because the
predicate is live in `locals` at the moment of the transition; no
history record is ever pushed for them — see this file's M2.10
block docstring on the pc-only / cross-block-dispatch-deferred-to-
M3.x design).
"""
function inverse(instr::ConditionalEntry, s::IState, prev)::IState
    s.pc -= 1
    return s
end

"""
    inverse(instr::ConditionalExit, s::IState, prev) -> IState

Decrement `pc` by 1 and return `s`. `prev` is unused.
"""
function inverse(instr::ConditionalExit, s::IState, prev)::IState
    s.pc -= 1
    return s
end
