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
    return copy(s.current.locals)
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
    step!(s::RState, prog::VMProgram) -> RState

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
     M3.4 loop can rely on the idempotent shape.
  2. **Resolve the instruction at the current pc** via `_instruction_at`
     (above). Out-of-range pc raises descriptively (Rule 1).
  3. **Dispatch into `forward(instr, s.current)`** — the per-subtype
     forward methods (M2.6 ArithmeticAssignment, M2.7 SwapInstruction,
     M2.8 Begin/End, M2.9 Uncond entry/exit, M2.10 Cond entry/exit,
     M2.11 MemoryAssignment, M2.14 CallInstruction). Each method
     mutates `s.current` in place — bumping `pc`, updating `locals` /
     `memory` as appropriate — and returns the same `IState`.
  4. **Halt detection.** If `instr isa EndInstruction`, set
     `s.current.status = :halted` AFTER the forward call has run. The
     `forward(::EndInstruction, ...)` method has already bumped `pc`
     past the End marker; the status transition signals to `run!`
     (M3.4) and to `is_halted` (M3.2) that no further `step!` calls
     should execute on this RState.

# Ordering invariant — forward FIRST, history push (future) SECOND

M3.3 is the **forward-only** step — there is no history operation
yet; the L3-checkpoint / L2-delta / L1-injective layers (PRD v4 §3.3)
arrive at M4. But the ordering convention is baked in here, in this
docstring, against the moment M4 adds the push:

> The history push MUST come AFTER `forward(...)`, not before.

The Phase-0 spike's `step!` originally pushed the pre-state snapshot
BEFORE calling `forward`; an exception inside `forward` (a div-by-zero,
an unsupported instruction, …) would then leave a partial history
entry referring to a state that the IState never actually moved through.
The corrupted history corrupted `unrun!` in turn, producing a phantom
"reversibility violation" that took the spike's Pass-1 review cycle
to track down. Pass-1F reordered the push to come AFTER `forward`,
which is what fixed it. See `spike/RETROSPECTIVE.md` Q3 for the full
account.

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

# Ref

  * `bennettvm_prd.md` (PRD v4) §3.11 — `step!(rstate, prog) :: RState`
    signature and forward-only scope at M3.3.
  * `spike/RETROSPECTIVE.md` Q3 — the forward-before-push ordering
    bug that fell out of Pass-1 review and was fixed by Pass-1F's
    reorder. The lesson is documented here proactively against the
    M4 history-bearing reshape.
  * `src/ir/instructions.jl` (M2.4) — the generic `forward` fallback
    that catches any user-defined `Instruction` subtype outside the
    twelve-class sealed set.
  * `src/ir/control_instructions.jl` (M2.8) — `EndInstruction` and
    its pc-bumping `forward` method; the halt-marker the End-detection
    clause above keys on.
  * CLAUDE.md Rule 1 (out-of-range pc / unknown instruction fail
    loud); Rule 11 (literate docstring); Rule 4 (the M3.3 tests
    that pin this behavior assert known-correct pc / locals /
    status values, not just "didn't throw").
"""
function step!(s::RState, prog::VMProgram)::RState
    # (1) Silent no-op gate. The `===` comparison matches the M2.1
    # IState.status convention (identity on interned symbols). Returning
    # early here makes `step!` idempotent on a non-running state, which
    # is what lets the M3.4 `run!` loop reach for an `is_halted` check
    # at the *top* of the loop without worrying about a stray dispatch.
    s.current.status === :running || return s

    # (2) Resolve the instruction at the current pc. Out-of-range pc
    # raises in `_instruction_at` (Rule 1).
    instr = _instruction_at(prog, s.current.pc)

    # (3) Dispatch into `forward`. The per-subtype methods (M2.6–M2.14)
    # mutate `s.current` in place — pc, locals, memory as appropriate.
    # Any unknown Instruction subtype falls through to the M2.4 generic
    # fallback, which raises with state context (Rule 1).
    forward(instr, s.current)

    # (4) Halt detection on EndInstruction. AFTER forward has run, so
    # that an exception in forward leaves status as `:running` and the
    # RState unchanged from before the step — the same atomicity the
    # M4 forward-FIRST history-push ordering will rely on (see
    # docstring §"Ordering invariant"). Per RC3 RSSAVM.java:585-590,
    # the main-routine End marker is the halt signal.
    if instr isa EndInstruction
        s.current.status = :halted
    end

    return s
end
