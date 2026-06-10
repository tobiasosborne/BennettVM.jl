"""
    SwapInstruction (M2.7)

The second concrete RSSA instruction in BennettVM's twelve-subclass
taxonomy (`docs/adr/0001-rc3-rvm-smoke.md` §Observations, row 2:
RC3 `SwapInstruction` / candidate name `RegSwap`). Implements the
RC3 four-field register-exchange form

    x, y := z, w

where `target1` (`x`) and `target2` (`y`) are *created* SSA names
that receive the values previously held by `source1` (`z`) and
`source2` (`w`) respectively, while `source1` and `source2` are
*destroyed* (removed from `active_locals(s)`). This is the canonical example
of an *injective* instruction — its inverse swaps the (target,
source) pairs and uses no history record. `is_injective` (wired in
M6.1) returns `true` for this type.

# Bead-vs-RC3 reconciliation: the four-field form

Some earlier bead text (`bennettvm-ti3` DESCRIPTION) described the
instruction as carrying *two* fields (`target1, target2`), with the
implication that the same two SSA names appear on both sides of the
`:=`. That two-field framing is convenient shorthand but is **not
SSA-faithful** and is **not the RC3 form**. RSSA — like every SSA
variant — disallows reassignment to an existing name, so the
"degenerate swap two existing vars" reading does not exist at this
IR layer: every register exchange materialises two fresh SSA names
on the LHS, destroying the two on the RHS. This file therefore
adopts the **four-field RC3 form** `x, y := z, w`, matching ADR 0001
§Observations row 2 verbatim.

The two-field reading is recoverable as the special case where
lowering produces `target1 = source2` AND `target2 = source1`
(i.e. `x, y := y, x`); but in SSA you cannot refer to `y` and
assign to `y` in the same instruction, so even that special case
must rename. Lowering passes that want "exchange in place" emit
`x, y := z, w` with fresh `x`/`y` names and rely on register
allocation (post-IR) to coalesce.

# Field convention — read carefully

`x, y := z, w` is *positional*: `x` (target1) gets `z`'s (source1)
value; `y` (target2) gets `w`'s (source2) value. This is the
order RC3's `SwapInstruction.execute()` uses (cross-checked
against the RC3 sample). The struct field convention is therefore:

  * `target1` (x) ← old value of `source1` (z)
  * `target2` (y) ← old value of `source2` (w)

Misreading this as `target1 ← source2` is the most likely user
error; the field docstrings below repeat the convention so that
code-completion tooltips carry it.

# Why this is the prototypical "no history" instruction

`SwapInstruction` is injective: forward execution loses no
information, because `(z, w) → (x, y)` is a bijection — the pair
of values is preserved, only the names change. The inverse
reconstruction is structural: read `active_locals(s)[target1]` and
`active_locals(s)[target2]`, recreate `source1` / `source2` with those
values, delete the targets. **No `prev` argument is ever consulted,
and `step!` (M3.x) never pushes a history entry for a
SwapInstruction.** This is the M6.1 "no history needed" property
that the min-cut delta-history analysis (M7) relies on to avoid
budgeting history slots for injective instructions.

ADR 0001 §Observations decision table row "Reversible via" pins
this for row 2 ("Self-inverse via target↔source swap"); the
inverse method below implements that swap literally.

# Constructor validation (Rule 1)

The constructor rejects three degenerate cases at construction
time, on the principle that reversibility violations must fail at
the earliest possible moment:

  1. `target1 === target2` — only one fresh name is materialised;
     one of `source1`/`source2`'s values would be lost.
  2. `source1 === source2` — only one source value is read; one of
     `target1`/`target2` would be uninitialised.
  3. Any target name equals any source name — SSA single-assignment
     violation. The name on the LHS cannot also be on the RHS,
     because every SSA name has exactly one defining instruction.

These are not "user errors to be diagnosed by a linter"; they are
structural impossibilities at the IR layer, and Rule 1 demands
they fail loud here rather than be caught by a downstream
property test.

# pc symmetry

`forward` sets `s.pc += 1`; `inverse` sets `s.pc -= 1`. Matches the
per-step ±1 symmetry established by `ArithmeticAssignment` (M2.6)
and required by the M3.x `RState`-level round-trip tests, which
align forward and inverse frames by `pc` alone.

# Ref

  * `references/PRD-v4.md` §3.2 (injective classification —
    SwapInstruction is the prototypical injective instruction);
    §3.1 (RSSA instruction taxonomy).
  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations row 2
    (`SwapInstruction` / `x, y := z, w` / "Self-inverse via
    target↔source swap").
  * RC3 source: `src/main/java/.../instances/SwapInstruction.java`
    — the analogue this class mirrors. Behaviour cross-checked
    against RC3 `SwapInstruction.execute()` and `reverse()`.
  * CLAUDE.md Rule 1 — constructor validates inputs; degenerate
    cases fail loud at construction time.
"""
struct SwapInstruction <: Instruction
    target1::Symbol    # x — created; receives the OLD value of source1 (z)
    target2::Symbol    # y — created; receives the OLD value of source2 (w)
    source1::Symbol    # z — destroyed; its value moves to target1 (x)
    source2::Symbol    # w — destroyed; its value moves to target2 (y)

    function SwapInstruction(target1::Symbol, target2::Symbol,
                             source1::Symbol, source2::Symbol)
        target1 === target2 &&
            error("SwapInstruction: target1 === target2 (= $(target1)); ",
                  "would materialise only one fresh SSA name and lose ",
                  "one source value")
        source1 === source2 &&
            error("SwapInstruction: source1 === source2 (= $(source1)); ",
                  "would read only one source and leave one target ",
                  "uninitialised")
        (target1 === source1 || target1 === source2 ||
         target2 === source1 || target2 === source2) &&
            error("SwapInstruction: SSA single-assignment violation — ",
                  "target name $((target1, target2)) overlaps source name ",
                  "$((source1, source2)); RSSA forbids re-defining an ",
                  "existing SSA name")
        return new(target1, target2, source1, source2)
    end
