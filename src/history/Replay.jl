"""
    Replay (M4.3 + M4.4 + M7.4) — `unstep!` and `unrun!` via L2 delta
    fast-path on top of the L3 checkpoint-replay fallback

The third and fourth concrete steps in the PRD v4 §3.3 three-layer
history implementation. Where M4.1 defined `CheckpointEntry` (the entry
type) and M4.2 modified `step!` to push entries periodically (every K
steps), M4.3 lands the single-backward-step *consumer* (`unstep!`):
find the nearest checkpoint at-or-before the target step and replay
forward deterministically to reconstruct the prior state. M4.4 lands
the *loop-driver* companion (`unrun!`): repeatedly invoke `unstep!`
until `s.step_count == 0`, then assert the structural exit invariant
`isempty(s.history)` — the Bennett-1973 Stage-3 retrace's BennettVM
realisation. Both functions are exported from this file; the M4.4
prose lives below the M4.3 `unstep!` definition, just above `unrun!`.

M7.4 (bd `bennettvm-bk5`) grows a *fast-path* on top of M4.3's
checkpoint-restore-and-replay path: when the top of `s.history` is a
`DeltaEntry` whose `step` field equals `s.step_count` (i.e., the delta
for the just-completed forward step), `unstep!` pops the entry, calls
`inverse(entry.instruction, s.current, entry.payload)` — the M7.4
NamedTuple-dispatch specialisation in each non-injective instruction's
file — and decrements `step_count` by 1. The L3 fallback is unchanged;
control falls through to it whenever the fast-path doesn't apply
(history top is a `CheckpointEntry`, history top is a `DeltaEntry`
from an earlier step, or history is empty). See the `unstep!`
docstring §"M7.4 — DeltaEntry fast-path" for the full rationale.

# What `unstep!` does (one backward step)

`unstep!(s::RState, prog::VMProgram)::RState` mutates `s` in place so
that it represents the interpreter at step `s.step_count - 1` of the
program — exactly one step earlier than the caller saw it. Returns the
same `RState` for chaining and to satisfy the PRD v4 §3.9 signature
`unstep!(rstate, prog) :: RState`.

# The five-step algorithm

The algorithm is the rr-architecture core (O'Callahan et al 2017 §2.1,
`references/reverse-debugging/ocallahan-2017-rr-deployability.pdf`):
*record nondeterminism, replay determinism*. Because the VM is fully
deterministic (no I/O, no concurrency, no RDRAND — see CLAUDE.md "rr's
lesson" callout and `src/history/CheckpointEntry.jl` §"The rr
architecture lesson"), the "record nondeterminism" half degenerates to
zero work and the entire backward step is "find the nearest checkpoint,
replay forward".

  1. **Precondition.** `s.step_count > 0`, else Rule 1 raise (PRD v4
     §3.16: `unstep!` on empty history MUST raise descriptively; we
     read the precondition from `step_count` rather than
     `isempty(history)` because the L3 layer can have `step_count > 0`
     with `isempty(history)` — e.g., K=64 and only 12 forward steps
     taken: backward IS still possible via the `s.initial` fallback).

  2. **Find nearest checkpoint.** Walk `s.history` from the right and
     pick the last entry whose `step <= target` (where `target =
     s.step_count - 1`). M4.2 pushes monotonically — every successful
     `step!` increments `step_count` then either pushes (post-step,
     so the entry's `step == s.step_count`) or doesn't, and the
     entries on `s.history` therefore appear in ascending `step`
     order. A linear walk from the end is O(K_pushes_after_target) in
     the worst case, which for a typical reverse-debug session (one
     backward step at a time near the most recent push) is O(1).

  3. **Pick restore source.** If the walk found a checkpoint,
     `restore_snap = matching_entry.snapshot` and `start_step =
     matching_entry.step`. Otherwise, fall back to `s.initial` and
     `start_step = 0`. This is where the M4.3 `initial::IState` field
     on RState earns its keep (see `src/ir/RState.jl` §"Why
     `initial::IState` here, not a step-0 anchor entry on history"):
     without it, backing up past the first checkpoint would require
     either pushing a phantom step-0 entry (which would violate the
     M4.2 step-0 carve-out and the M4.4 `isempty(history)` invariant)
     or re-running `initial_state(prog, input)` from a stored input
     dict (which isn't on the RState).

  4. **Restore (with deepcopy).** `s.current = deepcopy(restore_snap)`.
     The deepcopy is **mandatory** and **not** an optimisation that
     can be skipped: this is the same defense-in-depth Q2.2 lesson the
     M4.1 `CheckpointEntry` constructor encodes, applied at the read
     end. M4.1 deepcopies *at push time* so the snapshot inside the
     entry is independent of subsequent `s.current` mutations
     (`spike/RETROSPECTIVE.md` Q2.2). M4.3 must also deepcopy *at pop
     time* — without it, the next `step!` (during replay below) would
     mutate `s.current` directly, but `s.current` would be aliased to
     `s.history[nearest_idx].snapshot`. The next `unstep!` would then
     find the same checkpoint silently corrupted by the previous
     replay's forward mutations. Both ends defend.

  5. **Truncate "future" history.** Pop entries from `s.history`
     whose `step > target`. Monotonic-ascending order (step (2)
     above) makes this `while !isempty(s.history) &&
     s.history[end].step > target; pop!(s.history); end`. Entries
     with `step <= target` are retained; M4.4's `unrun!` will
     consume them on subsequent `unstep!` calls until the history is
     empty AND `step_count == 0`.

     **Why pop entries with `step > target`, not entries with `step ==
     target`.** If a checkpoint sits exactly at `target` — i.e., the
     just-pushed checkpoint at our restore step — it remains valid
     for future backward steps to `target - 1`, `target - 2`, …, all
     the way until the next-earlier checkpoint (or `s.initial`)
     becomes the nearer source. Dropping it eagerly would force every
     subsequent `unstep!` to walk further back than necessary.

  6. **Reset step count + replay forward.** `s.step_count =
     start_step`; then call `step!(s, prog;
     checkpoint_interval=typemax(Int))` until `s.step_count ==
     target`. The `typemax(Int)` suppresses spurious pushes during
     replay — see "Why typemax(Int) during replay" below. The replay
     loop terminates because every `step!` increments `step_count` by
     exactly 1 (M4.2's "increment only on success" rule); the
     `target` is by construction `>= start_step` (target =
     `step_count - 1 >= 0 = start_step` in the fallback case, and
     `target >= matching_entry.step = start_step` by the nearest-
     checkpoint walk's selection criterion); so the loop is bounded
     by `target - start_step` iterations.

# Why `checkpoint_interval = typemax(Int)` during replay (M4.2 + M7.6 update)

M4.2's `step!` push guard for L3 is `s.step_count % checkpoint_interval
== 0 && s.step_count > 0`. With `K = typemax(Int)`, for any `step_count`
in `[1, typemax(Int) - 1]` we have `step_count % typemax(Int) ==
step_count`, which is `> 0` (never `== 0`). The L3 push therefore
never fires. Pre-M7.6 this was the *only* push the replay loop had
to suppress, so `K = typemax(Int)` was the load-bearing signal.

**M7.6 update.** M7.6 introduced an L2 (delta) push path that fires
when `must_cache(set, label, idx)` is true — independent of K. The
`typemax(Int)` trick does NOT suppress L2; if the caller's
`must_cache_set` is non-empty and replay drives `step!` through a
non-injective body slot in the set, the replay would re-create the
DeltaEntry `unstep!` just popped, breaking the M4.4
`isempty(history)` post-condition.

The fix is a new `replay_mode::Bool` kwarg on `step!` (and `run!`)
that suppresses BOTH L2 and L3 pushes. M4.3's replay loop now
passes `replay_mode=true`. The `checkpoint_interval=typemax(Int)`
spelling is retained alongside it — see the comment at the replay
loop in `unstep!` step (6) — both for symmetry with the M4.2
documentation and as defense in depth (if a future agent removes
`replay_mode=true` accidentally, the typemax(Int) still prevents
the L3 push, which is still a partial improvement over an
uncontrolled replay).

The alternative — calling a hypothetical internal `_step_without_push!`
— was rejected on Law 2 / Rule 11 grounds: every consumer that wants
"step without push" can spell it as `step!(..., replay_mode=true)`,
and forking the function signature would duplicate the dispatch
logic for no readability gain.

# Why `s.initial` is the fallback rather than recomputing from input

`initial_state(prog, input)` is the constructive recipe for "the
RState at step 0", but recomputing it inside `unstep!` would require
either storing the original `input::AbstractDict` on `RState`
(extending the struct further) or re-running the lowering pass on
the source program (which doesn't even apply in the IR-only path).
Storing the constructed `IState` directly — the `s.initial` field
M4.3 adds — is the cheapest correct option: O(deepcopy(IState))
space, O(1) lookup, no input dict serialisation, no dependency on
the program text.

# Halt-state interaction (M4.2)

M4.2's `step!` flips `s.current.status = :halted` AFTER
`forward(::EndInstruction)` runs, then pushes a `CheckpointEntry` if
the post-increment count is a multiple of K. The captured snapshot
therefore has `status === :halted`. M4.3's `unstep!` can move
backward through halt transparently: the restored snapshot reflects
the program's actual status at that step (likely `:halted` if the
checkpoint was taken AT or after the End-step, `:running` otherwise),
and the replay loop drives `step!` forward, which itself respects
the same halt-detection rule. So unstepping out of `:halted` back
into `:running` is automatic — the `:running` status of the prior
step is recovered transparently via the restored snapshot OR via the
replay's deterministic forward driver (which has not yet hit the
End-step at a backward target that's strictly before it).

# Cross-references

  * `bennettvm_prd.md` (PRD v4) §3.3 — three-layer history; L3 is
    "periodic full-state checkpoints + deterministic replay"; this
    function is L3's backward primitive.
  * `bennettvm_prd.md` (PRD v4) §3.9 — `unstep!(rstate, prog) ::
    RState` signature.
  * `bennettvm_prd.md` (PRD v4) §3.16 — `unstep!` on empty history
    MUST raise descriptively.
  * `references/reverse-debugging/ocallahan-2017-rr-deployability.pdf`
    §2.1 (p. 2) — the rr "record nondeterminism, replay determinism"
    architecture this layer is the BennettVM specialisation of.
  * `references/reverse-debugging/rr-docs.md` — local digest of the
    above paper with the BennettVM-specific applicability note.
  * `src/history/CheckpointEntry.jl` (M4.1) — the entry type whose
    `snapshot::IState` field this function reads. The deepcopy-in-
    constructor contract from M4.1 means we're reading a snapshot
    independent of the captured `s.current`; the deepcopy at restore
    (this file) means the *restored* `s.current` is independent of
    the captured snapshot. Both ends defend.
  * `src/interpreter/Interpreter.jl` (M4.2) — `step!` push policy
    and the `checkpoint_interval` kwarg this function passes
    `typemax(Int)` for.
  * `src/ir/RState.jl` (M4.3) — the `initial::IState` field this
    function reads on the fallback path.
  * `spike/RETROSPECTIVE.md` Q2.2 — the deepcopy / Dict-aliasing
    lesson this function applies at the restore site.
  * `docs/impl-plan/phase2-impl-plan.md` M4.3 (lines 218-220) — the
    milestone spec.
  * CLAUDE.md Rule 1 (fail-loud); Rule 11 (literate docstring);
    Rule 4 (every test pins a known-correct value).
"""

