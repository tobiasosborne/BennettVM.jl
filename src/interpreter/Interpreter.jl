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

    # Seed the read-only const-global segment (bead `bennettvm-416r.4`). The
    # ROM is materialized ONCE in the `VMProgram` (`_lower_parsed_ir` /
    # `_global_segment`) and SHARED by reference into the IState — `GlobalROM`'s
    # `deepcopy_internal` returns the same object, so the `deepcopy(istate)`
    # anchor below (and every L3 `CheckpointEntry`) shares this one ROM rather
    # than copying its cell map. Empty for a globals-free program (the shared
    # `_EMPTY_GLOBAL_ROM` default was already installed by the constructor), so
    # this assignment is a harmless no-op re-share there.
    istate.globals = prog.globals

    # (7) Wrap in RState with an empty history vector. The element
    # type `AbstractHistoryEntry` (M2.3) is the polymorphism point for
    # the three layers PRD v4 §3.3 prescribes (L1 injective, L2 delta,
    # L3 checkpoint); the empty vector here will receive whatever
    # concrete entry types future `step!` calls push.
    #
    # M4.3 — explicit `initial` anchor via the 4-arg constructor. The
    # `deepcopy(istate)` here is defense-in-depth against the spike
    # Q2.2 Dict-aliasing trap: the M4.3 RState constructor's 2-arg
    # back-compat form ALSO deepcopies the current into `initial`, so
    # this site is technically redundant — but defending at both sites
    # means a future code change that drops one defense still has the
    # other. The same belt-and-braces discipline `CheckpointEntry`
    # uses (deepcopy inside its constructor) and that M4.3's `unstep!`
    # uses at the restore site (deepcopy when reading FROM the anchor
    # / a checkpoint snapshot). Two cheap copies at construction beat
    # one missed deepcopy debugged at the round-trip-test failure.
    return RState(istate, AbstractHistoryEntry[], 0, deepcopy(istate))
end

"""
    is_halted(s::RState) -> Bool

True iff the wrapped `IState`'s `status` is `:halted`. Used by the
`run!` loop terminator (M3.4) — the loop runs `step!` while
`!is_halted(s)` — and by callers wanting to extract the result before
inspecting `s.current.locals`.

The comparison is `===` (identity) rather than `==`; symbols are
interned in Julia so the two always agree for `Symbol` values, but
the M2.1 `IState.status` field docstring already documents `===` as
the canonical spelling for the three legal status values
(`:running`, `:halted`, `:error`) and we match that convention here.

# Why this is its own accessor (rather than `s.current.status === :halted`
# spelled inline at every call site)

Every callsite that wants "is the interpreter done?" must agree on
the halt predicate; if the predicate ever generalises (e.g., grows
to "halted OR error" for some callers — PRD v4 §3.9 status-symbol
set), centralising the question here means one edit, not N. The M3.4
`run!` loop and the M3.x `unrun!` loop will both go through this
function.

# Ref

  * PRD v4 §3.9 — `is_halted(rstate) :: Bool` signature.
  * `src/ir/IState.jl` (M2.1) — the `status::Symbol` field and the
    `:running` / `:halted` / `:error` enumeration this predicate
    dispatches on.
"""
is_halted(s::RState) = s.current.status === :halted

"""
    result(s::RState) -> Dict{Symbol,Int64}

Extract the locals dict from a halted `RState`, returned as a **copy**
so the caller cannot mutate interpreter state through the returned
handle. Errors descriptively (Rule 1) if the RState is not halted —
the Phase-0 spike retrospective's Q3 area (status-handling) documents
that silently returning partial-running results was a load-bearing
bug class; Phase 2 explicitly rejects it at the boundary.

# Why a copy (and not the live `s.current.locals`)

`IState.locals` is the live mutable dict the interpreter mutates on
every `step!`. If `result` returned that dict directly, a caller doing
`r = result(s); r[:x] = 0` would silently corrupt the interpreter
state — and (worse) make `unrun!` produce wrong answers because the
backward-pass invariants assume `locals` matches the history. Copying
at the boundary is the cheapest insurance; the cost is one `Dict`
allocation per terminal `result` call (not per step), and the
guarantee is structural.

# Why an error (not `nothing`) on non-halted state

PRD v4 §3.16 + Rule 1: silent partial-result returns are a banned
mode. The error message names the actual status so the caller can
distinguish `:running` (loop hasn't reached `Halt` yet) from `:error`
(an instruction raised — see PRD v4 §3.9 status-symbol enumeration).

# Ref

  * PRD v4 §3.9 — `result(rstate) :: Dict{Symbol,Int64}` signature
    and the precondition that the RState be halted.
  * `src/ir/IState.jl` (M2.1) — `locals::Dict{Symbol,Int64}` is the
    field this accessor copies.
  * `spike/RETROSPECTIVE.md` Q3 area — the silent partial-result
    failure mode Phase 2 must not reintroduce.
  * CLAUDE.md Rule 1 (fail loud, not silent `nothing`).
"""
function result(s::RState)
    if !is_halted(s)
        error("result: RState is not halted (status = $(s.current.status)). ",
              "Did run! finish? Inspect the RState before calling result.")
    end
    return copy(active_locals(s.current))   # CW-B2: active register file = frames[end].locals.
end

# ============================================================================
# M3.3 — `step!` single-instruction dispatch (bd `bennettvm-1hn`).
#
# `step!(s::RState, prog::VMProgram)::RState` is the single most load-bearing
# function in the interpreter — every forward run of a Phase-2 program is a
# loop of `step!` calls until `is_halted(s)`. It resolves the instruction at
# the current `pc` against the flat instruction stream of `prog.blocks`,
# dispatches into `forward(instr, s.current)` (the per-subtype methods landed
# at M2.6 through M2.14), and detects the `EndInstruction` of the entry
# subroutine to transition status to `:halted`.
#
# ## Why the flat-stream resolver lives here, not on VMProgram
#
# `LabelEntry.fwd_address` (M2.16) is a 1-based index into a *virtual* flat
# stream where each block contributes `[entry, body..., exit]`. The
# `VMProgram` struct (M2.17) does NOT materialize that flat stream as a
# field — only the per-block triples plus the label table. Dispatch
# therefore needs a helper that walks blocks in order and computes the
# offset on the fly. That helper is `_instruction_at` below, kept private
# (underscore prefix) because callers outside this file should reach for
# `step!` instead — there is no legitimate reason to address the flat
# stream directly except as `step!`'s dispatch substrate.
#
# Materializing the flat stream as a `VMProgram` field was considered and
# rejected: it would duplicate state that the per-block layout already
# carries, and any future `BasicBlock` mutation (extending an instruction
# list, splicing in a new block) would have to keep the cached flat stream
# in sync — exactly the synchronization burden the M2.17 docstring's
# "Counts are derived, not stored" section calls out as a footgun. The
# resolver pays an O(B) walk per step (B = number of blocks), which is
# negligible for the realistic programs of PRD v4 §3.6.2 (B ≤ a few dozen)
# and which a future M9 pebble-scheduler-aware build could memoize if it
# ever matters.
#
# Ref: bennettvm_prd.md (PRD v4) §3.11 — `step!(rstate, prog) :: RState`
#      signature and the forward-only-at-M3.3 scope.
# Ref: spike/RETROSPECTIVE.md Q3 — the forward-before-push ordering
#      invariant that M4's history-bearing `step!` must respect; the
#      reorder lesson is documented here proactively even though M3.3
#      itself does no history work.

"""
    _instruction_at(prog::VMProgram, pc::Int) -> Instruction

Resolve the flat-stream address `pc` (1-based) to the corresponding
`Instruction` value by walking `prog.blocks` in order. The flat stream
is virtual: each block `b` contributes the triple
`[b.entry, b.instructions..., b.exit]`, in sequence, so the address of
block `k`'s entry is `1 + Σᵢ₌₁ᵏ⁻¹ (2 + length(prog.blocks[i].instructions))`.

# Why a linear walk rather than a precomputed offset table

A precomputed `cumulative_starts::Vector{Int}` field on `VMProgram` would
make this lookup O(log B) (binary-search) instead of O(B). It was
rejected for the same synchronization reason `n_instructions` is derived
rather than stored (see `src/ir/VMProgram.jl` M2.17 docstring §"Counts
are derived, not stored"): any future block-mutation pass would have to
remember to invalidate or recompute the offset table, with no compiler
help, and the cost of a missed invalidation is a silent dispatch on
the wrong instruction — exactly the Rule 1 ("fail loud") violation
Phase 2 cannot afford. The linear walk pays O(B) per `step!`; for the
PRD v4 §3.6.2 motivating cases (B ≤ a few dozen) this is well below the
threshold at which it could matter. If the M9 pebble-scheduler ever
calls `step!` in a profile-sensitive loop, an offset-table memoizer
can be added at that bead — but not before.

# Fail-loud bounds (Rule 1)

  * `pc < 1` raises immediately. Julia's 1-based-indexing convention is
    binding for the M2.16 `LabelEntry.fwd_address` field (its own
    constructor rejects values `< 1`); a `pc = 0` reaching this helper
    indicates a corrupted RState that must not be allowed to silently
    dispatch on `blocks[1].entry` by happenstance.
  * `pc` beyond the end of the flat stream raises with the total
    instruction count in the message. This is the failure mode an
    off-by-one in `forward(::EndInstruction, ...)` would manifest as,
    and the error wording is deliberately diagnostic.

# Ref

  * `src/ir/label_table.jl` (M2.16) — the same `[entry, body..., exit]`
    flat-stream convention is what `LabelTable` consults when computing
    `fwd_address` and `inv_address` per block.
  * `src/ir/VMProgram.jl` (M2.17) — `n_instructions` uses the same
    `2 + length(b.instructions)` block-contribution formula.
  * CLAUDE.md Rule 1 (out-of-range pc fails loud, not silent).
"""
function _instruction_at(prog::VMProgram, pc::Int)
    pc < 1 && error("_instruction_at: pc=", pc,
                    " < 1 (program addresses are 1-based; the M2.16 ",
                    "LabelEntry.fwd_address constructor itself rejects ",
                    "values < 1, so a pc=0 reaching here indicates a ",
                    "corrupted RState — Rule 1 fail-loud)")
    pos = 1
    for b in prog.blocks
        # Block layout: [entry, body..., exit] — contributes
        # 2 + length(b.instructions) addresses to the flat stream.
        body_len = length(b.instructions)
        if pc == pos
            return b.entry
        elseif pc > pos && pc <= pos + body_len
            return b.instructions[pc - pos]
        elseif pc == pos + body_len + 1
            return b.exit
        end
        pos += 2 + body_len
    end
    error("_instruction_at: pc=", pc, " beyond end of program ",
          "(total flat-stream instruction count = ", pos - 1,
          "). This usually means `forward(::EndInstruction, ...)` ",
          "bumped pc past the last instruction and the run! loop ",
          "failed to detect the halt — see step!'s EndInstruction ",
          "detection clause (M3.3).")
