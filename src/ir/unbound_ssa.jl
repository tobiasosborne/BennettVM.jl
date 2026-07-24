# src/ir/unbound_ssa.jl — the Rule-1 diagnostic for an unbound SSA read
# (bead `bennettvm-35yn`).
#
# # Why this file exists
#
# Every operand read in the VM funnels through `_resolve`
# (`src/ir/arithmetic_assignment.jl`), which is one `Dict{Symbol,Int64}`
# lookup against the active frame's register file. When the name is not
# bound, Julia's own `getindex` raised
#
#     KeyError: key :__v327 not found
#
# and nothing else. That message names the symbol and NOTHING about where
# the read happened: not the instruction, not the pc, not which activation
# of which function, not what *was* bound. Debugging `bennettvm-rnhv` — a
# φ-edge that destroyed a still-live value 46 steps before the read that
# needed it — cost an instrumented interpreter walk to recover facts this
# message should have carried. Rule 1 says "crashes WITH CONTEXT, not
# corrupted state"; a bare `KeyError` is only half of that.
#
# # Why it matters MORE after `bennettvm-rnhv` / ADR 0022
#
# ADR 0022 relaxed the cross-block args→params transfer from destructive
# MOVE to non-destructive BIND. The one genuine risk that carries is that a
# *malformed* lowering — one that genuinely fails to define a name on some
# path — can now find a **stale** binding left over from an earlier block
# and read it silently, instead of hitting a loud `KeyError`. The
# mitigations are (a) making the failure that DOES fire maximally
# informative, which is this file, and (b) the deferred SSA-dominance
# validator (ADR 0022 §Risks). This file is (a).
#
# # What the message carries
#
#   * the SSA symbol that was not bound;
#   * the instruction being executed, when the caller supplied it (the
#     `ctx` argument — threaded from the arithmetic carriers, `Define` and
#     `ArithmeticAssignment`, which is where operand reads overwhelmingly
#     land);
#   * the pc;
#   * the frame stack, innermost last, as `fname` plus a pc per frame —
#     the live `s.pc` for the innermost activation and the saved return
#     address (`Frame.link`) for each caller;
#   * how many names ARE bound in the active frame, plus a sorted,
#     truncated sample, so a near-miss (a drifted `__vN` index, a name
#     defined in the *caller's* frame) is visible at a glance.
#
# The `__vN` SSA names are per-body and DO collide across bodies, so the
# frame stack is not decoration: without it a name in the report cannot be
# attributed to a body at all.
#
# # Ref
#
#   * CLAUDE.md Rule 1 — fail fast, fail loud, WITH context.
#   * `docs/adr/0022-phi-edge-binding.md` §Risks — the stale-read risk this
#     mitigates.
#   * `src/ir/call_frames.jl` — `Frame` (`fname`, `link`) and
#     `active_locals`.

"""
    _unbound_ssa_error(x::Symbol, s::IState, ctx)

Raise a context-bearing `ErrorException` for a read of the unbound SSA name
`x` against `s`'s active register file. `ctx` is the `Instruction` being
executed when the read happened, or `nothing` when the calling site does not
have it in scope (in which case the pc identifies it — `_instruction_at(prog,
pc)`).

Never returns; declared `Union{}` so callers stay type-stable. Kept out of
`_resolve`'s body deliberately: `_resolve` is on the hottest path in the
interpreter and must remain a single dict probe plus a branch, with all the
message-building work behind a `@noinline` call that the happy path never
enters.

Ref: CLAUDE.md Rule 1; `docs/adr/0022-phi-edge-binding.md` §Risks.
"""
@noinline function _unbound_ssa_error(x::Symbol, s::IState, ctx)::Union{}
    L = active_locals(s)
    bound = sort!(collect(keys(L)); by = String)
    shown = length(bound) <= 24 ? bound : vcat(bound[1:24], [Symbol("…")])
    stack = String[]
    for (i, f) in enumerate(s.frames)
        # Innermost frame's live pc is `s.pc`; an outer frame's pc is the
        # return address it is parked on (`Frame.link`, BobISA's branch
        # register — see `src/ir/call_frames.jl`).
        p = i == length(s.frames) ? s.pc : f.link
        push!(stack, string(f.fname, "@pc=", p))
    end
    error("unbound SSA name :", x, " — the VM read a register that is not ",
          "bound in the active frame.\n",
          "  instruction : ", ctx === nothing ?
              "(not supplied by this call site; recover it with " *
              "`_instruction_at(prog, $(s.pc))`)" : repr(ctx), "\n",
          "  pc          : ", s.pc, "\n",
          "  frames      : ", join(stack, " > "),
          "   (outermost first)\n",
          "  bound here  : ", length(bound), " name(s) — ", shown, "\n",
          "This is malformed IR or a lowering bug, not a runtime condition: ",
          "every operand of an executed instruction must have been defined ",
          "on the path that reached it. Common causes: a φ-incoming that was ",
          "never bound on the taken edge; an `args`/`params` list that omits ",
          "a value the destination block reads; a name defined in a DIFFERENT ",
          "activation (`__vN` names are per-body and collide across bodies — ",
          "check the frame stack above before assuming the definition is ",
          "missing). See CLAUDE.md Rule 1 and ",
          "docs/adr/0022-phi-edge-binding.md.")
end