"""
    unstep!(s::RState, prog::VMProgram)::RState

Move the interpreter backward by exactly one step via the L3
checkpoint-replay strategy (PRD v4 §3.3). After a successful return,
`s.step_count` has decreased by 1, `s.current` matches the IState the
interpreter held at step `step_count_before - 1`, and `s.history` has
been truncated of any entries whose `step` index exceeds the new
target. The same `RState` is returned for chaining.

# Precondition

`s.step_count > 0`. PRD v4 §3.16: `unstep!` on a zero-step state MUST
raise an `ErrorException` with a descriptive message.

# Algorithm

See the top-of-file docstring §"The five-step algorithm" for the full
specification of the M4.3 path. Briefly: find the nearest
`CheckpointEntry` at or before the target step, restore its
(deep-copied) snapshot into `s.current`, truncate later entries off
`s.history`, reset `s.step_count`, then replay `step!` forward until
`step_count == target`. Replay passes `replay_mode=true` (M7.6) AND
`checkpoint_interval = typemax(Int)` (M4.2, kept for symmetry) to
suppress spurious pushes — see top-of-file §"Why `checkpoint_interval
= typemax(Int)` during replay" and the M7.6 update note in the same
section. The `replay_mode=true` flag is the primary signal post-M7.6
because it suppresses BOTH L2 (delta) and L3 (checkpoint) pushes,
where `checkpoint_interval=typemax(Int)` alone only suppresses L3.

# M7.4 — DeltaEntry fast-path

After the precondition check and before the M4.3 path, `unstep!`
inspects the top of `s.history`. If it is a `DeltaEntry` whose `step`
field equals `s.step_count` (the entry records the just-completed
forward step), `unstep!`:

  1. pops the `DeltaEntry`;
  2. calls `inverse(entry.instruction, s.current, entry.payload)` —
     the M7.4 NamedTuple-dispatch specialisation, distinct from the
     existing `inverse(instr, s, prev)` method that accepts `nothing`
     or other `Any`-typed `prev`;
  3. decrements `s.step_count` by 1;
  4. returns `s` directly.

The `entry.step == s.step_count` guard (NOT `entry.step ==
s.step_count - 1`) is correct: M7.6's push site (when it lands) will
push deltas with `step = post-increment step_count`, mirroring M4.2's
`CheckpointEntry` convention. So the delta on the top of history
records "the state-transition that took `step_count` from `N-1` to
`N`", and `unstep!` reverses *exactly* that transition.

When the fast-path doesn't apply — the top of history is a
`CheckpointEntry`, the top is a `DeltaEntry` whose `step` is strictly
less than `s.step_count` (i.e., the most recent forward step was an
injective L1-skip or an L3-deferred step that didn't push), or
history is empty — control falls through to the M4.3 checkpoint-
restore-and-replay path. Both paths produce the same result on the
same delta+pre-state input (the fast-path is a sound *optimisation*;
the M4.3 path is its general-case envelope).

Composition with M6's L1 gate and M4.2's L3 gate is locked in
ADR 0002 §Composition with M6. The architectural point is that the
two reverse paths share the *same* RState shape; they differ only in
which work the per-step reversal performs.

# Ref

  * PRD v4 §3.3, §3.9, §3.16.
  * `references/reverse-debugging/ocallahan-2017-rr-deployability.pdf`
    §2.1 — the rr architecture.
  * `src/history/CheckpointEntry.jl` (M4.1) — entry type.
  * `src/interpreter/Interpreter.jl` (M4.2) — forward `step!` whose
    push policy this function inverts.
  * `src/ir/RState.jl` (M4.3) — the `initial::IState` anchor field.
  * `src/history/delta.jl` (M7.2) — `DeltaEntry{T}` entry type the
    M7.4 fast-path pops.
  * `docs/adr/0002-enzyme-min-cut-mapping.md` §Composition with M6 —
    the binding composition rule for the push site and the dispatch
    side (M7.4 is the dispatch-side half).
"""
function unstep!(s::RState, prog::VMProgram)::RState
    # (1) Precondition. PRD v4 §3.16 + Rule 1: descriptive raise on
    # step_count <= 0, not a silent no-op. Spike Q4 §"Test patterns
    # worth keeping" identified fail-fast-on-empty-unstep! as a
    # load-bearing correctness check; the spike's equivalent guard
    # is at `spike/src/Interpreter.jl:206-214`.
    s.step_count > 0 ||
        error("unstep!: step_count is ", s.step_count,
              " — cannot move backward from step 0. ",
              "PRD v4 §3.16 requires a descriptive raise here ",
              "(not a silent no-op or default state). Rule 1: ",
              "reversibility violations are correctness bugs.")

    # (1a) M7.4 — DeltaEntry fast-path (bd `bennettvm-bk5`). If the top
    # of history is a DeltaEntry whose `step` field equals the current
    # `step_count`, the most recent forward step left a delta record;
    # pop it and apply the per-instruction inverse with the payload,
    # no checkpoint-restore-and-replay needed. The
    # `entry.step == s.step_count` guard is the post-increment
    # convention M4.2's CheckpointEntry uses, mirrored here per ADR
    # 0002 §DeltaEntry payload schema (the `step::Int` field carries
    # the post-increment step_count at which the entry was pushed).
    #
    # When the guard is false (top is a CheckpointEntry, top is a
    # DeltaEntry from an earlier step, or history is empty), control
    # falls through to the existing M4.3 checkpoint-restore-and-replay
    # path below. Both paths produce the same RState on the same
    # delta+pre-state input.
    #
    # The third argument to `inverse` is `entry.payload::NamedTuple`,
    # NOT `nothing`. The NamedTuple dispatches to the M7.4-added
    # `inverse(::T, s::IState, payload::NamedTuple)` specialisation in
    # the per-instruction file (`src/ir/arithmetic_assignment.jl`,
    # `src/ir/memory_instructions.jl`); the existing
    # `inverse(::T, s, prev)` method that accepts `prev::Any` (per the
    # M2.4 dispatch convention) is the prev::Any path that M4.3
    # post-replay does not use directly (its replay loop drives
    # `step!` forward; M7.4's fast-path is the only consumer of
    # `inverse` on the L2 layer at this milestone).
    if !isempty(s.history) &&
       last(s.history) isa DeltaEntry &&
       _entry_step(last(s.history)) == s.step_count
        entry = pop!(s.history)
        inverse(entry.instruction, s.current, entry.payload)
        s.step_count -= 1
        return s
    end

    target = s.step_count - 1

    # (2) Find the nearest checkpoint with step <= target. Linear walk
    # from the end exploits M4.2's monotonic-ascending push order
    # (every successful step! increments step_count then conditionally
    # pushes; the push records the post-increment count). For a
    # typical reverse-debug session (one backward step near the most
    # recent push) this is O(1); worst-case O(history length).
    nearest_idx = nothing
    for i in lastindex(s.history):-1:firstindex(s.history)
        entry = s.history[i]
        if entry isa CheckpointEntry && entry.step <= target
            nearest_idx = i
            break
        end
    end

    # (3) Pick the restore source. The branchless fallback to
    # s.initial means the algorithm handles the "no checkpoint at or
    # before target" case (typical for backward steps near step 0
    # before any checkpoint has been pushed) uniformly with the
    # "checkpoint found" case — the only difference is which snapshot
    # we deepcopy from and which start_step we reset step_count to.
    local restore_snap::IState
    local start_step::Int
    if nearest_idx === nothing
        restore_snap = s.initial
        start_step = 0
    else
        restore_snap = s.history[nearest_idx].snapshot
        start_step = s.history[nearest_idx].step
    end

    # (4) Restore with deepcopy. See top-of-file §"The five-step
    # algorithm" step (4) for the mandatory-deepcopy rationale. If
    # the deepcopy were elided, the next replay step!'s mutation of
    # s.current would corrupt the source snapshot (either
    # s.history[nearest_idx].snapshot, breaking future unstep!s that
    # target the same checkpoint; or s.initial, breaking M4.4's
    # unrun! exit invariant). Spike Q2.2 / `src/history/
    # CheckpointEntry.jl` §"Why deep-copy in the constructor" is the
    # canonical citation; the analogous defense at the read end lives
    # here.
    s.current = deepcopy(restore_snap)
    s.step_count = start_step

    # (5) Truncate "future" history. Entries with step > target are
    # the ones we've just walked past; they must be popped so that
    # M4.4's `isempty(history)` exit invariant becomes reachable AND
    # so that the M4.2 monotonic-ascending push order is preserved
    # for any subsequent step!() during replay. The loop is bounded
    # by the number of entries originally past target — typically 0
    # or 1 for a fine-grained unstep! sequence, more for a long
    # initial unstep! that crosses multiple K-boundaries.
    while !isempty(s.history) && _entry_step(s.history[end]) > target
        pop!(s.history)
    end

    # (6) Replay forward to target. Both kwargs suppress spurious
    # pushes during replay:
    #
    #   - `replay_mode=true` (M7.6): the primary signal — suppresses
    #     ALL pushes (L2 AND L3). Without it, the replay path would
    #     re-create L2 DeltaEntries that `unstep!`'s fast-path just
    #     popped, breaking the M4.4 `isempty(history)` post-condition.
    #   - `checkpoint_interval=typemax(Int)` (M4.2): kept for symmetry
    #     and documentation. Pre-M7.6 this was the only mechanism;
    #     post-M7.6 it is redundant when `replay_mode=true` (the L3
    #     branch is skipped via `replay_mode` before the modulo check
    #     would matter). Retained because (a) the M4.2 docstring
    #     references it explicitly and (b) defense in depth: if a
    #     future agent removes the `replay_mode=true` argument
    #     accidentally, the typemax(Int) still prevents the L3 push.
    #
    # The loop is bounded by `target - start_step` iterations — at
    # most `K - 1` for a target one-past the nearest checkpoint
    # (typical M4.2 K=64 default → at most 63 replay steps), and at
    # most `step_count_before - 1` for the worst-case fallback to
    # s.initial (i.e., no checkpoint at or before target — only
    # happens when target < first_checkpoint_step, which for K=64
    # means target < 64).
    while s.step_count < target
        step!(s, prog;
              checkpoint_interval=typemax(Int),
              replay_mode=true)
    end

    return s
