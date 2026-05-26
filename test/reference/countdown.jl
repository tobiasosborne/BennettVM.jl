# test/reference/countdown.jl — golden-master irreversible reference
# for the M3.8 countdown forward-integration test.
#
# Per CLAUDE.md Rule 4 ("'Runs without errors' is not a passing test")
# and Phase-0 spike rule P0.5 ("Golden master required — every test
# program has a reference *irreversible* Julia function that computes
# the same result"), the M3.8 capstone (`bennettvm-mqh`) compares the
# BennettVM forward interpreter's output on a hand-built `countdown(N)`
# VMProgram against the result of this function evaluated on the same
# N. Forward execution must agree bit-for-bit.
#
# Why a separate file rather than inlining the reference in the test:
# subsequent integration milestones (M3.x and beyond) will accrete
# more reference functions (frtN, matrix_sum, collatz_steps — the
# PRD v4 §3.6.2 motivating cases), and the convention of one-reference-
# per-file under `test/reference/` keeps each golden master read-only
# and citable from the test that consumes it. Inlining the reference
# in the test file would (a) tangle the oracle with the test logic,
# making it harder to verify the oracle itself is correct, and
# (b) prevent the same reference being reused across multiple tests
# (e.g. M4's round-trip test will reuse `countdown_ref`).
#
# Ref:
#   * CLAUDE.md Rule 4 — every test asserts against a known-correct value.
#   * CLAUDE.md Phase-0 gating P0.5 — golden-master required.
#   * bd `bennettvm-mqh` (M3.8) — countdown forward integration.

"""
    countdown_ref(n::Int64) -> Int64

The irreversible Julia reference for `countdown(n)`. For non-negative
`n`, returns `n` itself (the number of decrement steps required to
reach 0 starting from `n`). Used as the golden master for BennettVM's
hand-built `countdown` VMProgram in M3.8.

The implementation is a plain `while` loop — irreversible by
construction (the loop counter `n` is destructively decremented, and
`steps` is destructively incremented). The BennettVM equivalent is a
straight-line unrolling into `n` decrement blocks (M3.8 builds 5
basic blocks for `n=3`; entry + 3 decrement blocks + done), each of
which performs its decrement reversibly via `ArithmeticAssignment`
with modop `:sub`. The two computations must produce the same
`steps` value despite differing radically in their internal
mechanics; agreement is the load-bearing assertion.

# Why `Int64` and not `Int` (the platform default)

`IState.locals` is declared `Dict{Symbol,Int64}` (src/ir/IState.jl
M2.1), so every value the BennettVM interpreter produces is `Int64`.
Typing the reference function the same way prevents a Julia-on-32-bit
platform surprise where `Int === Int32` and the reference would
compare unequal to the BennettVM output even though both computed
"3".

# Ref

  * CLAUDE.md Rule 4 + Phase-0 gating P0.5 — known-correct reference.
  * `src/ir/IState.jl` (M2.1) — `Dict{Symbol,Int64}` element-type
    constraint motivates the `Int64` signature here.
  * bd `bennettvm-mqh` (M3.8) — the test that consumes this oracle.
"""
function countdown_ref(n::Int64)
    steps = Int64(0)
    while n > 0
        n -= 1
        steps += 1
    end
    return steps
end
