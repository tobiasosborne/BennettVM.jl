"""
    CallEnter / ReturnExit (CW-B2, ADR 0019 §3–§4)

The reversible call/return transition pair. Where `CallInstruction`
(`src/ir/call_instruction.jl`, M2.14) was a pc-only stub that punted the
actual subroutine invocation to "M3.x", these two instructions ARE that
invocation, built on the `Frame` stack that CW-B2 chunk 1 lifted into
`IState` (`src/ir/call_frames.jl`, `src/ir/IState.jl`). ADR 0019 §8
SUPERSEDES `CallInstruction` with this pair.

# Why two instructions, not one

A reversible call is asymmetric in its history cost (ADR 0019 §3–§4):

  * **`CallEnter` costs NO history (L1-injective).** Information is
    conserved by construction: the return site lives in `Frame.link`
    (BobISA's saved branch register, Thomsen–Axelsen–Glück 2012 §3.2),
    the args are COPIED into the callee's params (the caller KEEPS its
    own bindings — CW-C3, ADR 0019 Amendment A: an LLVM SSA arg is
    multi-use, so the call side copies rather than moves), and nothing
    is erased ⇒ nothing is logged. The backward pass crosses it via the
    M4.3 checkpoint-replay path — replay re-executes
    `forward(CallEnter, …)`, which reconstructs the frame (ADR 0019 §3
    normative dispatch note).
  * **`ReturnExit` costs ONE L2 delta, UNCONDITIONALLY.** Our callees are
    lowered from irreversible LLVM IR and arrive with DEAD TEMPORARIES
    live at `End` (ADR 0019 §"the constraint that drives everything"): a
    frame-pop that did not log them would be un-invertible, because the
    backward pass that re-pushes the frame would lack exactly the scratch
    the callee body's reversal needs. So the return logs its
    statically-bounded RESIDUAL (the live-but-not-returned locals). The
    delta is also the BACKWARD-DISPATCH BREADCRUMB (ADR 0019 §4 property
    2): under a flat pc, the instruction before the post-call `link` is
    the `CallEnter` itself, so naive `pc-1` stepping would re-enter the
    call; the history entry routes the backward pass into the callee's
    `End` instead. This is why it pushes even when the residual is empty.

# Why `CallEnter`'s real work lives in the interpreter, not `forward`

`forward(instr, s::IState)` cannot see the `VMProgram` (no `prog`
argument), but resolving the callee's `entry_label` → starting pc and its
formal `params` requires the function table + `LabelTable`. So `CallEnter`
follows the `UnconditionalExit` / `ConditionalExit` precedent
(`_handle_cross_block_dispatch!`): `forward(::CallEnter, s)` is a minimal
pc-bumping placeholder, and the substantive arg-COPY + frame-push +
param-bind + pc-set (args are COPIED, not moved — CW-C3, ADR 0019
Amendment A; the caller keeps its multi-use SSA args) runs in
`_handle_call_dispatch!` (`src/interpreter/Interpreter.jl`),
which DOES have `prog`. `ReturnExit`, by contrast, needs NOTHING from
`prog` (its `returns` live on the instruction, its `targets` / `link` live
on the frame being popped), so its full semantics live in
`forward(::ReturnExit, s)` directly.

# The `end_pc` payload field (hostile-review B1)

`ReturnExit.inverse` must re-enter the callee at its `End` marker's
flat-stream address. Neither the `inverse` signature nor `IState` carries
`prog` to look that address up, and `pc-1` is wrong (it points at the
`CallEnter`, per the breadcrumb argument above). So the L2 payload carries
`end_pc = s.pc` captured at predelta time — interpreter step (3a) fires
BEFORE `forward` moves pc, so `s.pc` there IS the `ReturnExit` marker's own
address. `inverse` restores `s.pc = p.end_pc`.

Ref: docs/adr/0019-reversible-calls.md §3 (CallEnter, zero-history),
     §4 (ReturnExit, unconditional L2 residual delta; the end_pc field),
     §6 (fail-loud modes a–f), §8 (supersession of CallInstruction).
Ref: references/reversible-isa/axelsen-yokoyama-2011-bobisa.pdf §3.2
     (link register; call site recovered from state on the backward pass).
Ref: references/reversible-isa/vieri-1995-pendulum-ms.pdf p.22
     (the MOVE — read-and-drop, never copy — discipline). Under CW-C3
     (ADR 0019 Amendment A) this discipline applies to the RETURN side
     ONLY: an LLVM SSA call arg is multi-use (the caller reads it again
     after the call), so the CALL side COPIES the args into the callee
     rather than moving them; the return still MOVEs its values out.
"""

