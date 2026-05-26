"""
    BasicBlock + reversed() (M2.15)

The unit of RSSA program structure: a single straight-line code segment
bracketed by exactly one control-flow entry marker and exactly one
control-flow exit marker. M2.15 introduces the struct, its
construction-time invariants (Rule 1), and the block-level structural
inverse `reversed(::BasicBlock)` that the pebble-game compute /
uncompute pass (M9) consumes. Concrete `BasicBlock` graphs are
assembled into a callable program at M2.17 (`VMProgram`) and dispatched
at M3.x (the interpreter); this file lays the type foundation only.

# Why explicit `entry` / `exit` fields, not first/last of `instructions`

A defensible alternative shape is `struct BasicBlock{label, instructions}`,
with `entry = first(instructions)` and `exit = last(instructions)` by
convention. We reject that shape for three reasons:

  1. **Type-level clarity.** The Julia type system can constrain `entry`
     and `exit` to `<: ControlInstruction`, but it cannot constrain
     `first(instructions)` / `last(instructions)` likewise. The
     explicit fields make the contract visible in the struct
     definition.
  2. **Constructor validation in one place.** With `entry` and `exit`
     as fields, the inner constructor checks (a) `entry` is one of
     {`BeginInstruction`, `UnconditionalEntry`, `ConditionalEntry`},
     (b) `exit` is one of {`EndInstruction`, `UnconditionalExit`,
     `ConditionalExit`}, and (c) `instructions` contains NO
     `ControlInstruction`. Three checks, one site, fail-loud per Rule 1.
  3. **Match the M9 pebble pass.** The pebble-game compute / uncompute
     pass (PRD v4 §3.4) operates on entry / exit boundaries by name —
     a block-level "reverse this body" pass that takes
     `bb.instructions` as the work and `bb.entry` / `bb.exit` as the
     stable cross-block-edge metadata. The split is exactly what the
     M9 design wants to consume.

The redundancy (a `BasicBlock`'s `entry` is "first" in execution order
even if it's not the first element of `instructions`) is therefore by
design.

# `reversed(bb)` — the block-level structural inverse

`reversed` is the block-level analogue of each concrete instruction's
`reverse()` in RC3: it returns a new `BasicBlock` whose execution
backward equals `bb`'s execution forward. Specifically, it does
three things simultaneously:

  1. **Reverse the body.** The order of the non-control instructions is
     reversed; each non-control instruction is replaced by its
     structural inverse (`structural_inverse(::Instruction)`).
  2. **Swap entry and exit slots, with structural inversion.** The
     reversed block's `entry` is the structural inverse of the
     forward block's `exit`; the reversed block's `exit` is the
     structural inverse of the forward block's `entry`. The
     instruction-class flip (Entry ↔ Exit) is what makes the swap
     well-formed: `ConditionalExit` inverts to `ConditionalEntry`,
     `UnconditionalExit` inverts to `UnconditionalEntry`,
     `EndInstruction` inverts to `BeginInstruction`, and so on.
  3. **Preserve the label.** A block's `label` is its identity in
     the program-level callgraph — it remains the same in the
     reversed block. Cross-block dispatch (M3.x) recovers the
     predecessor of a forward `bb` from its label, and that lookup
     must still work after reversal.

# Why `structural_inverse(::Instruction)` is distinct from `inverse(...)`

The dispatch-level `inverse(instr::Instruction, s::IState, prev)`
(defined per concrete subtype at M2.6-M2.14) operates on a **live
interpreter state** — it reads `s.locals` / `s.memory`, applies the
dual modop, etc. The IR-graph-level `structural_inverse(instr)`
operates on the **instruction itself**, returning a new `Instruction`
value whose `forward` semantics equal the original's `inverse`
semantics. They are NOT the same function — one is a state
transformer, the other is an IR rewrite.

The distinction matters for the M9 pebble pass: pebble-game lowering
constructs new IR fragments at compile time (no live `IState`
available) by mirroring forward fragments via `structural_inverse`.
At runtime, those mirrored fragments are dispatched the same way as
forward fragments — they just *are* forward fragments now, since the
inversion has been baked into the IR.

# Why label injection for control-flow exits is at the block level

A `ConditionalExit` carries `condition`, `target_true`, `target_false`,
`args` — it does NOT carry the *source* block's label, because the
exit's source is whatever block the exit appears in. When reversing,
the structural inverse of a `ConditionalExit` is a `ConditionalEntry`
that needs a `label` field — and that label is the source block's
label, which the exit does not know about.

`structural_inverse` for control-flow exits therefore cannot be
implemented as a single-argument `(::Instruction) -> Instruction`
function. Two designs are workable:

  (a) Pass the block label as a second argument:
      `structural_inverse(::ConditionalExit, block_label::Symbol)`.
  (b) Handle the entry/exit slots inside `reversed(::BasicBlock)`
      itself, where the block label is in scope. Define helper
      functions `_reverse_exit_to_entry(exit, block_label)` and
      `_reverse_entry_to_exit(entry, block_label)` that produce the
      new entry / new exit with the block label injected where the
      concrete subtype needs it.

This file uses **option (b)**. It keeps `structural_inverse(::Instruction)`
clean (no label argument) and concentrates the label-injection logic
at the only site where the block label is in scope — the
`reversed(::BasicBlock)` body. The 6 non-control instruction
subtypes get module-level `structural_inverse` methods; the 6
control-flow subtypes are handled by the two helper functions.

# Coverage of `structural_inverse` across the twelve instruction subtypes

  Body-only (module-level `structural_inverse`, no label needed):
    * `ArithmeticAssignment` → swap target/source, flip modop via `dual_modop`.
    * `SwapInstruction`      → swap (target1,target2) ↔ (source1,source2).
    * `MemoryAssignment`     → flip modop via `dual_modop`.
    * `MemoryInterchange`    → swap target ↔ source.
    * `MemorySwap`           → self-inverse (returns a new instance for purity).
    * `CallInstruction`      → swap targets ↔ args AND flip `:call ↔ :uncall`.

  Entry/Exit (handled by `_reverse_entry_to_exit` / `_reverse_exit_to_entry`):
    * `BeginInstruction`     ↔ `EndInstruction`.
    * `UnconditionalEntry`   ↔ `UnconditionalExit`.
    * `ConditionalEntry`     ↔ `ConditionalExit`.

# Constructor validation (Rule 1)

The inner constructor rejects three categories of malformed input at
construction time:

  1. `entry` not in {`BeginInstruction`, `UnconditionalEntry`,
     `ConditionalEntry`} — the slot is for an entry-direction control
     marker; a `ConditionalExit` here would be backwards.
  2. `exit` not in {`EndInstruction`, `UnconditionalExit`,
     `ConditionalExit`} — same shape, opposite direction.
  3. `instructions` contains any `ControlInstruction` — control-flow
     markers are structurally required to sit in the entry/exit
     slots; allowing them in the body would create two-headed blocks
     with ambiguous reversed-form construction.

The checks use `isa` against the concrete subtypes; no fragile
string-name match. Per Rule 1, all three categories raise
`ErrorException` carrying the offending value.

# Ref

  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations rows 7-12 — the
    `reverse() → <complement>` decisions per concrete control-flow
    instruction; the load-bearing input for `_reverse_entry_to_exit` /
    `_reverse_exit_to_entry`.
  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations Structural-Pattern
    point 1 — "Reversibility is structural, not historical. … the IR
    layer can use this same trick." `structural_inverse` is that trick
    at the IR-graph layer.
  * `bennettvm_prd.md` (PRD v4) §3.1 — RSSA IR structure: BasicBlock
    is the unit of the program graph.
  * `bennettvm_prd.md` (PRD v4) §3.4 — pebble-game compute / uncompute
    pass consumes `reversed(::BasicBlock)` to materialise the
    backward half of each compute / uncompute pair.
  * RC3 source: `compiler/src/main/java/rc3/rssa/BasicBlock.java`
    `reversed()` method — the direct port template.
  * `src/ir/control_instructions.jl` (M2.8/M2.9/M2.10) — the
    Begin/End, Uncond, and Cond entry/exit pairs that
    `_reverse_entry_to_exit` / `_reverse_exit_to_entry` rewrite.
  * `src/ir/arithmetic_assignment.jl` — `dual_modop` (reused here by
    `ArithmeticAssignment` and `MemoryAssignment` structural
    inverses, per Law 2).
  * CLAUDE.md Rule 1 (constructor validates inputs); Rule 10 (LOC
    budget — this file stays under 200 code-LOC); Rule 11 (literate
    docstrings — this top-of-file block expands the WHY).
"""

