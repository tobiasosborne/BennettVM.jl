# test/reference/collatz.jl — golden-master oracle + lowering helper for
# the collatz vertical slice. M_UNBOUNDED.1 (`bennettvm-c39`, ADR 0012).
#
# # Why this file exists
#
# PRD v4 §3.14 binds the golden-master co-location rule: every Phase-2
# test program factory MUST sit beside a reference irreversible Julia
# oracle in the same file (or a sibling under `test/reference/`), and
# forward execution of the lowered VM MUST agree with the oracle
# bit-for-bit on the same inputs. `collatz_steps(::Int8)` is PRD v4
# §3.6.2 Case D — the unbounded `while` the circuit backend cannot
# compile and the load-bearing SC9 motivating case (PRD v4 §6).
#
# This file co-locates two artifacts that must move together:
#
#   1. `collatz_steps(x::Int8) -> Int8` — the irreversible Julia oracle,
#      copied VERBATIM from `test/test_handoff_smoke.jl:76-87` so the two
#      sites compute identical LLVM IR (and therefore identical ParsedIR)
#      for identical input. The `steps < Int8(20)` self-cap keeps
#      Bennett.jl's `max_loop_iterations=20` circuit lowering byte-exact;
#      BennettVM lowers the *symbolic* loop, so the cap is semantically
#      present but only fires for trajectories that would otherwise
#      exceed 20 steps.
#
#   2. `collatz_vm() -> VMProgram` — the lowering helper: pull the
#      `collatz_steps` ParsedIR via Bennett.jl's exported frontend and
#      run it through the real `lower_vm` (M_UNBOUNDED.1). NOT hand-built
#      (contrast `countdown_program`, M3.8, which predates the real
#      lower_vm) — this is the first reference factory produced by the
#      ingest pass itself, so the factory IS part of what's under test.
#
# # Why no include-time self-check `@assert` here
#
# `countdown.jl` runs an include-time golden-master `@assert` because it
# is `include`d by many consumers. `collatz.jl` has a single consumer
# (`test_collatz_forward.jl`) which frames the same assertions inside a
# `@testset`; duplicating them at include time would just slow every
# load with a redundant `lower_vm` digest print. The forward gate lives
# in the testset, where Rule 4 (assert known-correct values) is met.
#
# # Width caveat (ADR 0012 R1)
#
# `IState.locals` are `Int64`; collatz is i8. The lowering does not mask
# to width, so the VM and the i8 oracle agree only for inputs whose
# trajectory stays in i8 range. `test_collatz_forward.jl` picks such
# inputs (x ∈ {1, 7, 9}); the round-trip invariant is width-independent.
#
# # Ref
#
#   * bennettvm_prd.md (PRD v4) §3.14 (golden-master co-location),
#     §3.6.2 Case D, §6 SC9.
#   * docs/adr/0012-collatz-lowering.md — the lowering design.
#   * test/reference/countdown.jl — the co-location pattern this mirrors.
#   * test/test_handoff_smoke.jl:76-87 — the verbatim oracle source.
#   * CLAUDE.md Rule 4 (known-correct values), Rule 11 (literate),
#     Phase-0 gating P0.5 (golden master required).

using BennettVM
import Bennett

# Re-include guard. Keyed on `collatz_vm` (the factory UNIQUE to this
# reference file), NOT on `collatz_steps`: `test_handoff_smoke.jl`
# defines its own top-level `collatz_steps` in `Main` (a verbatim copy
# of the same oracle), so a `collatz_steps`-keyed guard would
# false-positive under `runtests.jl` and skip defining `collatz_vm` /
# `collatz_parsed`. Keying on `collatz_vm` makes the guard track THIS
# file's load state precisely. We deliberately RE-define `collatz_steps`
# here (it is `===`-identical to the smoke's copy, so the "method
# overwritten" warning is benign and the oracle stays the single source
# of truth for `collatz_vm`'s golden master).
if !@isdefined(collatz_vm)

# ---------------------------------------------------------------------
# 1. The irreversible Julia oracle (verbatim from test_handoff_smoke.jl).
# ---------------------------------------------------------------------

"""
    collatz_steps(x::Int8) -> Int8

The irreversible Julia reference for the Collatz step-count. Counts the
hailstone steps from `x` to 1, capped at 20 steps. Even → halve, odd →
`3x+1`. The golden master for BennettVM's lowered `collatz_vm`
VMProgram. Copied verbatim from `test/test_handoff_smoke.jl` so the
extracted ParsedIR is identical between the two sites.
"""
function collatz_steps(x::Int8)
    steps = Int8(0); val = x
    while val > Int8(1) && steps < Int8(20)
        if val % Int8(2) == Int8(0)
            val = val >> Int8(1)
        else
            val = Int8(3) * val + Int8(1)
        end
        steps += Int8(1)
    end
    return steps
end

# ---------------------------------------------------------------------
# 2. The lowering helper: ParsedIR → VMProgram via the real lower_vm.
# ---------------------------------------------------------------------

"""
    collatz_parsed() -> Bennett.ParsedIR

Pull the `collatz_steps(::Int8)` `ParsedIR` via Bennett.jl's exported
frontend (`extract_parsed_ir`). Kept separate from `collatz_vm` so a
test can inspect the raw ParsedIR (block count, φ shape) without
re-running the lowering.
"""
collatz_parsed() = Bennett.extract_parsed_ir(collatz_steps, Tuple{Int8})

"""
    collatz_vm() -> VMProgram

Lower `collatz_steps`'s ParsedIR to a runnable VMProgram via the real
`lower_vm` (M_UNBOUNDED.1, ADR 0012), naming the routine `:collatz`.
The returned program's entry block is `:top`; its single formal
parameter is `Symbol("x::Int8")` (the i8 argument's SSA name).
"""
collatz_vm() = lower_vm(collatz_parsed(); opts=:collatz)

end  # if !@isdefined(collatz_vm) — re-include guard.
