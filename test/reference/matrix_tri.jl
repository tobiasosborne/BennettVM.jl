# test/reference/matrix_tri.jl — golden-master oracle + lowering helper
# for the TRIANGULAR nested-loop vertical slice (bead `bennettvm-e4l`,
# the IRCast end-to-end gate of `bennettvm-hek`; ADR 0012 / ADR 0013).
#
# # Why this file exists
#
# PRD v4 §3.14 binds the golden-master co-location rule: every Phase-2
# test program factory MUST sit beside a reference irreversible Julia
# oracle in the same file (or a sibling under `test/reference/`), and
# forward execution of the lowered VM MUST agree with the oracle
# bit-for-bit on the same inputs. `matrix_tri_while(::Int8)` is the
# *triangular* nested-loop shape: a doubly-nested `while` whose INNER
# trip count VARIES with the outer index (`j` counts down from `i`),
# unlike `matrix_sum_while` whose inner loop runs a fixed `n` times. The
# result is the triangular sum `sum_{i=1}^{n} i(i+1)/2` — a runtime-bounded
# loop nest of statically-unknown, *non-rectangular* total trip count that
# the circuit backend (target=:circuit) cannot represent.
#
# # Why this case is the e4l + IRCast gate (not just another nested loop)
#
# matrix_tri is the program that surfaced the within-edge synthetic-constant
# φ-name collision (bead `bennettvm-e4l`). Its `top → L7.preheader` edge
# has SIX φ-param slots, two PAIRS of which receive the SAME constant from
# `top` (value 0 → both `indvars.iv14` and `value_phi18`; value 1 → both
# `indvars.iv10` and `value_phi7`). The pre-fix ingest deduped synthetic
# constant names by VALUE within a predecessor, so the edge's arg list
# repeated a name and `UnconditionalExit`'s `allunique(args)` check
# (correctly) rejected it. The fix (`src/ir/ingest.jl`, ADR 0012 §D5)
# shares constant creates across edges but mints a FRESH counter-based
# name + an extra `Define` for each within-one-edge duplicate, so each
# destructively-bound param slot gets its own create. matrix_tri also
# exercises the IRCast lowering (`bennettvm-hek`): the i8 trip counters
# are sign-extended in the IR, so the program does not lower at all
# without `CastInstruction`. This file is the end-to-end witness for both.
#
# This file co-locates three artifacts that must move together:
#
#   1. `matrix_tri_while(n::Int8) -> Int8` — the irreversible Julia
#      oracle: a doubly-nested `while`. The outer loop runs `i` from
#      `1..n`; for each `i` the inner loop counts `j` DOWN from `i` to
#      `1`, adding `j` to the accumulator `s` each step. The inner loop
#      therefore contributes `i + (i-1) + … + 1 = i(i+1)/2` per outer
#      iteration, so `s = sum_{i=1}^{n} i(i+1)/2` for `n >= 1`, `0` for
#      `n <= 0`. Int8 is the argument width; valid inputs keep the result
#      `<= 127` ⇒ `n ∈ 1..8` (n=8 → 120; n=9 → 165 overflows i8).
#
#   2. `matrix_tri_ref(n) -> Int64` — a SECOND, structurally-independent
#      oracle computing the same value by the closed form
#      `sum_{i=1}^{n} i(i+1)÷2`. It is deliberately NOT the nested loop:
#      the golden master is strongest when the reference does not share
#      the VM's control-flow shape (the loop nest and its closed form must
#      agree). The include-time `@assert` pins `matrix_tri_ref ==
#      matrix_tri_while` for `n ∈ 1..8` so a drift in either oracle fails
#      fast at load (Rule 1, Rule 4).
#
#   3. `matrix_tri_vm() -> VMProgram` — the lowering helper: pull the
#      `matrix_tri_while` ParsedIR via Bennett.jl's exported frontend and
#      run it through the real `lower_vm` (M_UNBOUNDED.1). NOT hand-built
#      — the factory IS part of what is under test, exactly as
#      `matrix_sum_vm` / `collatz_vm` are.
#
# # Hand-checked oracle table (the known-correct values, Rule 4)
#
#   n |  i(i+1)/2 terms       | cumulative s = matrix_tri(n)
#   --+-----------------------+-----------------------------
#   1 | 1                     |   1
#   2 | 1, 3                  |   4
#   3 | 1, 3, 6               |  10
#   4 | 1, 3, 6, 10           |  20
#   5 | 1, 3, 6, 10, 15       |  35
#   6 | 1, 3, 6, 10, 15, 21   |  56
#   7 | …, 28                 |  84
#   8 | …, 36                 | 120
#
# n=9 would add 45 → 165, overflowing Int8 (max 127); valid range is 1..8.
#
# # Width caveat (mirrors ADR 0012 R1 for collatz / matrix_sum)
#
# `IState.locals` are `Int64`; `matrix_tri_while` is i8. The lowering does
# not mask to width, so the VM and the i8 oracle agree only for inputs
# whose accumulator stays in i8 range (result `<= 127`, i.e. `n <= 8`).
# The forward / round-trip gates pick such inputs; the round-trip
# invariant itself is width-independent.
#
# # Ref
#
#   * bennettvm_prd.md (PRD v4) §3.14 (golden-master co-location),
#     §3.6.2 Case C (nested loops), §6 SC9; Phase-0 gating P0.5
#     (golden master required), P0.6 (round-trip is load-bearing).
#   * docs/adr/0012-collatz-lowering.md §D5 — the synthetic-constant
#     φ-incoming lowering the e4l fix corrects (within-edge uniqueness).
#   * docs/adr/0013-*.md §D-5 — the IRCast lowering matrix_tri exercises.
#   * src/ir/ingest.jl — `_phi_const_name` / `_phi_const_dup_name`, the
#     cross-edge-shared vs within-edge-unique constant naming (bead e4l).
#   * test/reference/matrix_sum.jl — the rectangular-nest sibling this
#     mirrors exactly (structure, re-include guard, literate docstring).
#   * test/reference/collatz.jl — the co-location pattern this mirrors.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known-correct values),
#     Rule 11 (literate top-of-file docstrings).

