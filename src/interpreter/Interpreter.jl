"""
    Interpreter (M3.1) — `initial_state` for the forward-only interpreter

The gateway file for milestone M3 (bd `bennettvm-afj`). M2 closed with
the IR type hierarchy stable (`IState`, `RState`, the twelve concrete
`Instruction` subtypes, `BasicBlock`, `LabelTable`, `VMProgram`); M3
opens by giving the interpreter its starting point — a function that
takes a `VMProgram` and an input binding and produces an `RState` whose
`pc` is at the entry block's first instruction, whose `locals` carry
the input bindings, whose `memory` is empty, whose `status` is
`:running`, and whose `history` is an empty `AbstractHistoryEntry`
vector ready to receive the entries that future `step!` calls will
push.

# Why a separate file (and a separate `src/interpreter/` directory)

The interpreter is logically distinct from the IR. `src/ir/` defines
*what programs are*; `src/interpreter/` defines *what running them
means*. The split lets the M3.x → M3.x interpreter beads (`step!`,
`unstep!`, `run!`, `unrun!`, `is_halted`, `result`, the cross-block
dispatch routing) accrete in one directory without each touching the
IR layer, and it keeps the dispatch layer's grow rate independent of
the IR's. `src/BennettVM.jl` loads this file after the IR includes —
see the include-graph rationale at the bottom of `src/BennettVM.jl`.

# Why `initial_state` lives at M3.1 (not earlier)

Three transitive dependencies that all landed in M2:

  1. `VMProgram` (M2.17) is the real Phase-2 program artifact —
     `initial_state` must consume *the* shape, not the M0.2 digest
     stub. Building `initial_state` before M2.17 would have forced
     a re-write the moment the real `VMProgram` shape landed.
  2. `LabelTable` (M2.16) is what lets `initial_state` resolve
     `prog.entry_label` to a concrete flat-stream address. The
     `fwd_address` field is what M3.1 reads (see "What `pc` is set
     to" below); without M2.16 there was nothing to read.
  3. `IState` (M2.1) + `RState` (M2.3) + `AbstractHistoryEntry`
     (M2.3) are the three types `initial_state` constructs and
     returns. Each one was a separate Phase-2 design decision
     (mutable structs per spike Q1, the `Vector{AbstractHistoryEntry}`
     polymorphism point per PRD §3.3); M3.1 is the first downstream
     consumer that crosses all three at once.

PRD v4 §3.16 ratifies the binding requirement that
`initial_state(prog)` MUST raise on an empty `prog`. The error message
here cites M2.16 (where label-table lookup happens) rather than M2.17,
because an empty `blocks` vector means the LabelTable is also empty
and the entry_label lookup would raise — fail loud earlier in
the call.

# What `pc` is set to

`prog.label_table[prog.entry_label].fwd_address` — the 1-based flat-
stream index of the entry block's `entry` instruction (M2.16
`LabelEntry.fwd_address` semantics). This is *the* address the
forward interpreter's `step!` will dispatch into on its first
iteration. Setting `pc = 1` unconditionally would be wrong in any
program whose entry block is not `blocks[1]`; setting `pc = 0` would
violate Julia's 1-based indexing convention (and the M2.16
constructor that rejects `< 1`).

# Why input validation matters here (Rule 1 / PRD §3.16)

A `VMProgram` carries `arg_widths` (number of formal arguments and
their widths in bits, from the `ParsedIR` it was lowered from), but
those are *widths*, not *names*. The names of the entry block's
formal parameters live on the entry block's `entry` field — if that
field is a `BeginInstruction`, its `params::Vector{Symbol}` is the
authoritative list of SSA-name expectations.

A future agent might assume `length(input) == length(prog.arg_widths)`
suffices. That is *necessary* but not *sufficient*: the same name
could be passed in `input` more than once if you also keyed by, say,
position; or a typo (`Dict(:n_ => Int64(7))` instead of `:n`) would
silently shadow the expected key with a never-read junk key, and the
first time the program reads `locals[:n]` it would `KeyError`
mid-step — exactly the silent-corruption mode PRD §3.16 forbids.

We therefore validate names when we have them (entry is a
`BeginInstruction`) and fall back to name-agnostic acceptance when we
do not (the lowering pass produced an `UnconditionalEntry` for main —
legal, but the param list is on the block-edge sender, not on the
entry marker). The fallback is intentional: M3.x lowering will decide
whether main always carries an explicit `Begin`; until that decision
lands, this function must accept either shape.

# Coercion: input value type

`IState.locals` is declared `Dict{Symbol,Int64}`. Tests want to write
`Dict(:n => Int64(7))` (already-Int64) literals, and lowering passes
should be free to write either `Dict(:n => 7)` (Julia default `Int`,
which on a 64-bit platform IS `Int64`) or `Dict(:n => Int32(7))`
(narrower types from a typed front-end). We coerce explicitly via
`Int64(v)` per-entry so the produced `locals` dict matches its
declared element type regardless of the caller's source type. Any
type that cannot be `convert`ed to `Int64` (e.g., a `Float64`) will
raise an `InexactError` at the coercion site — fail loud, per Rule 1,
at the boundary rather than at the first arithmetic instruction.

The `input` parameter is typed `AbstractDict` (not the concrete
`Dict{Symbol,Int64}`) so that tests passing `Dict(:n => Int64(5))`
(which has eltype inferred at the call site) do not have to
constrain their dict construction syntax — Julia's `Dict(...)`
literal infers `Dict{Symbol,Int64}` for the test fixture but
`Dict{Symbol,Int32}` when narrower types are mixed in, and forcing
the test author to spell the eltype explicitly is exactly the kind
of paper cut Rule 4 says costs the maintainer days.

# Ref

  * `bennettvm_prd.md` (PRD v4) §3.9 — `initial_state(prog) :: RState`
    signature and the requirement that `prog` non-emptiness is
    validated.
  * `bennettvm_prd.md` (PRD v4) §3.16 — `initial_state` MUST raise a
    descriptive error if `prog` is empty.
  * `src/ir/VMProgram.jl` (M2.17) — the program-artifact type.
  * `src/ir/label_table.jl` (M2.16) — `LabelTable.entries`, the
    `LabelEntry.fwd_address` field, and the `Base.getindex` lookup.
  * `src/ir/IState.jl` (M2.1) — the snapshot type and the 3-arg
    constructor used here (memory defaults to empty).
  * `src/ir/RState.jl` (M2.3) — the history-bearing wrapper and the
    `AbstractHistoryEntry` supertype this function constructs an
    empty `Vector` of.
  * `spike/src/BennettVMSpike.jl` `initial_state` — the Phase-0
    template (the broad shape — set pc, install locals, wrap in
    RState — was already proved out there; this M3.1 lands the
    Phase-2-flavored version with `LabelTable` lookup instead of
    `pc = 1` and with `AbstractHistoryEntry[]` instead of the
    spike's full-snapshot history).
  * CLAUDE.md Rule 1 (fail-fast / fail-loud); Rule 10 (LOC budget —
    this file stays well under 200 code-LOC); Rule 11 (literate
    docstrings).
"""