"""
    BasicBlock

A single straight-line code segment bracketed by exactly one
control-flow entry marker (`BeginInstruction`, `UnconditionalEntry`, or
`ConditionalEntry`) and exactly one control-flow exit marker
(`EndInstruction`, `UnconditionalExit`, or `ConditionalExit`). The
unit of `VMProgram` structure (M2.17) and the operand of the M9
pebble-game compute / uncompute pass.

  * `label::Symbol` — the block's identity in the program-level
    callgraph. Cross-block dispatch (M3.x) looks blocks up by label.
  * `entry::ControlInstruction` — the inbound control marker. Must
    be a `BeginInstruction`, `UnconditionalEntry`, or
    `ConditionalEntry` (entry-direction subclasses). Enforced at
    construction time.
  * `instructions::Vector{Instruction}` — non-control body. Must NOT
    contain any `ControlInstruction`. Empty vector legal (a pure
    pass-through block whose only purpose is control-flow
    pattern-matching at the IR-graph level).
  * `exit::ControlInstruction` — the outbound control marker. Must
    be an `EndInstruction`, `UnconditionalExit`, or
    `ConditionalExit` (exit-direction subclasses). Enforced at
    construction time.
"""
struct BasicBlock
    label::Symbol
    entry::ControlInstruction
    instructions::Vector{Instruction}
    exit::ControlInstruction

    function BasicBlock(label::Symbol,
                        entry::ControlInstruction,
                        instructions::Vector{Instruction},
                        exit::ControlInstruction)
        # (1) entry must be an entry-direction control marker.
        (entry isa BeginInstruction ||
         entry isa UnconditionalEntry ||
         entry isa ConditionalEntry) ||
            error("BasicBlock: entry slot holds ", typeof(entry),
                  "; must be one of BeginInstruction, UnconditionalEntry, ",
                  "or ConditionalEntry (the three entry-direction ",
                  "ControlInstruction subtypes)")
        # (2) exit must be an exit-direction control marker.
        (exit isa EndInstruction ||
         exit isa UnconditionalExit ||
         exit isa ConditionalExit) ||
            error("BasicBlock: exit slot holds ", typeof(exit),
                  "; must be one of EndInstruction, UnconditionalExit, ",
                  "or ConditionalExit (the three exit-direction ",
                  "ControlInstruction subtypes)")
        # (3) body must contain NO ControlInstruction.
        for (i, instr) in enumerate(instructions)
            instr isa ControlInstruction &&
                error("BasicBlock: instructions[", i, "] is a ",
                      typeof(instr), " (a ControlInstruction subtype); ",
                      "control-flow markers must sit in the entry/exit ",
                      "slots only, not in the body vector")
        end
        return new(label, entry, instructions, exit)
    end
