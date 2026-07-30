"""
    CallInstruction (M2.14)

The sixth concrete RSSA instruction in BennettVM's twelve-subclass
taxonomy (`docs/adr/0001-rc3-rvm-smoke.md` §Observations, row 6:
RC3 `CallInstruction` / candidate name `Call`). Implements the RC3
procedure-call form

    (x,...) := call/uncall l(y,...)

where `targets` (`x,...`) is a list of *created* SSA names that receive
the callee's outputs, `args` (`y,...`) is a list of *destroyed* SSA
names whose values are passed to the callee, `callee` (`l`) is the
subroutine label, and `direction ∈ {:call, :uncall}` is the source-
level direction marker that the RC3 design unifies under a single
class (ADR 0001 §Observations Structural-Pattern point 4 / decision
table row "Call/Uncall unification").

# Why one class, two directions

ADR 0001 §Observations Structural-Pattern point 4 (and decision-table
row "Call/Uncall unification") locks the RC3 design choice: rather
than two distinct opcodes (`Call`, `Uncall`) — the spike-style design
that fans out two structural primitives where one suffices — RC3
collapses both forms into a single `CallInstruction` carrying a
`direction::Direction` field. Phase-2 BennettVM follows the same
pattern; the field here is a `Symbol` (`:call` or `:uncall`) for
parity with `IState.status` and `ArithmeticAssignment.modop`'s
small-finite-tag-set convention. The single-class design composes
cleanly with the VM-level direction flag (`docs/adr/0001-rc3-rvm-smoke.md`
§Observations decision-table row "Direction flag" — one per-VM
`Direction` enum flipped at run start, NOT per-instruction), giving
the XOR-of-directions semantics encoded in `effective_call_direction`
below.

# Scoping (CRITICAL) — what M2.14 does, and what M3.x does

The bead text (`bennettvm-dp1` DESCRIPTION) reads: *"forward(call) and
inverse(call) dispatch to the callee's run!/unrun! respectively;
raises a descriptive error if callee is not registered."* That
description is correct **for the eventual M3.x interpreter**, but it
conflates two layers and would require infrastructure that does not
yet exist at M2.14:

  * The **callee registry** (label → BasicBlock list, with type-
    checked parameter / return-value lists) lives on `VMProgram`
    (M2.17 — `bennettvm-cm5` — not yet implemented).
  * The **recursive sub-execution** that runs the callee's
    BasicBlocks forward or backward lives in the M3.x interpreter
    (`bennettvm-*` M3.1–M3.4 — not yet implemented).
  * The **direction composition** that picks forward vs backward
    callee execution from `(instr.direction, vm.direction)` is the
    XOR-of-directions semantics captured by `effective_call_direction`
    in this file.

**M2.14 lays the type foundation only**: the struct + inner
constructor (which Rule-1-validates the invariants that ARE local to
the per-instruction layer), the pc-only `forward` / `inverse` methods
that match the M2.8 / M2.9 / M2.10 control-flow-marker template, and
the `effective_call_direction` helper that documents the eventual
XOR-of-directions semantics now while the design is fresh. The actual
subroutine invocation arrives with M3.x once the LabelTable / VMProgram
machinery exists; trying to inline it here would require a forward
reference to types that do not exist yet.

This is intentionally the same pc-only-now / cross-instruction-rewrite-
later pattern as the M2.8 `BeginInstruction` / `EndInstruction` pair
(file-cohesion neighbours under `control_instructions.jl`); see those
docstrings for the same "structural inverse vs. dispatch-level
inverse" caveat.

# XOR-of-directions semantics (encoded in `effective_call_direction`)

The two direction flags — `instr.direction` (the *source-level*
marker baked into the IR at lowering time) and `vm_direction` (the
*runtime* flag flipped at `run!` / `unrun!` start) — compose
multiplicatively. On runtime **forward** execution (`vm_direction
=== :forward`):

  * A `:call` instruction → callee runs **forward** (the obvious case).
  * An `:uncall` instruction → callee runs **backward** (the
    uncomputation pattern: the IR explicitly requests a reverse
    pass even though the VM is going forward).

On runtime **backward** execution (`vm_direction === :backward`):

  * A `:call` instruction → callee runs **backward** (the VM is
    reversing; every call site reverses).
  * An `:uncall` instruction → callee runs **forward** (the VM
    is reversing AND the IR explicitly asked for an
    uncomputation; the two negations cancel).

The mnemonic is "XOR of two booleans": `effective_dir = forward` iff
exactly one of `instr.direction === :call` and `vm_direction ===
:forward` is true, OR both are. (Concretely: `:call ⊕ :forward =
:forward`; `:uncall ⊕ :forward = :backward`; `:call ⊕ :backward =
:backward`; `:uncall ⊕ :backward = :forward`.)

`effective_call_direction(instr, vm_direction)` returns the
resulting `:forward` / `:backward` symbol. **M2.14 exports this
helper for M3.x to use**; `CallInstruction`'s `forward` / `inverse`
at the IState layer do not call it themselves (they only bump pc),
but the helper documents the semantics now while the design is
fresh — exactly the literate-programming convention CLAUDE.md
Rule 11 calls for.

# Constructor validation (Rule 1)

The constructor rejects four categories of degenerate input at
construction time:

  1. `direction` not in `(:call, :uncall)` — typo or stale spike-
     style `:reverse_call` / `:invert` symbol; reject with a clear
     "expected :call or :uncall" message.
  2. `targets` contains duplicates — the same SSA name materialised
     twice on the LHS of `:=`; one value would be lost. Same RSSA
     single-assignment-within-receiver rule as the M2.9
     `UnconditionalEntry.params` and M2.7 `SwapInstruction.target1/2`
     constraints.
  3. Any symbol appears in BOTH `targets` and `args`. Retained as a
     TRIPWIRE, not as a semantic necessity — the RC3 rationale ("an
     SSA name cannot be simultaneously created and destroyed by one
     instruction") is a MOVE-model claim, and this machine COPIEs its
     args (ADR 0019 A.1) and OVERWRITEs its targets with a
     `target_olds` capture (A.2), so an overlapping call would in
     fact round-trip. It is rejected because it is UNREACHABLE from
     LLVM-derived IR: SSA dominance forbids a call being its own
     operand (bead `bennettvm-p3j2`, 2026-07-30; ADR 0023
     §Amendment). Zero false positives ⇒ a cheap Rule-1 net for
     hand-built programs. Mirrors the live `CallEnter` guard
     (`src/ir/call_transitions.jl`) exactly, per the lockstep rule
     below.
  4. `callee` appears in `targets` or `args` — the callee label
     shadows an SSA name; the dispatch would be ambiguous (does the
     `callee` Symbol refer to the label being called, or to the
     local being created / destroyed?). Forbid the shadow at
     construction time.

There used to be a fifth: **`args` contains duplicates**. It is GONE
(ADR 0023, bead `bennettvm-0fw7`). Its rationale — "the same SSA name
destroyed twice" — presupposed the MOVE-args discipline of ADR 0019 §3,
which ADR 0019 Amendment A.1 replaced with a COPY: a call reads its
args and leaves the caller's bindings intact, so naming one value in
two argument positions destroys nothing twice. `g(x, x)` and
`setindex!(d, i, i)` (the lowering of `d[i] = i`) are ordinary,
verifier-legal LLVM. This class is dead on the lowering path — only
`BasicBlock.reverse()` (`src/ir/basic_block.jl`) and tests construct it
— but it is relaxed in LOCKSTEP with the live `CallEnter`
(`src/ir/call_transitions.jl`) so that a reader cannot find two
different answers to the same question. See ADR 0023 for the full
argument.

One asymmetry follows and is deliberate: `structural_inverse` for this
class swaps `targets` ↔ `args` (`src/ir/basic_block.jl`), so a
duplicate-arg `CallInstruction` inverts to a duplicate-TARGET one and
is rejected by check 2 — which is correct, because two returns really
cannot land on one name. A dup-arg call is therefore constructible but
not structurally invertible in THIS class. That is harmless today (the
class is dead on the lowering path and `CallEnter`/`ReturnExit` do not
use `structural_inverse`); if the class is ever revived, the inverse
must land the two positions via the callee's params, not by a naive
list swap.

Empty `targets` / `args` are **legal** — a no-arg / no-return
subroutine is a well-formed RSSA program (a `void main()` analogue,
or a pure side-effecting `procedure clear()` with no parameters or
returns). The M2.9 `UnconditionalEntry` / `UnconditionalExit`
constructors already establish this convention.

Cross-instruction invariants — that `callee` names a label registered
on the `VMProgram` (M2.17), that the callee's `BeginInstruction.params`
has `length(args)` parameters of matching types, that the callee's
`EndInstruction.returns` has `length(targets)` returns of matching
types — are **not** enforced at this layer. They require seeing the
whole `VMProgram` and are M2.17's responsibility (callee registry)
and M3.x's responsibility (runtime dispatch).

# Forward / inverse semantics — pc-only at this layer

Per the scoping decision above, the dispatch-level forward / inverse
are deliberately pc-only:

```
forward(::CallInstruction, s) → s with s.pc += 1
inverse(::CallInstruction, s, _) → s with s.pc -= 1
```

`prev` is unused on `inverse`: the actual destruction of `args` and
creation of `targets` (and the recursive sub-execution of the callee)
lives at the M3.x interpreter layer, NOT here. The cross-instruction
rewrite — flipping `:call` to `:uncall` under direction reversal —
also belongs at the IR-graph / interpreter layer, exactly as M2.8
Begin/End and M2.9/M2.10 entry/exit do; the per-instruction layer is
local. A future agent tempted to bake the callee dispatch into
`forward` should stop and re-read this docstring.

# pc symmetry

`forward` sets `s.pc += 1`; `inverse` sets `s.pc -= 1`. Matches the
per-step ±1 symmetry of every M2.x instruction; the M3.x `RState`
round-trip aligns frames by `pc` alone.

# Ref

  * `bennettvm_prd.md` (PRD v4) §3.1 — RSSA instruction taxonomy
    (row 6 of the ADR 0001 §Observations twelve-class table:
    procedure call / uncall).
  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations row 6 —
    `CallInstruction` / `(x,...) := call/uncall l(y,...)` /
    "`Direction` field flips; one class for both".
  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations Structural-Pattern
    point 4 — "Procedure calls unify call and uncall under one class
    with a `Direction` field. Reverse-of-call is reverse-of-uncall
    — a single structural primitive."
  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations decision-table
    rows "Direction flag" and "Call/Uncall unification" — the
    one-per-VM direction flag pattern and the single-class
    Call/Uncall design that this file inherits.
  * RC3 source: `src/main/java/.../instances/CallInstruction.java`
    — the analogue this class mirrors; the `reverse()` method
    builds a fresh instance with `direction` flipped, which is the
    cross-instruction-rewrite that lands at M2.15
    `BasicBlock.reversed()` time, not at the per-instruction
    dispatch layer (this file).
  * `src/ir/swap_instruction.jl` (M2.7) — template for the inner-
    constructor SSA-overlap check.
  * `src/ir/control_instructions.jl` (M2.8/M2.9/M2.10) — the
    pc-only-dispatch / cross-block-rewrite-deferred template this
    file inherits for control-flow-marker semantics.
  * CLAUDE.md Rule 1 — constructor validates inputs; degenerate
    cases fail loud at construction time.
  * CLAUDE.md Rule 11 — literate exposition; the
    `effective_call_direction` helper is defined here (not at M3.x)
    specifically to document the XOR-of-directions semantics while
    the design is fresh.
"""
struct CallInstruction <: Instruction
    targets::Vector{Symbol}    # x,...  — created; receive callee's outputs
    callee::Symbol             # l — subroutine label
    args::Vector{Symbol}       # y,... — passed to callee (RC3 says "destroyed";
                               #   the live CallEnter COPIEs — ADR 0019 A.1 / 0023)
    direction::Symbol          # :call | :uncall (source-level direction)

    function CallInstruction(targets::Vector{Symbol},
                             callee::Symbol,
                             args::Vector{Symbol},
                             direction::Symbol)
        direction === :call || direction === :uncall ||
            error("CallInstruction: invalid direction $(direction); ",
                  "must be :call or :uncall (RC3 Direction set; ",
                  "see ADR 0001 §Observations decision-table row ",
                  "\"Call/Uncall unification\")")
        allunique(targets) ||
            error("CallInstruction: duplicate target names in $(targets) ",
                  "(SSA single-assignment-within-receiver violation — the ",
                  "same SSA name cannot be created twice on the LHS of ",
                  "`(x,...) := call l(...)`)")
        # NO `allunique(args)` check — mirrors the `CallEnter` relaxation in
        # `src/ir/call_transitions.jl` (ADR 0023, bead `bennettvm-0fw7`).
        # Duplicate args are legal under COPY-args (ADR 0019 Amendment A.1);
        # they were only ill-formed under the superseded MOVE model. Kept in
        # lockstep with `CallEnter` so the two constructors cannot diverge.
        # Target/arg OVERLAP. RETAINED, behaviour unchanged (bead
        # `bennettvm-p3j2`, 2026-07-30) — rationale rewritten in lockstep with
        # `CallEnter` (`src/ir/call_transitions.jl`). It is a TRIPWIRE against
        # hand-built programs, not a semantic necessity: under COPY-args /
        # OVERWRITE-targets an overlapping call round-trips, but SSA dominance
        # forbids a call being its own operand, so the shape is unreachable
        # from LLVM-derived IR and the check is zero-false-positive.
        for t in targets
            if t in args
                error("CallInstruction: symbol $(t) appears in BOTH ",
                      "targets $(targets) and args $(args) — unreachable from ",
                      "LLVM-derived IR (SSA dominance forbids a call being its ",
                      "own operand), so this is a hand-built program or a ",
                      "front-end name-synthesis bug; ADR 0023 §Amendment (p3j2)")
            end
        end
        if callee in targets
            error("CallInstruction: callee label $(callee) shadows a ",
                  "target in $(targets) — the label being called cannot ",
                  "also be an SSA name created by the call (dispatch ",
                  "ambiguity); lowering must rename")
        end
        if callee in args
            error("CallInstruction: callee label $(callee) shadows an ",
                  "arg in $(args) — the label being called cannot also ",
                  "be an SSA name destroyed by the call (dispatch ",
                  "ambiguity); lowering must rename")
        end
        return new(targets, callee, args, direction)
    end