end

"""
    _entry_step(entry::AbstractHistoryEntry) -> Int

Extract the step index from a history entry. At M4.3 only
`CheckpointEntry` exists, so dispatch is trivial; this helper exists
so that M6.x / M7.x entries (introduced by the L1 / L2 history layers)
can each define their own `_entry_step` method without M4.3's
`unstep!` having to know about them. A future entry type with no
intrinsic step index (purely structural marker, e.g., an L1 no-log
sentinel) MAY define `_entry_step` to return its position-derived
step via a side channel — that decision is the introducing
milestone's, not M4.3's.

Fail-loud (Rule 1) on an unrecognised entry type: the M4.3 truncation
loop calls this on every entry it inspects, so a silent fallthrough
to a wrong value would corrupt the history-pop decision.
"""
_entry_step(e::CheckpointEntry) = e.step

"""
    _entry_step(entry::DeltaEntry) -> Int

The polymorphic step-index accessor for the M7.2 L2 `DeltaEntry`.
Mirrors `_entry_step(::CheckpointEntry)` so the truncation loop in
`unstep!` step (5) is unchanged — it walks back popping entries with
`step > target` regardless of entry type. Also consumed by the M7.4
fast-path guard at step (1a) of `unstep!` and by `unrun!`'s
post-condition diagnostic message.

The search loop in `unstep!` step (2) (`entry isa CheckpointEntry &&
entry.step <= target`) intentionally keeps the `isa CheckpointEntry`
check — a `DeltaEntry` cannot serve as a restore anchor; only
`CheckpointEntry` can (its `snapshot::IState` is what `s.current` is
deepcopied from). The polymorphism via `_entry_step` is load-bearing
*only* at the truncation loop and the diagnostic; restore-anchor
selection remains type-specific.
"""
_entry_step(e::DeltaEntry) = e.step