# ===========================================================================
# CallEnter — zero-history call transition (ADR 0019 §3).
# ===========================================================================

"""
    CallEnter(callee, args, targets)

A reversible call to function `callee`. `args` are caller-frame SSA names
whose values are COPIED into the callee's params — the caller KEEPS its
bindings (CW-C3, ADR 0019 Amendment A: an LLVM SSA arg is multi-use, so
the call side copies rather than the Vieri p.22 MOVE, which now governs
the RETURN side only); `targets` are caller-frame SSA names where the
callee's return values will land on `ReturnExit` (OVERWRITING any live
prior value, whose old binding is captured in the L2 `target_olds`
payload). `targets` is carried HERE (not only on the matching
`ReturnExit`) because the `ReturnExit` reads it off the suspended frame —
`CallEnter` is what writes `Frame.targets` at push time.

Constructor validation (Rule 1; ADR 0019 §6): no duplicate args, no
duplicate targets, no symbol in BOTH (an SSA name cannot be simultaneously
moved-out and landed-into by one logical call), and the callee name cannot
shadow an arg/target (dispatch ambiguity). Inherits the `CallInstruction`
checks (`src/ir/call_instruction.jl`), the instruction it supersedes.
"""
struct CallEnter <: Instruction
    callee::Symbol               # function name — resolved in VMProgram.functions
    args::Vector{Symbol}         # caller SSA names COPIED into callee params (caller keeps them — CW-C3)
    targets::Vector{Symbol}      # caller SSA names that receive returns at ReturnExit

    function CallEnter(callee::Symbol, args::Vector{Symbol},
                       targets::Vector{Symbol})
        allunique(args) ||
            error("CallEnter: duplicate arg names in ", args,
                  " (an SSA name cannot be moved into a callee twice).")
        allunique(targets) ||
            error("CallEnter: duplicate target names in ", targets,
                  " (an SSA name cannot receive two returns).")
        for t in targets
            t in args && error("CallEnter: symbol ", t, " appears in BOTH ",
                "args ", args, " and targets ", targets,
                " — cannot be simultaneously moved-out and landed-into.")
        end
        (callee in args || callee in targets) &&
            error("CallEnter: callee :", callee, " shadows an arg/target ",
                  "(dispatch ambiguity); lowering must rename.")
        return new(callee, args, targets)
    end
end

"""
    forward(instr::CallEnter, s::IState) -> IState

Minimal pc-bumping placeholder. The substantive call semantics (COPY args
into the callee — the caller keeps its multi-use SSA args, CW-C3 / ADR 0019
Amendment A — push the callee frame, bind params, jump to the callee entry)
run in
`_handle_call_dispatch!` (`src/interpreter/Interpreter.jl`), which has the
`VMProgram` this layer lacks — the `UnconditionalExit` precedent. Reaching
the un-overwritten pc bump only happens in a unit test that drives
`forward(::CallEnter, …)` directly (no interpreter hook); the interpreter
ALWAYS calls `_handle_call_dispatch!` immediately after, overwriting pc.
"""
function forward(instr::CallEnter, s::IState)::IState
    s.pc += 1
    return s
end