using BennettVM
import Bennett

# Re-include guard. Keyed on `matrix_tri_vm` (the factory UNIQUE to this
# reference file), mirroring `matrix_sum.jl`'s guard. The oracle functions
# `matrix_tri_while` / `matrix_tri_ref` are defined inside the guard so
# they are not re-evaluated on a second include; the include-time
# self-check `@assert` below sits OUTSIDE the guard so it re-fires on
# every include (cheap; the golden-master gate every consumer re-confirms
# at load time — the `matrix_sum.jl` / `countdown.jl` convention).
if !@isdefined(matrix_tri_vm)

# ---------------------------------------------------------------------
# 1. The irreversible Julia oracle (triangular nested-loop form).
# ---------------------------------------------------------------------

"""
    matrix_tri_while(n::Int8) -> Int8

The irreversible Julia reference for the TRIANGULAR nested loop. A
doubly-nested `while`: the outer loop runs `i` from `1..n`, and for each
`i` the inner loop counts `j` DOWN from `i` to `1`, adding `j` to the
accumulator `s` each step. The inner loop contributes `i + (i-1) + … + 1
= i(i+1)/2` per outer iteration, so the returned `s` is the triangular
sum `sum_{i=1}^{n} i(i+1)/2` for `n >= 1` (and `0` for `n <= 0`: the
outer guard `i <= n` is false immediately).

Unlike `matrix_sum_while` (whose inner loop runs a fixed `n` times),
the inner trip count here VARIES with the outer index `i` — a
non-rectangular nest. It is the program that surfaced the within-edge
synthetic-constant φ-name collision (bead `bennettvm-e4l`) and exercises
the IRCast lowering (`bennettvm-hek`). The golden master for BennettVM's
lowered `matrix_tri_vm` VMProgram.

Int8 width keeps the result `<= 127` ⇒ valid inputs `n ∈ 1..8` (n=8 →
120; n=9 → 165 overflows i8).
"""
function matrix_tri_while(n::Int8)
    s = Int8(0); i = Int8(1)
    while i <= n
        j = i
        while j > Int8(0)
            s += j; j -= Int8(1)
        end
        i += Int8(1)
    end
    s