_entry_step(e::AbstractHistoryEntry) =
    error("_entry_step: no method for entry type ", typeof(e),
          " — M4.3's truncation loop needs an explicit step index. ",
          "If this is an M6/M7 entry type, the introducing milestone ",
          "must define `_entry_step(::ThatType)` alongside the type. ",
          "Rule 1: fail loud, not silent.")

# ============================================================================
# M4.4 — `unrun!` full-reverse driver (bd `bennettvm-5jb`).
#
# Where M4.3 (`unstep!`) is the single-backward-step primitive, M4.4 is
# the loop-driver companion: keep calling `unstep!` until the
# interpreter is back at step 0. This is the direct analogue of M3.4's
# `run!` — same kwarg-guarded loop shape, same Rule-1 fail-loud
# boundary, same "RState left in place for inspection on guard fire"
# discipline. Symmetry with `run!` is the design intent here: any
# caller that thinks in terms of `run!` / `unrun!` as paired forward /
# backward drivers gets exactly the same surface in both directions.
#
# ## The Bennett-1973 Stage-3 retrace lineage
#
# Bennett 1973 §"Discussion" (p. 529, col. 1, lines 19-25) — paraphrased
# from `references/foundational/bennett-1973-logical-reversibility.pdf`:
#
#   "The third stage undoes the work of the first and consists of the
#    inverses of all first-stage transitions with C's substituted for
#    A's. In the final state C₁, the history tape is again blank and
#    the other tapes contain the reconstructed input and the desired
#    output."
#
# `unrun!` is the BennettVM specialisation of that Stage-3 retrace: at
# the end of the loop, `s.history` is blank (`isempty(s.history)`) and
# `s.current` is the reconstructed input (`s.current == s.initial`,
# the M4.3-introduced step-0 anchor). The "C-state inverses" of Bennett
# 1973 are M4.3's per-step `unstep!` (find-checkpoint + replay), one
# per iteration of this loop.
#
# Notice that the retrace's two structural invariants — (i) history
# blank, (ii) reconstructed input — are *both* needed for Bennett's
# Stage-3 to be a clean inverse. M4.4 asserts (i) inside `unrun!`
# (because it is the loop's structural exit condition and a missed-
# truncation bug is exactly the kind of silent reversibility violation
# Rule 1 forbids). M4.4 does NOT assert (ii); that semantic invariant
# is M4.5's job to test from the outside, and folding it into `unrun!`
# would reduce M4.5's round-trip test to "did unrun! throw?" — the
# Rule-4 anti-pattern.
#
# ## Why `step_count > 0` is the loop predicate (not `!isempty(history)`)
#
# The spike's `unrun!` (`spike/src/Interpreter.jl:247-253`) used
# `while !isempty(s.history)` as the loop predicate. That worked
# because the spike's L3-equivalent pushed one history entry per step;
# `history empty ⇔ step_count == 0` was guaranteed by construction.
#
# Phase 2's L3 layer (PRD v4 §3.3) decouples the two: with K=64 and 12
# forward steps, `history` is empty but `step_count == 12`. The
# "are we done?" signal is therefore `step_count`, not history
# emptiness. Using `!isempty(history)` here would mis-fire — it would
# exit the loop early when the last surviving checkpoint sits at step
# 0 (impossible by the M4.2 step-0 carve-out, but the loop predicate
# should not depend on that carve-out) and, more importantly, would
# leave us at a non-zero `step_count` with `s.current` not equal to
# `s.initial`, breaking the M4.5 round-trip exit invariant.
#
# `step_count > 0` is the right predicate because M4.3's `unstep!`
# decrements `step_count` by exactly 1 per call, so the loop is
# bounded by the initial `step_count` (well-defined termination).
#
# ## Why the structural post-condition assertion lives here
#
# After the loop terminates, `step_count == 0`. If `unstep!` is
# correct, the truncation rule "pop entries with step > target" run at
# `target = -1` on the final iteration would also drain the last entry
# (step 0 entries are forbidden by M4.2's step-0 carve-out, so any
# remaining entry has step >= 1 > 0 >= -1... wait, but the final
# `unstep!` runs with `step_count = 1`, so `target = 0`, popping
# entries with `step > 0` and retaining the impossible step-0 entry).
# In other words, `isempty(history)` SHOULD be implied by
# `step_count == 0` IF M4.3 is correct. The post-condition assertion
# inside `unrun!` is the structural canary that fires when M4.3's
# truncation logic has silently regressed — the load-bearing
# invariant is `step_count == 0 ⇔ history empty`, and we pin it here
# because pinning it inside `unstep!` is per-step (slow, and the
# wrong scope: `unstep!` allows transient violations of this
# biconditional mid-call between the truncate and the replay).
#
# ## Why NO manual status reset to `:running`
#
# A subtle smell to avoid. After the loop, `s.current` is the
# (deepcopied) `s.initial`, which was constructed by `initial_state`
# (`src/interpreter/Interpreter.jl` M3.1) with `status === :running`.
# So `s.current.status === :running` will hold post-`unrun!`
# *naturally* — there is no manual reset needed. Adding one would be a
# correctness smell: the post-state of `unrun!` is determined by
# `s.initial`, not by a side-channel reset. If a caller constructs a
# degenerate RState with `initial.status === :error` (`initial_state`
# would never produce one, but the M4.3 4-arg constructor does not
# enforce a `:running` check on the initial), runs it a few steps,
# then `unrun!`s, the post-state status MUST be `:error` — that's the
# faithful inverse. A manual `:running` reset would lie about that.
#
# ## Why the max-iterations guard is binding
#
# PRD v4 §3.16 forbids silent infinite loops. If M4.3's `unstep!` ever
# fails to decrement `step_count` (e.g., a hypothetical regression
# where it errors-silently-and-returns-without-decrement), this loop
# would spin forever; the guard converts that pathological case into
# a loud Rule-1 raise with the offending step_count and history
# length, leaving the RState mid-reverse so a future
# debugger/`unstep!` audit can inspect it. The default value (10_000)
# matches `run!`'s default — the symmetry is intentional: a program
# that finished in N < 10_000 forward steps will not need more than
# N backward steps to reverse, by M4.3's "decrement by 1 per call"
# invariant.
#
# # Cross-references
#
#   * `references/foundational/bennett-1973-logical-reversibility.pdf`
#     §"Discussion" p. 529 col. 1 — Stage-3 retrace; the canonical
#     ancestor of this function. Table 1 (p. 528) shows the
#     Compute/Output/Retrace three-stage decomposition; M4.4 is the
#     retrace stage's BennettVM realisation.
#   * `bennettvm_prd.md` (PRD v4) §3.3 — three-layer history; this
#     function is L3's reverse-driver.
#   * `bennettvm_prd.md` (PRD v4) §3.9 — `unrun!(rstate, prog) ::
#     RState` signature.
#   * `bennettvm_prd.md` (PRD v4) §3.16 — descriptive raise on guard
#     fire; no silent infinite loops.
#   * `references/reverse-debugging/ocallahan-2017-rr-deployability.pdf`
#     §2.1 — the rr architecture M4.3 (this function's per-iteration
#     primitive) is the BennettVM specialisation of.
#   * `src/history/Replay.jl` `unstep!` (M4.3) — the per-iteration
#     primitive. `unrun!`'s correctness rests on M4.3's correctness:
#     `unstep!` MUST decrement `step_count` by exactly 1 and MUST
#     leave `s.current` reflecting the step `target = step_count - 1`
#     state.
#   * `src/interpreter/Interpreter.jl` `run!` (M3.4) — the forward
#     analogue whose kwarg-guarded loop shape this function mirrors.
#   * `spike/src/Interpreter.jl:247-253` — the spike's `unrun!`,
#     which used `while !isempty(history)` because its L3-equivalent
#     pushed every step. The Phase-2 predicate change documented
#     above is the lesson the L3 redesign forced.
#   * `docs/impl-plan/phase2-impl-plan.md` M4.4 (lines 221-223) — the
#     milestone spec.
#   * CLAUDE.md Rule 1 (fail loud); Rule 4 (every test pins a known-
#     correct value, never inside the function under test); Rule 11
#     (literate docstring).