end

"""
    _block_index_at(prog::VMProgram, pc::Int) -> Tuple{Symbol, Int}

Resolve the flat-stream address `pc` (1-based) to the
`(block_label, body_idx)` coordinate consumed by M7.5's
`must_cache(set, label, idx)` query. The coordinate convention
matches `compute_must_cache`'s loop (`src/analysis/liveness.jl`):

  * `block_label` — the `BasicBlock.label` field of the block
    containing `pc`.
  * `body_idx` — 1-based index INTO `block.instructions` (i.e., the
    non-control body only) when `pc` lands on a body slot. For the
    entry-marker slot we return `0`; for the exit-marker slot we
    return `length(block.instructions) + 1`. The latter two values
    never satisfy `must_cache` (M7.5's set only contains body
    indices) so the L2 path never fires for control-flow markers —
    consistent with M6.1's type-level injectivity for all six
    `ControlInstruction` subtypes.

# Why this lives next to `_instruction_at`, not in liveness.jl

The M7.6 push site needs *both* the resolved instruction (for the
`is_injective` and `make_delta` dispatch) AND its (block_label,
body_idx) coordinate (for the `must_cache` query). Having both
resolvers in the same file lets them share the block-walk loop
shape verbatim and stay co-located with the M3.3 docstring's
flat-stream layout explanation. `compute_must_cache` in
`src/analysis/liveness.jl` is the *producer* of the set; this
helper is its corresponding per-pc *coordinate-lookup* — they meet
at the M7.6 push site in `step!`.

# Cross-block dispatch interaction

The M7.6 push site captures `pc_before = s.current.pc` at the top
of `step!` (BEFORE `forward()` and BEFORE
`_handle_cross_block_dispatch!`), so this helper always sees the
pc that was *dispatched on*, not the post-step pc (which for
Uncond/Cond Exit gets overridden to the destination block by
`_dispatch_to_block!`). For a non-injective body instruction in
any block — entry block or otherwise — `pc_before` is the address
of that body slot in the flat stream, regardless of how control
arrived. The walk below produces the matching (label, idx) per
the M2.16 `fwd_address` convention.

# Ref

  * ADR 0002 §"Design decisions that ripple to M7.2–M7.7" decision
    5 — the `Set{Tuple{Symbol, Int}}` coordinate convention.
  * `src/analysis/liveness.jl` (M7.5) — the producer of the set
    this helper's output is queried against.
  * `src/ir/basic_block.jl` (M2.15) — `BasicBlock` field layout;
    `instructions` is the non-control body only.
  * `_instruction_at` (above) — the sibling resolver that returns
    the instruction value at `pc`; this helper returns its
    coordinate. Both share the flat-stream walk shape.
  * CLAUDE.md Rule 1 — fail loud on out-of-range pc.
"""
function _block_index_at(prog::VMProgram, pc::Int)::Tuple{Symbol, Int}
    pc < 1 && error("_block_index_at: pc=", pc,
                    " < 1 (program addresses are 1-based; the M2.16 ",
                    "LabelEntry.fwd_address constructor rejects values ",
                    "< 1). Rule 1 fail-loud.")
    pos = 1
    for b in prog.blocks
        body_len = length(b.instructions)
        if pc == pos
            # Entry marker. Return body_idx == 0 — never a key in
            # the must_cache set (whose body indices start at 1).
            return (b.label, 0)
        elseif pc > pos && pc <= pos + body_len
            return (b.label, pc - pos)
        elseif pc == pos + body_len + 1
            # Exit marker. Return body_idx == body_len + 1 — never
            # a key in the must_cache set.
            return (b.label, body_len + 1)
        end
        pos += 2 + body_len
    end
    error("_block_index_at: pc=", pc, " beyond end of program ",
          "(total flat-stream instruction count = ", pos - 1,
          "). This indicates a corrupted RState — Rule 1 fail-loud.")
end

