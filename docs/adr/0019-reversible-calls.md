# ADR 0019 — Reversible call/return: frame stack in `IState`, zero-history call, L2-residual return

> **Status: ACCEPTED 2026-06-10.** Bead `bennettvm-416r.5` (CW-B1). First
> hostile review: REJECT (B1, B2 blocking + C1–C6); all fixes applied;
> focused re-review: ACCEPT (reviews archived in session transcript).
> Implements ADR 0017 §Decision 2 under the constraints of ADR 0018 §C.
> Synthesized from two independent design proposals (proposer A: ISA-faithful
> minimal-history; proposer B: explicit frame stack; both archived in the
> 2026-06-10 session transcript). The two converged on §1–§2 independently;
> §4 adjudicates their one substantive fork.

---

## Ground truth (Law 1)

- **BobISA** — Thomsen–Axelsen–Glück 2012 (file
  `references/reversible-isa/axelsen-yokoyama-2011-bobisa.pdf`, see manifest
  citation-errata), §3.2 / Table 2 (paper pp. 5–6; LNCS 7165 pp. 34–35):
  jump-and-link via SWB/RSWB —
  *"SWB will swap the value of a given register with the value of the branch
  register"*; the return offset is saved **in register state at the target**,
  and inverse calls are the same mechanism under a direction flip. The
  CLAUDE.md callout ("BobISA jumps encode the source label") is this
  discipline.
- **PISA** — Vieri 1995 (`references/reversible-isa/vieri-1995-pendulum-ms.pdf`)
  p. 22: *"the information is merely moved from one place to another rather
  than erased"* — argument passing must MOVE values between frames, never
  copy-and-drop. Vieri's coalescing-control-flow observation (~p. 31): joins
  in control flow force stored information unless the source language
  guarantees reversibility.
- **RC3 `rvm`** — `references/implementations/RC3/` (design lessons only,
  per CLAUDE.md): `RSSAVM.java` explicit `callStack` of `StackFrame`s
  (per-frame locals + return ip + caller direction), two-phase
  pass-and-destroy / restore-and-create call protocol, `allDestroyed`
  assertion at procedure `End`.
- **This machine** — `src/interpreter/Interpreter.jl` (flat-stream pc,
  cross-block dispatch, three-way L1/L2/L3 push gate), `src/ir/IState.jl`
  (flat `locals`; the `arena_top`-must-join-`==`/`hash` lesson, ADR 0018 §H),
  `src/history/` (L2 `DeltaEntry`, L3 `CheckpointEntry` = `deepcopy(IState)`,
  `Replay.jl`), `src/ir/call_instruction.jl` (the existing RC3-style
  `CallInstruction` stub — superseded by this ADR, see §8).

## The constraint that drives everything

BobISA and RC3 achieve **history-free calls** because their source languages
are reversible by construction: at a procedure's `End`, every local is
provably consumed, so popping the activation loses nothing. **Our callees
are lowered from irreversible C/Rust/Julia LLVM IR and arrive with dead
temporaries live at `End`.** A design that assumes clean-`End` (proposer A's
zero-history return) has an unsatisfiable precondition; a design that claims
frame-pop is injective while silently dropping scratch (proposer B's §3 as
written) is unsound for the same reason — the re-pushed frame on the
backward pass would lack exactly the values the callee body's reversal needs.
The floor must log the residual. The optimization tier (liveness/min-cut,
ADR 0002; or a Bennett-style uncompute pass) later shrinks the residual
toward zero — at which point the design degrades gracefully into BobISA.

## Decision

### 1. State: frames live in `IState`

```julia
struct Frame
    link::Int64                  # caller's return pc (flat-stream; = call_pc + 1)
    targets::Vector{Symbol}      # caller SSA dests where return values land
    locals::Dict{Symbol,Int64}   # this activation's register file
    fname::Symbol                # callee name (diagnostics + End resolution checks)
end
# IState gains: frames::Vector{Frame}   (never empty; frames[1] is the entry activation)
```

- `frames` **joins `Base.:(==)` and `Base.hash`** (`Frame` gets content
  `==`/`hash`). Non-negotiable — ADR 0018 §H / ADR 0008 Finding-3: state
  that must round-trip but is absent from `==` makes round-trip tests pass
  spuriously.