"""
    unrun!(s::RState, prog::VMProgram; max_unsteps::Int = 10_000)::RState

Reverse the interpreter all the way back to step 0 — the inverse of
`run!`. Repeatedly invokes `unstep!(s, prog)` until `s.step_count ==
0`, then asserts the structural exit invariant `isempty(s.history)`
(PRD v4 §3.9). The RState is mutated in place; the same RState is
returned for chaining.

The post-condition `s.current == s.initial` is NOT asserted inside
this function: that semantic invariant is M4.5's job to test from the
outside, and folding it in here would reduce the round-trip test to
"did `unrun!` throw?" — the Rule-4 anti-pattern. The structural
invariant `isempty(s.history)` IS asserted here because it is the
loop's explicit exit condition: a violation indicates a bug in
`unstep!`'s history-truncation logic (the load-bearing invariant being
`step_count == 0 ⇔ history empty`).

# Loop invariant

Each iteration calls `unstep!(s, prog)`, which by M4.3's contract
decrements `s.step_count` by exactly 1 and truncates any
`s.history` entries whose `step` index exceeds the new target. The
loop is bounded by the initial `s.step_count`, so termination is
mechanical (no convergence argument needed).

# Halt-state interaction

A fully-run program has `s.current.status === :halted`. `unrun!`
must reverse from that state; the path is transparent — the first
iteration's `unstep!` call backs out of the halt boundary (M4.3
restores a pre-halt snapshot whose `status === :running`), and
subsequent iterations are pure `:running`-to-`:running` reversals.
No manual status reset is needed; the final `s.current.status`
emerges naturally from `s.initial.status` (which is `:running` when
`s.initial` came from `initial_state`).

# Arguments

  * `s` — RState; mutated in place.
  * `prog` — the VMProgram being reversed.
  * `max_unsteps` — keyword; default 10_000. Mirror of `run!`'s
    `max_steps` default. A correct `unstep!` decrements `step_count`
    by 1 per call, so a program that ran forward in `N < max_unsteps`
    steps reverses in the same number of iterations; the guard exists
    to catch the pathological case where `unstep!` regresses
    silently-without-decrement (Rule 1). On guard fire, the RState is
    left mid-reverse for inspection — the partial reversal is NOT
    rolled back.

# Returns

`s` (the same mutated RState). After return: `s.step_count == 0`,
`isempty(s.history)`, and `s.current == s.initial` (the last
property is implied by `unstep!`'s correctness; M4.5 tests it).

# Errors

`ErrorException` if either:

  - The `max_unsteps` guard fires before `s.step_count` reaches 0.
    Indicates a bug in `unstep!` (which MUST decrement `step_count`
    by 1 per call). The RState is left mid-reverse.
  - The post-condition `isempty(s.history)` is violated. Indicates a
    bug in `unstep!`'s truncation logic. The diagnostic message
    reports the remaining entries' step indices via `_entry_step`
    (M4.3 dispatch helper; gracefully handles future M6/M7 entry
    types).

# Ref

  * `references/foundational/bennett-1973-logical-reversibility.pdf`
    §"Discussion" p. 529 col. 1 — Stage-3 retrace; the canonical
    ancestor: "The third stage undoes the work of the first … the
    history tape is again blank and the other tapes contain the
    reconstructed input and the desired output."
  * PRD v4 §3.3 (three-layer history), §3.9 (`unrun!` signature),
    §3.16 (fail-loud on guard fire).
  * `references/reverse-debugging/ocallahan-2017-rr-deployability.pdf`
    §2.1 — the rr architecture (per-iteration primitive M4.3).
  * `src/history/Replay.jl` `unstep!` (M4.3) — per-iteration
    primitive.
  * `src/interpreter/Interpreter.jl` `run!` (M3.4) — forward
    analogue.
  * `spike/RETROSPECTIVE.md` Q3 — the halt-state propagation lesson
    motivating the "no manual `:running` reset" discipline above;
    `run!`'s docstring in `src/interpreter/Interpreter.jl` cites the
    same source for the symmetric forward-direction issue.
  * CLAUDE.md Rule 1, Rule 4, Rule 11.
"""
function unrun!(s::RState, prog::VMProgram; max_unsteps::Int = 10_000)::RState
    # The guard counter mirrors `run!`'s n; bound is max_unsteps. A
    # correct `unstep!` decrements step_count by 1, so this loop runs
    # at most the initial value of `s.step_count` (the count on entry
    # to `unrun!`) times — always finite. The guard exists for the
    # pathological "unstep! silently fails to decrement" case Rule 1
    # forbids being silent about.
    n = 0
    while s.step_count > 0
        n >= max_unsteps && error(
            "unrun!: max_unsteps=", max_unsteps, " exceeded ",
            "(step_count=", s.step_count, ", history length=",
            length(s.history), "). RState left mid-reverse for ",
            "inspection — the partial reversal has NOT been rolled ",
            "back. This guard should NEVER fire for a correct ",
            "unstep! implementation (each unstep! must decrement ",
            "step_count by exactly 1); if it does, M4.3's algorithm ",
            "has regressed. Increase max_unsteps if the program ",
            "legitimately took >", max_unsteps, " forward steps. ",
            "PRD v4 §3.16 (fail-loud) + Rule 1.")
        unstep!(s, prog)
        n += 1
    end

    # Structural post-condition. After the loop, step_count == 0; the
    # load-bearing invariant is `step_count == 0 ⇔ history empty`. A
    # violation here indicates that `unstep!`'s truncation logic has
    # silently regressed (e.g., a `step >= target` rule slipping into
    # what should be a `step > target` rule, or an off-by-one in the
    # final iteration's target computation). The `_entry_step` call is
    # M4.3's dispatch helper — it handles `CheckpointEntry` today and
    # will gracefully handle M6/M7 entry types as they land, without
    # this assertion needing to know about them.
    isempty(s.history) || error(
        "unrun!: structural post-condition violated — step_count ",
        "reached 0 but s.history is non-empty (",
        length(s.history), " entries remain at steps ",
        [_entry_step(e) for e in s.history],
        "). The load-bearing invariant `step_count == 0 ⇔ history ",
        "empty` is broken; this indicates a bug in unstep!'s ",
        "history-truncation logic (M4.3). PRD v4 §3.9 + Rule 1: ",
        "reversibility violations are correctness bugs, not warnings.")

    return s
end