end

"""
    forward(instr::CallInstruction, s::IState) -> IState

Bump `pc` by 1 and return `s`. `locals` and `status` untouched at this
dispatch layer — the actual transfer of `args` into the callee's
parameter slots, the recursive sub-execution of the callee's
BasicBlocks (in the direction picked by `effective_call_direction`),
and the harvesting of return values into `targets` all live in M3.x's
interpreter. See this file's top-of-module M2.14 docstring for the
scoping rationale.
"""
function forward(instr::CallInstruction, s::IState)::IState
    # Recursive sub-execution of the callee (forward or backward,
    # picked by `effective_call_direction(instr, vm.direction)`) lands
    # in M3.x's interpreter once the VMProgram callee registry (M2.17)
    # and LabelTable (M2.16) exist. This dispatch layer is local: bump
    # pc only.
    s.pc += 1
    return s
end

"""
    inverse(instr::CallInstruction, s::IState, prev) -> IState

Decrement `pc` by 1 and return `s`. `prev` is unused at this dispatch
layer — Call's reversibility is structural (the `direction` flip is a
cross-instruction rewrite that lands at M2.15 `BasicBlock.reversed()`,
and the recursive sub-execution lands at M3.x's interpreter). No
history record is ever pushed for a `CallInstruction` at this layer;
see this file's top-of-module M2.14 docstring on "structural inverse
vs. dispatch-level inverse" — same pattern as M2.8 Begin/End and
M2.9/M2.10 Uncond/Cond entry/exit.

# pc-symmetry audited by M8.3 mutation-proof harness (bd `bennettvm-7cg`)

This `inverse(::CallInstruction, ...)` method's **pc symmetry IS now
audited** by `test/test_mutation_proof.jl` (M8.3) via a `:direct`-mode
manifest entry (`CallInstruction/no-pc`, added by bd `bennettvm-7cg`,
follow-up to M8.3 `bennettvm-2kl`). That entry drives the M6.3
`forward+inverse` round-trip — `forward` bumps `pc`, this canonical
`inverse` un-bumps it — and mutation-proves the contract by dropping
the `s.pc -= 1`, confirming the round-trip diverges (RED) and then
restoring (GREEN). This is the same `:direct` pattern the injective
kinds (SwapInstruction, MemoryInterchange, MemorySwap) use.

What stays out of scope: the **L2-scaffold path remains impossible to
drive** because its M7.3 `make_delta(::CallInstruction, ...)` raises
unconditionally (v5-deferred — see `make_delta` docstring below and
ADR 0002 §Open Questions item 4): no delta is ever pushed, so
`unstep!` never delegates to this method via the M7.4 fast-path. Only
the pc-only dispatch-level inverse is exercised; the recursive-callee
semantics (destruction of `args`, creation of `targets`, sub-execution
of the callee) are intrinsically a v5 concern and are NOT audited.
"""
function inverse(instr::CallInstruction, s::IState, prev)::IState
    s.pc -= 1
    return s
