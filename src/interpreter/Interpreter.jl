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

    # (4) Cross-block dispatch on Uncond/Cond Exit (M3.6). The per-
    # subtype `forward(::UnconditionalExit, ...)` and
    # `forward(::ConditionalExit, ...)` methods only bump pc by 1 at
    # the per-instruction layer (control_instructions.jl M2.9 / M2.10
    # docstring §"Forward / inverse semantics — pc-only"); the
    # block-boundary relocation (consulting `prog.label_table` to
    # land pc on the destination block's first body instruction) and
    # the args→params positional rename are this layer's
    # responsibility. The forward() pc-bump is OVERWRITTEN by
    # `_dispatch_to_block!` — keeping the uniform "always call
    # forward()" shape at this dispatch site costs one wasted
    # increment per cross-block step but means the step! body never
    # has to special-case which instructions skip forward(). See the
    # M3.6 cross-block dispatch §"Why overwrite, not skip" comment
    # on `_handle_cross_block_dispatch!`.
    _handle_cross_block_dispatch!(s, prog, instr)

    # (5) Halt detection on EndInstruction. AFTER forward has run, so
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
        cond_val = s.current.locals[instr.condition]
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
    if entry_instr isa UnconditionalEntry
        _rename_args_to_params!(s.current.locals, args, entry_instr.params)
    elseif entry_instr isa ConditionalEntry
        _rename_args_to_params!(s.current.locals, args, entry_instr.params)
    elseif entry_instr isa BeginInstruction
        # Begin's params are the subroutine's formals; cross-block
        # dispatch arriving here is the main-routine call (the M2.14
        # CallInstruction surface is the proper Phase-2 home for full
        # subroutine semantics, but a plain Uncond/Cond Exit landing
        # on a Begin block — e.g., a main-rooted CFG where main was
        # encoded with a BeginInstruction rather than an
        # UnconditionalEntry — must also bind positionally).
        _rename_args_to_params!(s.current.locals, args, entry_instr.params)
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

"""
    run!(s::RState, prog::VMProgram; max_steps::Int = 10_000) -> RState

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

# Arguments

  * `s` — RState; mutated in place.
  * `prog` — the VMProgram being executed.
  * `max_steps` — keyword; default 10_000. Pick higher for unbounded-
    loop programs like `collatz_steps(::Int8)`.

# Returns

`s` (the same mutated RState).

# Errors

`ErrorException` if `step!` doesn't reach `:halted` within `max_steps`
iterations.

# Ref

  * PRD v4 §3.16 — descriptive error on max-steps exceed; no silent
    partial returns.
  * `src/interpreter/Interpreter.jl` M3.3 — `step!`, `is_halted`.
  * `spike/RETROSPECTIVE.md` Q3 — silent-partial-return failure mode.
  * CLAUDE.md Rule 1 (fail loud); Rule 11 (literate docstring).
"""
function run!(s::RState, prog::VMProgram; max_steps::Int = 10_000)
    n = 0
    while !is_halted(s)
        n >= max_steps && error(
            "run!: max_steps=$max_steps exceeded ",
            "(pc=$(s.current.pc), status=$(s.current.status)). ",
            "The RState is left mid-run for inspection / unrun!. ",
            "Increase max_steps or check for non-termination.")
        step!(s, prog)
        n += 1
    end
    return s
end
