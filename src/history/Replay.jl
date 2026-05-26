"""
    Replay (M4.3) — `unstep!` via L3 checkpoint-replay

The third concrete step in the PRD v4 §3.3 three-layer history
implementation. Where M4.1 defined `CheckpointEntry` (the entry type)
and M4.2 modified `step!` to push entries periodically (every K steps),
M4.3 lands the *consumer*: a single-step backward primitive that finds
the nearest checkpoint at-or-before the target step and replays forward
deterministically to reconstruct the prior state.

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

# Why `checkpoint_interval = typemax(Int)` during replay

M4.2's `step!` push guard is `s.step_count % checkpoint_interval == 0
&& s.step_count > 0`. With `K = typemax(Int)`, for any `step_count`
in `[1, typemax(Int) - 1]` we have `step_count % typemax(Int) ==
step_count`, which is `> 0` (never `== 0`). The push therefore never
fires. Setting K to `typemax(Int)` is the cleanest way to suppress
pushes without introducing a "replay mode" flag on `RState` or a
second variant of `step!`. The cost is one redundant modulo per step
during replay; M4.5's round-trip benchmark will show this is below
the noise floor for the four motivating cases of PRD v4 §3.6.2.

The alternative — calling a hypothetical internal `_step_without_push!`
— was rejected on Law 2 / Rule 11 grounds: every consumer that wants
"step without push" can spell it as `step!(..., checkpoint_interval =
typemax(Int))`, and forking the function signature would duplicate
the dispatch logic for no readability gain.

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
specification. Briefly: find the nearest `CheckpointEntry` at or
before the target step, restore its (deep-copied) snapshot into
`s.current`, truncate later entries off `s.history`, reset
`s.step_count`, then replay `step!` forward until `step_count ==
target`. Replay passes `checkpoint_interval = typemax(Int)` to
suppress spurious pushes (see top-of-file §"Why `checkpoint_interval
= typemax(Int)` during replay").

# Ref

  * PRD v4 §3.3, §3.9, §3.16.
  * `references/reverse-debugging/ocallahan-2017-rr-deployability.pdf`
    §2.1 — the rr architecture.
  * `src/history/CheckpointEntry.jl` (M4.1) — entry type.
  * `src/interpreter/Interpreter.jl` (M4.2) — forward `step!` whose
    push policy this function inverts.
  * `src/ir/RState.jl` (M4.3) — the `initial::IState` anchor field.
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

    # (6) Replay forward to target. The kwarg suppresses spurious
    # pushes (see top-of-file §"Why `checkpoint_interval = typemax(Int)`
    # during replay"). The loop is bounded by `target - start_step`
    # iterations — at most `K - 1` for a target one-past the nearest
    # checkpoint (typical M4.2 K=64 default → at most 63 replay
    # steps), and at most `step_count_before - 1` for the worst-case
    # fallback to s.initial (i.e., no checkpoint at or before
    # target — only happens when target < first_checkpoint_step,
    # which for K=64 means target < 64).
    while s.step_count < target
        step!(s, prog; checkpoint_interval=typemax(Int))
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
_entry_step(e::AbstractHistoryEntry) =
    error("_entry_step: no method for entry type ", typeof(e),
          " — M4.3's truncation loop needs an explicit step index. ",
          "If this is an M6/M7 entry type, the introducing milestone ",
          "must define `_entry_step(::ThatType)` alongside the type. ",
          "Rule 1: fail loud, not silent.")