end

"""
    make_delta(instr::CallInstruction, s_pre::IState, step::Integer)
        -> DeltaEntry{CallInstruction}

L2 delta-entry constructor for `CallInstruction` (M7.3, bead
`bennettvm-vk8`). **Always raises `ErrorException`** — cross-call
delta semantics are deferred to v5 per ADR 0002 §Open Questions
item 4.

# Why this errors rather than returning an empty-payload entry

`CallInstruction` is non-injective per M6.1 (`src/history/Injective.jl`
default `false`), so M7.6's push site WILL call `make_delta` on it
if a program contains a procedure call under `target=:reversible_vm`.
The naïve choice would be to return `DeltaEntry(instr, NamedTuple(),
step)` mirroring `ArithmeticAssignment` / `MemoryAssignment`. ADR
0002 explicitly rejects this:

> Row 15: `CallInstruction` — deferred to v5 per
> `src/ir/call_instruction.jl`'s top-of-module docstring. Phase-2
> (this iteration) treats `CallInstruction` as conservatively
> non-injective; M3.x interpreter does not yet recurse into the
> callee.
> ([ADR 0002 §The mapping table, "Cross-procedure boundary" row])

The reason: at this dispatch layer `CallInstruction.forward` only
bumps `pc` (`src/ir/call_instruction.jl:266-274`). The actual
recursive sub-execution of the callee's BasicBlocks — which is
what would need a delta entry to record — lands at M3.x once the
`VMProgram` callee registry exists. **An empty-payload entry would
silently lie about the call's reversibility**: the M7.6 push would
record "non-injective step at `step_count`" with no information,
and any future `unstep!` that consulted the entry would do nothing
(no payload to restore from). Worse: if a future v5 bead extended
the delta to actually carry callee state, existing programs that
were "running" with empty-payload entries would have those entries
silently misinterpreted.

Rule 1 demands fail-loud on unsupported cases. Raising here gives
the user an exact message — "your program contains a `Call`,
which v5 hasn't wired into the delta history yet" — and pins the
v5 contract: when v5 lands, this method body is replaced (not the
whole method), and the call sites in M7.6's push gate continue to
work unchanged.

# When this method is actually reached

Only when:

  * `M7.6`'s push site has landed (delta entries are pushed by
    `step!`),
  * a program contains a `CallInstruction` (M2.14 type),
  * and the call's `forward`/`inverse` actually run (i.e. the
    program is being executed under `target=:reversible_vm`).

Until M7.6 lands, this method is callable but unreachable from
the interpreter — only the M7.3 unit tests exercise it.

# Workaround for users hitting this error

Pre-v5: avoid procedure calls in Phase-2 programs. The motivating
cases (PRD v4 §3.6.2 Cases A-D) are all flat or single-block
programs that lower to no `CallInstruction`s.

# Ref

  * `docs/adr/0002-enzyme-min-cut-mapping.md` §Open Questions
    item 4 — cross-call delta semantics deferred to v5.
  * `docs/adr/0002-enzyme-min-cut-mapping.md` §DeltaEntry payload
    schema row 3 — "CallInstruction: deferred to v5".
  * `docs/adr/0002-enzyme-min-cut-mapping.md` §The mapping table,
    "Cross-procedure boundary" row.
  * `src/ir/call_instruction.jl:266-291` (this file, `forward` /
    `inverse` above) — pc-only stubs.
  * `effective_call_direction` (below) — the helper that future
    v5 sub-execution will consume to pick the callee direction.
  * `CLAUDE.md` Rule 1 — fail loud on unsupported cases.
  * Bead `bennettvm-vk8` (M7.3) — this method's bead.
"""
function make_delta(instr::CallInstruction, s_pre::IState,
                    step::Integer)::DeltaEntry
    error("BennettVM.make_delta(::CallInstruction): CallInstruction delta ",
          "is deferred to v5 per ADR 0002 §Open Questions item 4. The ",
          "recursive sub-execution semantics are not yet wired into the ",
          "delta history. If you reached this error, a program contains a ",
          "CallInstruction at step ", step, " (pc=", s_pre.pc, ") under ",
          "target=:reversible_vm. Workaround: avoid procedure calls in ",
          "Phase-2 programs until v5.")