end

# ============================================================================
# structural_inverse — IR-graph-level instruction inversion
# ============================================================================

"""
    structural_inverse(instr::Instruction) -> Instruction

The IR-graph-level inverse of an instruction. Returns a NEW
`Instruction` value whose `forward` semantics equal `instr`'s
`inverse` semantics. Consumed by `reversed(::BasicBlock)` (this file)
and by the M9 pebble-game compute / uncompute pass.

**Distinct from `inverse(instr, s, prev)`** — the latter operates on
a live `IState`; this one operates on the instruction itself, with no
state in scope. See this file's top-of-module docstring on "Why
`structural_inverse` is distinct from `inverse`" for the rationale.

The generic fallback below mirrors the M2.4 sentinel pattern for
`forward` / `inverse`: any concrete `Instruction` subtype reaching
this method is missing its `structural_inverse` definition and fails
loud per Rule 1.

# Coverage

Module-level methods are defined for the six non-control instruction
subtypes (`ArithmeticAssignment`, `SwapInstruction`, `MemoryAssignment`,
`MemoryInterchange`, `MemorySwap`, `CallInstruction`). The six
control-flow subtypes (`BeginInstruction`, `EndInstruction`,
`UnconditionalEntry`, `UnconditionalExit`, `ConditionalEntry`,
`ConditionalExit`) are handled inside `reversed(::BasicBlock)` via
`_reverse_entry_to_exit` / `_reverse_exit_to_entry`, because their
inversion requires the containing block's label as a side input. See
the file's top-of-module docstring "Why label injection for
control-flow exits is at the block level" for why.
"""
function structural_inverse(instr::Instruction)::Instruction
    error("BennettVM: no `structural_inverse` method for instruction ",
          "of type ", typeof(instr),
          ". The six non-control subtypes get module-level methods; ",
          "the six control-flow subtypes are handled inside ",
          "`reversed(::BasicBlock)` via `_reverse_entry_to_exit` / ",
          "`_reverse_exit_to_entry`. A method reaching this fallback ",
          "indicates either an unregistered Instruction subtype (Rule 1) ",
          "or that the caller should be using one of the block-level ",
          "helpers instead.")