"""
    step!(s::RState, prog::VMProgram;
          checkpoint_interval::Int = 64,
          must_cache_set::Set{Tuple{Symbol, Int}} = Set{Tuple{Symbol, Int}}(),
          replay_mode::Bool = false) -> RState

Advance the interpreter one instruction forward in `prog`. Returns the
same `RState` (mutated in place); the return value is for chaining and
to satisfy the PRD v4 §3.11 signature `step!(rstate, prog) :: RState`.

# Behavior

  1. **Silent no-op when not running.** If `s.current.status !== :running`
     (i.e., the interpreter is `:halted` or `:error`), `step!` returns
     `s` unchanged. This makes `step!` safe to call from a `run!` loop
     that has already detected halt — the loop terminator (M3.4) reads
     `is_halted(s)`, but a caller that defensively calls `step!` after
     the halt observes a no-op rather than a spurious dispatch on a
     past-the-end pc. Documented at the function level here so the
     M3.4 loop can rely on the idempotent shape. The authoritative
     source for this behavior is `spike/RETROSPECTIVE.md` Q2.4
     (Phase-0 halt-state-propagation lessons): the spike's `step!`
     adopted the same idempotent-on-halted shape, and the discipline
     carried forward into Phase 2 unchanged.
  2. **Resolve the instruction at the current pc** via `_instruction_at`
     (above). Out-of-range pc raises descriptively (Rule 1).
  3. **Dispatch into `forward(instr, s.current)`** — the per-subtype
     forward methods (M2.6 ArithmeticAssignment, M2.7 SwapInstruction,
     M2.8 Begin/End, M2.9 Uncond entry/exit, M2.10 Cond entry/exit,
     M2.11 MemoryAssignment, M2.14 CallInstruction). Each method
     mutates `s.current` in place — bumping `pc`, updating `locals` /
     `memory` as appropriate — and returns the same `IState`.
  4. **Cross-block dispatch** (M3.6) for Uncond/Cond Exit.
  5. **Halt detection.** If `instr isa EndInstruction`, set
     `s.current.status = :halted` AFTER the forward call has run. The
     `forward(::EndInstruction, ...)` method has already bumped `pc`
     past the End marker; the status transition signals to `run!`
     (M3.4) and to `is_halted` (M3.2) that no further `step!` calls
     should execute on this RState.
  6. **Step-count + checkpoint push (M4.2).** Increment `s.step_count`,
     then — if the new count is a positive multiple of
     `checkpoint_interval` — push a `CheckpointEntry` capturing the
     just-stepped state. See the M4.2 section below.

# Ordering invariant — forward FIRST, history push SECOND

The ordering convention is baked in here, in this docstring, and is
now load-bearing (M4.2 actually pushes):

> The history push MUST come AFTER `forward(...)` AND after
> cross-block dispatch AND after halt detection.

The Phase-0 spike's `step!` originally pushed the pre-state snapshot
BEFORE calling `forward`; an exception inside `forward` (a div-by-zero,
an unsupported instruction, …) would then leave a partial history
entry referring to a state that the IState never actually moved through.
The corrupted history corrupted `unrun!` in turn, producing a phantom
"reversibility violation" that took the spike's Pass-1 review cycle
to track down. Pass-1F reordered the push to come AFTER `forward`,
which is what fixed it. See `spike/RETROSPECTIVE.md` Q2.2 for the
deepcopy-semantics + ordering account (Q3 for the Pass-1F reorder
narrative).

The status-transition-on-End rule is itself an instance of the
forward-FIRST principle: we set `:halted` AFTER `forward(::EndInstruction)`
has bumped pc, so a hypothetical future EndInstruction exception
(none today, but the discipline is generic) would leave status as
`:running` and pc unchanged — i.e., the IState is unchanged from
before the step. That is the same atomicity invariant the history
ordering rule protects.

# Halt is detected on EndInstruction, not on pc-past-end

A future agent might propose detecting halt by checking
`pc > n_instructions(prog)` after `forward`. That is wrong: a program
with multiple blocks may have valid intermediate `EndInstruction`s
(if Phase-2 ever admits subroutine returns in this style) where pc is
NOT past the end of the flat stream, yet the interpreter should halt.
The marker-based detection here matches RC3's main-routine End ↔ VM
halt transition (RC3 `RSSAVM.java:585-590` — the `instances.End`
visitor sets the VM's halted flag) and is the design point ratified
by PRD v4 §3.11.

# M4.2 — Checkpoint push

`checkpoint_interval::Int = 64` (kwarg, default per PRD v4 §3.3
placeholder). When `s.step_count` (post-increment) is a positive
multiple of `checkpoint_interval`, `step!` pushes a `CheckpointEntry`
onto `s.history` capturing the post-step `s.current` and the
just-incremented count. The L3 history layer of PRD v4 §3.3.

# M6.2 — L1 "no log" gate

PRD v4 §3.3 layer 1 ("No log") says injective instructions and
reversible jumps push nothing. M6.2 implements that gate by AND-ing
the M6.1 trait into the M4.2 push condition:

    should_checkpoint =
        !is_injective(instr) &&
        s.step_count > 0    &&
        s.step_count % checkpoint_interval == 0

i.e., the L3 checkpoint push fires only when (a) the instruction is
**non-injective**, (b) `step_count > 0` (the M4.2 step-0 carve-out),
and (c) `step_count` is a multiple of `K`. Injective instructions —
`SwapInstruction`, all `ControlInstruction` subtypes (Begin/End,
Unconditional Entry/Exit, Conditional Entry/Exit), `MemoryInterchange`,
`MemorySwap`, and `ArithmeticAssignment` with `modop === :xor` (see
M6.1 trait `src/history/Injective.jl`) — skip the push entirely,
even when `step_count % K == 0` would otherwise fire. The inverse
is recoverable from current state alone (Vieri Pendulum §4.2.1 +
Mogensen RSSA §3 for the structural pattern; PRD v4 §3.2/§3.3 for
the binding wording), so no checkpoint is needed.

`step_count` STILL increments for injective instructions — the
counter is canonical and used by replay (`unstep!` in
`src/history/Replay.jl` finds the nearest checkpoint at-or-before
`target = step_count - 1` and replays forward; the absence of a
push at an injective step does not break that lookup because the
replay falls through to the next-earlier checkpoint or to
`s.initial`). Only the *push* is gated; the *counter* is not.

The gate is **necessary AND SUFFICIENT** for L1 — no other
interpreter / `Replay.jl` modification is needed in this bead.
`unstep!`'s find-nearest-then-replay algorithm already handles the
"no checkpoints available" case via the `s.initial` fallback
(`src/history/Replay.jl` step (3)), so a program that pushes fewer
(or zero) checkpoints still reverses correctly — the replay just
spans more steps per `unstep!` call. M6.3 (per-instruction
`inverse()` short-circuits for injective instructions, so `unstep!`
itself can skip the replay) and M6.4 (zero-history round-trip test)
are separate beads that build on this gate.

See `src/history/Injective.jl` (M6.1) for the trait definition and
the per-instruction injectivity rationale (Pendulum exchange-as-
injective, Mogensen RSSA paired entry/exit, the conservative `:xor`-
only modop classification on `ArithmeticAssignment`).

**`K = 1` is a forensic-test mode, NOT a production configuration.**
Passing `checkpoint_interval = 1` reproduces the §3.3-prohibited
per-step full-snapshot pattern (every successful step pushes a deep-
copied `IState`) — the worst point on the time-space curve PRD v4
§3.3 explicitly rejects. It exists in the interface so the M4.2 test
suite can exercise post-step state capture exhaustively; downstream
callers (M5 bridge, M9 scheduler, M4.5 round-trip harness) must NOT
use K=1 in production runs.

**When the push fires.** The first push is at step `K` (i.e., after
the K-th successful step), the second at step `2K`, the third at
`3K`, and so on. Step 0 — the *initial* state, before any forward
step has run — is **not** checkpointed; M4.3's `unstep!` finds the
nearest checkpoint at or before the current step and replays
forward, so the initial state is reachable by replay from "no
checkpoint, run from initial_state". The Step-0 carve-out is M4.3's
concern.

**What state is captured.** The post-step `s.current` (after
`forward`, after cross-block dispatch, after halt detection) and the
post-increment `s.step_count`. Capturing the *post* state means a
replay from this checkpoint resumes immediately PAST the captured
step — exactly the rr-style "checkpoint = resumption point"
convention. M4.3's `unstep!` will rely on this: to recover the state
at step `k`, find the largest checkpoint at step `j <= k`, restore,
and replay forward `k - j` times.

**Why the deepcopy lives inside `CheckpointEntry`'s constructor, not
here.** `CheckpointEntry(snapshot, step)` already deep-copies its
`snapshot` argument as part of its constructor contract (see
`src/history/CheckpointEntry.jl` §"Why deep-copy in the constructor"
and `spike/RETROSPECTIVE.md` Q2.2). A second deepcopy here would be
wasteful and confusing — and would violate Law 2 ("reuse before
reinvention") at the *type-contract* level. The single deepcopy is
the right shape.

**Why `step_count` is incremented in `step!`, not in `run!`.** Two
reasons. (1) `step!` itself reads the just-incremented count to
decide whether to push a `CheckpointEntry` — moving the increment to
`run!` would mean `step!` couldn't make that decision without a
parameter the caller might forget. (2) `step!` is the only place
that *knows* whether the just-attempted forward succeeded (the
early-return on non-`:running`, an exception in `forward`, …).
Putting the counter on `RState` and incrementing it here is what
makes "the count tracks successful steps and only successful steps"
expressible as a local invariant. See `src/ir/RState.jl` §"Why
`step_count` here, not in `run!`'s local scope" for the
field-placement rationale.

**Increment ordering — only on success.** The increment happens only
*after* `forward` + cross-block + halt-detection have all completed
without raising. The early-return path (status !== :running, before
any work) does NOT increment; an exception in `forward` does NOT
increment (the exception propagates and `step!` returns without
reaching the increment). This preserves the "every increment
corresponds to one successful forward step" invariant that M4.3's
decrement-on-`unstep!` will rely on.

**`checkpoint_interval` validation.** A non-positive
`checkpoint_interval` is rejected with a descriptive error before
the dispatch begins (Rule 1). `K=0` would cause a `DivideError` at
`step_count % checkpoint_interval`; `K<0` would silently never fire
the push (because `step_count > 0` and `step_count % K` would be
negative in Julia for negative K — well-defined but useless).
Failing loud at the boundary beats every alternative.

# M7.6 — L2 delta push integration

PRD v4 §3.3 layer 2 ("delta entries with min-cut selection") is the
binding mandate for L2; ADR 0002 §"Composition with M6's injective
gate" locks the three-way decision at the push site:

    s.step_count += 1
    if replay_mode                            # M7.6: suppress all pushes
        # nothing
    elseif is_injective(instr)                # L1 (M6.2)
        # nothing
    elseif must_cache(must_cache_set, blk, i) # L2 (M7.6)
        push!(s.history, make_delta(instr, s_pre, s.step_count))
    elseif s.step_count % K == 0              # L3 (M4.2)
        push!(s.history, CheckpointEntry(s.current, s.step_count))
    end

The `(blk, i)` coordinate is `_block_index_at(prog, pc_before)`,
where `pc_before` is captured at the *top* of `step!` (before
`forward()` and `_handle_cross_block_dispatch!` overwrite pc). The
M7.5 coordinate convention (body indices 1..N inside the block's
`instructions` field) matches this lookup; entry / exit markers
produce body_idx 0 / N+1 which are never in the must_cache set.

## `must_cache_set` — kwarg, NOT a VMProgram field (M7.6 decision A)

ADR 0002 §Design Decision 5 says the must-cache set "lives on
VMProgram". M7.6 ships the set as a kwarg on `step!` and `run!`
instead, defaulting to `Set{Tuple{Symbol, Int}}()` (empty). With
the default, the L2 branch never fires (membership in the empty
set is always false), and existing callers see the M4.2 / M6.2
behaviour unchanged — a strict superset of pre-M7 semantics.

This is NOT a feature flag (CLAUDE.md Rule 13): the default-empty
case is *strictly sound* (L3 takes over for non-injective steps
the empty set "rejects"). The deviation from the ADR's "lives on
VMProgram" wording is a deliberate scope choice to avoid the test
cascade across 18+ M4.x test files that adding a VMProgram field
would force. A future refactor MAY move the set to VMProgram once
measurements justify the cascade; this rewrite is non-breaking.
M7.7 (and any production caller) explicitly passes
`compute_must_cache(prog)` to opt into L2.

## `replay_mode::Bool = false` — suppresses ALL pushes (M7.6 decision C)

`unstep!`'s M4.3 replay loop calls `step!(s, prog;
checkpoint_interval=typemax(Int))` to drive the interpreter from a
restored checkpoint to the backward target. Pre-M7.6 that
suppressed L3 pushes (the `% typemax(Int)` modulo never hits 0
for any positive step_count). Post-M7.6 we ALSO need to suppress
L2 pushes during replay — otherwise the replay path would
re-create the very DeltaEntries `unstep!` just popped. The
`replay_mode=true` flag suppresses both layers uniformly, and
M4.3's `unstep!` sets it. The `checkpoint_interval=typemax(Int)`
spelling is kept for symmetry (M4.3 still passes it for clarity)
but is redundant when `replay_mode=true`.

## Pre-`forward()` L2 capture — the `predelta_payload` hook (M_DYN)

ADR 0002 §"Payload construction order" specifies `make_delta(instr,
s_pre, step)` where `s_pre` is the IState *before* `forward()`
mutates it. M7.6 originally short-cut this by passing `s.current`
(post-`forward()`) as `s_pre`, safe ONLY because the empty-payload
finding (ADR 0002 §"DeltaEntry payload schema") established that
every then-existing non-injective instruction's `make_delta`
*ignored* `s_pre`.

M_DYN (bd `bennettvm-ekc`, ADR 0009 Decision 2b) lands the FIRST L2
delta that needs pre-`forward()` state: `MemoryStore`'s `inverse`
must restore the cell value the overwrite destroyed, which is gone
the instant `forward()` runs. The short-cut would have produced a
delta carrying the JUST-WRITTEN value — a silent reversibility
corruption (the worst Rule 1 / Rule 2 failure mode). So the push
site now captures pre-state explicitly via a `predelta_payload`
hook, at step (3a) above:

  * `predelta_payload(instr, s_pre)::Union{Nothing,NamedTuple}`
    (default `nothing` in `src/history/delta.jl`; specialised in the
    instruction's own file per ADR 0002 Design Decision 3). Returns
    the MINIMAL pre-`forward()` NamedTuple the L2 `inverse` needs —
    for `MemoryStore`, `(addr, old_value, was_present)`, an O(1)
    capture of one cell.
  * The capture runs at (3a), BEFORE `forward()`, gated on the SAME
    predicate as the L2 push branch (`!replay_mode &&
    !is_injective(instr) && must_cache(...)`) — that predicate is
    `forward()`-independent, so evaluating it pre-`forward()` is
    sound and avoids re-walking the block layout twice.
  * **No full deepcopy.** Capturing `deepcopy(s.current)` per step
    would be the L3 cost (a whole-IState snapshot), defeating L2's
    space win (ADR 0009 Decision 2b; PRD §3.3 forbids full snapshots
    on the L2 path). We capture only the per-instruction NamedTuple.
  * **Backward-compatible.** Every instruction whose `make_delta` is
    pre-state-independent inherits the `nothing` default; the push
    gate (7) then takes the unchanged `make_delta(instr, s.current,
    step)` (empty-payload) path. `replay_mode=true` suppresses the
    capture AND the push uniformly (no history writes during replay).

## Backward compatibility

The defaults (`must_cache_set = Set{...}()`, `replay_mode = false`)
reproduce the M6.2 push behaviour exactly: the L2 branch never
fires (empty set), the `replay_mode` suppression never fires, and
the L3 branch is the only push path. Every pre-M7.6 test that
constructed a `step!` or `run!` call without the new kwargs gets
the M4.2 / M6.2 behaviour bit-for-bit.

# Ref

  * `bennettvm_prd.md` (PRD v4) §3.11 — `step!(rstate, prog) :: RState`
    signature.
  * `bennettvm_prd.md` (PRD v4) §3.3 — three-layer history; L3 is
    periodic full-state checkpoints + deterministic forward replay;
    "every 64 retained-snapshot-equivalent steps" is the placeholder
    default K.
  * `docs/adr/0002-enzyme-min-cut-mapping.md` §"Composition with M6's
    injective gate" — the binding three-way decision at the push
    site this implementation discharges.
  * `docs/adr/0002-enzyme-min-cut-mapping.md` §"DeltaEntry payload
    schema" — the empty-payload finding that justifies the `s_pre`
    simplification.
  * `docs/adr/0002-enzyme-min-cut-mapping.md` §"Design decisions
    that ripple to M7.2–M7.7" decision 5 — the
    `Set{Tuple{Symbol, Int}}` coordinate convention.
  * `src/analysis/liveness.jl` (M7.5) — `compute_must_cache` /
    `must_cache`, the producer and query for the set this kwarg
    carries.
  * `src/history/delta.jl` (M7.2) — `DeltaEntry{T}` the L2 branch
    pushes.
  * `src/ir/<instr>.jl` (M7.3) — per-instruction `make_delta`
    methods this push site dispatches to.
  * `src/history/Replay.jl` (M4.3 / M7.4) — `unstep!`'s replay loop
    that passes `replay_mode=true` to suppress all pushes.
  * `spike/RETROSPECTIVE.md` Q2.2 — deepcopy semantics + the
    forward-before-push ordering invariant; the "deepcopy inside
    CheckpointEntry's constructor" decision pattern that lets
    `step!` stay free of explicit copying.
  * `spike/RETROSPECTIVE.md` Q3 — the Pass-1F reorder of forward-then-
    push fixing a corrupted-history bug. The lesson is encoded in
    this docstring's ordering invariant section above.
  * `src/history/CheckpointEntry.jl` (M4.1) — the entry type pushed,
    and the deepcopy contract that lets `step!` defer the copy.
  * `src/ir/RState.jl` (M2.3 / M4.2) — the `step_count` field this
    function mutates.
  * `src/ir/instructions.jl` (M2.4) — the generic `forward` fallback
    that catches any user-defined `Instruction` subtype outside the
    twelve-class sealed set.
  * `src/ir/control_instructions.jl` (M2.8) — `EndInstruction` and
    its pc-bumping `forward` method; the halt-marker the End-detection
    clause above keys on.
  * CLAUDE.md Rule 1 (out-of-range pc / unknown instruction / K<=0
    fail loud); Rule 11 (literate docstring); Rule 4 (the M3.3 and
    M4.2 tests pin known-correct pc / locals / status / count /
    history-length values, not just "didn't throw").
"""
function step!(s::RState, prog::VMProgram;
               checkpoint_interval::Int = 64,
               must_cache_set::Set{Tuple{Symbol, Int}} =
                   Set{Tuple{Symbol, Int}}(),
               replay_mode::Bool = false)::RState
    # (1) Silent no-op gate. The `===` comparison matches the M2.1
    # IState.status convention (identity on interned symbols). Returning
    # early here makes `step!` idempotent on a non-running state, which
    # is what lets the M3.4 `run!` loop reach for an `is_halted` check
    # at the *top* of the loop without worrying about a stray dispatch.
    # No step_count increment on this path (the brief's increment-only-
    # on-success rule — M4.2).
    s.current.status === :running || return s

    # (2) Validate `checkpoint_interval` at the boundary. Rule 1 / fail
    # loud: K=0 would `DivideError` at the modulo check below; K<0 is
    # well-defined Julia (Julia's `%` follows the sign of the dividend
    # for negative divisors) but silently useless — `step_count > 0`
    # combined with a negative K never matches `% K == 0` for K=-1 but
    # always matches for K=-step_count, an unpredictable footgun the
    # caller cannot reason about. The validation lives AFTER the early
    # return so a halted RState (whose status flips through `step!`
    # without consuming K) is not gated on the kwarg being sensible.
    checkpoint_interval > 0 ||
        error("step!: checkpoint_interval must be positive, got ",
              checkpoint_interval,
              ". A non-positive K disables periodic checkpointing in ",
              "a way the caller cannot reason about (K=0 would ",
              "DivideError; K<0 fires unpredictably). PRD v4 §3.3 ",
              "places no upper bound on K — pass `typemax(Int)` to ",
              "suppress pushes entirely. PRD v4 §3.16 (fail-loud ",
              "boundary) requires this validation at the entry to ",
              "step!, not deeper in the call stack.")

    # (2a) M7.6 — Capture `pc_before` BEFORE forward() / cross-block
    # dispatch overwrite it. Used at the push gate below to derive the
    # `(block_label, body_idx)` coordinate the M7.5 `must_cache` query
    # consults. For cross-block-exit instructions (Uncond/Cond Exit),
    # `s.current.pc` will be overwritten by `_dispatch_to_block!` to
    # the destination block's first body slot — but those Exit
    # instructions are themselves `ControlInstruction`s and hence
    # always injective (M6.1 type-level), so the M7.6 L2 branch never
    # fires for them anyway. Capturing `pc_before` here is the
    # uniform-shape choice: it is correct regardless of which
    # instruction class fires.
    pc_before = s.current.pc

    # (3) Resolve the instruction at the current pc. Out-of-range pc
    # raises in `_instruction_at` (Rule 1).
    instr = _instruction_at(prog, s.current.pc)

    # (3-CW-B2) End-at-depth>1 routing (ADR 0019 §4, §8). The lowering
    # frames EVERY function (entry routine AND callee) with the same
    # `EndInstruction` exit marker; depth decides its role:
    #
    #   * depth == 1 (the bottom :__entry frame) — `End` is the HALT marker
    #     exactly as today (handled at (6) below, unchanged).
    #   * depth  > 1 (a suspended caller exists) — `End` is the callee's
    #     RETURN: synthesize the `ReturnExit(fname, returns, frame.targets)` and
    #     dispatch IT instead. This single-marker-two-roles design is what lets
    #     a RECURSIVE function (whose one exit marker is reached at every
    #     activation depth) both halt at the top and return at every inner
    #     level. The synthesized `ReturnExit` is a real instruction: its
    #     `predelta_payload` captures the residual + `end_pc = s.pc` (the End
    #     marker's address — available HERE, before forward moves pc), its
    #     `forward` pops + lands, and the push gate records a
    #     `DeltaEntry{ReturnExit}` so `unstep!` reverses it via the L2 inverse.
    #     `fname` / `targets` / `link` come from the active frame; `returns` is
    #     the PER-BLOCK `EndInstruction.returns` (authoritative for THIS exit —
    #     a function with multiple ret blocks returns a different SSA name per
    #     block, so the marker's own returns is the correct value to read),
    #     EXCEPT for a VOID callee: the function table records empty declared
    #     returns, in which case the returns is forced empty (the per-block End
    #     marker may carry a dummy ret symbol that the void caller never lands).
    #     The empty-returns case also matches the void caller's empty `targets`,
    #     so the `ReturnExit` returns↔targets arity holds.
    if instr isa EndInstruction && length(s.current.frames) > 1
        fr = s.current.frames[end]
        rets = (haskey(prog.functions, fr.fname) &&
                isempty(prog.functions[fr.fname].returns)) ?
            Symbol[] : instr.returns
        instr = ReturnExit(fr.fname, rets, fr.targets)
    end

    # (3a) M_DYN (bd `bennettvm-ekc`) — PRE-`forward()` L2 delta capture.
    # An L2 delta whose `inverse` needs information DESTROYED by
    # `forward()` (the canonical case: `MemoryStore`, whose overwrite
    # loses the prior cell value) MUST capture that information BEFORE
    # `forward()` runs. The `predelta_payload(instr, s_pre)` hook
    # (`src/ir/<instr>.jl`; default `nothing` in `src/history/delta.jl`)
    # returns the minimal pre-state NamedTuple for such an instruction,
    # or `nothing` for every instruction whose `make_delta` is
    # pre-state-independent (the empty-payload finding, ADR 0002).
    #
    # We compute the capture HERE, before `forward()`, but ONLY when the
    # L2 branch at the push gate (7) would actually fire — i.e. when the
    # step is not replayed, the instruction is non-injective, AND its
    # (block_label, body_idx) is in `must_cache_set`. That gate decision
    # depends solely on `instr`, `pc_before`, `must_cache_set`, and
    # `replay_mode`, NONE of which `forward()` mutates, so it is sound to
    # evaluate it pre-`forward()`. Computing the L2 predicate once and
    # reusing it at the push gate (7) keeps the two in lockstep.
    #
    # MINIMALITY (the L2 space win — report item (b)). We do NOT
    # `deepcopy(s.current)` per step: that is the L3 cost (a full IState
    # snapshot), and paying it here would defeat the entire reason L2
    # exists (ADR 0009 Decision 2b: per-write O(1) delta, NOT a
    # whole-state snapshot; PRD §3.3 forbids full snapshots on the L2
    # path). We capture ONLY what `predelta_payload` asks for — for
    # `MemoryStore` that is one cell's value + its presence bit, an O(1)
    # NamedTuple. When `predelta_payload` returns `nothing` (every
    # existing non-injective instruction except `MemoryStore`), the push
    # gate falls back to the empty-payload `make_delta(instr, s.current,
    # step)` path unchanged — zero behavioural change for them.
    #
    # `local` so `pre_l2` / `pre_payload` are visible at the push gate.
    local pre_l2::Bool = false
    local pre_payload::Union{Nothing,NamedTuple} = nothing
    if !replay_mode && !is_injective(instr)
        # CW-B2 (ADR 0019 §4): an `is_unconditional_l2` instruction
        # (`ReturnExit`) pushes its L2 delta on EVERY forward step,
        # independent of `must_cache` — its history entry is the backward-
        # control-flow breadcrumb that routes `unstep!` into the callee's
        # `End` (ADR 0019 §4 property 2), not only a data-recovery payload.
        # It is also the block's EXIT marker, never a body slot, so
        # `compute_must_cache` (which scans only `block.instructions`) would
        # never select it — the unconditional flag is the ONLY path that
        # records its delta. `_block_index_at` is consulted ONLY on the
        # must_cache branch (the exit-marker pc would return the exit slot
        # index, irrelevant here).
        if is_unconditional_l2(typeof(instr))
            pre_l2 = true
            pre_payload = predelta_payload(instr, s.current)
        else
            (block_label, body_idx) = _block_index_at(prog, pc_before)
            if must_cache(must_cache_set, block_label, body_idx)
                pre_l2 = true
                pre_payload = predelta_payload(instr, s.current)
            end
        end
    end

    # (4) Dispatch into `forward`. The per-subtype methods (M2.6–M2.14)
    # mutate `s.current` in place — pc, locals, memory as appropriate.
    # Any unknown Instruction subtype falls through to the M2.4 generic
    # fallback, which raises with state context (Rule 1). If `forward`
    # throws, the exception propagates and `step_count` is NOT
    # incremented (the brief's "no increment on exception" rule). The
    # (3a) pre-state capture above is read-only on `s.current`, so a
    # throwing `forward` still leaves NO partial history entry: the push
    # at (7) is what appends to `s.history`, and it only runs AFTER a
    # successful `forward` (the exception-safety invariant the M4.2
    # forward-FIRST ordering protects — see the docstring above).
    forward(instr, s.current)

    # (5) Cross-block dispatch on Uncond/Cond Exit (M3.6). See M3.6
    # docstring §"What this layer adds on top of forward()" for the
    # full rationale on why this overwrites forward()'s pc bump.
    _handle_cross_block_dispatch!(s, prog, instr)

    # (5-CW-B2) Call dispatch on `CallEnter` (ADR 0019 §3). `CallEnter`'s
    # `forward` is a pc-bumping placeholder (it cannot see `prog`); the
    # substantive MOVE args + push the callee frame + bind params + jump to
    # the callee entry runs HERE, where `prog.functions` / `prog.label_table`
    # are in scope — the `_handle_cross_block_dispatch!` precedent. A no-op
    # for every non-`CallEnter` instruction. (`ReturnExit` needs nothing from
    # `prog`, so its full semantics live in `forward(::ReturnExit, s)`.)
    _handle_call_dispatch!(s, prog, instr)

    # (6) Halt detection on EndInstruction. AFTER forward + cross-block
    # has run, so the IState is in its post-step shape (pc has been
    # bumped, locals / memory updated).
    if instr isa EndInstruction
        s.current.status = :halted
    end

    # (7) M4.2 / M6.2 / M7.6 — Step-count increment + three-way push
    # gate. The increment happens unconditionally on success (the
    # early-return at (1) skips it; an exception in forward() /
    # cross-block propagates past it). The push gate composes:
    #
    #   - `replay_mode=true` (M7.6) suppresses ALL pushes, replacing
    #     the old `checkpoint_interval=typemax(Int)` trick at M4.3's
    #     replay loop (which only suppressed L3; M7.6 also has to
    #     suppress L2).
    #   - L1 (`is_injective(instr)` — M6.2): no push, ever. The inverse
    #     is recoverable from current state alone (Vieri Pendulum
    #     §4.2.1 + Mogensen RSSA §3 — see this docstring's
    #     §"M6.2 — L1 'no log' gate").
    #   - L2 (`must_cache(must_cache_set, label, idx)` — M7.6): push a
    #     DeltaEntry. Default empty set → L2 never fires → backwards-
    #     compat with M6.2 behaviour. `compute_must_cache(prog)`
    #     populates the set; M7.7 (and any production caller) opts in
    #     by passing it.
    #   - L3 (`step_count % checkpoint_interval == 0` — M4.2): push a
    #     CheckpointEntry. Safety net per PRD §3.3 lines 461-465.
    #
    # See this docstring's §"M7.6 — L2 delta push integration" for the
    # design-decision rationale (kwarg vs VMProgram field, the s_pre
    # simplification, the replay_mode flag).
    s.step_count += 1
    if !replay_mode
        if is_injective(instr)
            # L1 (M6.2). No push.
        elseif pre_l2
            # L2 (M7.6 / M_DYN). The (block_label, body_idx) ∈
            # must_cache_set decision was made at (3a), before
            # `forward()`, and recorded in `pre_l2`; recomputing it here
            # would re-walk the block layout for no gain and risk the two
            # decisions drifting apart. `pre_payload` is the pre-`forward()`
            # NamedTuple `predelta_payload` returned at (3a):
            #
            #   * NON-`nothing` (e.g. `MemoryStore`'s (addr, old_value,
            #     was_present)) → wrap it directly in a `DeltaEntry`. This
            #     is the M_DYN pre-state path: the destroyed cell value was
            #     captured BEFORE `forward()` overwrote it.
            #   * `nothing` (every other non-injective instruction, whose
            #     `make_delta` is pre-state-independent — the ADR 0002
            #     empty-payload finding) → fall back to
            #     `make_delta(instr, s.current, step)`, the post-`forward()`
            #     M7.6 path, unchanged.
            entry = pre_payload === nothing ?
                make_delta(instr, s.current, s.step_count) :
                DeltaEntry(instr, pre_payload, s.step_count)
            push!(s.history, entry)
        elseif s.step_count > 0 &&
               s.step_count % checkpoint_interval == 0
            # L3 (M4.2). The deepcopy is inside CheckpointEntry's
            # constructor (`src/history/CheckpointEntry.jl`);
            # doing it a second time here would be redundant and
            # confusing.
            push!(s.history, CheckpointEntry(s.current, s.step_count))
        end
    end

    return s