end

"""
    inverse(instr::CallInstruction, s::IState, payload::NamedTuple) -> IState

M7.4 NamedTuple specialisation per ADR 0002 §Design Decision 4 (bd
`bennettvm-bk5`). **Always raises `ErrorException`** — parallel to
the `make_delta` v5-deferral above. This is the second line of
defense: the first is `make_delta(::CallInstruction, ...)` which
errors *before* any delta would ever be pushed (so M7.6's push site
cannot reach a payload-bearing `DeltaEntry{CallInstruction}` in
`s.history` at this milestone); the second is this method, which
errors *if* `unstep!`'s M7.4 fast-path ever reaches a
`DeltaEntry{CallInstruction}` (a state that should be unreachable
under M7.6's push gate, but Rule 1 demands fail-loud even on the
unreachable path).

# Why this method exists separately from the prev::Any inverse

`CallInstruction.inverse(instr, s, prev)` (above, line 288) is the
pc-only dispatch-level inverse — the M3.x-pending placeholder.
Calling that from M7.4's fast-path would silently no-op the call
(only pc decrements), giving the *appearance* of a successful
reverse step while the cross-call state was never restored. Rule 1
forbids that silent corruption; the NamedTuple method raises
descriptively instead.

# Ref

  * `docs/adr/0002-enzyme-min-cut-mapping.md` §Open Questions item 4
    — cross-call delta semantics deferred to v5.
  * `docs/adr/0002-enzyme-min-cut-mapping.md` §The mapping table,
    "Cross-procedure boundary" row.
  * `src/ir/call_instruction.jl` (this file, `make_delta` above) —
    the first line of defense; errors before push.
  * `src/ir/call_instruction.jl` (this file, `inverse(instr, s, prev)`
    above) — the pc-only dispatch-level inverse this method
    deliberately does NOT delegate to.
  * `CLAUDE.md` Rule 1 — fail loud on unsupported cases.
  * Bead `bennettvm-bk5` (M7.4) — this method's bead.
"""
function inverse(instr::CallInstruction, s::IState,
                 payload::NamedTuple)::IState
    error("BennettVM.inverse(::CallInstruction, s, payload::NamedTuple): ",
          "CallInstruction reverse-dispatch is deferred to v5 per ADR 0002 ",
          "§Open Questions item 4. If you reached this error, a program ",
          "contains a CallInstruction whose forward step pushed a delta ",
          "(M7.6 should never have done this — file a bug). State at error: ",
          "pc=", s.pc, ", status=", s.status, ".")