end

# --- ArithmeticAssignment: swap target/source, flip modop ------------------
#
# Forward: `target := source ⊕ (lhs op rhs)`.
# Inverse: `source := target ⊖ (lhs op rhs)` — same shape, target/source
# swapped, modop replaced by its dual (`dual_modop`; reused from
# `arithmetic_assignment.jl` per Law 2). `lhs`/`op`/`rhs` are read-only
# operands and are preserved unchanged.
function structural_inverse(instr::ArithmeticAssignment)::Instruction
    return ArithmeticAssignment(instr.source, instr.target,
                                dual_modop(instr.modop),
                                instr.lhs, instr.op, instr.rhs)
end

# --- SwapInstruction: positional target↔source pair swap -------------------
#
# Forward: `target1, target2 := source1, source2`.
# Inverse: `source1, source2 := target1, target2` — the same four-field
# form with the (target,source) roles exchanged positionally. Self-
# inverse modulo the role swap (applying `structural_inverse` twice
# returns an equivalent struct; see M2.15 idempotency test).
function structural_inverse(instr::SwapInstruction)::Instruction
    return SwapInstruction(instr.source1, instr.source2,
                           instr.target1, instr.target2)
end

# --- MemoryAssignment: flip modop, address unchanged -----------------------
#
# Forward: `M[addr] ⊕= (lhs op rhs)`.
# Inverse: `M[addr] ⊖= (lhs op rhs)` — same shape, modop replaced by
# its dual. `addr` is neither created nor destroyed (memory cells are
# not SSA-tracked); same `addr` on both directions.
function structural_inverse(instr::MemoryAssignment)::Instruction
    return MemoryAssignment(instr.addr, dual_modop(instr.modop),
                            instr.lhs, instr.op, instr.rhs)
end

# --- MemoryInterchange: target↔source swap ---------------------------------
#
# Forward: `target := M[addr] := source` (atomic exchange).
# Inverse: `source := M[addr] := target` — same exchange with the
# register slots swapped. `addr` is preserved. Mirrors RC3
# `MemoryInterchangeInstruction.reverse()` (cited in memory_instructions.jl
# M2.12).
function structural_inverse(instr::MemoryInterchange)::Instruction
    return MemoryInterchange(instr.source, instr.addr, instr.target)
