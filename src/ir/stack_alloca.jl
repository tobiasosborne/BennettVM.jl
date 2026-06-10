"""
    StackAlloca — frame-relative static stack allocation (CW-C3, ADR 0019)

The multi-function fix for static `alloca`s. A C `-O0` translation unit
stores EVERY local in an `alloca` (memory-backed), and the VM's `s.memory`
is GLOBAL across call frames (ADR 0019 §1 — frames carry registers, never
memory). The static-alloca bump cursor RESETS to cell 1 per function
(`_lower_parsed_ir`'s `alloca_cursor`), so without a runtime offset a
callee's stack allocas land at the SAME absolute cells as its caller's — a
nested call clobbers the caller's memory-backed locals, and the caller reads
garbage after the call returns. (The CW-C3 wall: `ht_demo_basic`'s table
pointer `t` was overwritten by a nested `ht_get` / `ht_third_pass`, so the
final `ht_free(t)` got a garbage address.)

    StackAlloca(dest, base)  →  forward
        active_locals(s)[dest] = base + s.stack_top ;  s.pc += 1

`base` is the COMPILE-TIME cell index within THIS function's frame (1, 2, …;
the per-function `alloca_cursor`), exactly the `Int64` the pre-CW-C3 static
alloca baked into its `Define(dest, base, :add, 0)`. `s.stack_top` (the
`IState` field; see `src/ir/IState.jl`) is the RUNTIME call-stack bump
offset: `CallEnter` advances it by the CALLER's frame size before the
callee's allocas run, `ReturnExit` retracts the same amount, so each live
activation occupies a DISJOINT region of the stack segment `[0, ARENA_BASE)`
and `stack_top` round-trips `0 → … → 0`. A SINGLE-function program never
calls, so `stack_top` stays 0 throughout and `dest = base + 0 == base` —
BYTE-IDENTICAL to the pre-CW-C3 absolute-address behaviour (no churn to the
collatz / arena / single-function tests). This is the runtime-allocator-state
lift `DynAlloca` did for `heap_top` (`src/ir/alloca.jl`), applied to the
call-stack cursor for STATIC allocas.

# Why a dedicated instruction, not the old `Define(dest, base, :add, 0)`

The pre-CW-C3 static alloca lowered to a compile-time `Define` (a pure
constant create). To become frame-relative the materialised address must
READ `s.stack_top` at FORWARD time — a runtime read the compile-time
`Define` cannot express. `StackAlloca` is that runtime-relative create. It
is otherwise semantically identical to the static-alloca `Define`: a
non-injective pointer create reversed by L3 checkpoint-replay.

# is_injective = false (L3-reversed) — inherited, not registered

`StackAlloca` materialises a pointer (a re-definition in a loop could
overwrite a prior `dest` — the cross-iteration crux shared with `Define` /
`MemoryLoad`). The static type-level `is_injective` cannot see runtime
freshness, so the conservative default (`is_injective(::Type{<:Instruction})
= false`, `src/history/Injective.jl`) is exactly right and is INHERITED — no
explicit registration. Likewise `is_l2_capable` defaults to `false`
(`src/history/delta.jl`), so the M6.2/M7.6 push gate records an L3
`CheckpointEntry` around it and `unstep!` reverses it via checkpoint-replay
(`src/history/Replay.jl`), which restores the nearest full `IState` snapshot
(including `stack_top`) and replays forward — never a per-instruction
inverse. This is byte-for-byte the reversal contract the static-alloca
`Define` had. (Static allocas execute exactly ONCE per call — they live in
the entry block, which has no predecessors, so the loop-overwrite case is
not actually reached, but the conservative trait keeps the floor sound if a
future shape ever does re-execute it.)

# Why `inverse` raises

`StackAlloca` reverses EXCLUSIVELY via the L3 checkpoint-replay path, so its
per-instruction `inverse()` is not on any live code path (mirrors `Define`).
Reaching it means `unstep!` tried an L1/L2 path on a `StackAlloca`, which is
a bug — Rule 1: raise descriptively rather than silently no-op (which would
falsely report a successful reverse while the overwritten prior pointer went
unrestored).

# Constructor validation (Rule 1)

`base >= 1` — a stack alloca reserves at least the first frame cell; cell 0
is reserved as the frame's stack-base anchor (the `stack_top + 0` would
alias the cursor origin). The per-function `alloca_cursor` starts at 1
(`_lower_parsed_ir`), so a well-formed lowering never emits `base < 1`; a
value below 1 indicates a malformed lowering, not a runnable program.

# Ref

  * `docs/adr/0019-reversible-calls.md` §1 (frames carry registers, never
    memory; memory is global across frames — the constraint that MAKES the
    per-frame stack offset necessary).
  * `src/ir/IState.jl` (the `stack_top` field — its full rationale, the LIFO
    advance/retract discipline, and the byte-identical-for-single-function
    argument).
  * `src/ir/alloca.jl` — `DynAlloca`, the runtime-offset (`heap_top`) lift
    this file mirrors for `stack_top` (Law 2: same pattern, different cursor).
  * `src/ir/define_instruction.jl` — the static-alloca `Define` create this
    supersedes for the multi-function case; the L3-reversed / raising-inverse
    house style.
  * `src/ir/call_transitions.jl` — `CallEnter` / `ReturnExit`, which
    advance / retract `s.stack_top` by the caller frame size.
  * CLAUDE.md Rule 1 (fail loud), Rule 2 (reuse the DynAlloca/Define
    template), Rule 11 (literate).
"""
struct StackAlloca <: Instruction
    dest::Symbol    # pointer SSA name created — holds the Int64 frame-relative addr
    base::Int64     # compile-time cell index within this function's frame (>= 1)

    function StackAlloca(dest::Symbol, base::Int64)
        base >= 1 ||
            error("StackAlloca: base=", base, " (dest=", dest, ") must be >= 1 ",
                  "— a static stack alloca reserves at least the first frame ",
                  "cell; the per-function alloca_cursor starts at 1, so base < 1 ",
                  "is a malformed lowering (Rule 1 fail-loud).")
        return new(dest, base)
    end