end

# ============================================================================
# M3.6 — cross-block dispatch (bd `bennettvm-yx3`).
#
# Extends `step!` so that the two non-fall-through control-flow exits —
# `UnconditionalExit` and `ConditionalExit` — actually transfer control
# to the destination block instead of stepping into the next flat-stream
# instruction. The per-instruction `forward()` methods on these classes
# only bump pc by 1 (control_instructions.jl M2.9 / M2.10), which is
# correct for straight-line programs (where the next block's entry
# happens to sit at pc+1 in the flat layout) but wrong for any program
# whose blocks are reordered, or whose conditional branches actually
# branch.
#
# ## What this layer adds on top of forward()
#
#   1. Resolves the destination block via `prog.label_table[target]`,
#      where `target` is `UnconditionalExit.target` or, for the
#      conditional case, `target_true` / `target_false` selected by
#      `s.locals[condition]`.
#   2. Performs the args→params positional rename: the sender's `args`
#      are removed from `locals` and re-inserted under the receiver's
#      `params` names. The rename is two-phase (capture-then-assign) so
#      that the identity case `args == params` is a structural no-op
#      rather than a delete-then-fail KeyError. See
#      `_rename_args_to_params!`.
#   3. Sets `s.current.pc = target_entry.fwd_address + 1` — i.e., one
#      past the destination block's entry marker. The marker itself is
#      a no-op-on-data (its `forward()` only bumps pc — see M2.9 / M2.10
#      docstrings); we have already done the rename here, so dispatching
#      `step!` again on the marker would either be a wasted iteration
#      OR a double-rename bug. Skipping it is the simpler, less error-
#      prone choice.
#
# ## Why "overwrite forward()'s pc" rather than "skip forward()"
#
# Two designs were considered:
#   (a) In step!, special-case `UnconditionalExit` / `ConditionalExit`
#       BEFORE calling forward(); do the rename + pc-set ourselves and
#       skip the forward() call entirely.
#   (b) Always call forward() (uniformity), let
#       `_handle_cross_block_dispatch!` OVERWRITE pc afterward for the
#       two control-flow-exit cases.
#
# We chose (b). The motivation is the same "uniform dispatch shape"
# that drives `step!`'s post-condition halt detection: the M4 history-
# bearing reshape (PRD v4 §3.3) will want to wrap the forward() call in
# a try-catch + push! pattern, and special-casing two instruction
# subtypes BEFORE that wrapper would force the same wrapper to live in
# two places (forward branch + skip branch) by M4. The cost of (b) is
# one wasted pc increment per cross-block step; the benefit is that
# step!'s body is a single, linearly-readable sequence of
# (forward → cross-block → halt-detection) calls regardless of which
# instruction class fires.
#
# ## Args/params arity mismatch is a Rule-1 failure
#
# `_rename_args_to_params!` errors loudly if `length(args) != length(params)`.
# At Phase 2 a cross-block arity mismatch must not exist in a well-formed
# IR — M2.18's `validate(::VMProgram)` pass (when it lands) will catch
# it at construction time. But UNTIL that pass exists, the dispatch
# layer is the last line of defense; failing silently here would
# produce a `KeyError` mid-block when the receiver-block's body first
# reads `:p`-but-`:p`-was-never-bound. The error message names both
# argument lists.
#
# Ref: bennettvm_prd.md (PRD v4) §3.11 — step! dispatch must do cross-
#      block control transfer for Uncond/Cond Exit.
# Ref: src/ir/control_instructions.jl M2.9 / M2.10 docstrings — the
#      pc-only convention at the per-instruction layer, deferring
#      cross-block dispatch to M3.x.
# Ref: src/ir/label_table.jl M2.16 §"Flat-instruction layout" — the
#      `fwd_address` semantics this layer reads.
# Ref: CLAUDE.md hallucination-risk callout "BobISA jumps encode the
#      source label" — BennettVM uses paired-entry dispatch via
#      LabelTable, not source-label encoding; this is the layer that
#      consumes the LabelTable.