end

# --- MemorySwap: self-inverse (fresh instance for purity) ------------------
#
# `M[addr1] <-> M[addr2]` is its own inverse — the same swap applied
# twice restores the original cells. Returning a NEW instance (rather
# than `instr` itself) preserves the contract that `structural_inverse`
# is a pure rewrite producing a fresh `Instruction` value, in case
# downstream code (M9 pebble) ever caches or mutates the returned IR
# fragment.
function structural_inverse(instr::MemorySwap)::Instruction
    return MemorySwap(instr.addr1, instr.addr2)
end

# --- CallInstruction: targets↔args swap AND :call ↔ :uncall flip -----------
#
# Forward: `(targets,...) := call/uncall callee(args,...)`.
# Inverse: `(args,...) := uncall/call callee(targets,...)` — the
# targets and args lists are swapped (the destination of the call
# becomes the source of its inverse) AND the source-level direction
# tag is flipped. `callee` is preserved (same subroutine, opposite
# direction). Mirrors RC3 `CallInstruction.reverse()`.
function structural_inverse(instr::CallInstruction)::Instruction
    flipped = instr.direction === :call ? :uncall : :call
    return CallInstruction(instr.args, instr.callee, instr.targets, flipped)
end

# ============================================================================
# Control-flow entry/exit rewrites (block-label-aware)
# ============================================================================

"""
    _reverse_entry_to_exit(entry::ControlInstruction, block_label::Symbol) -> ControlInstruction

Given a forward block's `entry` and the block's `label`, build the
corresponding reversed-block `exit`. The returned value is one of
`EndInstruction`, `UnconditionalExit`, or `ConditionalExit` (i.e.
sits in the reversed block's `exit` slot).

# Per-subtype rewrites

  * `BeginInstruction(label, params)`           → `EndInstruction(label, params)`.
    The subroutine-marker pair flips; `params` (forward formal-parameter
    list) becomes the reversed `returns` list. Block label is unused
    here (the BeginInstruction's `label` field already carries it).

  * `UnconditionalEntry(label, params)`         → `UnconditionalExit(block_label, params)`.
    The forward Entry receives values bound on block entry; the
    reversed Exit ships them back out, targeting the same block
    label. The `block_label` parameter is exactly the source-block
    label needed on the reversed `UnconditionalExit.target` field —
    see the file's top-of-module docstring "Why label injection for
    control-flow exits is at the block level".

  * `ConditionalEntry(label, params, pred_t, pred_f, condition)`
    → `ConditionalExit(condition, pred_t, pred_f, params)`.
    The conditional-branch entry/exit pair flips; the forward Entry's
    predecessor labels become the reversed Exit's target labels
    (preserving the "true-on-left" mnemonic). The predicate symbol
    is preserved. Block label is unused here (Entry.label is
    metadata; the Exit doesn't carry a label-of-source).

A fallback `else` would never fire because the `BasicBlock`
constructor already restricts `entry` to one of the three entry-
direction subtypes; the function therefore enumerates exactly three
cases and uses no default arm.
"""
function _reverse_entry_to_exit(entry::ControlInstruction,
                                block_label::Symbol)::ControlInstruction
    if entry isa BeginInstruction
        return EndInstruction(entry.label, entry.params)
    elseif entry isa UnconditionalEntry
        return UnconditionalExit(block_label, entry.params)
    else  # entry isa ConditionalEntry (guaranteed by BasicBlock constructor).
        return ConditionalExit(entry.condition,
                               entry.predecessor_true,
                               entry.predecessor_false,
                               entry.params)
    end
end

