```@meta
CurrentModule = BennettVM
```

# The Reversibility Model

*Why BennettVM can un-run any terminating computation it ran — and how it does so without
storing a snapshot at every step. This page explains the three-layer history tape, the data
structure at the heart of the VM.*

A reversible circuit is a fixed permutation; its inverse is just the gate sequence read
backwards. An *interpreter* has no such luxury. It overwrites registers, stores into a heap,
and follows a program counter whose path the input decides. To run such a machine backwards
you must be able to reconstruct, at every step, the state the forward step destroyed.

The naive way — snapshot the whole machine before every instruction — costs `O(T)` full
state copies for a `T`-step run and is **explicitly prohibited** by the specification
([`bennettvm_prd.md`](https://github.com/tobiasosborne/BennettVM.jl/blob/master/bennettvm_prd.md)
§3.3). BennettVM instead keeps a *history tape* with three layers, each cheaper than the last,
tried in order of preference. Most steps log nothing at all.

## The shape of the round-trip

Everything below exists to make one line of code true:

```julia
using Bennett, BennettVM

prog = reversible_compile(f, Int64; target = :reversible_vm)   # a BennettVM.VMProgram
#   (lower_vm(parsed_ir) is the lower-level door to the same VMProgram.)

s = initial_state(prog, Dict(:x => 7))   # input keyed by the entry block's parameter names
run!(s, prog)                            # forward to :halted
out = result(s)                          # a copy of the active register file

unrun!(s, prog)                          # retrace all the way back

@assert s.step_count == 0                # back at the start
@assert isempty(s.history)               # the tape is empty again
@assert s.current == s.initial           # bit-for-bit the initial state
```

`s` is an `RState` (`src/ir/RState.jl`): a `current::IState`, a `history::Vector` of tape
entries, a `step_count`, and `initial::IState` — a deep copy of the starting state, frozen at
construction. The history tape is that `history` vector, and the rest of this page is about
what goes onto it and what does not.

## Three layers, tried in order

At each successful forward step the interpreter's *push gate* (step `(7)` of `step!`,
`src/interpreter/Interpreter.jl`) decides which layer records the step:

| Layer | Pushed when | Entry | Space | Reversed by |
|-------|-------------|-------|-------|-------------|
| **L1 — no log** | `is_injective(instr)` | *nothing* | 0 | nothing to pop — falls through to the L3 replay-forward path |
| **L2 — delta** | non-injective **and** the slot is must-cached (or `is_unconditional_l2`) | `DeltaEntry` (minimal payload) | `O(`destroyed value`)` | `inverse(instr, state, payload)` — fast-path |
| **L3 — checkpoint** | every `K = 64` steps | `CheckpointEntry` (deep-copied `IState`) | `O(T/K)` | restore nearest snapshot, replay forward |

The gate logic, in order:

```julia
step_count += 1
if !replay_mode
    if is_injective(instr)                         # L1
        # push nothing
    elseif pre_l2                                  # L2  (captured before forward())
        push!(history, DeltaEntry(instr, payload, step_count))
    elseif step_count % checkpoint_interval == 0   # L3
        push!(history, CheckpointEntry(s.current, step_count))
    end
end
```

`step_count` is canonical: it advances on **every** successful forward step, including the
injective ones that push nothing. This is why history length is *not* a step proxy — a 12-step
injective run leaves `step_count == 12` and `isempty(history)`.

### L1 — no log: injective instructions

An instruction is **injective** when its forward semantics are a bijection on the slice of
`IState` it touches: no information is destroyed, so the inverse is recoverable from the
post-state alone. These steps push nothing.

The gate is the `is_injective` trait (`src/history/Injective.jl`), a type-level predicate that
**defaults to `false`** — the fail-safe choice from Rule 1: an unclassified instruction logs a
history entry rather than silently corrupting its inverse. Marking a type `true` is a
deliberate correctness assertion. Eleven concrete subtypes are pinned `true`:

- the control-flow markers `BeginInstruction`, `EndInstruction`, `UnconditionalEntry`,
  `UnconditionalExit`, `ConditionalEntry`, `ConditionalExit` — invertible without a record
  because the predicate that selected the branch stays *live* in the locals at every
  transition, so backward dispatch recovers the source block structurally;
- the exchange/permutation ops `SwapInstruction`, `MemoryInterchange`, `MemorySwap` — they
  permute existing values rather than overwriting them with computed ones;
- `CallEnter`, the zero-history call transition (its inverse re-runs the forward dispatch);
- `IntrinsicFree`, the one injective heap intrinsic — at the memory floor `free` mutates
  nothing, because the arena cursor only *grows* and freed regions are never re-allocated.