- L3 `CheckpointEntry` does `deepcopy(IState)`; the frame stack (with every
  suspended activation's locals) **rides checkpoints with zero
  `CheckpointEntry.jl`/`Replay.jl` structural change** — the same free ride
  `heap_top`/`arena_top` get. Replay-forward reconstructs call context
  because the snapshot *is* the call context.
- **Active register file = `frames[end].locals`, via an accessor**
  (`active_locals(s)`), migrating existing `s.locals` reads. We explicitly
  REJECT proposer B's swap-the-Dict alternative (install/restore a fresh
  `Dict` in `IState.locals` at the boundary): B's own risk analysis is
  right — any retained reference to the swapped Dict (delta payload,
  closure) silently corrupts the wrong frame; the accessor has more churn
  but no aliasing.
- **The `IState.locals` FIELD IS REMOVED** (hostile-review B2). Keeping
  both a top-level `locals` and `frames[end].locals` invites exactly the
  staleness trap the reviewer identified: instructions write the frame,
  checkpoints snapshot a stale top-level dict, replay corrupts (the spike
  Q2.2 trap at frame level). Resolution that avoids the constructor
  cascade: **every existing constructor keeps its arity and argument
  order** — the `locals::Dict` argument is wrapped at construction into
  the bottom frame, `frames = [Frame(0, Symbol[], locals, :__entry)]`.
  Constructor *call sites* (~111) are untouched; only field *reads*
  migrate to `active_locals(s)` (a bounded, grep-auditable set).
  `Base.:(==)`/`hash` compare `frames` (which contains the bottom locals)
  — no double-count, no stale copy. Single-function programs are
  semantically byte-identical (default-constructor discipline as for
  `arena_top`).
- **Memory is global and monotone across frames.** `s.memory`, `heap_top`,
  `arena_top` are VM-global; a callee's `malloc` survives return (the C
  idiom `ht_new` → `malloc` → return pointer requires it), and retracting
  the arena at return would violate ADR 0018 §A's monotone-cursor soundness.
  Frames carry registers, never memory.

### 2. Program: function table over one flat stream

```julia
struct FunctionEntry
    name::Symbol; entry_label::Symbol
    params::Vector{Symbol}; returns::Vector{Symbol}
end
# VMProgram gains: functions::Dict{Symbol,FunctionEntry}; entry_function::Symbol
```

All functions' blocks live in the existing single `blocks` vector with the
existing single `LabelTable`; **labels are function-qualified at ingest**
with the precise scheme (hostile-review C3): `qualified =
Symbol(string(fname), "#", string(label))`. The `#` separator is collision-
proof against the existing synthetic-label conventions (`:e_<src>_<dst>`
trampolines and `_phi_const_<src>_<v>` defines use `_`, never `#`; LLVM/
Bennett.jl block labels use letters, digits, `.` and `_`, never `#`).
Ingest validates fail-loud that (a) no incoming label or function name
contains `#`, and (b) function names are unique across the module. (RC3
itself mangles per-procedure — same move.) This deliberately
preserves the flat global `pc`, `_instruction_at`, cross-block dispatch, and
the L3 replay loop unchanged (proposer A), rejecting proposer B's
per-function `(fn, pc)` addressing, which B itself called the most invasive
change with no floor-level payoff. Closed-world resolution at ingest: an
`IRCall` callee that is not in `_NONDETERMINISTIC_CALLEES` (guard 1), not in
`_HEAP_DISPATCH` (guard 2, ADR 0018 §C), not a SoftCall float op (guards
3–4) must resolve in `functions` — **miss ⇒ `error()`** (Rule 1). Indirect
calls (function pointers) fail loud; closed-world devirtualization is
deferred (§7).

### 3. Call transition: `CallEnter` — zero history (L1-injective)

```text
forward(CallEnter(callee, args, targets), s):
  argv = [active_locals(s)[a] for a in args]; delete each a   # MOVE, not copy (Vieri p.22)
  push!(s.frames, Frame(link = s.pc + 1, targets, Dict(), callee))
  bind argv positionally under functions[callee].params in the new frame
  s.pc = label_table[entry_label(callee)].fwd_address + 1

inverse(CallEnter, s):     # SEMANTIC inverse — see normative note below
  argv = [active_locals(s)[p] for p in params]   # body reversal restored params = original args
  pop!(s.frames); rebind argv under args in the caller frame
  s.pc = (popped frame).link - 1                 # call site recovered FROM STATE (BobISA)
```