end

"""
    forward(instr::SwapInstruction, s::IState) -> IState

Execute `x, y := z, w` in-place on `s`. Reads `active_locals(s)[source1]`
and `active_locals(s)[source2]`, deletes both, writes the values into
`active_locals(s)[target1]` and `active_locals(s)[target2]` respectively, and
bumps `pc`. Two reads, two deletes, two creates.

The four-field form means the assignment is **positional**:
`target1` receives `source1`'s value, `target2` receives
`source2`'s value. (Misreading this as "target1 receives
source2's value" would still typecheck but would silently break
the round-trip invariant under any lowering that uses the
non-degenerate four-field form.)
"""
function forward(instr::SwapInstruction, s::IState)::IState
    v1 = active_locals(s)[instr.source1]
    v2 = active_locals(s)[instr.source2]
    delete!(active_locals(s), instr.source1)
    delete!(active_locals(s), instr.source2)
    active_locals(s)[instr.target1] = v1
    active_locals(s)[instr.target2] = v2
    s.pc += 1
    return s
end

"""
    inverse(instr::SwapInstruction, s::IState, prev) -> IState

Undo a previous `forward` on `instr`. Structurally reversible —
the inverse swaps the (target, source) roles: read
`active_locals(s)[target1]` / `active_locals(s)[target2]`, delete the targets,
recreate `source1` / `source2` with those values, decrement `pc`.

The `prev` argument is part of the dispatch signature (M2.4
convention) but is **unused** — `SwapInstruction` is injective,
no history record is ever pushed for it (M6.1
`is_injective(SwapInstruction) = true`), and the caller is free
to pass `nothing`. See this file's top-of-module docstring for
the "no history needed" rationale.
"""
function inverse(instr::SwapInstruction, s::IState, prev)::IState
    v1 = active_locals(s)[instr.target1]
    v2 = active_locals(s)[instr.target2]
    delete!(active_locals(s), instr.target1)
    delete!(active_locals(s), instr.target2)
    active_locals(s)[instr.source1] = v1
    active_locals(s)[instr.source2] = v2
    s.pc -= 1
    return s
end