end

"""
    forward(instr::StackAlloca, s::IState) -> IState

Materialise the frame-relative pointer `dest := base + s.stack_top` in the
active register file and bump `pc`. `base` is the compile-time per-frame cell
index; `s.stack_top` is the runtime call-stack offset (0 for the entry frame
/ any single-function program — byte-identical to the pre-CW-C3 absolute
address). The region is NOT zeroed — cells stay absent and read as `0` by the
floor's absent=0 convention (LLVM `alloca`'s uninitialised semantics; the ADR
0014 §D1 zero-init convention), exactly as the static-alloca `Define` did.
"""
function forward(instr::StackAlloca, s::IState)::IState
    active_locals(s)[instr.dest] = instr.base + s.stack_top
    s.pc += 1
    return s
end

"""
    inverse(instr::StackAlloca, s::IState, prev) -> IState

**Always raises.** `StackAlloca` reverses via L3 checkpoint-replay (the
nearest `CheckpointEntry` snapshot + forward replay), NOT a per-instruction
inverse — it is non-injective (a loop re-definition could overwrite a prior
`dest`) so the M6.2/M7.6 push gate caches it as an L3 checkpoint. Reaching
this means `unstep!` dispatched an L1/L2 inverse on a `StackAlloca`, which is
a bug. Mirrors `Define`'s raising inverse (Rule 1: fail loud rather than
silently no-op, which would falsely report a successful reverse).
"""
function inverse(instr::StackAlloca, s::IState, prev)::IState
    error("BennettVM.inverse(::StackAlloca): StackAlloca is non-injective and ",
          "reverses via L3 checkpoint-replay (CheckpointEntry restore + forward ",
          "replay), NOT a per-instruction inverse. Reaching this means unstep! ",
          "tried an L1/L2 path on a StackAlloca — Rule 1 fail-loud. dest=",
          instr.dest, ", base=", instr.base, ", pc=", s.pc, ", stack_top=",
          s.stack_top, ".")
end