end

"""
    effective_call_direction(instr::CallInstruction, vm_direction::Symbol) -> Symbol

Returns `:forward` or `:backward` — the direction in which the callee
should execute, given the instruction's source-level direction
(`instr.direction`) and the VM's current run direction (`vm_direction`).
Captures the XOR-of-directions semantics from RC3's `RSSAVM.java`
(`Direction` flag composition with per-instruction `:call`/`:uncall`
marker; ADR 0001 §Observations Structural-Pattern point 4 and decision-
table rows "Direction flag" + "Call/Uncall unification").

# Truth table

| `instr.direction` | `vm_direction` | Returns        |
|-------------------|----------------|----------------|
| `:call`           | `:forward`     | `:forward`     |
| `:uncall`         | `:forward`     | `:backward`    |
| `:call`           | `:backward`    | `:backward`    |
| `:uncall`         | `:backward`    | `:forward`     |

The mnemonic: `effective_dir = :forward` iff `instr.direction === :call`
agrees with `vm_direction === :forward`, else `:backward`. (Concretely
the XOR of two booleans; both-true and both-false produce `:forward`,
mixed produces `:backward`.)

# Where this helper is consumed

`CallInstruction.forward` / `inverse` at the IState layer (this file)
do NOT call this helper — at the per-instruction dispatch level the
call is just a pc bump, and the actual callee invocation is M3.x's
job. The helper is defined here, not at M3.x, **so that the XOR-of-
directions semantics is documented at the same site as the
`direction::Symbol` field** (CLAUDE.md Rule 11 — literate
exposition: the rationale lives alongside the data, not in a
faraway module). M3.x's interpreter will import this function and
use it to pick which direction to run the callee's BasicBlocks.

# Failure mode (Rule 1)

If `vm_direction` is anything other than `:forward` or `:backward`,
the function raises an `ErrorException`. The valid set is fixed by
ADR 0001 decision-table row "Direction flag" (one per-VM
`Direction` enum: `Forward` / `Backward`); an unexpected value
indicates a caller bug — most likely a typo (`:fwd`, `:reverse`) or
a stale spike-style tag (`:running` / `:halted`, confusing
`vm_direction` with `IState.status`). Fail loud per Rule 1; do not
silently default.

# Ref

  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations Structural-Pattern
    point 4 — "Procedure calls unify call and uncall under one class
    with a `Direction` field. Reverse-of-call is reverse-of-uncall
    — a single structural primitive."
  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations decision-table
    row "Direction flag" — one per-VM `Direction` enum flipped at
    run start, NOT per-instruction.
  * RC3 source: `RSSAVM.java` — the `direction` field composes with
    each `CallInstruction.direction` exactly as encoded here.
"""
function effective_call_direction(instr::CallInstruction,
                                  vm_direction::Symbol)::Symbol
    if instr.direction === :call && vm_direction === :forward
        return :forward
    elseif instr.direction === :uncall && vm_direction === :forward
        return :backward
    elseif instr.direction === :call && vm_direction === :backward
        return :backward
    elseif instr.direction === :uncall && vm_direction === :backward
        return :forward
    else
        error("effective_call_direction: invalid vm_direction ",
              "$(vm_direction); expected :forward or :backward (ADR ",
              "0001 §Observations decision-table row \"Direction flag\")")
    end
end