"""
    _handle_cross_block_dispatch!(s::RState, prog::VMProgram, instr::Instruction)

If `instr` is a `UnconditionalExit` or `ConditionalExit`, perform the
cross-block control transfer: resolve the destination block via
`prog.label_table`, rename `args` → destination's `params`, and set
`s.current.pc` to one past the destination's entry marker. Otherwise
a no-op (the per-instruction `forward()` already advanced pc
correctly).

For `ConditionalExit`, the destination is selected by reading
`s.current.locals[instr.condition]`: nonzero → `target_true`,
zero → `target_false`. The predicate symbol is **not consumed** by
this dispatch — it remains in `locals` because RSSA's invertibility
argument depends on the predicate being live across the transition
(M2.10 §"φ-nodes appear at splits AND joins"; backward dispatch via
M4+'s `unstep!` will re-read the same symbol to recover the
predecessor). If a future M9 pebble pass needs the predicate
consumed at the Exit and re-emitted at the matching Entry, that
should land as a structural rewrite at IR-graph level, not a runtime
mutation here.

# Ref

  * `src/ir/control_instructions.jl` (M2.10) — ConditionalExit fields
    `condition` / `target_true` / `target_false` / `args`.
  * `src/ir/control_instructions.jl` (M2.9) — UnconditionalExit fields
    `target` / `args`.
"""
function _handle_cross_block_dispatch!(s::RState, prog::VMProgram,
                                       instr::Instruction)
    if instr isa UnconditionalExit
        _dispatch_to_block!(s, prog, instr.target, instr.args)
    elseif instr isa ConditionalExit
        # Nonzero predicate selects target_true; zero selects
        # target_false. IState.locals is Dict{Symbol,Int64}, so the
        # comparison is well-defined integer-vs-zero (no Bool
        # type-system needed at this milestone — Phase 0 retrospective
        # Q6 note on UnaryOp :not). The CLAUDE.md "Bool-typed regs"
        # caveat: until a type system lands, "true" is "nonzero" by
        # the same convention as C / LLVM IR.
        cond_val = active_locals(s.current)[instr.condition]   # CW-B2: frames[end].locals.
        target = cond_val != 0 ? instr.target_true : instr.target_false
        _dispatch_to_block!(s, prog, target, instr.args)
    end
    # All other instruction types: forward() already bumped pc to the
    # next flat-stream slot, which IS the correct destination for
    # straight-line / non-branching control flow.
    return s