"""
    initial_state(prog::VMProgram, input::AbstractDict)::RState

Construct the starting `RState` for forward execution of `prog`. The
returned `RState` has:

  * `current.pc` set to the entry block's `fwd_address` (M2.16
    `LabelTable.entries[prog.entry_label].fwd_address`).
  * `current.locals` populated from `input`, with each value coerced
    to `Int64` (M2.1 `IState.locals` is declared `Dict{Symbol,Int64}`).
  * `current.status` = `:running`.
  * `current.memory` empty.
  * `history` an empty `Vector{AbstractHistoryEntry}`.

# Validation (Rule 1, PRD v4 §3.16)

  * Empty program → `error` (descriptive). PRD v4 §3.16 binding.
  * `entry_label` missing from `label_table` → `error` via
    `LabelTable.getindex` (M2.16 descriptive raise).
  * If entry block's `entry` is a `BeginInstruction`, `Set(keys(input))`
    MUST equal `Set(begin_instruction.params)` — else `error`. When
    the entry slot is not a `BeginInstruction` (e.g., an
    `UnconditionalEntry`; Phase-2 lowering may choose this shape for
    a basic-block-rooted main), name validation is skipped and the
    `input` is installed verbatim.
  * Each value coerced via `Int64(v)`; an uncoercible value raises
    `InexactError` (Julia stdlib).

# Ref

  * PRD v4 §3.9, §3.16.
  * `src/ir/VMProgram.jl` (M2.17), `src/ir/label_table.jl` (M2.16),
    `src/ir/IState.jl` (M2.1), `src/ir/RState.jl` (M2.3).
"""
function initial_state(prog::VMProgram, input::AbstractDict)::RState
    # (1) Empty-program validation. PRD v4 §3.16: descriptive error.
    # Spike-Phase-0 template: `spike/src/Interpreter.jl:119` raised on
    # the same condition. This is the LOAD-BEARING first guard: an
    # empty `blocks` vector cannot host a forward step, and silently
    # producing a `pc = 1`-but-no-instruction `RState` would surface
    # later as a confusing dispatch-on-undefined-array-index failure.
    isempty(prog.blocks) &&
        error("initial_state: VMProgram has no blocks — cannot start ",
              "(was lower_vm called with a real ParsedIR? The M0.2 ",
              "digest-stub `VMProgram(arg_widths, return_widths)` ",
              "produces an empty-blocks program by design; M3.x ",
              "lowering populates blocks. PRD v4 §3.16.)")

    # (2) Entry-label lookup. `LabelTable.getindex` (M2.16) already
    # raises a descriptive `ErrorException` (not a bare `KeyError`)
    # listing the known labels — re-raising it unmodified is the
    # right move here.
    entry_addr = prog.label_table[prog.entry_label]

    # (3) Resolve the entry block to read its `entry` field. The
    # block_index hint on the LabelEntry is the cheapest path; the
    # label-keyed lookup would also work but pays a Symbol-hash for
    # a value we already have.
    entry_block = prog.blocks[entry_addr.block_index]

    # (4) Parameter-name validation when the entry slot carries the
    # names. PRD v4 §3.16 + this file's top-of-module docstring on
    # "Why input validation matters here". When `entry` is a
    # `BeginInstruction`, its `params::Vector{Symbol}` is the
    # authoritative expected-keys set; mismatch is a Rule 1 failure.
    # When `entry` is not a `BeginInstruction` (e.g., an
    # `UnconditionalEntry` for a basic-block-rooted main), validation
    # is skipped and the input is accepted verbatim.
    if entry_block.entry isa BeginInstruction
        expected = Set(entry_block.entry.params)
        provided = Set(keys(input))
        expected == provided ||
            error("initial_state: input keys ", collect(provided),
                  " do not match entry block's BeginInstruction.params ",
                  collect(expected), " — every formal parameter of the ",
                  "entry block must be bound by `input`, and no extra ",
                  "keys are permitted (PRD v4 §3.16; M3.1).")
    end

    # (5) Build the `locals` dict with explicit `Int64` coercion. Per
    # the top-of-module docstring on "Coercion: input value type":
    # `IState.locals` is declared `Dict{Symbol,Int64}`, so any narrower
    # input integer width (Int32 from typed front-ends, default `Int`
    # literals on 32-bit platforms) is coerced at the boundary. An
    # uncoercible value (Float64 with non-integer payload, etc.) will
    # raise `InexactError` here — Rule 1 says we want that loud, at
    # the construction site, not later mid-step.
    locals = Dict{Symbol,Int64}()
    for (k, v) in input
        locals[k] = Int64(v)
    end

    # (6) Construct IState via the 3-arg constructor (M2.1) — memory
    # defaults to empty. Status `:running` per the spike-Q4 status-bit
    # ratification and PRD v4 §3.9 status-symbol enumeration.
    istate = IState(entry_addr.fwd_address, locals, :running)

    # (7) Wrap in RState with an empty history vector. The element
    # type `AbstractHistoryEntry` (M2.3) is the polymorphism point for
    # the three layers PRD v4 §3.3 prescribes (L1 injective, L2 delta,
    # L3 checkpoint); the empty vector here will receive whatever
    # concrete entry types future `step!` calls push.
    return RState(istate, AbstractHistoryEntry[])
end