"""
    inverse(instr::CallEnter, s::IState, prev) -> IState

The SEMANTIC inverse of `CallEnter` (ADR 0019 §3). NOT reached on the
history-driven backward path: `CallEnter` pushes no history, so `unstep!`
crosses it via M4.3 checkpoint-replay (which re-runs `forward` +
`_handle_call_dispatch!`, NOT this method). Raises (Rule 1): a direct-
inverse call would have to reconstruct the caller frame from the callee's
restored params, which needs the function table this signature lacks. The
direct-inverse backward-dispatch extension (the function-entry special
case) is bead-`xtb` territory, deferred per ADR 0019 §3.
"""
function inverse(instr::CallEnter, s::IState, prev)::IState
    error("BennettVM.inverse(::CallEnter): CallEnter is zero-history and is ",
          "reversed via M4.3 checkpoint-replay (which re-runs forward + ",
          "_handle_call_dispatch!), NOT a direct per-step inverse (ADR 0019 ",
          "§3 normative dispatch note). Reaching this means unstep! dispatched ",
          "a direct inverse on a CallEnter — Rule 1 fail-loud. State: pc=",
          s.pc, ", depth=", length(s.frames), ".")
end

# ===========================================================================
# ReturnExit — unconditional L2 residual-frame delta (ADR 0019 §4).
# ===========================================================================

"""
    ReturnExit(fname, returns, targets)

The callee-`End` transition at frame depth > 1 (at depth 1 the routine's
`End` remains the halt marker — ADR 0019 §4). `fname` is the callee name
(diagnostics + a frame-`fname` cross-check); `returns` are the callee SSA
names whose values flow out; `targets` are the caller SSA names where they
land. `targets` is denormalised onto the instruction (it also lives on the
suspended `Frame`) so the inverse can un-land WITHOUT consulting the frame
it is about to re-push.

Constructor validation (Rule 1; ADR 0019 §6c): returns↔targets arity must
match, and neither list may contain duplicates.
"""
struct ReturnExit <: Instruction
    fname::Symbol                # callee name (diagnostics + frame cross-check)
    returns::Vector{Symbol}      # callee SSA names flowing out
    targets::Vector{Symbol}      # caller SSA names that receive them

    function ReturnExit(fname::Symbol, returns::Vector{Symbol},
                        targets::Vector{Symbol})
        length(returns) == length(targets) ||
            error("ReturnExit: returns/targets arity mismatch — returns=",
                  returns, " (", length(returns), ") vs targets=", targets,
                  " (", length(targets), "). ADR 0019 §6c.")
        allunique(returns) ||
            error("ReturnExit: duplicate return names in ", returns, ".")
        allunique(targets) ||
            error("ReturnExit: duplicate target names in ", targets, ".")
        return new(fname, returns, targets)
    end
end

"""
    predelta_payload(instr::ReturnExit, s::IState) -> NamedTuple

PRE-`forward` L2 capture (the `IntrinsicMalloc` / `MemoryStore` template).
Captures, BEFORE `forward` pops the frame and moves pc:

  * `residual` — every active local NOT in `returns`: the dead-temporary
    scratch the frame-pop would otherwise destroy (ADR 0019 §4 property 1).
  * `fname` — the popped activation's name (cross-check on inverse).
  * `end_pc` — `s.pc`, the `ReturnExit` marker's own flat-stream address
    (hostile-review B1): the inverse re-enters the callee HERE, and neither
    the inverse signature nor `IState` carries `prog` to recompute it.

Fail-loud (ADR 0019 §6d): depth must be > 1 — a `ReturnExit` at the bottom
(`:__entry`) frame is a frame-stack underflow, NOT a halt (the routine's
own `End` at depth 1 is `EndInstruction`, dispatched as the halt marker).
"""
function predelta_payload(instr::ReturnExit, s::IState)
    length(s.frames) > 1 ||
        error("ReturnExit.predelta_payload: frame-stack depth is ",
              length(s.frames), " (the bottom :__entry frame) — a ReturnExit ",
              "at depth 1 is an underflow, not a return. The entry routine's ",
              "End is dispatched as the halt marker (EndInstruction), never as ",
              "a ReturnExit. ADR 0019 §6d; Rule 1 fail-loud.")
    fr = s.frames[end]
    instr.fname === fr.fname ||
        error("ReturnExit.predelta_payload: instruction fname :", instr.fname,
              " does not match active frame fname :", fr.fname,
              " — corrupted call stack (ADR 0019 §6; Rule 1 fail-loud).")
    residual = Tuple{Symbol,Int64}[(k, v) for (k, v) in active_locals(s)
                                   if !(k in instr.returns)]
    # CW-C3: capture the CALLER's PRE-OVERWRITE target values. `forward` lands the
    # returns into the caller by OVERWRITE (a loop-reused call target like
    # `%call8` is redefined each iteration), so the caller's PRIOR value of each
    # target — if any — is destroyed and the L2 inverse must restore it rather
    # than blindly delete. At predelta time the callee is still active, so the
    # caller is `s.frames[end-1]`; record `(t, old)` for each target present
    # there, so the inverse restores the prior binding (the cross-iteration
    # overwrite recovery) and deletes only the targets that were genuinely fresh.
    caller_locals = s.frames[end - 1].locals
    target_olds = Tuple{Symbol,Int64}[(t, caller_locals[t]) for t in instr.targets
                                      if haskey(caller_locals, t)]
    # CW-C3: capture the popped frame's `stack_delta` (the CallEnter advance) so
    # the inverse re-pushes the frame with the SAME delta and re-advances
    # `stack_top` exactly — `forward` retracts it, the inverse restores it, so
    # `stack_top` round-trips. Captured PRE-`forward` (the frame is still on the
    # stack here) for the same reason `end_pc` is (hostile-review B1).
    return (residual = residual, fname = fr.fname, end_pc = s.pc,
            stack_delta = fr.stack_delta, target_olds = target_olds)