end

"""
    _dispatch_to_block!(s::RState, prog::VMProgram, target::Symbol,
                        args::Vector{Symbol})

Transfer control to the block labelled `target`, passing the values
currently bound to `args` (positionally) to that block's entry-marker
`params` list. Sets `s.current.pc` to one past the destination's
entry marker (`fwd_address + 1`), bypassing the entry's `forward()`
call because we have already performed the rename ourselves.

# What "the destination's entry-marker params" means

The destination block's `entry::ControlInstruction` is one of
`BeginInstruction` (subroutine main), `UnconditionalEntry`
(basic-block-rooted main / unconditional join), or `ConditionalEntry`
(predicated join). All three carry a `params::Vector{Symbol}` field;
the rename uses that list as the receiving side.

Any other `ControlInstruction` subtype reaching the destination's
entry slot is rejected loudly — Rule 1 / PRD v4 §3.16. The
`BasicBlock` constructor (M2.15) already guarantees the entry slot
holds one of the three entry-direction subtypes, so this error is a
defensive catch-all for a future Instruction subtype that breaks
the M2.15 invariant.

# Ref

  * `src/ir/label_table.jl` (M2.16) — `LabelEntry.fwd_address` is the
    1-based flat-stream index of the destination block's entry
    instruction; `fwd_address + 1` is the first body instruction.
  * `src/ir/control_instructions.jl` (M2.8 / M2.9 / M2.10) — the
    three entry-direction subtypes with `params::Vector{Symbol}`.
"""
function _dispatch_to_block!(s::RState, prog::VMProgram, target::Symbol,
                             args::Vector{Symbol})
    target_entry = prog.label_table[target]
    target_block = prog.blocks[target_entry.block_index]

    entry_instr = target_block.entry
    # CW-B2 (ADR 0019 §1): the active register file is `active_locals(s.current)`
    # = `frames[end].locals`. Block-to-block dispatch renames into the CURRENT
    # activation's dict (cross-FUNCTION call/return — which pushes/pops frames —
    # is `CallEnter`/`ReturnExit`'s job, a later CW-B2 chunk).
    if entry_instr isa UnconditionalEntry
        _rename_args_to_params!(active_locals(s.current), args, entry_instr.params)
    elseif entry_instr isa ConditionalEntry
        _rename_args_to_params!(active_locals(s.current), args, entry_instr.params)
    elseif entry_instr isa BeginInstruction
        # Begin's params are the subroutine's formals; cross-block
        # dispatch arriving here is the main-routine call (the M2.14
        # CallInstruction surface is the proper Phase-2 home for full
        # subroutine semantics, but a plain Uncond/Cond Exit landing
        # on a Begin block — e.g., a main-rooted CFG where main was
        # encoded with a BeginInstruction rather than an
        # UnconditionalEntry — must also bind positionally).
        _rename_args_to_params!(active_locals(s.current), args, entry_instr.params)
    else
        error("_dispatch_to_block!: target block :", target,
              " has unexpected entry type ", typeof(entry_instr),
              " — must be one of UnconditionalEntry, ConditionalEntry, ",
              "or BeginInstruction (the M2.15 BasicBlock constructor ",
              "enforces this; a value reaching here indicates a broken ",
              "invariant somewhere upstream).")
    end

    # pc lands ONE PAST the entry marker (so the next step! dispatches
    # on the first body instruction). The entry marker is a no-op-on-
    # data; running its forward() here would either waste a step or —
    # worse — duplicate the args→params rename. See this file's M3.6
    # §"What this layer adds on top of forward()" comment, item 3.
    s.current.pc = target_entry.fwd_address + 1
    return s
end

"""
    _rename_args_to_params!(locals::Dict{Symbol,Int64},
                            args::Vector{Symbol},
                            params::Vector{Symbol})

Positional rename: for `i` in `1:length(args)`, the value at
`locals[args[i]]` is moved to `locals[params[i]]`. Two-phase
(capture all values, delete all args, then assign all params) so
that the identity case `args == params` is a no-op rather than a
delete-then-fail KeyError, AND so that renames that re-use names
across the boundary (e.g., `args=[:x,:y]`, `params=[:y,:x]`) work
correctly without intermediate stomping.

Arity mismatch (`length(args) != length(params)`) raises an
`ErrorException` (Rule 1 — until M2.18's `validate(::VMProgram)`
pass lands, the dispatch layer is the last line of defense).

# Ref

  * CLAUDE.md Rule 1 — fail loud on arity mismatch.
  * M2.18 (not yet landed) — the cross-block invariant pass that
    will catch the same mismatch at construction time.
"""
function _rename_args_to_params!(locals::Dict{Symbol,Int64},
                                 args::Vector{Symbol},
                                 params::Vector{Symbol})
    length(args) == length(params) ||
        error("_rename_args_to_params!: args/params arity mismatch — ",
              "args=", args, " (length ", length(args), ") vs ",
              "params=", params, " (length ", length(params), "). ",
              "A cross-block edge with mismatched sender/receiver ",
              "arity is malformed RSSA; M2.18's validate pass will ",
              "catch this at construction time once it lands.")
    # Two-phase: capture, delete, assign. Necessary for the identity
    # case (args == params) and for the cross-permutation case
    # (args = [:x,:y], params = [:y,:x]).
    values = Int64[locals[a] for a in args]
    for a in args
        delete!(locals, a)
    end
    for (p, v) in zip(params, values)
        locals[p] = v
    end
    return locals
end