Information conservation: the return site lives in `Frame.link` (BobISA's
saved branch register); the moved args live under the callee's params.
Nothing is erased ⇒ nothing is logged.

**Normative dispatch note (hostile-review C1).** `unstep!` in this machine
is history-driven (M7.4 fast path: top entry is a `DeltaEntry` matching
`step_count`) or checkpoint-driven (M4.3: restore nearest `CheckpointEntry`,
replay forward via `step!` with `replay_mode=true`). Because `CallEnter`
pushes nothing, **the backward pass crosses it via the M4.3 path**: replay
re-executes `forward(CallEnter, …)`, which reconstructs the frame — the
reviewer verified this is mechanically correct in the current `Replay.jl`.
The `inverse` pseudocode above is the *semantic* inverse; it is reached
only if the direct-inverse backward-dispatch path (bead `xtb` territory)
is later extended with the function-entry special case (`pre-image pc =
frames[end].link - 1` when standing at an entry marker with depth > 1).
CW-B2 MUST NOT assume history-driven dispatch ever reaches it.
Registration (hostile-review C2): `is_injective(::CallEnter) = true` in
`src/history/Injective.jl` AND `is_l2_capable(::CallEnter) = false` in
`src/history/delta.jl` — without the former, the push gate calls the
raising `make_delta` fallback and every call-containing program aborts.

### 4. Return transition: `ReturnExit` — unconditionally L2, residual-frame delta

The adjudicated fork. `ReturnExit` (the callee-`End` role at frame depth
> 1; at depth 1 `End` remains the halt marker exactly as today):

```text
predelta_payload(ReturnExit, s):               # captured BEFORE forward (interpreter step 3a)
  residual = [ (name, val) for (name,val) in active_locals(s)
               if name ∉ returns ]             # scratch live at End — the un-clean part
  return (residual = residual, fname = frames[end].fname,
          end_pc = s.pc)                       # hostile-review B1: the End marker's
                                               # flat-stream address, available exactly
                                               # here because 3a fires before forward
                                               # moves pc — inverse needs it and neither
                                               # the inverse signature nor IState carries
                                               # prog to look it up

forward(ReturnExit, s):
  retv = [active_locals(s)[r] for r in returns]
  fr = pop!(s.frames)
  bind retv under fr.targets in the (now-active) caller frame
  s.pc = fr.link

inverse(ReturnExit, p, s):                     # p = the L2 payload
  retv = [active_locals(s)[t] for t in saved targets]; delete each t from caller
  push!(s.frames, Frame(link = s.pc, targets, locals = Dict(returns .=> retv) ∪ Dict(p.residual), fname))
  s.pc = p.end_pc                              # re-enter callee at its End (from payload — B1)
```

Three properties make this the right floor:

1. **Soundness without preconditions.** The popped frame is reconstructed
   exactly: `returns` values are read back from the caller's `targets`
   (return landing is a MOVE — the inverse un-lands them), and the scratch
   the pop would otherwise destroy is in the logged residual. No clean-`End`
   assumption (proposer A's admitted gap), no silent scratch-drop (proposer
   B's gap).
2. **The L2 entry doubles as the backward-dispatch breadcrumb.** Under a
   flat pc, the instruction before the post-call site `link` is the
   `CallEnter` itself — naive `pc-1` backward stepping would re-enter the
   call instead of the callee's `End`. BobISA solves this with paired
   come-from branch targets at the return site; our equivalent is the
   history stack: the top entry at that point IS the `ReturnExit` delta,
   which routes the backward pass into the callee. This is why `ReturnExit`
   pushes **unconditionally** (an empty residual still pushes an empty
   delta): the entry is load-bearing for control, not only for data.
3. **Graceful degradation to BobISA.** For a callee proven clean at `End`
   (future liveness/uncompute pass), the residual is `[]` and the cost is
   one near-empty entry per return. The optimization tier — compute
   live-at-`End` statically, uncompute scratch, eventually elide via paired
   come-from markers — is exactly Enzyme-min-cut territory (ADR 0002) and
   is deferred with its forcing condition (§7). The floor never pays more
   than O(|scratch live at End|) per return.

### 5. Recursion: supported from day one

Frame isolation resolves SSA-name collision across activations (every
activation's `%n` is a key in its own frame's Dict); no mangling. The arity
checks reuse the existing positional `_rename_args_to_params!` discipline.
Recursion depth is bounded only by `run!`'s existing `max_steps` fail-loud
guard; a dedicated `max_frame_depth` guard is deferred (§7).

### 6. Fail-loud modes (Rule 1)

(a) unknown/indirect callee at ingest; (b) call arity mismatch
(args↔params); (c) return arity mismatch (returns↔targets) and a `targets`
name already live in the caller frame (SSA violation); (d) frame-stack
underflow on `ReturnExit`/`unstep!` (depth inconsistent with history);
(e) `ReturnExit.inverse` finding a `targets` value absent in the caller
(corrupted landing); (f) reading an SSA name absent from the active frame
(existing behavior, now frame-scoped).

### 7. Deferred (Rule 9 — bead + forcing condition each)

- **Residual-shrinking** (liveness → uncompute → zero-history returns).
  Forcing: history volume on call-heavy programs dominated by residual
  deltas, or the pebble/quantum tier needs history-free control flow.
- **`max_frame_depth` guard.** Forcing: a runaway-recursion program that
  exhausts memory before `max_steps` fires.
- **Closed-world devirtualization** of indirect calls. Forcing: first
  C/Rust fixture with function pointers.
- **RSSA `allDestroyed`-style validity pass** (RC3 lesson). Forcing: the
  uncompute pass lands and clean-`End` becomes checkable.
- **Reversible frame/alloca reclamation.** Forcing: per ADR 0018 §F.

### 8. Supersession and impact

The existing `src/ir/call_instruction.jl` `CallInstruction`
(recursive-sub-execution stub; host-stack recursion, no in-VM frame state,
`make_delta` raises) is **superseded**: its arg/target validation is
retained; its execution model is replaced by `CallEnter`/`ReturnExit`.
Direction-bit/`uncall` semantics (RC3) stay out of scope — `run!`/`unrun!`
remain the only direction drivers.

Impact (CW-B2): `IState.jl` (REMOVE `locals` field, wrap into bottom frame
at construction — constructor arities/call sites unchanged, field reads
migrate to `active_locals(s)`; +`frames` in `==`/`hash`), new
`src/ir/call_frames.jl` (Frame + CallEnter + ReturnExit, ≤200 LOC),
`VMProgram` (+`functions`, `entry_function`), `ingest.jl` (IRCall guard-5
resolution + multi-function lowering + `#`-label qualification — **will
force the u110 split; do the split first**), `Interpreter.jl` (accessor
migration; End-at-depth>1 routing), `Injective.jl` (+`CallEnter = true`),
`delta.jl` (+`ReturnExit` L2; `CallEnter` `is_l2_capable = false`).
The existing `CallInstruction` `:direct`-mode coverage in
`test/test_mutation_proof.jl` becomes a dead-letter at supersession
(hostile-review C5) — replace with `CallEnter`/`ReturnExit` `:direct`
equivalents in the same commit. Tests: new
`test_call_roundtrip.jl` (nested, recursive-factorial golden master vs
`factorial(5)`, per-step inverse ON `CallEnter` and ON `ReturnExit`,
L3-checkpoint-inside-callee, malloc-in-callee pointer survival, zero-history
assertion after `CallEnter`, fail-loud suite (§6)), mutation-proofs
(drop frame pop; drop residual from delta; drop `frames` from `==`).

## Reuse (Law 2)

**BobISA (TAG 2012 §3.2 pp. 5–6; LNCS pp. 34–35):** link-register call discipline —
`Frame.link` is the saved branch register; call-site recovery from state on
the backward pass. Why not more: BobISA's zero-history *return* presumes a
reversible-by-construction source; our LLVM-derived callees are not, so the
return logs its statically-bounded residual instead. **RC3 `rvm`
(`RSSAVM.java`, `StackFrame.java`):** the explicit frame-stack structure and
two-phase move-based arg/return protocol — adapted, not transcribed (per
CLAUDE.md; Janus-specific direction bits and `allDestroyed` are out of
scope/deferred). **Vieri 1995 p.22:** argument passing as exchange (move,
never copy-and-drop) — both transitions MOVE values between frames.
**Enzyme min-cut (ADR 0002, deferred):** the residual-shrinking tier.