end

"""
    forward(instr::ReturnExit, s::IState) -> IState

Read the return values, POP the activation, MOVE the returns into the
caller frame under the popped frame's `targets`, and set pc to the popped
frame's `link` (the caller's return site; BobISA). Fully `prog`-free: the
returns are on the instruction, the targets / link are on the frame. The
return side still MOVEs (Vieri p.22) — it is the CALL side that COPIES
(CW-C3, ADR 0019 Amendment A).

A target already live in the caller is OVERWRITTEN, not rejected (CW-C3,
ADR 0019 Amendment A): C `-O0` redefines a call-result SSA name every loop
iteration, so the old single-assignment guard is GONE; the overwritten
prior value is captured in the L2 `target_olds` payload and restored by the
inverse. Fail-loud (ADR 0019 §6) reduces to the depth-underflow guard (>1).
"""
function forward(instr::ReturnExit, s::IState)::IState
    length(s.frames) > 1 ||
        error("ReturnExit.forward: frame-stack depth is ", length(s.frames),
              " (the bottom :__entry frame) — underflow, not a return ",
              "(ADR 0019 §6d; Rule 1 fail-loud).")
    retv = Int64[active_locals(s)[r] for r in instr.returns]
    fr = pop!(s.frames)
    # CW-C3: RETRACT the call-stack cursor by exactly the advance CallEnter made
    # entering this activation (recorded on the popped frame). This restores
    # `stack_top` to the caller's value, so the caller's static allocas remain at
    # the cells they occupied before the call, and a SIBLING call after this
    # return reuses the same stack region (LIFO activation records). `stack_top`
    # round-trips because every CallEnter advance has this matching retract.
    s.stack_top -= fr.stack_delta
    caller = active_locals(s)            # now the caller's register file
    # Land the returns by OVERWRITE (CW-C3 — the LLVM-IR adaptation of ADR 0019
    # §6c). The ADR forbade landing over a live target on an SSA
    # single-assignment premise, but C `-O0` REDEFINES a call-result SSA name
    # every loop iteration (`%call8 = call @ht_del(...)` inside a `for` is the
    # same static name, overwritten each turn — exactly the cross-iteration crux
    # `Define.forward` handles by unconditional overwrite). So this overwrites
    # like `Define` rather than erroring. The OLD target value is recovered by L3
    # checkpoint-replay (a finite `checkpoint_interval` captures it — the
    # universal correctness floor, ADR 0012; the residual delta below recovers
    # the CALLEE's scratch, the L3 checkpoint recovers the CALLER's overwritten
    # target). A program whose call targets are single-use (the CW-B factorial /
    # two-level tests) overwrites nothing, so the L2-only (K=typemax) round-trip
    # is unaffected; only loop-reused targets need L3, which the C-track e2e runs
    # with. Shrinking this to a live-target guard via liveness is the deferred
    # optimisation tier (ADR 0002), never a correctness gate.
    for (t, v) in zip(fr.targets, retv)
        caller[t] = v
    end
    s.pc = fr.link
    return s