"""
    _handle_call_dispatch!(s::RState, prog::VMProgram, instr::Instruction)

If `instr` is a `CallEnter`, perform the reversible call transition (ADR
0019 §3): COPY the args into a fresh callee activation, PUSH it, BIND the
copied values positionally under the callee's formal params, and JUMP to
the callee's entry (one past its Begin marker). A no-op for every other
instruction type — the `_handle_cross_block_dispatch!` sibling that runs
immediately before this.

The args are COPIED, not moved (CW-C3, ADR 0019 Amendment A): ADR 0019 §3
specified the Vieri 1995 p.22 MOVE (read-and-drop) on the premise that a
call arg is dead after the call — true for reversible-by-construction
source, false for our irreversible-LLVM-IR callees, where an SSA value is
MULTI-USE (a C `-O0` `alloca` pointer is passed to a callee AND read back
after). So the caller KEEPS its bindings; the copy is a pure deterministic
function of caller state, so the backward pass (M4.3 / L3 replay)
reconstructs both the untouched caller arg and the re-copied callee param.
The MOVE discipline now governs the RETURN side only. The return site is
saved in `Frame.link = pc_before + 1` (BobISA's branch register); the
landing `targets` ride the frame so the matching `ReturnExit` (or
End-at-depth>1) can un-land them.

Fail-loud (ADR 0019 §6): unknown callee (closed-world miss) and call arity
mismatch (args↔params). The old "targets name already live" SSA-violation
guard is GONE (CW-C3, ADR 0019 Amendment A): a live target is OVERWRITTEN
on return (its prior value captured in the L2 `target_olds` payload), not
rejected — C `-O0` redefines a call-result SSA name every loop iteration.

# Ref

  * `docs/adr/0019-reversible-calls.md` §3 (CallEnter forward), §6 (a,b;
    the §6c live-target guard is superseded by Amendment A / CW-C3).
  * `src/ir/call_transitions.jl` — the `CallEnter` instruction.
  * `src/ir/call_frames.jl` — `Frame` / `FunctionEntry`.
"""
function _handle_call_dispatch!(s::RState, prog::VMProgram,
                                instr::Instruction)
    instr isa CallEnter || return s

    # (a) Closed-world callee resolution (ADR 0019 §6a). The ingest guard-5
    # already validated the callee at lowering time, but the dispatch layer
    # is the last line of defense for a hand-built program (Rule 1).
    haskey(prog.functions, instr.callee) ||
        error("_handle_call_dispatch!: unknown callee :", instr.callee,
              " — not in the function table (known: ",
              sort!(collect(keys(prog.functions))), "). Indirect / open-world ",
              "calls are deferred (ADR 0019 §6a, §7); Rule 1 fail-loud.")
    fe = prog.functions[instr.callee]

    # (b) Call arity check (ADR 0019 §6b).
    length(instr.args) == length(fe.params) ||
        error("_handle_call_dispatch!: call arity mismatch for :",
              instr.callee, " — ", length(instr.args), " arg(s) ", instr.args,
              " vs ", length(fe.params), " param(s) ", fe.params,
              " (ADR 0019 §6b; Rule 1 fail-loud).")

    caller = active_locals(s.current)

    # COPY args into the callee (CW-C3 — the LLVM-IR adaptation of ADR 0019 §3's
    # MOVE). ADR 0019 §3 specified a MOVE (Vieri p.22 — read the arg, DELETE it
    # from the caller) on the premise that a call arg is dead after the call,
    # which holds for reversible-by-construction source (BobISA/RC3/Janus). Our
    # callees are lowered from irreversible C/Rust/Julia LLVM IR, where an SSA
    # value has MULTIPLE uses: a C `-O0` pointer like `%found = alloca i64` is
    # passed to `ht_get(..., ptr %found)` AND read back afterwards (`load ptr
    # %found`). DELETING it on the call would make the post-call use read an
    # undefined name — a forward miscompile. This is the SAME assumption-mismatch
    # ADR 0019 §"the constraint that drives everything" already documents for the
    # RETURN side (callees arrive with dead temporaries live at End, so the return
    # logs a residual). The symmetric adaptation on the CALL side is: do NOT
    # consume the caller's arg — COPY its value into the callee. Reversibility is
    # UNAFFECTED: CallEnter stays L1 (no own history push) and is reversed by L3
    # checkpoint-replay (ADR 0019 §3 normative note — replay re-runs `forward`
    # deterministically); a copy is a pure deterministic forward function of
    # caller state, so the replay reconstructs both the caller arg (untouched) and
    # the callee param (re-copied). The copied value is captured in the callee's
    # ReturnExit residual on return (ADR 0019 §4), so the floor's per-call cost is
    # the residual it already pays. A dead-after-call arg simply lingers in the
    # caller frame (harmless; round-trips); shrinking that via liveness is the
    # deferred optimisation tier (ADR 0002 / §7), never a correctness gate.
    argv = Int64[]
    for a in instr.args
        haskey(caller, a) ||
            error("_handle_call_dispatch!: arg :", a, " is absent from the ",
                  "caller frame (reading an undefined SSA name as a call arg; ",
                  "ADR 0019 §6f; Rule 1 fail-loud).")
        push!(argv, caller[a])
    end

    # ADVANCE the call-stack cursor by the CALLER's frame size (CW-C3, ADR 0019;
    # `src/ir/IState.jl` `stack_top`). The caller is the CURRENT top frame (still
    # active — the callee is not pushed yet). Its static allocas occupy cells
    # `stack_top + 1 … stack_top + caller_frame_size` of the global stack
    # segment; advancing past that region BEFORE the callee runs makes the
    # callee's own (compile-time-cell `1…F_callee`) `StackAlloca`s land at
    # `new_stack_top + 1 …`, DISJOINT from the caller — so a nested C `-O0` call
    # no longer clobbers its caller's memory-backed locals (the CW-C3 wall). The
    # matching `ReturnExit` retracts the same amount, so `stack_top` round-trips.
    # The `:__entry` bottom frame's name is in the table (it is the entry
    # function); a callee with no allocas has caller_frame_size contribution only
    # from the caller, never itself. A missing caller in the table is a Rule-1
    # corruption (every active frame names an in-module function).
    # The bottom (`:__entry`) frame runs the ENTRY function's code but carries the
    # reserved `:__entry` name (IState's constructor builds it; ADR 0019 §1), so
    # its frame size is the entry function's. Any other active frame names an
    # in-module function directly. A name that is neither is a corrupted stack.
    caller_fname = s.current.frames[end].fname
    caller_lookup = caller_fname === :__entry ? prog.entry_function : caller_fname
    haskey(prog.functions, caller_lookup) ||
        error("_handle_call_dispatch!: active (caller) frame names :",
              caller_fname, " which is absent from the function table (known: ",
              sort!(collect(keys(prog.functions))), ") — a corrupted call stack ",
              "(CW-C3 stack_top advance needs the caller frame size; Rule 1 ",
              "fail-loud).")
    stack_delta = prog.functions[caller_lookup].frame_size
    s.current.stack_top += stack_delta

    # PUSH the callee activation. `link = pc_before + 1` is the return site
    # (the flat-stream slot AFTER the CallEnter, where forward() bumped pc to
    # — but `_handle_cross_block_dispatch!` ran first and is a no-op for
    # CallEnter, so `s.current.pc` is exactly `pc_before + 1` here). The
    # `stack_delta` (= caller frame size advanced above) rides the Frame so the
    # matching `ReturnExit` retracts EXACTLY this on pop without consulting
    # `prog` (CW-C3; `src/ir/call_frames.jl` Frame.stack_delta).
    callee_locals = Dict{Symbol,Int64}()
    for (p, v) in zip(fe.params, argv)
        callee_locals[p] = v
    end
    link = s.current.pc
    push!(s.current.frames, Frame(link, instr.targets, callee_locals,
                                  instr.callee, stack_delta))

    # JUMP to the callee entry: one past its Begin marker (the
    # `_dispatch_to_block!` convention — the entry marker is a no-op-on-data
    # whose forward we skip because we have bound the params ourselves).
    entry_addr = prog.label_table[fe.entry_label]
    s.current.pc = entry_addr.fwd_address + 1
    return s
end

# ============================================================================
# M3.4 — `run!` loop with max-steps guard (bd `bennettvm-fbh`).
#
# `run!(s::RState, prog::VMProgram; max_steps=10_000)::RState` is the
# canonical forward driver: a simple loop that calls `step!` until
# `is_halted(s)` reports the entry-subroutine `EndInstruction` has fired,
# OR until `max_steps` iterations have elapsed — whichever comes first.
# On the first condition the RState is returned (mutated in place) with
# `status === :halted`; on the second condition the loop raises an
# `ErrorException` with the step count, the current pc, and the current
# status embedded in the message (Rule 1 / PRD v4 §3.16).
#
# ## Why this is its own function rather than inlined at every site
#
# Every caller of the interpreter — Phase-2 tests, the M5 Handoff-A
# bridge, the M9 pebble-scheduler post-pass, the M11 cross-target
# semantics theorem's witness driver — wants exactly the same "loop
# step! to halt with a divergence guard" shape. Centralising it here
# means one definition for the guard semantics, one error message
# template, one place to evolve the loop when (e.g.) M4 adds the
# history-bearing variant or when M9 needs an interrupt-checkpoint
# variant. Inlining the loop at every site would scatter the Rule-1
# discipline across the codebase and make a future generalisation an
# audit nightmare.
#
# ## Why the max-steps guard is binding
#
# PRD v4 §3.16 forbids silent partial returns. Phase-2 programs can
# diverge for principled reasons (SC9 Case D `collatz_steps` is the
# motivating example — termination is proved by Collatz conjecture for
# known inputs, but no static bound exists). Without a guard, a
# runaway program loops forever; with a silent return, the caller
# cannot distinguish "program halted normally" from "program ran out
# of patience mid-execution". Both modes are bugs the spike Q3 area
# retrospective flagged as load-bearing — Phase 2 must reject them at
# the boundary.
#
# The guard's *value* (10_000 default) is conservative for the four
# SC9 motivating cases of PRD v4 §3.6.2: a Case-A `fdict` walk over a
# 256-entry table is ~5_000 dispatches, Case B / C / D need a higher
# bound passed explicitly by the caller. The default is "loud enough
# to catch hello-world infinite loops, quiet enough that small tests
# don't have to think about it"; callers that know their program
# diverges should pass a higher bound or a sentinel like `typemax(Int)`
# (which still triggers a *finite* check at integer overflow time, so
# remains Rule-1-compliant — Julia's `>=` on `typemax(Int)` is defined,
# not UB).
#
# ## Why the RState is left mid-run on guard fire (not reset)
#
# The error message says so explicitly: "the RState is left mid-run
# for inspection / unrun!". This is the discipline that lets M4's
# history-bearing `unrun!` (when it lands) recover the pre-guard state
# by rolling back the partial history. Resetting the RState in the
# guard error handler would destroy that recovery path; raising while
# leaving state intact preserves it.
#
# ## Why the loop terminator is `is_halted` (not pc-past-end)
#
# The same reasoning as M3.3's EndInstruction halt detection (see the
# `step!` docstring §"Halt is detected on EndInstruction, not on
# pc-past-end"). A future multi-subroutine program may have intermediate
# `EndInstruction`s at pc values NOT past the end of the flat stream;
# the marker-based `is_halted` predicate handles that case correctly
# where a pc-bounds check would not.
#
# Ref: bennettvm_prd.md (PRD v4) §3.16 — max-steps guard must be
#      descriptive and must NOT silently return.
# Ref: spike/RETROSPECTIVE.md Q3 — silent partial-return failure mode.
# Ref: CLAUDE.md Rule 1 (fail loud); Rule 4 (every test asserts a
#      known-correct value, not just "didn't throw").
#
# ## B1 (bd `bennettvm-zr7x`) — `record::Bool` fast mode
#
# Track B of the framerate strategy (`docs/design/emulator-on-bennettvm.md`
# §9.2) needs a **forward-only fast mode**: run to halt with NO
# reversibility tape, to (a) measure raw forward throughput and (b)
# validate correctness at speed, decoupled from "is reversible". The
# M7.6 `replay_mode::Bool` kwarg on `step!` ALREADY suppresses every
# L1/L2/L3 push when `true` (see `step!`'s docstring §"M7.6 — L2 delta
# push integration") — that machinery is REUSED verbatim, not
# reinvented. What's missing is a narrow, user-facing name for it:
# `test/test_per_step_inverse.jl`'s top-of-file comment documents that
# `replay_mode` is "deliberately NOT exposed: it is an internal kwarg
# … Per CLAUDE.md Rule 1, we keep the failure surface narrow." `record`
# is that dedicated public surface — `run!(s, prog; record=false)` — so
# ordinary callers reach for a documented forward-only mode instead of
# being told to pass an internal replay flag.
#
# `record=false` ALSO sets `s.fast_mode = true` (`src/ir/RState.jl`),
# a monotonic taint bit `unstep!` (`src/history/Replay.jl`) checks and
# refuses to run past. Without that bit, `unstep!`'s existing
# fall-back-to-`s.initial`-and-replay path (which exists to reverse a
# *normal* run that simply hasn't pushed any checkpoint yet) would
# ALSO silently "succeed" on a fast-mode RState — replaying the ENTIRE
# program forward from scratch on every single backward step, an
# O(n) cost per `unstep!` and O(n²) for a full `unrun!`. That is
# technically correct (deterministic replay) but is exactly the
# "runs, just catastrophically slowly" trap Rule 4 forbids papering
# over with a passing-looking round-trip test — see `RState.jl`
# §"Why this can't be inferred from `isempty(history)`" for the full
# argument. So `unrun!`/`unstep!` after a fast-mode run FAIL LOUD
# instead (see `src/history/Replay.jl`), by design.