There is also one **value-level** injective case: `ArithmeticAssignment` with `modop === :xor`.
`x := y ⊕ (lhs op rhs)` is self-inverse only for xor; the `:add`/`:sub` modops are deliberately
treated as non-injective (they take the L2 path, inverted via the dual modop). This is a
conservative narrowing of PRD §3.2, which lists all three as no-log primitives.

A subtle pin worth knowing (ADR 0012, the *cross-iteration reversibility crux*): `Define`,
`MemoryLoad`, `CastInstruction`, `SelectInstruction`, `VarGEP`, and `IRMapGet` are forced
non-injective **even though a single execution looks bijective** — inside a loop the same SSA
name is redefined each iteration and may overwrite a prior live value, and the static trait
cannot see runtime freshness. Do not "optimise" these to `true`.

### L2 — delta entries: the minimal destroyed value

When a non-injective step *does* run, the cheapest honest record is not a full snapshot but
just the value the forward step is about to clobber — Enzyme's min-cut cache idea
(Moses–Churavy 2020), ported to the VM's IR per
[ADR 0002](https://github.com/tobiasosborne/BennettVM.jl/blob/master/docs/adr/0002-enzyme-min-cut-mapping.md).
That record is a `DeltaEntry` (`src/history/delta.jl`):

```julia
struct DeltaEntry{T<:Instruction} <: AbstractHistoryEntry
    instruction::T
    payload::NamedTuple   # the minimal pre-state the inverse needs beyond current state
    step::Int             # the post-increment step index
end
```

The minimal pre-state is captured **before** `forward()` runs, by the `predelta_payload` hook
(default `nothing`). It returns exactly what the forward step is about to destroy:

- `MemoryStore` → `(addr, old_value, was_present)` — the cell's prior contents;
- `DynAlloca` → `(base, n)` — the bump-cursor delta to undo;
- `IRMapInsert` / `IRMapDelete` → `(key, prior)` — the reversible-map slot before the edit;
- `ReturnExit` → `(residual, fname, end_pc)` — the backward-control-flow breadcrumb.

The payload is a `NamedTuple` — a value type, so it compares and hashes structurally and costs
nothing when empty. And it is empty in the dominant case: the `{:xor, :add, :sub}` modop set is
closed under its dual, so an `ArithmeticAssignment` or `MemoryAssignment` inverts by recomputing
from surviving state alone, with `payload = NamedTuple()`.

Which non-injective slots actually take L2 is an *opt-in min-cut decision*. The liveness pass
`compute_must_cache(prog)` (`src/analysis/liveness.jl`) returns the set of body slots that are
non-injective **and** `is_l2_capable` (have a working `inverse` + payload path); the caller
passes it as the `must_cache_set` kwarg to `run!`. A slot takes L2 when it is in that set —
or when the instruction is `is_unconditional_l2`, which is true for exactly one type:
`ReturnExit`, whose delta is the breadcrumb that routes the backward pass into the callee's
end instead of re-entering `CallEnter` ([ADR 0019](https://github.com/tobiasosborne/BennettVM.jl/blob/master/docs/adr/0019-reversible-calls.md)).
Non-injective instructions that are *not* L2-capable (`Define`, `MemoryLoad`, `Cast`, …) are
never min-cut and fall through to L3 — routing them to L2 would hit a deliberately-raising
`make_delta` fallback (Rule 1), which is the whole point of the `is_l2_capable` guard.

### L3 — checkpoints and deterministic replay

L3 is the safety net under everything else: a full-state `IState` snapshot taken every
`K = 64` steps (`src/history/CheckpointEntry.jl`).

```julia
struct CheckpointEntry <: AbstractHistoryEntry
    snapshot::IState   # deep-copied in the constructor — mandatory, not an optimisation
    step::Int
end
```

The deep copy in the constructor is load-bearing: `IState` carries `Dict` fields (`memory`,
`revmap`, the per-frame `locals`), and a by-reference capture would *alias* the live dicts and
silently track the latest state instead of the state at step `K`. Periodicity is what keeps L3
off the prohibited per-step-snapshot anti-pattern: space is `O(T/K)`, not `O(T)`.

The reversal strategy is rr's *record-nondeterminism, replay-determinism* architecture
(O'Callahan 2017), degenerate here because the VM is fully deterministic — no I/O, no
concurrency, no hardware randomness. So "record nondeterminism" is zero work, and going
backward is simply: **restore the nearest checkpoint, then replay forward**. A 64-step window
costs at most one snapshot restore plus ≤ 63 deterministic forward steps.

## Forward-before-push

The ordering invariant the whole tape rests on: `step!` runs `forward()` (and cross-block
dispatch, call dispatch, and halt detection) **first**, and pushes the history entry **only
after**, at step `(7)`. The L2-vs-L3 decision is read *pre-`forward()`* into local flags
(`pre_l2`, `pre_payload`) because it depends only on the instruction, the pc, and the
`must_cache_set` — none of which `forward()` mutates — but the entry is constructed and pushed
post-`forward()`, when the destroyed value and the final `step_count` are both known.

One consequence worth stating plainly: on a *throwing* `forward()`, `history` and `step_count`
are unchanged (the push never happened), but `s.current` may be partially mutated, because
`forward` mutates `IState` in place. The atomicity guarantee is over the tape, not over
`s.current`.

## How `unstep!` and `unrun!` reverse

`unstep!(s, prog)` moves the machine back exactly one step, and it has two routes to the same
answer (`src/history/Replay.jl`):

1. **L2 fast-path.** If the top of `history` is a `DeltaEntry` whose `step == s.step_count`
   (note: the *post-increment* convention — equal to `step_count`, not `step_count - 1`), pop
   it, call `inverse(entry.instruction, s.current, entry.payload)`, and decrement
   `step_count`. This is `O(1)`.

2. **L3 restore + replay.** Otherwise: walk `history` for the nearest `CheckpointEntry` with
   `step ≤ target` (`= step_count - 1`); if none exists, fall back to `s.initial` with
   `start_step = 0`. Set `s.current = deepcopy(restore_snap)`, truncate the future tail of
   `history`, then replay `step!` forward — in `replay_mode = true`, which suppresses *both*
   L2 and L3 pushes — until `step_count == target`.

The fast-path is a sound optimisation of the general path: both reconstruct the identical prior
state.

The **`initial` field is the step-0 anchor.** When the target is earlier than the first
checkpoint, the L3 path falls back to `s.initial` as its restore source. This is exactly why
the `RState` carries a deep-copied `initial::IState`: backing past the first checkpoint needs a
seed, and without `initial` you would have to either push a phantom step-0 history entry (which
would break the empty-tape invariant below) or re-run the lowering from a stored input dict
(which the `RState` does not keep).

`unrun!(s, prog)` is the loop driver — BennettVM's realisation of Bennett-1973's Stage-3
retrace. It calls `unstep!` while `step_count > 0` (note the predicate: `step_count`, *not*
`!isempty(history)` — L3 decouples the two), then asserts the structural exit invariant
`isempty(s.history)`. It does **not** assert `s.current == s.initial`: that semantic check is
deliberately left to the external round-trip test, so that the test verifies something stronger
than "did `unrun!` throw?".

## The load-bearing invariant

```julia
unrun!(run!(s, prog), prog)   # ⟹  s.step_count == 0
                              #     isempty(s.history)
                              #     s.current == s.initial
```

The third clause is only meaningful because both `IState` and `RState` override `Base.==` and
`Base.hash` to compare **content** (`src/ir/IState.jl`, `src/ir/RState.jl`). Julia's default
`==` identity-compares `Dict` fields, under which a perfectly-reversed run would *never* satisfy
`s.current == s.initial`. The structural equality is mandatory machinery, not a convenience.

`step_count == 0 ⇔ isempty(history)` is itself load-bearing: it is the canary that catches a
truncation regression in `unstep!`. If an `unstep!` ever leaves an orphaned entry on the tape,
`unrun!`'s `isempty` assertion fires.

## Connecting back to Bennett 1973

Bennett's 1973 construction makes an irreversible computation reversible in three stages:
**compute** the result forward, **copy** the output out, then **retrace** the computation
backwards to erase every intermediate — leaving the machine clean, with all scratch space
returned to zero. Bennett.jl realises this as a circuit: forward gates, a CNOT fan-out of the
output, and the forward gates reversed.

BennettVM realises the same three stages dynamically:

| Bennett 1973 | Bennett.jl circuit | BennettVM |
|--------------|--------------------|-----------|
| compute      | forward gate sequence | `run!` — forward to `:halted` |
| copy output  | CNOT fan-out of the result | `result(s)` — a *copy* of the active register file, taken without disturbing the run |
| retrace      | the forward gates reversed | `unrun!` — `unstep!` back to step 0 |

The history tape *is* the reversible scratch space. "All ancillae return to zero" becomes
`isempty(s.history)` — the tape that recorded the forward run is fully consumed by the backward
run, and the machine is bit-for-bit where it started. The three layers are the optimisation
Bennett's abstract argument leaves open: the cheapest layer that can still reconstruct each
destroyed value wins, and the most common answer — for an injective step — is to store nothing
at all.

## See also

- [The instruction set & state model](instruction_set.md) — the ~34 `Instruction` subtypes and
  the `IState`/`RState` fields the tape operates over.
- [Integration with Bennett.jl](integration.md) — how `reversible_compile(f, T;
  target = :reversible_vm)` reaches `lower_vm`.
- [API reference](../reference/api.md) — signatures for `initial_state`, `run!`, `unrun!`,
  `step!`, `unstep!`, `result`.
- `bennettvm_prd.md` §3.2–§3.3 (PRD v4) — the binding specification for injective primitives
  and the three-layer history mechanism.