"""
    _reverse_exit_to_entry(exit::ControlInstruction, block_label::Symbol) -> ControlInstruction

Given a forward block's `exit` and the block's `label`, build the
corresponding reversed-block `entry`. The returned value is one of
`BeginInstruction`, `UnconditionalEntry`, or `ConditionalEntry` (i.e.
sits in the reversed block's `entry` slot).

# Per-subtype rewrites

  * `EndInstruction(label, returns)`            → `BeginInstruction(label, returns)`.
    Mirrors the Begin↔End flip in `_reverse_entry_to_exit`; the
    forward `returns` list becomes the reversed `params` list. Block
    label is unused (EndInstruction.label is already the subroutine
    label).

  * `UnconditionalExit(target, args)`           → `UnconditionalEntry(target, args)`.
    The forward Exit jumps to `target`; the reversed Entry IS the
    block that was being jumped to, now repurposed as a forward
    entry receiving the same args. The Entry's `label` is the
    forward Exit's `target` — the destination becomes the entry's
    own identity. Block label is unused (the reversed Entry's label
    is the original target, not the source block).

  * `ConditionalExit(condition, target_t, target_f, args)`
    → `ConditionalEntry(block_label, args, target_t, target_f, condition)`.
    The conditional Exit's targets become the reversed Entry's
    predecessors (true-on-left preserved); the predicate symbol is
    preserved. The Entry's `label` field requires the original
    block's label — the source of the forward Exit — which the Exit
    itself does not carry. `block_label` supplies it.

As in `_reverse_entry_to_exit`, the function enumerates exactly three
cases — the `BasicBlock` constructor guarantees the input is one of
the three exit-direction subtypes.
"""
function _reverse_exit_to_entry(exit::ControlInstruction,
                                block_label::Symbol)::ControlInstruction
    if exit isa EndInstruction
        return BeginInstruction(exit.label, exit.returns)
    elseif exit isa UnconditionalExit
        return UnconditionalEntry(exit.target, exit.args)
    else  # exit isa ConditionalExit (guaranteed by BasicBlock constructor).
        return ConditionalEntry(block_label,
                                exit.args,
                                exit.target_true,
                                exit.target_false,
                                exit.condition)
    end
end

# ============================================================================
# reversed(::BasicBlock)
# ============================================================================

"""
    reversed(bb::BasicBlock) -> BasicBlock

The block-level structural inverse: returns a new `BasicBlock` whose
forward execution equals `bb`'s backward execution. See this file's
top-of-module docstring on "`reversed(bb)` — the block-level
structural inverse" for the three-part contract (body reversal +
structural inversion, entry/exit swap with subtype flip, label
preservation).

# Implementation outline

```
new_body  = [structural_inverse(i) for i in reverse(bb.instructions)]
new_entry = _reverse_exit_to_entry(bb.exit,  bb.label)
new_exit  = _reverse_entry_to_exit(bb.entry, bb.label)
return BasicBlock(bb.label, new_entry, new_body, new_exit)
```

`reverse(bb.instructions)` returns an `Iterators.Reverse` view; the
list comprehension materialises a new `Vector{Instruction}` with the
elements in reversed order, each replaced by its `structural_inverse`.
The `BasicBlock` constructor's invariants (entry-direction in the
entry slot, exit-direction in the exit slot, no control-flow in the
body) are necessarily satisfied: the helper functions return values
of the correct directions by construction, and `structural_inverse`
on a non-control instruction returns a non-control instruction.

# Reverse-of-reverse property

For every well-formed `bb`, the double application
`reversed(reversed(bb))` produces a block structurally equivalent to
`bb` — same label, same body shape, same entry/exit class. (The
returned struct is a *new* value, not `===`-identical to the
original, by design — see `structural_inverse(::MemorySwap)` for the
purity rationale.) The test `BasicBlock.reversed() round-trip
(M2.15)` pins this.
"""
function reversed(bb::BasicBlock)::BasicBlock
    new_body = Instruction[structural_inverse(i) for i in Iterators.reverse(bb.instructions)]
    new_entry = _reverse_exit_to_entry(bb.exit, bb.label)
    new_exit  = _reverse_entry_to_exit(bb.entry, bb.label)
    return BasicBlock(bb.label, new_entry, new_body, new_exit)
end