"""
    run!(s::RState, prog::VMProgram;
         max_steps::Int = 10_000,
         checkpoint_interval::Int = 64,
         must_cache_set::Set{Tuple{Symbol, Int}} =
             Set{Tuple{Symbol, Int}}(),
         replay_mode::Bool = false,
         record::Bool = true) -> RState

Repeatedly `step!` until `is_halted(s)`, or until `max_steps`
steps have been taken — whichever first. Errors descriptively if
the max-steps guard fires (Rule 1; PRD v4 §3.16). The RState is
mutated in place; the same RState is returned for chaining.

The max-steps guard exists because Phase-2 programs may diverge:
SC9 Case D (`collatz_steps`) terminates for known inputs but not
in general. Without a guard, a runaway program would loop forever;
with a silent return, the caller could not distinguish "program
ran to halt" from "program hit the guard mid-execution" — both
bugs the spike retrospective flagged as load-bearing.

On guard fire, the error message includes the step count, the
current pc, and the current status — so a debugger can pick up
where execution stopped, AND the RState is left in its mid-run
state so `unrun!` (M4+) can roll it back.

# M4.2 — `checkpoint_interval` forwarding

The `checkpoint_interval::Int = 64` kwarg is forwarded verbatim to
every `step!` call. Default (64) matches PRD v4 §3.3's placeholder.
Pass `typemax(Int)` to suppress periodic checkpoint pushes entirely
(useful for tests that exercise non-history aspects of `run!`); a
non-positive value raises descriptively inside `step!` (Rule 1).
This is the M4.2 plumbing that lets the caller — `unrun!` (M4.4),
tests, the M5 Handoff-A bridge — choose the L3 history density
without re-implementing the loop driver. See `step!` docstring
§"M4.2 — Checkpoint push" for the per-step push semantics.

# M7.6 — `must_cache_set` and `replay_mode` forwarding

Both new M7.6 kwargs are forwarded verbatim to every `step!` call.

  * `must_cache_set::Set{Tuple{Symbol, Int}}` — the L2 must-cache
    set produced by `compute_must_cache(prog)`
    (`src/analysis/liveness.jl`). Default empty → L2 path never
    fires → backwards-compat with M6.2 behaviour. Production
    callers pass `compute_must_cache(prog)` to opt into L2.
  * `replay_mode::Bool` — when `true`, ALL pushes (L2 and L3) are
    suppressed. M4.3's `unstep!` replay loop sets this to `true`.
    Default `false` for backwards compat with every pre-M7.6 caller.

See `step!` docstring §"M7.6 — L2 delta push integration" for the
full design rationale (kwarg-vs-VMProgram-field decision, the
`s_pre` simplification, and the `replay_mode` semantics).

# B1 (bd `bennettvm-zr7x`) — `record::Bool` fast mode

`record::Bool = true`. Pass `record = false` for **fast mode**:
`run!` forwards `replay_mode = true` to every `step!` call regardless
of the caller's own `replay_mode` value (the two are OR'd — see this
file's top-of-section §"B1 … `record::Bool` fast mode" comment above
for the full rationale), so NO L1/L2/L3 history entry is ever pushed,
and sets `s.fast_mode = true` on entry (`src/ir/RState.jl`) so that
`unstep!` / `unrun!` (`src/history/Replay.jl`) refuse to run on this
`RState` afterward — loudly, not silently. `checkpoint_interval` and
`must_cache_set` are still accepted (for call-site symmetry with the
recording path) but are moot in fast mode: `step!`'s push gate is
short-circuited by `replay_mode` before either kwarg is consulted.

The marking is monotonic: once any `run!(...; record=false)` call has
touched an `RState`, `s.fast_mode` stays `true` even if a later call
passes `record=true` — the tape gap during the fast stretch can never
be un-created. Forward correctness (`result(s)`) is identical to the
`record=true` path bit-for-bit — fast mode only removes the *history*,
never changes `forward()`'s dispatch.

# Arguments

  * `s` — RState; mutated in place.
  * `prog` — the VMProgram being executed.
  * `max_steps` — keyword; default 10_000. Pick higher for unbounded-
    loop programs like `collatz_steps(::Int8)`.
  * `checkpoint_interval` — keyword; default 64. Forwarded to every
    `step!` call. Moot when `record = false`.
  * `must_cache_set` — keyword; default empty. Forwarded to every
    `step!` call (M7.6). Moot when `record = false`.
  * `replay_mode` — keyword; default `false`. Forwarded to every
    `step!` call (M7.6), OR'd with `!record`.
  * `record` — keyword; default `true`. `false` selects B1 fast mode
    (see above).

# Returns

`s` (the same mutated RState).

# Errors

`ErrorException` if `step!` doesn't reach `:halted` within `max_steps`
iterations. Also raises (via `step!`) if `checkpoint_interval <= 0`.

# Ref

  * PRD v4 §3.16 — descriptive error on max-steps exceed; no silent
    partial returns.
  * PRD v4 §3.3 — the three-layer history scheme; default
    `checkpoint_interval = 64` matches the §3.3 placeholder.
  * `src/interpreter/Interpreter.jl` M3.3 / M4.2 — `step!`,
    `is_halted`, the per-step push semantics.
  * `spike/RETROSPECTIVE.md` Q3 — silent-partial-return failure mode.
  * CLAUDE.md Rule 1 (fail loud); Rule 11 (literate docstring).
"""
function run!(s::RState, prog::VMProgram;
              max_steps::Int = 10_000,
              checkpoint_interval::Int = 64,
              must_cache_set::Set{Tuple{Symbol, Int}} =
                  Set{Tuple{Symbol, Int}}(),
              replay_mode::Bool = false,
              record::Bool = true)
    # B1 (bd `bennettvm-zr7x`). `record=false` is FAST MODE: OR it into
    # `replay_mode` so every step! call below suppresses ALL history
    # pushes (reusing the M7.6 machinery verbatim — see this function's
    # top-of-section comment and docstring §"B1 … fast mode"), and
    # permanently taint `s.fast_mode` so `unstep!`/`unrun!` fail loud
    # afterward instead of silently full-replaying from `s.initial` on
    # every backward step (`src/ir/RState.jl` §"Why `fast_mode` …").
    # Marking happens unconditionally (even if `s` is already halted /
    # zero steps run) — a `record=false` call is itself the taint
    # event, not a side effect of iterating.
    record || (s.fast_mode = true)
    effective_replay_mode = replay_mode || !record

    n = 0
    # Bennett-utzc / CW-D (ADR 0017 §4) — loop while RUNNING, not while
    # `!is_halted`. `is_halted` is `status === :halted`, so `!is_halted` is
    # `status !== :halted`, which is `true` for BOTH `:running` AND `:error`
    # — a `:__unreachable__` sink (which sets `:error`, never `:halted`) would
    # spin to `max_steps` under the old condition. `status === :running` exits
    # the loop the instant the sink traps. This is BEHAVIOURALLY IDENTICAL for
    # every existing program: `:error` was until now unproducible in `src/`, so
    # while running `status === :running ⟺ !is_halted` held exactly.
    while s.current.status === :running
        n >= max_steps && error(
            "run!: max_steps=$max_steps exceeded ",
            "(pc=$(s.current.pc), status=$(s.current.status)). ",
            "The RState is left mid-run for inspection / unrun!. ",
            "Increase max_steps or check for non-termination.")
        step!(s, prog;
              checkpoint_interval=checkpoint_interval,
              must_cache_set=must_cache_set,
              replay_mode=effective_replay_mode)
        n += 1
    end
    # Bennett-utzc / CW-D (ADR 0017 §4) — loud fail on the halt sink. A clean
    # exit leaves `status === :halted` (normal `EndInstruction` termination);
    # `status === :error` means the loop exited because a `:__unreachable__`
    # halt sink was TAKEN — a provably-dead throw arm fired, which is a
    # compiler/analysis contradiction (Rule 1 fail-loud). The RState is left
    # mid-run for inspection, exactly as the max_steps guard does.
    s.current.status === :error && error(
        "run!: reached the :__unreachable__ halt sink (status=:error) at ",
        "pc=$(s.current.pc) — a provably-dead throw arm (Bennett-utzc / ",
        "ADR 0017 §4) was TAKEN; the reversible program has trapped. ",
        "RState left mid-run for inspection.")
    return s
end