end

"""
    inverse(instr::ReturnExit, s::IState, p::NamedTuple) -> IState

The L2 reverse (ADR 0019 §4): un-land the return values from the caller's
`targets` (read them back, delete them), RE-PUSH the callee activation with
`link = s.pc` (the post-forward caller pc, which forward had set FROM the
frame's link — so re-pushing with the current pc restores it exactly), its
register file reconstructed as `returns ∪ residual`, and re-enter the
callee at `p.end_pc` (the `ReturnExit` marker — from the payload, B1).

Fail-loud (ADR 0019 §6e): each `targets` value must be present in the
caller (a corrupted landing otherwise).
"""
function inverse(instr::ReturnExit, s::IState, p::NamedTuple)::IState
    caller = active_locals(s)
    retv = Int64[]
    for t in instr.targets
        haskey(caller, t) ||
            error("ReturnExit.inverse: target :", t, " is absent from the ",
                  "caller frame — corrupted return landing (ADR 0019 §6e; ",
                  "Rule 1 fail-loud).")
        push!(retv, caller[t])
        delete!(caller, t)
    end
    # CW-C3: RESTORE the caller's PRE-OVERWRITE target values. `forward` lands
    # returns by overwrite (a loop-reused target), so un-landing must put back
    # the PRIOR binding the overwrite destroyed, not merely delete the target.
    # `target_olds` (captured by predelta from the caller frame) holds `(t, old)`
    # for exactly the targets that were live before the landing; the `delete!`
    # above already removed every target, so re-inserting the recorded olds
    # restores the prior bindings and leaves the genuinely-fresh targets deleted.
    for (t, old) in p.target_olds
        caller[t] = old
    end
    locals = Dict{Symbol,Int64}()
    for (r, v) in zip(instr.returns, retv)
        locals[r] = v
    end
    for (k, v) in p.residual
        locals[k] = v
    end
    # CW-C3: RE-ADVANCE the call-stack cursor by the captured `stack_delta`
    # (the exact inverse of `forward`'s `stack_top -= fr.stack_delta`), and
    # re-push the frame carrying that same delta so a subsequent backward step
    # across the matching CallEnter (L3 replay) sees a consistent stack. This
    # restores `stack_top` to the value it held inside the callee — exactly what
    # the callee's StackAlloca pointers were resolved against.
    s.stack_top += p.stack_delta
    push!(s.frames, Frame(s.pc, instr.targets, locals, p.fname, p.stack_delta))
    s.pc = p.end_pc
    return s
end

"""
    inverse(instr::ReturnExit, s::IState, prev) -> IState

Raising L3-prev catch-all (the never-taken path; mirrors `IntrinsicMalloc`
/ `DynAlloca`, Rule 1). `ReturnExit` reverses EXCLUSIVELY via its L2
NamedTuple inverse above — it always pushes a `DeltaEntry` (ADR 0019 §4),
so `unstep!`'s M7.4 fast-path always dispatches the `NamedTuple` method.
Reaching this means the `prev::Any` inverse was dispatched on a
`ReturnExit`, which the unconditional-push design makes impossible.
"""
inverse(instr::ReturnExit, s::IState, prev)::IState =
    error("ReturnExit reverses via its L2 (residual, fname, end_pc) delta, ",
          "not the L3-prev path (ADR 0019 §4 — it pushes unconditionally). ",
          "Reaching this means unstep! dispatched the prev::Any inverse on a ",
          "ReturnExit — Rule 1 fail-loud. State: pc=", s.pc, ".")