end

# ---------------------------------------------------------------------
# 2. A structurally-independent closed-form oracle.
# ---------------------------------------------------------------------

"""
    matrix_tri_ref(n) -> Int64

A SECOND, structurally-independent irreversible reference for the same
value: the triangular sum `sum_{i=1}^{n} i(i+1)÷2` for `n >= 1`, `0` for
`n <= 0`. Deliberately the closed-form summation (NOT the nested
count-down loop) so the golden master cross-checks two distinct
computations of the same quantity — the non-rectangular `while` nest
(`matrix_tri_while`) and its arithmetic identity. The include-time
self-check pins their agreement for `n ∈ 1..8` (Rule 4). Returns `Int64`
so it compares directly to the `Int64`-valued `result(rs)` entries
(`IState.locals` are `Int64`; cf. `matrix_sum_ref`'s rationale).
"""
matrix_tri_ref(n) = n >= 1 ? sum(Int64(i) * (Int64(i) + 1) ÷ 2 for i in 1:n) : Int64(0)

# ---------------------------------------------------------------------
# 3. The lowering helper: ParsedIR → VMProgram via the real lower_vm.
# ---------------------------------------------------------------------

"""
    matrix_tri_parsed() -> Bennett.ParsedIR

Pull the `matrix_tri_while(::Int8)` `ParsedIR` via Bennett.jl's exported
frontend (`extract_parsed_ir`). Kept separate from `matrix_tri_vm` so a
test can inspect the raw ParsedIR (block count, φ shape, the
within-edge duplicate-constant φ-incomings of `top → L7.preheader`)
without re-running the lowering. Mirrors `matrix_sum_parsed`.
"""
matrix_tri_parsed() = Bennett.extract_parsed_ir(matrix_tri_while, Tuple{Int8})

"""
    matrix_tri_vm() -> VMProgram

Lower `matrix_tri_while`'s ParsedIR to a runnable VMProgram via the real
`lower_vm` (M_UNBOUNDED.1, ADR 0012), naming the routine `:matrix_tri`.
The returned program's entry block is `:top`; its single formal
parameter is `Symbol("n::Int8")` (the i8 argument's SSA name). The
lowered program has 12 blocks (the triangular nested-loop CFG with
critical-edge trampolines) and returns via `Symbol("value_phi1.lcssa")`
— exercising BOTH the inner- and outer-loop bodies under L3
checkpoint-replay reversal, the within-edge synthetic-constant uniqueness
fix (bead `bennettvm-e4l`), and the IRCast lowering (`bennettvm-hek`).
"""
matrix_tri_vm() = lower_vm(matrix_tri_parsed(); opts=:matrix_tri)

end  # if !@isdefined(matrix_tri_vm) — re-include guard.

# ---------------------------------------------------------------------
# 4. Include-time self-check (golden master cross-validation).
#
# Rule 4: assert against a known-correct value, not "didn't throw". Pins
# the two oracles agree on `n ∈ 1..8` (peak result 120, the largest
# i8-safe input). Runs at include-time regardless of how this file is
# loaded (the `matrix_sum.jl` convention): if either oracle drifts, every
# consumer fails fast at include (Rule 1). Re-fires on every include — by
# design, cheap (microseconds), and the golden-master gate the VM gates
# depend on. The hardcoded `_want` table is the hand-checked closed-form
# (the docstring table) — a third, fully independent witness.
# ---------------------------------------------------------------------

let _table = (1 => 1, 2 => 4, 3 => 10, 4 => 20, 5 => 35, 6 => 56, 7 => 84, 8 => 120)
    for (_n, _want) in _table
        _got = Int64(matrix_tri_while(Int8(_n)))
        @assert _got == _want "matrix_tri oracle self-check: matrix_tri_while($_n)=$_got but hand-checked table wants $_want (golden-master mismatch, PRD v4 §3.14, CLAUDE.md Rule 4)"
        _ref = matrix_tri_ref(_n)
        @assert _ref == _want "matrix_tri oracle self-check: matrix_tri_ref($_n)=$_ref but hand-checked table wants $_want (closed-form drift, PRD v4 §3.14, CLAUDE.md Rule 4)"
    end
end
